import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InkModel

/// How to run the OAuth 2.0 authorization-code flow (with PKCE) against one provider.
public struct OAuthConfiguration: Hashable, Sendable {
    public var provider: OAuthProviderID
    public var clientID: String
    /// Native-app clients have no secret; set it only for providers that insist on one.
    public var clientSecret: String?
    public var redirectURI: String
    public var authorizationEndpoint: URL
    public var tokenEndpoint: URL
    public var scopes: [String]
    /// Extra query items on the authorization URL (Google: `access_type=offline`, `prompt=consent`).
    public var extraAuthorizationParameters: [String: String]

    public init(provider: OAuthProviderID, clientID: String, clientSecret: String? = nil, redirectURI: String,
                authorizationEndpoint: URL, tokenEndpoint: URL, scopes: [String],
                extraAuthorizationParameters: [String: String] = [:]) {
        self.provider = provider
        self.clientID = clientID
        self.clientSecret = clientSecret
        self.redirectURI = redirectURI
        self.authorizationEndpoint = authorizationEndpoint
        self.tokenEndpoint = tokenEndpoint
        self.scopes = scopes
        self.extraAuthorizationParameters = extraAuthorizationParameters
    }

    /// The scope Google requires for IMAP and SMTP.
    public static let googleMailScope = "https://mail.google.com/"
    /// Microsoft's IMAP and SMTP scopes (Outlook.com and Microsoft 365).
    public static let microsoftIMAPScope = "https://outlook.office.com/IMAP.AccessAsUser.All"
    public static let microsoftSMTPScope = "https://outlook.office.com/SMTP.Send"

    /// Google for an iOS/macOS OAuth client (`<prefix>.apps.googleusercontent.com`). The redirect
    /// URI is the reversed client ID, `com.googleusercontent.apps.<prefix>:/oauth2redirect`.
    /// Asks for offline access with a consent prompt so Google always returns a refresh token.
    /// Scopes: `https://mail.google.com/` plus `openid email profile`, so the reply identifies the account.
    public static func google(clientID: String) -> OAuthConfiguration {
        google(clientID: clientID, includeIdentity: true)
    }

    /// Google, optionally without the identity scopes (`includeIdentity: false` asks only for
    /// `https://mail.google.com/`).
    public static func google(clientID: String, includeIdentity: Bool) -> OAuthConfiguration {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let suffix = ".apps.googleusercontent.com"
        let prefix = id.lowercased().hasSuffix(suffix) ? String(id.dropLast(suffix.count)) : id
        var scopes = [googleMailScope]
        if includeIdentity { scopes += ["openid", "email", "profile"] }
        return OAuthConfiguration(
            provider: .google,
            clientID: id,
            redirectURI: "com.googleusercontent.apps.\(prefix):/oauth2redirect",
            authorizationEndpoint: URL(string: "https://accounts.google.com/o/oauth2/v2/auth")!,
            tokenEndpoint: URL(string: "https://oauth2.googleapis.com/token")!,
            scopes: scopes,
            extraAuthorizationParameters: ["access_type": "offline", "prompt": "consent"]
        )
    }

    /// Microsoft identity platform v2 on the `common` tenant (personal Outlook.com accounts and
    /// work/school accounts). Redirect `msauth.<bundleID>://auth`; scopes for IMAP, SMTP, a refresh
    /// token (`offline_access`) and the user's address (`openid email`).
    public static func microsoft(clientID: String, bundleID: String) -> OAuthConfiguration {
        let id = clientID.trimmingCharacters(in: .whitespacesAndNewlines)
        let bundle = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        return OAuthConfiguration(
            provider: .microsoft,
            clientID: id,
            redirectURI: "msauth.\(bundle)://auth",
            authorizationEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")!,
            tokenEndpoint: URL(string: "https://login.microsoftonline.com/common/oauth2/v2.0/token")!,
            scopes: [microsoftIMAPScope, microsoftSMTPScope, "offline_access", "openid", "email"],
            extraAuthorizationParameters: ["response_mode": "query"]
        )
    }

    /// The URL scheme of `redirectURI`, for ASWebAuthenticationSession's callback.
    public var callbackScheme: String {
        if let colon = redirectURI.firstIndex(of: ":") { return String(redirectURI[..<colon]) }
        return redirectURI
    }
}

/// A PKCE (RFC 7636) verifier and its S256 challenge.
public struct PKCE: Hashable, Sendable {
    public var verifier: String
    public var challenge: String
    /// Always `S256`.
    public var method: String { "S256" }

    /// Uses `verifier` as is and derives the challenge: `base64url(SHA256(ASCII(verifier)))`.
    public init(verifier: String) {
        self.verifier = verifier
        self.challenge = Base64URL.encode(InkSHA256.hash(Array(verifier.utf8)))
    }

