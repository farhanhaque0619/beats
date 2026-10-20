import Foundation
import SwiftUI
import AuthenticationServices
import InkCore

/// What "Sign in with Google / Microsoft" hands back.
struct OAuthSignInResult: Sendable {
    var token: OAuthToken
    /// The signed-in address, from the ID token when the provider sent one.
    var email: String?
    /// The person's name, from the ID token when present.
    var name: String?
}

/// OAuth 2.0 authorization-code sign-in with PKCE in the system's web authentication sheet.
///
/// Pass the view's `@Environment(\.webAuthenticationSession)`. The browser session is ephemeral,
/// so no provider cookies are shared with Safari. The code is redeemed at the provider's token
/// endpoint directly (public client, no secret) so the response's `id_token` can pre-fill the
/// account's address and name; the token itself is parsed by `OAuthClient.parseTokenResponse`.
@MainActor
enum OAuthSignIn {
    static func signIn(provider: OAuthProviderID, loginHint: String?, session: WebAuthenticationSession) async throws -> OAuthSignInResult {
        guard let configuration = OAuthSettings.configuration(for: provider) else {
            throw MailError.oauthNotConfigured(provider)
        }
        let pkce = PKCE.generate()
        let state = randomState()
        let hint = loginHint?.trimmingCharacters(in: .whitespacesAndNewlines)
        let url = OAuthClient.authorizationURL(
            config: configuration,
            pkce: pkce,
            state: state,
            loginHint: (hint?.isEmpty ?? true) ? nil : hint
        )

        let callback: URL
        do {
            callback = try await session.authenticate(
                using: url,
                callbackURLScheme: configuration.callbackScheme,
                preferredBrowserSession: .ephemeral
            )
        } catch {
            throw signInError(error)
        }

        let code = try authorizationCode(in: callback, expectedState: state)
        // The sheet that started this went away while the browser was up: stop quietly.
        if Task.isCancelled { throw MailError.cancelled }
        let redeemed = try await redeem(code: code, configuration: configuration, pkce: pkce)
        let claims = redeemed.idToken.map { identityClaims(in: $0) } ?? [:]
        return OAuthSignInResult(token: redeemed.token, email: email(in: claims), name: name(in: claims))
    }

    // MARK: Authorization response

    private static func authorizationCode(in callback: URL, expectedState: String) throws -> String {
        var fields: [String: String] = [:]
        for item in URLComponents(url: callback, resolvingAgainstBaseURL: false)?.queryItems ?? [] where fields[item.name] == nil {
            fields[item.name] = item.value ?? ""
        }
        if let error = fields["error"] {
            // The person said no on the consent screen: not an error worth showing.
            if error == "access_denied" { throw MailError.cancelled }
            let description = (fields["error_description"] ?? "")
                .replacingOccurrences(of: "+", with: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            throw MailError.oauth(description.isEmpty ? "The provider answered “\(error)”." : description)
        }
        guard fields["state"] == expectedState else {
            throw MailError.oauth("The sign-in response didn't match this request. Try again.")
        }
        guard let code = fields["code"], !code.isEmpty else {
            throw MailError.oauth("The provider didn't send back a sign-in code.")
        }
        return code
    }

    private static func signInError(_ error: Error) -> Error {
        if error is CancellationError { return MailError.cancelled }
        if let authError = error as? ASWebAuthenticationSessionError {
            if authError.code == .canceledLogin { return MailError.cancelled }
            return MailError.oauth("The sign-in window couldn't open. Try again.")
        }
        if let mailError = error as? MailError { return mailError }
        return MailError.oauth(error.localizedDescription)
    }

    // MARK: Token request

    private static func redeem(code: String, configuration: OAuthConfiguration, pkce: PKCE) async throws -> (token: OAuthToken, idToken: String?) {
        var request = URLRequest(url: configuration.tokenEndpoint, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.setValue("application/json", forHTTPHeaderField: "Accept")
        request.httpBody = formEncoded([
            ("grant_type", "authorization_code"),
            ("code", code),
            ("redirect_uri", configuration.redirectURI),
            ("client_id", configuration.clientID),
            ("code_verifier", pkce.verifier),
        ])

        let urlSession = URLSession(configuration: .ephemeral)
        defer { urlSession.finishTasksAndInvalidate() }
        let response: (Data, URLResponse)
        do {
            response = try await urlSession.data(for: request)
        } catch {
            if Task.isCancelled || error is CancellationError || (error as? URLError)?.code == .cancelled {
                throw MailError.cancelled
            }
            throw MailError.oauth("Couldn't reach the sign-in server. \(error.localizedDescription)")
        }
        let data = response.0
        let status = (response.1 as? HTTPURLResponse)?.statusCode ?? 200
        let token: OAuthToken
        do {
            token = try OAuthClient.parseTokenResponse(data, previous: nil, now: Date())
        } catch let error as MailError {
            // An error page that isn't JSON: say what happened instead of "couldn't read".
            if !(200..<300).contains(status), case .oauth(let detail) = error, detail.hasPrefix("The sign-in server sent a reply") {
                throw MailError.oauth("The sign-in server answered with an error (HTTP \(status)). Try again in a moment.")
            }
            throw error
        }
        let json = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
        return (token, json?["id_token"] as? String)
    }

    private static func formEncoded(_ fields: [(String, String)]) -> Data {
        let unreserved = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        let body = fields
            .map { name, value in "\(name)=\(value.addingPercentEncoding(withAllowedCharacters: unreserved) ?? value)" }
            .joined(separator: "&")
        return Data(body.utf8)
    }

    // MARK: Identity

    /// The payload of an OpenID Connect ID token. It came straight from the provider's token
    /// endpoint over TLS and only pre-fills the address and name, so the signature isn't re-checked.
    private static func identityClaims(in idToken: String) -> [String: Any] {
        let segments = idToken.split(separator: ".", omittingEmptySubsequences: false)
        guard segments.count >= 2 else { return [:] }
        var base64 = String(segments[1])
            .replacingOccurrences(of: "-", with: "+")
            .replacingOccurrences(of: "_", with: "/")
        base64 += String(repeating: "=", count: (4 - base64.count % 4) % 4)
        guard let data = Data(base64Encoded: base64),
              let object = try? JSONSerialization.jsonObject(with: data),
              let claims = object as? [String: Any] else { return [:] }
        return claims
    }

    private static func email(in claims: [String: Any]) -> String? {
        for key in ["email", "preferred_username", "upn"] {
            if let value = (claims[key] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines),
               EmailAddress(address: value).isValid {
                return value
            }
        }
        return nil
    }

    private static func name(in claims: [String: Any]) -> String? {
        guard let name = (claims["name"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines), !name.isEmpty else {
            return nil
        }
        return name
    }

    private static func randomState() -> String {
        let bytes = (0..<24).map { _ in UInt8.random(in: .min ... .max) }
        return Data(bytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}
