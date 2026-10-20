import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InkModel
import XCTest
@testable import InkProviders

final class OAuthConfigurationTests: XCTestCase {
    func testGoogle() {
        let config = OAuthConfiguration.google(clientID: "1234567890-abc123def456.apps.googleusercontent.com")
        XCTAssertEqual(config.provider, .google)
        XCTAssertEqual(config.clientID, "1234567890-abc123def456.apps.googleusercontent.com")
        XCTAssertEqual(config.redirectURI, "com.googleusercontent.apps.1234567890-abc123def456:/oauth2redirect")
        XCTAssertEqual(config.callbackScheme, "com.googleusercontent.apps.1234567890-abc123def456")
        XCTAssertEqual(config.authorizationEndpoint.absoluteString, "https://accounts.google.com/o/oauth2/v2/auth")
        XCTAssertEqual(config.tokenEndpoint.absoluteString, "https://oauth2.googleapis.com/token")
        XCTAssertEqual(config.scopes.first, "https://mail.google.com/")
        XCTAssertEqual(Set(config.scopes), ["https://mail.google.com/", "openid", "email", "profile"])
        XCTAssertEqual(config.extraAuthorizationParameters["access_type"], "offline")
        XCTAssertEqual(config.extraAuthorizationParameters["prompt"], "consent")
        XCTAssertNil(config.clientSecret)

        let minimal = OAuthConfiguration.google(clientID: "42-xyz.apps.googleusercontent.com", includeIdentity: false)
        XCTAssertEqual(minimal.scopes, ["https://mail.google.com/"])
        // A client id without the usual suffix is used whole.
        XCTAssertEqual(OAuthConfiguration.google(clientID: "plainid").redirectURI, "com.googleusercontent.apps.plainid:/oauth2redirect")
    }

    func testMicrosoft() {
        let config = OAuthConfiguration.microsoft(clientID: "00000000-1111-2222-3333-444444444444", bundleID: "app.ink.mail")
        XCTAssertEqual(config.provider, .microsoft)
        XCTAssertEqual(config.redirectURI, "msauth.app.ink.mail://auth")
        XCTAssertEqual(config.callbackScheme, "msauth.app.ink.mail")
        XCTAssertEqual(config.authorizationEndpoint.absoluteString, "https://login.microsoftonline.com/common/oauth2/v2.0/authorize")
        XCTAssertEqual(config.tokenEndpoint.absoluteString, "https://login.microsoftonline.com/common/oauth2/v2.0/token")
        XCTAssertEqual(config.scopes, [
            "https://outlook.office.com/IMAP.AccessAsUser.All",
            "https://outlook.office.com/SMTP.Send",
            "offline_access", "openid", "email",
        ])
    }