    /// A fresh verifier from 32 random bytes (43 base64url characters, 256 bits of entropy).
    public static func generate() -> PKCE {
        var generator = SystemRandomNumberGenerator()
        return generate(using: &generator)
    }

    /// A verifier from `generator`'s bytes (deterministic generators make tests repeatable).
    public static func generate<G: RandomNumberGenerator>(using generator: inout G) -> PKCE {
        let bytes = (0..<32).map { _ in UInt8.random(in: .min ... .max, using: &generator) }
        return PKCE(verifier: Base64URL.encode(bytes))
    }

    /// A random `state` value for the authorization request.
    public static func randomState() -> String {
        var generator = SystemRandomNumberGenerator()
        return Base64URL.encode((0..<16).map { _ in UInt8.random(in: .min ... .max, using: &generator) })
    }
}

/// The OAuth 2.0 calls: building the sign-in URL, reading the callback, and the token endpoint.
public enum OAuthClient {
    /// The browser URL that starts sign-in.
    public static func authorizationURL(config: OAuthConfiguration, pkce: PKCE, state: String, loginHint: String?) -> URL {
        var items: [(String, String)] = [
            ("client_id", config.clientID),
            ("redirect_uri", config.redirectURI),
            ("response_type", "code"),
            ("scope", config.scopes.joined(separator: " ")),
            ("code_challenge", pkce.challenge),
            ("code_challenge_method", pkce.method),
            ("state", state),
        ]
        if let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines), !hint.isEmpty {
            items.append(("login_hint", hint))
        }
        for key in config.extraAuthorizationParameters.keys.sorted() where !items.contains(where: { $0.0 == key }) {
            items.append((key, config.extraAuthorizationParameters[key] ?? ""))
        }
        let query = items.map { "\(HTTP.percentEncode($0.0))=\(HTTP.percentEncode($0.1))" }.joined(separator: "&")
        let base = config.authorizationEndpoint.absoluteString
        let separator = base.contains("?") ? "&" : "?"
        return URL(string: base + separator + query) ?? config.authorizationEndpoint
    }

    /// The authorization code from the redirect the browser came back with. Throws
    /// `.cancelled` when the user declined, `.oauth` for a provider error or a `state` mismatch.
    public static func authorizationCode(fromCallback url: URL, expectedState: String) throws -> String {
        var parameters: [String: String] = [:]
        let components = URLComponents(url: url, resolvingAgainstBaseURL: false)
        for item in components?.queryItems ?? [] where parameters[item.name] == nil {
            parameters[item.name] = item.value ?? ""
        }
        // Some providers answer in the fragment.
        if parameters.isEmpty, let fragment = components?.fragment {
            for pair in fragment.split(separator: "&") {
                let kv = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
                let key = kv[0].removingPercentEncoding ?? kv[0]
                let value = kv.count > 1 ? (kv[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? kv[1]) : ""
                if parameters[key] == nil { parameters[key] = value }
            }
        }
        if let error = parameters["error"] {
            if error == "access_denied" { throw MailError.cancelled }
            throw MailError.oauth(describe(error: error, description: parameters["error_description"]))
        }
        guard parameters["state"] == expectedState else {
            throw MailError.oauth("The sign-in reply didn't match this request. Please try again.")
        }
        guard let code = parameters["code"], !code.isEmpty else {
            throw MailError.oauth("The sign-in reply had no authorization code.")
        }
        return code
    }

    /// Trades an authorization code for tokens.
    public static func exchange(code: String, config: OAuthConfiguration, pkce: PKCE, session: URLSession = .shared) async throws -> OAuthToken {
        var fields: [(String, String)] = [
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", config.redirectURI),
            ("client_id", config.clientID),
            ("code_verifier", pkce.verifier),
        ]
        if let secret = config.clientSecret, !secret.isEmpty { fields.append(("client_secret", secret)) }
        return try await tokenRequest(fields, config: config, previous: nil, session: session)
    }

    /// Gets a new access token. Keeps the old refresh token when the reply doesn't include a new one.
    public static func refresh(_ token: OAuthToken, config: OAuthConfiguration, session: URLSession = .shared) async throws -> OAuthToken {
        guard let refreshToken = token.refreshToken, !refreshToken.isEmpty else {
            throw MailError.oauth("Your sign-in has expired. Sign in again.")
        }
        var fields: [(String, String)] = [
            ("grant_type", "refresh_token"),
            ("refresh_token", refreshToken),
            ("client_id", config.clientID),
        ]
        if config.provider == .microsoft { fields.append(("scope", config.scopes.joined(separator: " "))) }
        if let secret = config.clientSecret, !secret.isEmpty { fields.append(("client_secret", secret)) }
        return try await tokenRequest(fields, config: config, previous: token, session: session)
    }

    /// Reads a token endpoint reply. `expires_in` (number or string) becomes `expiresAt` relative to
    /// `now`; a missing `refresh_token` or `scope` is carried over from `previous`. An `error` reply
    /// throws `MailError.oauth` with the provider's `error_description` (first line only, so
    /// Microsoft's trace and correlation ids stay out of the UI).
    public static func parseTokenResponse(_ data: Data, previous: OAuthToken?, now: Date) throws -> OAuthToken {
        guard let object = try? JSONSerialization.jsonObject(with: data), let json = object as? [String: Any] else {
            throw MailError.oauth("The sign-in server sent a reply Ink couldn't read.")
        }
        if let error = json["error"], !(error is NSNull) {
            let code = (error as? String) ?? ((error as? [String: Any])?["message"] as? String) ?? "unknown_error"
            throw MailError.oauth(describe(error: code, description: json["error_description"] as? String))
        }
        guard let accessToken = string(json["access_token"]), !accessToken.isEmpty else {
            throw MailError.oauth("The sign-in server didn't return an access token.")
        }
        if let type = string(json["token_type"]), type.lowercased() != "bearer" {
            throw MailError.oauth("The sign-in server returned an unsupported token type (\(type)).")
        }
        var expiresAt: Date?
        if let seconds = number(json["expires_in"]), seconds > 0, seconds < 10 * 365 * 86_400 {
            expiresAt = now.addingTimeInterval(seconds)
        }
        let refreshToken = string(json["refresh_token"]).flatMap { $0.isEmpty ? nil : $0 } ?? previous?.refreshToken
        let scope = string(json["scope"]).flatMap { $0.isEmpty ? nil : $0 } ?? previous?.scope
        return OAuthToken(accessToken: accessToken, refreshToken: refreshToken, expiresAt: expiresAt, scope: scope)
    }

    /// The `email` claim of an OpenID Connect ID token (not verified; for showing and pre-filling only).
    public static func email(fromIDToken idToken: String) -> String? {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2, let payload = Base64URL.decode(String(segments[1])),
              let object = try? JSONSerialization.jsonObject(with: payload),
              let claims = object as? [String: Any] else { return nil }
        let email = (claims["email"] as? String) ?? (claims["preferred_username"] as? String)
        guard let email, email.contains("@") else { return nil }
        return email
    }

    // MARK: Internals

    private static func tokenRequest(_ fields: [(String, String)], config: OAuthConfiguration, previous: OAuthToken?, session: URLSession) async throws -> OAuthToken {
        var request = URLRequest(url: config.tokenEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = HTTP.formBody(fields)
        let response: HTTP.Response
        do {
            response = try await HTTP.perform(request, session: session)
        } catch {
            throw HTTP.mailError(for: error)
        }
        do {
            return try parseTokenResponse(response.data, previous: previous, now: Date())
        } catch let error as MailError {
            if (200..<300).contains(response.status) { throw error }
            // A non-JSON error page: say what happened instead of "couldn't read".
            if case .oauth(let detail) = error, detail.hasPrefix("The sign-in server sent a reply") {
                throw MailError.oauth("The sign-in server answered with an error (HTTP \(response.status)).")
            }
            throw error
        }
    }

    /// A sentence for an OAuth error: the provider's description (first line), else a known code's meaning.
    static func describe(error: String, description: String?) -> String {
        if let description {
            let firstLine = description
                .split(whereSeparator: \.isNewline)
                .first.map { $0.trimmingCharacters(in: .whitespaces) } ?? ""
            if !firstLine.isEmpty { return firstLine }
        }
        switch error {
        case "invalid_grant": return "Your sign-in has expired or was revoked. Sign in again."
        case "invalid_client", "unauthorized_client": return "This app isn't allowed to sign in with that provider."
        case "invalid_scope": return "The provider didn't allow access to your mail."
        case "access_denied": return "Access was denied."
        case "temporarily_unavailable", "server_error": return "The sign-in service is unavailable right now. Try again later."
        default: return "The provider reported “\(error)”."
        }
    }

    private static func string(_ value: Any?) -> String? {
        if let value = value as? String { return value }
        if let value = value as? NSNumber { return value.stringValue }
        return nil
    }

    private static func number(_ value: Any?) -> Double? {
        if let value = value as? NSNumber { return value.doubleValue }
        if let value = value as? String { return Double(value.trimmingCharacters(in: .whitespaces)) }
        return nil
    }
}
