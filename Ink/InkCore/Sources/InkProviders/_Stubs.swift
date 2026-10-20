// TEMPORARY: signatures from ARCHITECTURE.md so the app can be compiled on CI before the real
// InkProviders lands. The real module replaces this directory.
import Foundation
import InkModel
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

public enum ProviderAuthOption: Sendable {
    case appPassword(url: URL?, steps: [String])
    case password
    case oauth(OAuthProviderID)
}

public struct ProviderPreset: Identifiable, Sendable {
    public var id: ProviderID
    public var name: String
    public var domains: [String]
    public var mxSuffixes: [String]
    public var imap: (host: String, port: Int, security: ConnectionSecurity)
    public var smtp: (host: String, port: Int, security: ConnectionSecurity)
    public var authOptions: [ProviderAuthOption]
    public var savesSentAutomatically: Bool
    public var archiveRole: MailboxRole
    public var notes: [String]
    public func accountConfig(email: String, displayName: String, authMethod: AuthMethod) -> AccountConfig {
        AccountConfig(provider: id, displayName: displayName, emailAddress: email,
                      imap: ServerConfig(host: imap.host, port: imap.port, security: imap.security, username: email),
                      smtp: ServerConfig(host: smtp.host, port: smtp.port, security: smtp.security, username: email),
                      authMethod: authMethod)
    }
}

public enum Providers {
    public static let all: [ProviderPreset] = []
    public static func preset(for id: ProviderID) -> ProviderPreset? { nil }
    public static func preset(forEmail: String) -> ProviderPreset? { nil }
}

public struct DiscoveryResult: Sendable {
    public var imap: ServerConfig
    public var smtp: ServerConfig
    public var preset: ProviderID?
    public var source: String
}

public enum Autodiscovery {
    public static func discover(email: String, session: URLSession = .shared) async -> DiscoveryResult? { nil }
}

public struct OAuthConfiguration: Sendable {
    public var provider: OAuthProviderID
    public var clientID: String
    public var redirectURI: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var scopes: [String]
    public var callbackScheme: String
    public static func google(clientID: String) -> OAuthConfiguration { fatalError() }
    public static func microsoft(clientID: String, bundleID: String) -> OAuthConfiguration { fatalError() }
}

public struct PKCE: Sendable {
    public var verifier: String
    public var challenge: String
    public static func generate() -> PKCE { PKCE(verifier: "", challenge: "") }
}

public enum OAuthClient {
    public static func authorizationURL(config: OAuthConfiguration, pkce: PKCE, state: String, loginHint: String?) -> URL { config.authorizationEndpoint }
    public static func exchange(code: String, config: OAuthConfiguration, pkce: PKCE, session: URLSession = .shared) async throws -> OAuthToken { throw MailError.oauth("stub") }
    public static func refresh(_ token: OAuthToken, config: OAuthConfiguration, session: URLSession = .shared) async throws -> OAuthToken { token }
    public static func parseTokenResponse(_ data: Data, previous: OAuthToken?, now: Date) throws -> OAuthToken { throw MailError.oauth("stub") }
}
