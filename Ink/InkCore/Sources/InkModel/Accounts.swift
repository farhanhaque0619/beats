import Foundation

/// Known mail providers. `other` covers any IMAP/SMTP server; `demo` is the built-in sample inbox.
public enum ProviderID: String, Codable, Sendable, CaseIterable, Identifiable {
    case gmail, icloud, outlook, yahoo, aol, fastmail, zoho, other, demo
    public var id: String { rawValue }
}

/// How a connection is secured.
public enum ConnectionSecurity: String, Codable, Sendable, CaseIterable {
    /// TLS from the first byte (IMAP 993, SMTP 465).
    case tls
    /// Plaintext greeting, then STARTTLS before authenticating (IMAP 143, SMTP 587).
    case startTLS
    /// No encryption. Only for local test servers; the UI never offers it for real accounts.
    case none
}

public struct ServerConfig: Hashable, Codable, Sendable {
    public var host: String
    public var port: Int
    public var security: ConnectionSecurity
    /// Login name. Usually the full email address.
    public var username: String

    public init(host: String, port: Int, security: ConnectionSecurity, username: String) {
        self.host = host
        self.port = port
        self.security = security
        self.username = username
    }
}

public enum AuthMethod: String, Codable, Sendable {
    /// Account password or app-specific password, sent with LOGIN / AUTH PLAIN over TLS.
    case password
    /// OAuth 2.0 access token, sent with SASL XOAUTH2.
    case oauth2
}

public enum OAuthProviderID: String, Codable, Sendable, CaseIterable {
    case google, microsoft
}

/// Everything needed to talk to one account, minus the secret (which lives in the Keychain).
public struct AccountConfig: Identifiable, Hashable, Codable, Sendable {
    public var id: String
    public var provider: ProviderID
    /// Name shown to recipients ("Ada Lovelace").
    public var displayName: String
    public var emailAddress: String
    public var imap: ServerConfig
    public var smtp: ServerConfig
    public var authMethod: AuthMethod
    public var oauthProvider: OAuthProviderID?
    /// The server files a copy of mail sent over SMTP into Sent by itself (Gmail, Outlook),
    /// so the client must not APPEND another copy.
    public var savesSentAutomatically: Bool
    /// Plain-text signature appended to new messages. Nil or empty means none.
    public var signature: String?
    /// Index into the app's account colour palette, so each account gets a stable hint of colour.
    public var colorIndex: Int
    public var createdAt: Date

    public init(
        id: String = UUID().uuidString,
        provider: ProviderID,
        displayName: String,
        emailAddress: String,
        imap: ServerConfig,
        smtp: ServerConfig,
        authMethod: AuthMethod = .password,
        oauthProvider: OAuthProviderID? = nil,
        savesSentAutomatically: Bool = false,
        signature: String? = nil,
        colorIndex: Int = 0,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.provider = provider
        self.displayName = displayName
        self.emailAddress = emailAddress
        self.imap = imap
        self.smtp = smtp
        self.authMethod = authMethod
        self.oauthProvider = oauthProvider
        self.savesSentAutomatically = savesSentAutomatically
        self.signature = signature
        self.colorIndex = colorIndex
        self.createdAt = createdAt
    }

    public var address: EmailAddress { EmailAddress(name: displayName, address: emailAddress) }
    public var isDemo: Bool { provider == .demo }

    /// The built-in sample account.
    public static let demo = AccountConfig(
        id: "demo",
        provider: .demo,
        displayName: "Alex Rivera",
        emailAddress: "alex@ink.example",
        imap: ServerConfig(host: "demo.invalid", port: 993, security: .tls, username: "alex@ink.example"),
        smtp: ServerConfig(host: "demo.invalid", port: 465, security: .tls, username: "alex@ink.example"),
        savesSentAutomatically: true,
        colorIndex: 0,
        createdAt: Date(timeIntervalSince1970: 1_760_000_000)
    )
}

public struct OAuthToken: Hashable, Codable, Sendable {
    public var accessToken: String
    public var refreshToken: String?
    public var expiresAt: Date?
    public var scope: String?

    public init(accessToken: String, refreshToken: String? = nil, expiresAt: Date? = nil, scope: String? = nil) {
        self.accessToken = accessToken
        self.refreshToken = refreshToken
        self.expiresAt = expiresAt
        self.scope = scope
    }

    /// True when the token is expired or expires within `leeway` seconds.
    public func isExpired(at now: Date = Date(), leeway: TimeInterval = 120) -> Bool {
        guard let expiresAt else { return false }
        return expiresAt.timeIntervalSince(now) <= leeway
    }
}

/// The secret for an account.
public enum Credential: Hashable, Codable, Sendable {
    case password(String)
    case oauth(OAuthToken)
}

/// Stores account secrets. The app implements this on top of the Keychain (and refreshes OAuth
/// tokens inside `credential(for:)`); tests use `InMemoryCredentialStore`.
public protocol CredentialStore: AnyObject, Sendable {
    /// Returns a usable credential, refreshing an expired OAuth token first if needed.
    func credential(for account: AccountConfig) async throws -> Credential
    func save(_ credential: Credential, for accountID: String) async throws
    func delete(accountID: String) async throws
}

public actor InMemoryCredentialStore: CredentialStore {
    private var storage: [String: Credential]

    public init(_ initial: [String: Credential] = [:]) { storage = initial }

    public func credential(for account: AccountConfig) async throws -> Credential {
        if account.isDemo { return .password("demo") }
        guard let credential = storage[account.id] else {
            throw MailError.authenticationFailed("No saved password for \(account.emailAddress).")
        }
        return credential
    }

    public func save(_ credential: Credential, for accountID: String) async throws { storage[accountID] = credential }
    public func delete(accountID: String) async throws { storage[accountID] = nil }
}
