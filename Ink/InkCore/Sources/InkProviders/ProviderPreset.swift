import Foundation
import InkModel

/// One way of signing in to a provider, in the order the setup screen should offer them.
public enum ProviderAuthOption: Hashable, Sendable {
    /// A generated app-specific password. `url` opens the provider's page for making one;
    /// `steps` are short instructions shown next to the password field.
    case appPassword(url: URL?, steps: [String])
    /// The account's normal password.
    case password
    /// Sign in with the provider in the browser (OAuth 2.0 + XOAUTH2).
    case oauth(OAuthProviderID)

    /// The OAuth provider, for `.oauth`.
    public var oauthProvider: OAuthProviderID? {
        if case .oauth(let provider) = self { return provider }
        return nil
    }

    /// The `AuthMethod` an account set up with this option uses.
    public var authMethod: AuthMethod {
        if case .oauth = self { return .oauth2 }
        return .password
    }
}

/// Known settings for a mail provider: servers, sign-in options and quirks.
public struct ProviderPreset: Identifiable, Sendable {
    public var id: ProviderID
    /// Name shown in the provider picker ("Gmail", "iCloud Mail").
    public var name: String
    /// Address domains served by this provider (lowercased).
    public var domains: [String]
    /// MX host suffixes that identify custom domains hosted by this provider (lowercased, no leading dot).
    public var mxSuffixes: [String]
    public var imap: (host: String, port: Int, security: ConnectionSecurity)
    public var smtp: (host: String, port: Int, security: ConnectionSecurity)
    /// Sign-in options, preferred first.
    public var authOptions: [ProviderAuthOption]
    /// The server files mail sent over SMTP into Sent itself, so the client must not APPEND a copy.
    public var savesSentAutomatically: Bool
    /// Where "Archive" moves mail: `.all` for Gmail (remove the Inbox label), `.archive` elsewhere.
    public var archiveRole: MailboxRole
    /// Gotchas shown during setup, one sentence each.
    public var notes: [String]
    /// What to type as the user name, shown as the field's hint.
    public var usernameHint: String

    public init(
        id: ProviderID,
        name: String,
        domains: [String],
        mxSuffixes: [String],
        imap: (host: String, port: Int, security: ConnectionSecurity),
        smtp: (host: String, port: Int, security: ConnectionSecurity),
        authOptions: [ProviderAuthOption],
        savesSentAutomatically: Bool,
        archiveRole: MailboxRole = .archive,
        notes: [String] = [],
        usernameHint: String = "Your full email address"
    ) {
        self.id = id
        self.name = name
        self.domains = domains
        self.mxSuffixes = mxSuffixes
        self.imap = imap
        self.smtp = smtp
        self.authOptions = authOptions
        self.savesSentAutomatically = savesSentAutomatically
        self.archiveRole = archiveRole
        self.notes = notes
        self.usernameHint = usernameHint
    }

    /// The OAuth provider, if signing in with the browser is one of the options.
    public var oauthProvider: OAuthProviderID? { authOptions.lazy.compactMap(\.oauthProvider).first }

    /// True when the provider accepts only OAuth (no password of any kind).
    public var requiresOAuth: Bool { !authOptions.isEmpty && authOptions.allSatisfy { $0.oauthProvider != nil } }

    /// The app-password page and steps, when the provider offers app passwords.
    public var appPassword: (url: URL?, steps: [String])? {
        for option in authOptions {
            if case .appPassword(let url, let steps) = option { return (url, steps) }
        }
        return nil
    }

    /// True when `email`'s domain is one of this provider's own domains.
    public func handles(email: String) -> Bool {
        guard let domain = Providers.domain(of: email) else { return false }
        return domains.contains(domain)
    }

    /// The server settings for `email`. Usually the preset's hosts; Zoho accounts in the EU,
    /// India, Australia, Japan or Canada data centres get that region's hosts.
    public func servers(forEmail email: String) -> (imap: ServerConfig, smtp: ServerConfig) {
        let username = email.trimmingCharacters(in: .whitespacesAndNewlines)
        var imapHost = imap.host
        var smtpHost = smtp.host
        if id == .zoho, let domain = Providers.domain(of: username), let region = ZohoRegion.forAddressDomain(domain) {
            imapHost = "imap.\(region.hostSuffix)"
            smtpHost = "smtp.\(region.hostSuffix)"
        }
        return (
            ServerConfig(host: imapHost, port: imap.port, security: imap.security, username: username),
            ServerConfig(host: smtpHost, port: smtp.port, security: smtp.security, username: username)
        )
    }

