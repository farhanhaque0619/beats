import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif
import InkModel

/// One server entry from a Thunderbird `clientConfig` document, before choosing.
struct ClientConfigServer: Equatable {
    var type: String
    var hostname: String?
    var port: Int?
    var socketType: String?
    var username: String?
    var authentication: [String] = []
}

/// Everything of interest in a `clientConfig` document.
struct ClientConfigDocument: Equatable {
    var providerID: String?
    var displayName: String?
    var domains: [String] = []
    var incoming: [ClientConfigServer] = []
    var outgoing: [ClientConfigServer] = []
}

/// SAX-style reader for the Mozilla autoconfig format
/// (https://wiki.mozilla.org/Thunderbird:Autoconfiguration:ConfigFileFormat).
/// Only the first `emailProvider` is read. External entities are never resolved.
final class ClientConfigReader: NSObject, XMLParserDelegate {
    private(set) var document = ClientConfigDocument()
    private(set) var sawClientConfig = false
    private var path: [String] = []
    private var text = ""
    private var current: ClientConfigServer?
    private var providerDepth = 0
    private var providersSeen = 0

    static func read(_ data: Data) -> ClientConfigDocument? {
        guard !data.isEmpty, data.count <= 1_000_000 else { return nil }
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.shouldProcessNamespaces = false
        let reader = ClientConfigReader()
        parser.delegate = reader
        guard parser.parse(), reader.sawClientConfig else { return nil }
        return reader.document
    }

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?,
                qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        let name = Self.localName(elementName)
        path.append(name)
        text = ""
        switch name {
        case "clientconfig":
            if path.count == 1 { sawClientConfig = true }
        case "emailprovider":
            providersSeen += 1
            if providersSeen == 1 {
                providerDepth = path.count
                document.providerID = attributeDict["id"]
            }
        case "incomingserver", "outgoingserver":
            guard inFirstProvider else { break }
            let type = attributeDict["type"]?.trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            current = ClientConfigServer(type: type)
        default:
            break
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        if text.utf8.count < 4096 { text += string }
    }

    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) {
        if text.utf8.count < 4096 { text += String(decoding: CDATABlock, as: UTF8.self) }
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        let name = Self.localName(elementName)
        let value = text.trimmingCharacters(in: .whitespacesAndNewlines)
        text = ""
        defer { if !path.isEmpty { path.removeLast() } }
        guard inFirstProvider else { return }
        let parent = path.count >= 2 ? path[path.count - 2] : ""
        if var server = current {
            switch name {
            case "hostname": server.hostname = value
            case "port": server.port = Int(value)
            case "sockettype": server.socketType = value
            case "username": server.username = value
            case "authentication": if !value.isEmpty { server.authentication.append(value) }
            case "incomingserver":
                document.incoming.append(server)
                current = nil
                return
            case "outgoingserver":
                document.outgoing.append(server)
                current = nil
                return
            default: break
            }
            current = server
            return
        }
        if parent == "emailprovider" {
            switch name {
            case "displayname": if document.displayName == nil, !value.isEmpty { document.displayName = value }
            case "domain": if !value.isEmpty { document.domains.append(value.lowercased()) }
            default: break
            }
        }
    }

    private var inFirstProvider: Bool {
        providersSeen == 1 && providerDepth > 0 && path.count >= providerDepth && path[providerDepth - 1] == "emailprovider"
    }

    private static func localName(_ name: String) -> String {
        let local = name.split(separator: ":").last.map(String.init) ?? name
        return local.lowercased()
    }
}

extension Autodiscovery {
    /// Picks the best IMAP and SMTP servers from a parsed document: implicit TLS over STARTTLS,
    /// plain-text servers ignored, servers with sign-in methods Ink can use first, then document order.
    static func choose(_ document: ClientConfigDocument, email: EmailParts) -> (imap: ServerConfig, smtp: ServerConfig)? {
        let imapCandidates = document.incoming.filter { $0.type == "imap" }
        let smtpCandidates = document.outgoing.filter { $0.type == "smtp" || $0.type.isEmpty }
        guard let imap = best(imapCandidates, defaultPorts: (tls: 993, startTLS: 143), email: email),
              let smtp = best(smtpCandidates, defaultPorts: (tls: 465, startTLS: 587), email: email) else { return nil }
        return (imap, smtp)
    }

