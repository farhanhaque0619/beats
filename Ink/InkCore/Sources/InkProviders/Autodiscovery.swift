import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InkModel

/// Server settings found for an address.
public struct DiscoveryResult: Hashable, Sendable {
    public var imap: ServerConfig
    public var smtp: ServerConfig
    /// The provider preset these settings belong to, when recognised (custom domains on Google
    /// Workspace map to `.gmail`, so the setup screen can offer the right sign-in options).
    public var preset: ProviderID?
    /// Where the settings came from: `preset`, `ispdb`, `autoconfig`, `well-known`, `mx`,
    /// `ispdb-mx` (the ISPDB entry of the MX host's domain), `guess` or `clientConfig`.
    public var source: String
    /// The provider's name from the config file, if it had one.
    public var providerName: String?

    public init(imap: ServerConfig, smtp: ServerConfig, preset: ProviderID?, source: String, providerName: String? = nil) {
        self.imap = imap
        self.smtp = smtp
        self.preset = preset
        self.source = source
        self.providerName = providerName
    }

    /// True when the settings are only a guess and should be shown for the user to check.
    public var isGuess: Bool { source == "guess" }
}

/// Finds IMAP/SMTP settings for an email address.
///
/// Order: built-in presets (no network), then — fetched in parallel, used in this order —
/// Mozilla's ISPDB, the domain's own `autoconfig.` host, its `.well-known` config, and an MX
/// lookup over DNS-over-HTTPS that recognises custom domains hosted by Google, Microsoft,
/// Fastmail, Zoho, iCloud or Yahoo (falling back to the ISPDB entry for the MX host's domain).
/// When all of that fails it guesses `imap.<domain>` / `smtp.<domain>` with TLS.
/// Only HTTPS is used, plain-text servers are never suggested, and nothing here throws.
public enum Autodiscovery {
    /// Per-request timeout.
    public static var requestTimeout: TimeInterval { 8 }

    /// Settings for `email`, or nil when it isn't a usable address.
    public static func discover(email: String, session: URLSession = .shared) async -> DiscoveryResult? {
        guard let parts = EmailParts(email) else { return nil }
        if let preset = Providers.preset(forEmail: parts.address) {
            return result(for: preset, email: parts.address, source: "preset")
        }
        let urls = lookupURLs(for: parts)

        async let ispdb = fetchConfig(urls.ispdb, email: parts, source: "ispdb", session: session)
        async let autoconfig = fetchConfig(urls.autoconfig, email: parts, source: "autoconfig", session: session)
        async let wellKnown = fetchConfig(urls.wellKnown, email: parts, source: "well-known", session: session)
        async let mxHosts = lookupMX(domain: parts.asciiDomain, session: session)

        if let found = await ispdb { return found }
        if let found = await autoconfig { return found }
        if let found = await wellKnown { return found }
        let hosts = await mxHosts
        if !hosts.isEmpty {
            if let found = result(forMXHosts: hosts, email: parts.address) { return found }
            let base = DomainName.baseDomain(of: hosts[0])
            if base != parts.asciiDomain, let url = ispdbURL(domain: base),
               let found = await fetchConfig(url, email: parts, source: "ispdb-mx", session: session) {
                return found
            }
        }
        return guess(email: parts.address)
    }

    /// Parses a Thunderbird `clientConfig` XML document (ISPDB / autoconfig format), substituting
    /// `%EMAILADDRESS%`, `%EMAILLOCALPART%` and `%EMAILDOMAIN%`. Prefers SSL/TLS over STARTTLS and
    /// ignores plain-text servers. Nil when the document is malformed or lacks a usable IMAP or SMTP server.
    public static func parseClientConfig(_ xml: Data, email: String) -> DiscoveryResult? {
        guard let parts = EmailParts(email), let document = ClientConfigReader.read(xml),
              let servers = choose(document, email: parts) else { return nil }
        let preset = Providers.preset(forServerHost: servers.imap.host)?.id
        return DiscoveryResult(imap: servers.imap, smtp: servers.smtp, preset: preset, source: "clientConfig",
                               providerName: document.displayName)
    }

    /// The settings of a preset for `email`.
    public static func result(for preset: ProviderPreset, email: String, source: String) -> DiscoveryResult {
        let servers = preset.servers(forEmail: email)
        return DiscoveryResult(imap: servers.imap, smtp: servers.smtp, preset: preset.id, source: source, providerName: preset.name)
    }

    /// Settings for a custom domain whose MX hosts (most preferred first) belong to a known provider.
    /// Microsoft 365 domains get `smtp.office365.com`; Zoho domains get that region's `imappro`/`smtppro` hosts.
    public static func result(forMXHosts hosts: [String], email: String) -> DiscoveryResult? {
        guard let parts = EmailParts(email), let preset = Providers.preset(forMXHosts: hosts) else { return nil }
        var result = result(for: preset, email: parts.address, source: "mx")
        let primary = hosts.map(Providers.normalizeHost).first { Providers.preset(forMXHosts: [$0]) != nil } ?? ""
        switch preset.id {
        case .outlook:
            // Microsoft 365 (work/school) tenants submit through smtp.office365.com.
            result.smtp.host = "smtp.office365.com"
            result.smtp.port = 587
            result.smtp.security = .startTLS
            result.providerName = "Microsoft 365"
        case .zoho:
            let region = ZohoRegion.forMXHost(primary) ?? .us
            result.imap.host = "imappro.\(region.hostSuffix)"
            result.smtp.host = "smtppro.\(region.hostSuffix)"
        case .gmail:
            result.providerName = "Google Workspace"
        default:
            break
        }
        return result
    }