    /// A ready-to-save account for `email` on this provider. The user name is the full address.
    /// With `.oauth2` the account records this provider's OAuth provider.
    public func accountConfig(email: String, displayName: String, authMethod: AuthMethod) -> AccountConfig {
        let address = email.trimmingCharacters(in: .whitespacesAndNewlines)
        let servers = servers(forEmail: address)
        return AccountConfig(
            provider: id,
            displayName: displayName.trimmingCharacters(in: .whitespacesAndNewlines),
            emailAddress: address,
            imap: servers.imap,
            smtp: servers.smtp,
            authMethod: authMethod,
            oauthProvider: authMethod == .oauth2 ? oauthProvider : nil,
            savesSentAutomatically: savesSentAutomatically
        )
    }

    /// Tidies a pasted app password: trims it and, for providers whose generated passwords are
    /// shown in space-separated groups (Google, Yahoo, AOL, Fastmail), removes the spaces.
    /// iCloud's `xxxx-xxxx-xxxx-xxxx` hyphens are kept.
    public func cleanedAppPassword(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        switch id {
        case .gmail, .yahoo, .aol, .fastmail:
            return String(trimmed.unicodeScalars.filter { !CharacterSet.whitespacesAndNewlines.contains($0) }.map(Character.init))
        default:
            return trimmed
        }
    }
}

/// Zoho runs separate data centres with their own host names.
enum ZohoRegion: String, CaseIterable {
    case us, eu, india, australia, japan, canada, saudi

    /// `zoho.com`, `zoho.eu`, ...
    var hostSuffix: String {
        switch self {
        case .us: return "zoho.com"
        case .eu: return "zoho.eu"
        case .india: return "zoho.in"
        case .australia: return "zoho.com.au"
        case .japan: return "zoho.jp"
        case .canada: return "zohocloud.ca"
        case .saudi: return "zoho.sa"
        }
    }

    /// The region for a Zoho-owned address domain (`zohomail.eu` → `.eu`). Nil for US or unknown.
    static func forAddressDomain(_ domain: String) -> ZohoRegion? {
        switch domain {
        case "zoho.eu", "zohomail.eu": return .eu
        case "zoho.in", "zohomail.in": return .india
        case "zoho.com.au", "zohomail.com.au": return .australia
        case "zoho.jp", "zohomail.jp": return .japan
        case "zohocloud.ca", "zohomail.ca": return .canada
        case "zoho.sa", "zohomail.sa": return .saudi
        default: return nil
        }
    }

    /// The region for an MX host such as `mx.zoho.eu` or `mx2.zohocloud.ca`.
    static func forMXHost(_ host: String) -> ZohoRegion? {
        // Longest suffixes first so `zoho.com.au` isn't mistaken for `zoho.com`.
        let ordered = allCases.sorted { $0.hostSuffix.count > $1.hostSuffix.count }
        return ordered.first { host == $0.hostSuffix || host.hasSuffix("." + $0.hostSuffix) }
    }
}

/// The built-in provider presets.
public enum Providers {
    // Every literal below is a well-formed URL.
    private static func url(_ string: String) -> URL? { URL(string: string) }

    public static let gmail = ProviderPreset(
        id: .gmail,
        name: "Gmail",
        domains: ["gmail.com", "googlemail.com"],
        mxSuffixes: ["google.com", "googlemail.com"],
        imap: ("imap.gmail.com", 993, .tls),
        smtp: ("smtp.gmail.com", 465, .tls),
        authOptions: [
            .appPassword(url: url("https://myaccount.google.com/apppasswords"), steps: [
                "Turn on 2-Step Verification for your Google Account (app passwords need it).",
                "Open myaccount.google.com/apppasswords and sign in.",
                "Type “Ink” as the app name and choose Create.",
                "Copy the 16-letter password and paste it here. The spaces don't matter.",
            ]),
            .oauth(.google),
        ],
        savesSentAutomatically: true,
        archiveRole: .all,
        notes: [
            "Gmail keeps a copy of everything you send in Sent by itself.",
            "Archiving removes the Inbox label; the message stays in All Mail.",
            "Your normal Google password won't work here: use an app password or Sign in with Google.",
            "Work and school accounts may have app passwords turned off by an administrator; use Sign in with Google instead.",
        ],
        usernameHint: "Your full Gmail address"
    )

    // savesSentAutomatically: iCloud's SMTP submission server is not known to file a copy in
    // "Sent Messages" (Apple Mail always APPENDs one itself), so Ink saves the copy.
    public static let icloud = ProviderPreset(
        id: .icloud,
        name: "iCloud Mail",
        domains: ["icloud.com", "me.com", "mac.com"],
        mxSuffixes: ["icloud.com"],
        imap: ("imap.mail.me.com", 993, .tls),
        smtp: ("smtp.mail.me.com", 587, .startTLS),
        authOptions: [
            .appPassword(url: url("https://account.apple.com"), steps: [
                "Make sure two-factor authentication is on for your Apple Account.",
                "Sign in at account.apple.com and open Sign-In and Security.",
                "Choose App-Specific Passwords, then the + button, and name it “Ink”.",
                "Copy the password (it looks like xxxx-xxxx-xxxx-xxxx) and paste it here.",
            ]),
        ],
        savesSentAutomatically: false,
        notes: [
            "Use your full iCloud address (name@icloud.com) as the user name, even if you send from a custom domain.",
            "Your Apple Account password won't work here: iCloud Mail needs an app-specific password.",
            "Changing your Apple Account password revokes app-specific passwords; make a new one if Ink stops signing in.",
        ],
        usernameHint: "Your full iCloud address"
    )