    func testGoogleAuthorizationURL() throws {
        let config = OAuthConfiguration.google(clientID: "1234567890-abc.apps.googleusercontent.com")
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let url = OAuthClient.authorizationURL(config: config, pkce: pkce, state: "s/t+a=te", loginHint: "ada+mail@gmail.com")
        XCTAssertTrue(url.absoluteString.hasPrefix("https://accounts.google.com/o/oauth2/v2/auth?"))
        let items = queryItems(url)
        XCTAssertEqual(items["client_id"], "1234567890-abc.apps.googleusercontent.com")
        XCTAssertEqual(items["redirect_uri"], "com.googleusercontent.apps.1234567890-abc:/oauth2redirect")
        XCTAssertEqual(items["response_type"], "code")
        XCTAssertEqual(items["scope"], "https://mail.google.com/ openid email profile")
        XCTAssertEqual(items["code_challenge"], "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(items["code_challenge_method"], "S256")
        XCTAssertEqual(items["state"], "s/t+a=te")
        XCTAssertEqual(items["login_hint"], "ada+mail@gmail.com")
        XCTAssertEqual(items["access_type"], "offline")
        XCTAssertEqual(items["prompt"], "consent")
        // `+` must be percent-encoded or servers read it as a space.
        XCTAssertTrue(url.absoluteString.contains("login_hint=ada%2Bmail%40gmail.com"))
        XCTAssertTrue(url.absoluteString.contains("scope=https%3A%2F%2Fmail.google.com%2F%20openid"))
        XCTAssertFalse(url.absoluteString.contains("code_verifier"))
    }

    func testMicrosoftAuthorizationURLWithoutHint() {
        let config = OAuthConfiguration.microsoft(clientID: "client", bundleID: "app.ink.mail")
        let url = OAuthClient.authorizationURL(config: config, pkce: PKCE(verifier: String(repeating: "a", count: 43)), state: "xyz", loginHint: "  ")
        let items = queryItems(url)
        XCTAssertNil(items["login_hint"])
        XCTAssertEqual(items["redirect_uri"], "msauth.app.ink.mail://auth")
        XCTAssertEqual(items["response_mode"], "query")
        XCTAssertEqual(items["scope"]?.split(separator: " ").count, 5)
        XCTAssertTrue(url.absoluteString.hasPrefix("https://login.microsoftonline.com/common/oauth2/v2.0/authorize?"))
    }

    func testCallbackParsing() throws {
        let ok = try XCTUnwrap(URL(string: "com.googleusercontent.apps.123:/oauth2redirect?state=abc&code=4/0AeanS0b-xyz&scope=email%20https://mail.google.com/"))
        XCTAssertEqual(try OAuthClient.authorizationCode(fromCallback: ok, expectedState: "abc"), "4/0AeanS0b-xyz")

        let wrongState = try XCTUnwrap(URL(string: "msauth.app://auth?code=M.C507_BAY.2.U.abc&state=other"))
        XCTAssertThrowsError(try OAuthClient.authorizationCode(fromCallback: wrongState, expectedState: "abc")) { error in
            guard case MailError.oauth = error else { return XCTFail("\(error)") }
        }

        let denied = try XCTUnwrap(URL(string: "msauth.app://auth?error=access_denied&error_description=The+user+has+denied+access&state=abc"))
        XCTAssertThrowsError(try OAuthClient.authorizationCode(fromCallback: denied, expectedState: "abc")) { error in
            XCTAssertEqual(error as? MailError, .cancelled)
        }

        let invalid = try XCTUnwrap(URL(string: "msauth.app://auth?error=invalid_request&error_description=AADSTS50011%3A%20The%20redirect%20URI%20does%20not%20match.&state=abc"))
        XCTAssertThrowsError(try OAuthClient.authorizationCode(fromCallback: invalid, expectedState: "abc")) { error in
            XCTAssertEqual(error as? MailError, .oauth("AADSTS50011: The redirect URI does not match."))
        }

        let fragment = try XCTUnwrap(URL(string: "msauth.app://auth#code=frag-code&state=abc"))
        XCTAssertEqual(try OAuthClient.authorizationCode(fromCallback: fragment, expectedState: "abc"), "frag-code")

        let noCode = try XCTUnwrap(URL(string: "msauth.app://auth?state=abc"))
        XCTAssertThrowsError(try OAuthClient.authorizationCode(fromCallback: noCode, expectedState: "abc"))
    }
}

final class OAuthTokenParsingTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_792_000_000)

    func testGoogleExchangeReply() throws {
        let json = """
        {
          "access_token": "ya29.a0AfB_byC-EXAMPLE-ACCESS-TOKEN",
          "expires_in": 3599,
          "refresh_token": "1//0gEXAMPLE-REFRESH-TOKEN",
          "scope": "https://mail.google.com/ openid https://www.googleapis.com/auth/userinfo.email",
          "token_type": "Bearer",
          "id_token": "eyJhbGciOiJSUzI1NiJ9.eyJlbWFpbCI6ImFkYUBnbWFpbC5jb20ifQ.sig"
        }
        """
        let token = try OAuthClient.parseTokenResponse(Data(json.utf8), previous: nil, now: now)
        XCTAssertEqual(token.accessToken, "ya29.a0AfB_byC-EXAMPLE-ACCESS-TOKEN")
        XCTAssertEqual(token.refreshToken, "1//0gEXAMPLE-REFRESH-TOKEN")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3599))
        XCTAssertEqual(token.scope, "https://mail.google.com/ openid https://www.googleapis.com/auth/userinfo.email")
        XCTAssertFalse(token.isExpired(at: now))
        XCTAssertTrue(token.isExpired(at: now.addingTimeInterval(3500)))
    }

    func testGoogleRefreshKeepsOldRefreshToken() throws {
        let previous = OAuthToken(accessToken: "old", refreshToken: "1//keep-me", expiresAt: now, scope: "https://mail.google.com/")
        let json = #"{"access_token":"ya29.new","expires_in":3599,"scope":"https://mail.google.com/","token_type":"Bearer"}"#
        let token = try OAuthClient.parseTokenResponse(Data(json.utf8), previous: previous, now: now)
        XCTAssertEqual(token.accessToken, "ya29.new")
        XCTAssertEqual(token.refreshToken, "1//keep-me")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3599))
    }

    func testMicrosoftReplyWithRotatedRefreshToken() throws {
        let previous = OAuthToken(accessToken: "old", refreshToken: "M.C507_old", scope: "old scope")
        let json = """
        {"token_type":"Bearer","scope":"https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send","expires_in":"3600","ext_expires_in":3600,"access_token":"EwBIA8l6BAAU-EXAMPLE","refresh_token":"M.C507_BAY.0.U.-new","id_token":"x.y.z"}
        """
        let token = try OAuthClient.parseTokenResponse(Data(json.utf8), previous: previous, now: now)
        XCTAssertEqual(token.refreshToken, "M.C507_BAY.0.U.-new")
        XCTAssertEqual(token.expiresAt, now.addingTimeInterval(3600))
        XCTAssertEqual(token.scope, "https://outlook.office.com/IMAP.AccessAsUser.All https://outlook.office.com/SMTP.Send")
    }

    func testMissingExpiryAndEmptyFields() throws {
        let previous = OAuthToken(accessToken: "old", refreshToken: "r", scope: "s")
        let token = try OAuthClient.parseTokenResponse(Data(#"{"access_token":"a","refresh_token":"","scope":""}"#.utf8), previous: previous, now: now)
        XCTAssertNil(token.expiresAt)
        XCTAssertEqual(token.refreshToken, "r")
        XCTAssertEqual(token.scope, "s")
        // Nonsense expiry values are ignored rather than trusted.
        let weird = try OAuthClient.parseTokenResponse(Data(#"{"access_token":"a","expires_in":-5}"#.utf8), previous: nil, now: now)
        XCTAssertNil(weird.expiresAt)
    }

    func testGoogleError() {
        let json = #"{"error": "invalid_grant", "error_description": "Token has been expired or revoked."}"#
        XCTAssertThrowsError(try OAuthClient.parseTokenResponse(Data(json.utf8), previous: nil, now: now)) { error in
            XCTAssertEqual(error as? MailError, .oauth("Token has been expired or revoked."))
        }
    }

    func testMicrosoftErrorKeepsFirstLineOnly() {
        let json = """
        {"error":"invalid_grant","error_description":"AADSTS70000: The provided value for the 'code' parameter is not valid.\\r\\nTrace ID: 0b8a1c2d-0000-4000-8000-123456789abc\\r\\nCorrelation ID: 7f7e6d5c-1111-4222-8333-abcdefabcdef\\r\\nTimestamp: 2026-10-20 08:00:00Z","error_codes":[70000],"timestamp":"2026-10-20 08:00:00Z","trace_id":"0b8a1c2d","correlation_id":"7f7e6d5c","error_uri":"https://login.microsoftonline.com/error?code=70000"}
        """
        XCTAssertThrowsError(try OAuthClient.parseTokenResponse(Data(json.utf8), previous: nil, now: now)) { error in
            XCTAssertEqual(error as? MailError, .oauth("AADSTS70000: The provided value for the 'code' parameter is not valid."))
        }
    }

    func testErrorWithoutDescription() {
        XCTAssertThrowsError(try OAuthClient.parseTokenResponse(Data(#"{"error":"invalid_client"}"#.utf8), previous: nil, now: now)) { error in
            XCTAssertEqual(error as? MailError, .oauth("This app isn't allowed to sign in with that provider."))
        }
        XCTAssertThrowsError(try OAuthClient.parseTokenResponse(Data(#"{"error":"weird_thing"}"#.utf8), previous: nil, now: now)) { error in
            XCTAssertEqual(error as? MailError, .oauth("The provider reported “weird_thing”."))
        }
    }

    func testMalformedReplies() {
        for body in ["", "not json", "[1,2,3]", #"{"token_type":"Bearer"}"#, #"{"access_token":""}"#, "<html>502 Bad Gateway</html>"] {
            XCTAssertThrowsError(try OAuthClient.parseTokenResponse(Data(body.utf8), previous: nil, now: now), body) { error in
                guard case MailError.oauth = error else { return XCTFail("\(error)") }
            }
        }
        XCTAssertThrowsError(try OAuthClient.parseTokenResponse(Data(#"{"access_token":"a","token_type":"mac"}"#.utf8), previous: nil, now: now))
    }

    func testEmailFromIDToken() {
        // {"iss":"https://accounts.google.com","email":"ada@gmail.com","email_verified":true}
        let payload = Base64URL.encode(Array(#"{"iss":"https://accounts.google.com","email":"ada@gmail.com","email_verified":true}"#.utf8))
        XCTAssertEqual(OAuthClient.email(fromIDToken: "eyJhbGciOiJSUzI1NiJ9.\(payload).c2ln"), "ada@gmail.com")
        let microsoft = Base64URL.encode(Array(#"{"preferred_username":"sam@outlook.com","name":"Sam"}"#.utf8))
        XCTAssertEqual(OAuthClient.email(fromIDToken: "h.\(microsoft).s"), "sam@outlook.com")
        XCTAssertNil(OAuthClient.email(fromIDToken: "garbage"))
        XCTAssertNil(OAuthClient.email(fromIDToken: "a.!!!.c"))
    }
}

final class OAuthNetworkTests: XCTestCase {
    func testExchangeSendsPKCEForm() async throws {
        let server = MockHTTP()
        server.route("https://oauth2.googleapis.com/token", .json(#"{"access_token":"ya29.x","expires_in":3599,"refresh_token":"1//r","token_type":"Bearer"}"#))
        let config = OAuthConfiguration.google(clientID: "123-abc.apps.googleusercontent.com")
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        let token = try await OAuthClient.exchange(code: "4/0Ae+code/x", config: config, pkce: pkce, session: server.session)
        XCTAssertEqual(token.accessToken, "ya29.x")
        XCTAssertEqual(token.refreshToken, "1//r")
        let request = try XCTUnwrap(server.requests.first)
        XCTAssertEqual(request.method, "POST")
        XCTAssertEqual(request.headers["Content-Type"], "application/x-www-form-urlencoded")
        let form = formFields(request.body)
        XCTAssertEqual(form["grant_type"], "authorization_code")
        XCTAssertEqual(form["code"], "4/0Ae+code/x")
        XCTAssertEqual(form["code_verifier"], "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(form["redirect_uri"], "com.googleusercontent.apps.123-abc:/oauth2redirect")
        XCTAssertEqual(form["client_id"], "123-abc.apps.googleusercontent.com")
        XCTAssertNil(form["client_secret"])
    }

    func testMicrosoftRefreshSendsScopeAndKeepsRefreshToken() async throws {
        let server = MockHTTP()
        server.route("https://login.microsoftonline.com/common/oauth2/v2.0/token",
                     .json(#"{"token_type":"Bearer","expires_in":3600,"access_token":"EwB.new"}"#))
        let config = OAuthConfiguration.microsoft(clientID: "client-id", bundleID: "app.ink.mail")
        let old = OAuthToken(accessToken: "EwB.old", refreshToken: "M.C507_old", expiresAt: Date(timeIntervalSince1970: 0))
        let token = try await OAuthClient.refresh(old, config: config, session: server.session)
        XCTAssertEqual(token.accessToken, "EwB.new")
        XCTAssertEqual(token.refreshToken, "M.C507_old")
        XCTAssertNotNil(token.expiresAt)
        let form = formFields(try XCTUnwrap(server.requests.first).body)
        XCTAssertEqual(form["grant_type"], "refresh_token")
        XCTAssertEqual(form["refresh_token"], "M.C507_old")
        XCTAssertEqual(form["client_id"], "client-id")
        XCTAssertEqual(form["scope"], config.scopes.joined(separator: " "))
    }

    func testRefreshErrorSurfacesDescription() async {
        let server = MockHTTP()
        server.route("https://oauth2.googleapis.com/token",
                     .json(#"{"error":"invalid_grant","error_description":"Token has been expired or revoked."}"#, status: 400))
        let config = OAuthConfiguration.google(clientID: "123-abc.apps.googleusercontent.com")
        do {
            _ = try await OAuthClient.refresh(OAuthToken(accessToken: "a", refreshToken: "r"), config: config, session: server.session)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MailError, .oauth("Token has been expired or revoked."))
        }
    }

    func testHTMLErrorPage() async {
        let server = MockHTTP()
        server.route("https://oauth2.googleapis.com/token", .status(503, "<html><body>Service Unavailable</body></html>"))
        let config = OAuthConfiguration.google(clientID: "id")
        do {
            _ = try await OAuthClient.exchange(code: "c", config: config, pkce: PKCE.generate(), session: server.session)
            XCTFail("expected an error")
        } catch {
            XCTAssertEqual(error as? MailError, .oauth("The sign-in server answered with an error (HTTP 503)."))
        }
    }

    func testOfflineMapsToConnectionError() async {
        let server = MockHTTP()
        server.route("https://oauth2.googleapis.com/token", .failure(.notConnectedToInternet))
        do {
            _ = try await OAuthClient.exchange(code: "c", config: .google(clientID: "id"), pkce: PKCE.generate(), session: server.session)
            XCTFail("expected an error")
        } catch {
            guard case MailError.connectionFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testRefreshWithoutRefreshTokenFailsWithoutNetwork() async {
        let server = MockHTTP()
        do {
            _ = try await OAuthClient.refresh(OAuthToken(accessToken: "a"), config: .google(clientID: "id"), session: server.session)
            XCTFail("expected an error")
        } catch {
            guard case MailError.oauth = error else { return XCTFail("\(error)") }
        }
        XCTAssertTrue(server.requests.isEmpty)
    }
}

final class OAuthAPIShapeTests: XCTestCase {
    /// The documented factory signatures work as plain function references too.
    func testFactoriesAsFunctionReferences() {
        let google: (String) -> OAuthConfiguration = OAuthConfiguration.google(clientID:)
        let microsoft: (String, String) -> OAuthConfiguration = OAuthConfiguration.microsoft(clientID:bundleID:)
        XCTAssertEqual(google("1-a.apps.googleusercontent.com").provider, .google)
        XCTAssertEqual(microsoft("id", "app.ink.mail").provider, .microsoft)
    }
}