    /// `imap.<domain>` on 993 and `smtp.<domain>` on 465, both implicit TLS, with the full
    /// address as the user name. Nil when `email` isn't an address.
    public static func guess(email: String) -> DiscoveryResult? {
        guard let parts = EmailParts(email) else { return nil }
        return DiscoveryResult(
            imap: ServerConfig(host: "imap.\(parts.asciiDomain)", port: 993, security: .tls, username: parts.address),
            smtp: ServerConfig(host: "smtp.\(parts.asciiDomain)", port: 465, security: .tls, username: parts.address),
            preset: nil,
            source: "guess"
        )
    }

    /// MX hosts from a DNS-over-HTTPS JSON answer (Google `dns.google/resolve` or Cloudflare
    /// `application/dns-json`), most preferred first, lowercased, without the trailing dot.
    /// Empty for NXDOMAIN, a null MX (`0 .`) or anything malformed.
    public static func parseMXResponse(_ data: Data) -> [String] {
        guard let object = try? JSONSerialization.jsonObject(with: data),
              let json = object as? [String: Any] else { return [] }
        if let status = (json["Status"] as? NSNumber)?.intValue, status != 0 { return [] }
        guard let answers = json["Answer"] as? [Any] else { return [] }
        var records: [(preference: Int, index: Int, host: String)] = []
        for (index, item) in answers.enumerated() {
            guard let answer = item as? [String: Any],
                  (answer["type"] as? NSNumber)?.intValue == 15,
                  let data = answer["data"] as? String else { continue }
            let fields = data.split(whereSeparator: { $0 == " " || $0 == "\t" })
            guard fields.count == 2, let preference = Int(fields[0]) else { continue }
            let host = Providers.normalizeHost(String(fields[1]))
            guard !host.isEmpty, DomainName.ascii(host) != nil else { continue }
            records.append((preference, index, host))
        }
        records.sort { ($0.preference, $0.index) < ($1.preference, $1.index) }
        var seen = Set<String>()
        return records.map(\.host).filter { seen.insert($0).inserted }
    }

    // MARK: Lookups

    struct LookupURLs {
        var ispdb: URL?
        var autoconfig: URL?
        var wellKnown: URL?
        var dnsGoogle: URL?
        var dnsCloudflare: URL?
    }

    static func lookupURLs(for parts: EmailParts) -> LookupURLs {
        let domain = parts.asciiDomain
        let address = HTTP.percentEncode(parts.localPart + "@" + domain)
        return LookupURLs(
            ispdb: ispdbURL(domain: domain),
            autoconfig: URL(string: "https://autoconfig.\(domain)/mail/config-v1.1.xml?emailaddress=\(address)"),
            wellKnown: URL(string: "https://\(domain)/.well-known/autoconfig/mail/config-v1.1.xml?emailaddress=\(address)"),
            dnsGoogle: URL(string: "https://dns.google/resolve?name=\(domain)&type=MX"),
            dnsCloudflare: URL(string: "https://cloudflare-dns.com/dns-query?name=\(domain)&type=MX")
        )
    }

    static func ispdbURL(domain: String) -> URL? {
        guard let domain = DomainName.ascii(domain) else { return nil }
        return URL(string: "https://autoconfig.thunderbird.net/v1.1/\(domain)")
    }

    /// Fetches and parses a config document; nil on any failure.
    static func fetchConfig(_ url: URL?, email: EmailParts, source: String, session: URLSession) async -> DiscoveryResult? {
        guard let url else { return nil }
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
        request.setValue("application/xml, text/xml;q=0.9, */*;q=0.5", forHTTPHeaderField: "Accept")
        guard let response = try? await HTTP.perform(request, session: session),
              response.status == 200,
              var result = parseClientConfig(response.data, email: email.address) else { return nil }
        result.source = source
        return result
    }

    /// MX hosts for `domain` via Google's DNS-over-HTTPS, then Cloudflare's. Empty on failure.
    static func lookupMX(domain: String, session: URLSession) async -> [String] {
        guard let parts = EmailParts("postmaster@" + domain) else { return [] }
        let urls = lookupURLs(for: parts)
        for url in [urls.dnsGoogle, urls.dnsCloudflare].compactMap({ $0 }) {
            if Task.isCancelled { return [] }
            var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: requestTimeout)
            request.setValue("application/dns-json", forHTTPHeaderField: "Accept")
            guard let response = try? await HTTP.perform(request, session: session, maxBytes: 64 * 1024),
                  response.status == 200 else { continue }
            let hosts = parseMXResponse(response.data)
            if !hosts.isEmpty { return hosts }
            // A valid NOERROR / NXDOMAIN answer with no MX is final; don't ask the second resolver.
            if let object = try? JSONSerialization.jsonObject(with: response.data),
               let json = object as? [String: Any], json["Status"] != nil { return [] }
        }
        return []
    }
}