    public static let outlook = ProviderPreset(
        id: .outlook,
        name: "Outlook.com",
        domains: [
            "outlook.com", "hotmail.com", "live.com", "msn.com", "passport.com", "windowslive.com",
            "outlook.fr", "outlook.de", "outlook.es", "outlook.it", "outlook.jp", "outlook.com.au",
            "hotmail.co.uk", "hotmail.fr", "hotmail.de", "hotmail.it", "hotmail.es",
            "live.co.uk", "live.fr", "live.de", "live.nl", "live.it", "live.ca", "live.com.au",
        ],
        mxSuffixes: ["protection.outlook.com", "outlook.com"],
        imap: ("outlook.office365.com", 993, .tls),
        smtp: ("smtp-mail.outlook.com", 587, .startTLS),
        authOptions: [.oauth(.microsoft)],
        savesSentAutomatically: true,
        notes: [
            "Microsoft turned off password sign-in for Outlook.com, Hotmail and Live in 2024, so you sign in with Microsoft in the browser.",
            "Outlook.com keeps a copy of everything you send in Sent Items by itself.",
            "Work and school accounts only work if your organisation allows IMAP and SMTP sign-in.",
        ],
        usernameHint: "Your full Outlook.com address"
    )

    public static let yahoo = ProviderPreset(
        id: .yahoo,
        name: "Yahoo Mail",
        domains: [
            "yahoo.com", "ymail.com", "rocketmail.com", "yahoo.co.uk", "yahoo.fr", "yahoo.de", "yahoo.es",
            "yahoo.it", "yahoo.ca", "yahoo.com.au", "yahoo.co.in", "yahoo.com.br", "yahoo.com.mx",
            "yahoo.com.ar", "yahoo.ie", "yahoo.co.nz", "yahoo.com.sg", "yahoo.com.ph",
        ],
        mxSuffixes: ["yahoodns.net"],
        imap: ("imap.mail.yahoo.com", 993, .tls),
        smtp: ("smtp.mail.yahoo.com", 465, .tls),
        authOptions: [
            .appPassword(url: url("https://login.yahoo.com/account/security"), steps: [
                "Sign in at login.yahoo.com/account/security.",
                "Choose Generate app password (it may be under “How you sign in”).",
                "Type “Ink” as the app name and choose Generate password.",
                "Copy the password and paste it here.",
            ]),
        ],
        savesSentAutomatically: false,
        notes: [
            "Your normal Yahoo password won't work here: Yahoo needs an app password for mail apps.",
        ]
    )

    public static let aol = ProviderPreset(
        id: .aol,
        name: "AOL Mail",
        domains: ["aol.com", "aim.com", "aol.co.uk", "aol.de", "aol.fr", "love.com", "ygm.com", "games.com", "wow.com"],
        mxSuffixes: ["mx-aol.mail.gm0.yahoodns.net"],
        imap: ("imap.aol.com", 993, .tls),
        smtp: ("smtp.aol.com", 465, .tls),
        authOptions: [
            .appPassword(url: url("https://login.aol.com/account/security"), steps: [
                "Sign in at login.aol.com/account/security.",
                "Choose Generate app password.",
                "Type “Ink” as the app name and choose Generate password.",
                "Copy the password and paste it here.",
            ]),
        ],
        savesSentAutomatically: false,
        notes: [
            "Your normal AOL password won't work here: AOL needs an app password for mail apps.",
        ]
    )

    public static let fastmail = ProviderPreset(
        id: .fastmail,
        name: "Fastmail",
        domains: [
            "fastmail.com", "fastmail.fm", "fastmail.net", "fastmail.org", "fastmail.us", "fastmail.co.uk",
            "fastmail.com.au", "fastmail.de", "fastmail.jp", "fastmail.in", "fastmail.to", "sent.com",
            "messagingengine.com",
        ],
        mxSuffixes: ["messagingengine.com"],
        imap: ("imap.fastmail.com", 993, .tls),
        smtp: ("smtp.fastmail.com", 465, .tls),
        authOptions: [
            .appPassword(url: url("https://app.fastmail.com/settings/security"), steps: [
                "In Fastmail on the web, open Settings → Privacy & Security.",
                "Under Integrations, find App passwords and choose New app password.",
                "Name it “Ink” and give it access to Mail (IMAP/POP/SMTP).",
                "Copy the password and paste it here.",
            ]),
        ],
        savesSentAutomatically: false,
        notes: [
            "Fastmail needs an app password for mail apps; your normal password won't work.",
            "If you use your own domain with Fastmail, sign in with your Fastmail login address.",
        ]
    )