    private static func best(_ servers: [ClientConfigServer], defaultPorts: (tls: Int, startTLS: Int), email: EmailParts) -> ServerConfig? {
        var ranked: [(rank: Int, index: Int, config: ServerConfig)] = []
        for (index, server) in servers.enumerated() {
            guard let rawHost = server.hostname, !rawHost.isEmpty else { continue }
            let hostname = email.substitute(rawHost)
            guard !hostname.contains("%"), let host = DomainName.ascii(hostname) else { continue }
            guard let security = security(socketType: server.socketType, port: server.port) else { continue }
            let port = server.port ?? (security == .tls ? defaultPorts.tls : defaultPorts.startTLS)
            guard (1...65535).contains(port) else { continue }
            var username = email.substitute(server.username ?? "%EMAILADDRESS%")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if username.isEmpty || username.contains("%") { username = email.address }
            var rank = security == .tls ? 0 : 10
            if !server.authentication.isEmpty && !server.authentication.contains(where: isUsableAuthentication) { rank += 100 }
            ranked.append((rank, index, ServerConfig(host: host, port: port, security: security, username: username)))
        }
        return ranked.min { ($0.rank, $0.index) < ($1.rank, $1.index) }?.config
    }

    /// `SSL` (and `TLS` on a non-STARTTLS port) is implicit TLS; `STARTTLS` is STARTTLS; `plain`
    /// and unknown values are ignored. A missing socket type counts as TLS only on 993 / 465.
    static func security(socketType: String?, port: Int?) -> ConnectionSecurity? {
        let value = socketType?.trimmingCharacters(in: .whitespacesAndNewlines).uppercased() ?? ""
        switch value {
        case "SSL", "SSL/TLS", "IMPLICIT":
            return .tls
        case "TLS":
            if let port, [25, 143, 587].contains(port) { return .startTLS }
            return .tls
        case "STARTTLS":
            return .startTLS
        case "":
            if let port, port == 993 || port == 465 { return .tls }
            return nil
        default:
            return nil
        }
    }

    /// Sign-in methods Ink can use: passwords (sent as AUTH PLAIN/LOGIN over TLS) and OAuth 2.0.
    private static func isUsableAuthentication(_ method: String) -> Bool {
        switch method.trimmingCharacters(in: .whitespaces).lowercased() {
        case "password-cleartext", "plain", "password-encrypted", "secure", "oauth2": return true
        default: return false
        }
    }
}

/// An email address split for `%EMAILADDRESS%`-style substitution and URL building.
struct EmailParts: Equatable {
    var address: String
    var localPart: String
    /// Domain as typed, lowercased (may be non-ASCII).
    var domain: String
    /// IDNA form of `domain`, safe to put in a URL host.
    var asciiDomain: String

    init?(_ email: String) {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@"), at != trimmed.startIndex else { return nil }
        let local = String(trimmed[..<at])
        var domain = trimmed[trimmed.index(after: at)...].lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        guard !local.isEmpty, !domain.isEmpty,
              !local.unicodeScalars.contains(where: { $0.value < 0x20 || $0.value == 0x7F || $0 == " " }),
              let ascii = DomainName.ascii(domain) else { return nil }
        self.address = local + "@" + domain
        self.localPart = local
        self.domain = domain
        self.asciiDomain = ascii
    }

    /// Replaces `%EMAILADDRESS%`, `%EMAILLOCALPART%` and `%EMAILDOMAIN%` (case-insensitive).
    func substitute(_ template: String) -> String {
        guard template.contains("%") else { return template }
        var result = template
        for (placeholder, value) in [("%EMAILADDRESS%", address), ("%EMAILLOCALPART%", localPart), ("%EMAILDOMAIN%", domain)] {
            result = result.replacingOccurrences(of: placeholder, with: value, options: .caseInsensitive)
        }
        return result
    }
}