    public static let zoho = ProviderPreset(
        id: .zoho,
        name: "Zoho Mail",
        domains: [
            "zoho.com", "zohomail.com", "zoho.eu", "zohomail.eu", "zoho.in", "zohomail.in",
            "zoho.com.au", "zohomail.com.au", "zoho.jp", "zohomail.jp", "zohocloud.ca", "zoho.sa",
        ],
        mxSuffixes: ["zoho.com", "zoho.eu", "zoho.in", "zoho.com.au", "zoho.jp", "zohocloud.ca", "zoho.sa"],
        imap: ("imap.zoho.com", 993, .tls),
        smtp: ("smtp.zoho.com", 465, .tls),
        authOptions: [
            .appPassword(url: url("https://accounts.zoho.com/home#security/app_password"), steps: [
                "Sign in at accounts.zoho.com and open Security.",
                "Choose App Passwords, then Generate New Password.",
                "Name it “Ink” and choose Generate.",
                "Copy the password and paste it here.",
            ]),
            .password,
        ],
        savesSentAutomatically: false,
        notes: [
            "Turn on IMAP first: in Zoho Mail open Settings → Mail Accounts → IMAP and enable IMAP Access.",
            "With two-factor authentication on, Zoho needs an app-specific password; without it your normal password works.",
            "Accounts on your own domain may need imappro.zoho.com and smtppro.zoho.com (Ink finds these when it looks up your domain).",
        ]
    )

    /// Every preset, in the order the provider picker shows them.
    public static let all: [ProviderPreset] = [gmail, icloud, outlook, yahoo, aol, fastmail, zoho]

    /// The preset for a provider id, or nil for `.other` and `.demo`.
    public static func preset(for id: ProviderID) -> ProviderPreset? {
        all.first { $0.id == id }
    }

    /// The preset whose address domains include `email`'s domain (case-insensitive).
    public static func preset(forEmail email: String) -> ProviderPreset? {
        guard let domain = domain(of: email) else { return nil }
        return all.first { $0.domains.contains(domain) }
    }

    /// The preset that hosts a custom domain with these MX hosts (most preferred first).
    public static func preset(forMXHosts hosts: [String]) -> ProviderPreset? {
        // Longest suffix first: AOL's MX hosts live under Yahoo's yahoodns.net.
        let candidates = all.flatMap { preset in preset.mxSuffixes.map { (preset, $0) } }
            .sorted { $0.1.count > $1.1.count }
        for raw in hosts {
            let host = normalizeHost(raw)
            guard !host.isEmpty else { continue }
            if host.hasPrefix("mx-aol."), host.hasSuffix(".yahoodns.net") { return aol }
            if let match = candidates.first(where: { host == $0.1 || host.hasSuffix("." + $0.1) }) {
                return match.0
            }
        }
        return nil
    }

    /// The provider whose servers include `host` (`imap.gmail.com` → Gmail), for recognising
    /// presets in autodiscovered settings.
    public static func preset(forServerHost host: String) -> ProviderPreset? {
        let host = normalizeHost(host)
        guard !host.isEmpty else { return nil }
        if let exact = all.first(where: { $0.imap.host == host || $0.smtp.host == host }) { return exact }
        let known: [(String, ProviderID)] = [
            ("gmail.com", .gmail), ("googlemail.com", .gmail),
            ("mail.me.com", .icloud),
            ("office365.com", .outlook), ("outlook.com", .outlook),
            ("mail.yahoo.com", .yahoo), ("aol.com", .aol),
            ("fastmail.com", .fastmail), ("messagingengine.com", .fastmail),
        ]
        if let match = known.first(where: { host == $0.0 || host.hasSuffix("." + $0.0) }) {
            return preset(for: match.1)
        }
        if ZohoRegion.forMXHost(host) != nil { return zoho }
        return nil
    }

    /// Lowercased domain of an address (after the last `@`), or nil when there isn't one.
    static func domain(of email: String) -> String? {
        let trimmed = email.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let at = trimmed.lastIndex(of: "@"), at != trimmed.startIndex else { return nil }
        var domain = trimmed[trimmed.index(after: at)...].lowercased()
        while domain.hasSuffix(".") { domain.removeLast() }
        guard !domain.isEmpty else { return nil }
        return domain
    }

    /// Lowercased host without a trailing dot or surrounding whitespace.
    static func normalizeHost(_ host: String) -> String {
        var value = host.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        while value.hasSuffix(".") { value.removeLast() }
        return value
    }
}
