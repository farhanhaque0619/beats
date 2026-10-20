import XCTest
import InkModel
@testable import InkProviders

/// Which providers file sent mail themselves, iCloud's two user name forms, and the advice
/// attached to sign-in refusals (RESEARCH §2.2, §2.3, §2.6, §3.8).
final class ProviderAccountRulesTests: XCTestCase {
    // MARK: Sent copies

    func testWhichPresetsFileSentMailThemselves() {
        let saving = Providers.all.filter(\.savesSentAutomatically).map(\.id)
        XCTAssertEqual(Set(saving), [.gmail, .outlook, .yahoo, .aol, .zoho])
        XCTAssertFalse(Providers.icloud.savesSentAutomatically)
        XCTAssertFalse(Providers.fastmail.savesSentAutomatically)
        // Accounts carry the preset's answer.
        let yahoo = Providers.yahoo.accountConfig(email: "ada@yahoo.com", displayName: "Ada", authMethod: .password)
        XCTAssertTrue(yahoo.savesSentAutomatically)
    }

    // MARK: iCloud user names

    func testICloudIMAPUsesTheNamePartAndSMTPTheFullAddress() {
        for address in ["grace@icloud.com", "grace@me.com", "Grace.Hopper@mac.com"] {
            let servers = Providers.icloud.servers(forEmail: address)
            XCTAssertEqual(servers.imap.username, String(address.split(separator: "@")[0]))
            XCTAssertEqual(servers.smtp.username, address)
        }
        // A custom domain hosted by iCloud: the name part means nothing to Apple, so the full address.
        XCTAssertEqual(Providers.icloud.imapUsername(forEmail: " ada@lovelace.example "), "ada@lovelace.example")
        // Everyone else signs in to IMAP with the full address.
        for preset in Providers.all where preset.id != .icloud {
            let address = "ada@\(preset.domains[0])"
            XCTAssertEqual(preset.servers(forEmail: address).imap.username, address, preset.name)
        }
    }

    func testICloudDiscoveryUsesTheSameForms() async throws {
        let discovered = await Autodiscovery.discover(email: "grace@me.com")
        let preset = try XCTUnwrap(discovered)
        XCTAssertEqual(preset.imap.username, "grace")
        XCTAssertEqual(preset.smtp.username, "grace@me.com")
        let hosted = try XCTUnwrap(Autodiscovery.result(forMXHosts: ["mx01.mail.icloud.com"], email: "ada@lovelace.example"))
        XCTAssertEqual(hosted.preset, .icloud)
        XCTAssertEqual(hosted.imap.username, "ada@lovelace.example")
    }

    func testAlternateICloudUsername() {
        let account = Providers.icloud.accountConfig(email: "grace@icloud.com", displayName: "Grace", authMethod: .password)
        XCTAssertEqual(Providers.alternateIMAPUsername(for: account, refused: "grace"), "grace@icloud.com")
        XCTAssertEqual(Providers.alternateIMAPUsername(for: account, refused: "grace@icloud.com"), "grace")
        XCTAssertEqual(Providers.alternateIMAPUsername(for: account, refused: " GRACE@icloud.com "), "GRACE")

        // Recognised by host when the account was set up by hand.
        var manual = account
        manual.provider = .other
        manual.imap.host = "p42-imap.mail.me.com"
        XCTAssertEqual(Providers.alternateIMAPUsername(for: manual, refused: "grace"), "grace@icloud.com")

        // Nothing to try for other providers or OAuth.
        let gmail = Providers.gmail.accountConfig(email: "ada@gmail.com", displayName: "Ada", authMethod: .password)
        XCTAssertNil(Providers.alternateIMAPUsername(for: gmail, refused: "ada@gmail.com"))
        var oauth = account
        oauth.authMethod = .oauth2
        XCTAssertNil(Providers.alternateIMAPUsername(for: oauth, refused: "grace"))
        // Without a full address there's no other form to try.
        var odd = account
        odd.emailAddress = "grace"
        XCTAssertNil(Providers.alternateIMAPUsername(for: odd, refused: "grace"))
    }

    // MARK: Error advice

    private func advise(_ error: MailError, _ provider: ProviderID, host: String = "", auth: AuthMethod = .password,
                        _ server: ProviderErrorAdvice.Server = .imap) -> MailError {
        ProviderErrorAdvice.advise(error, provider: provider, host: host, authMethod: auth, server: server)
    }

    func testGmailRefusals() {
        // IMAP: `NO [ALERT] Application-specific password required: https://… (Failure)` (detail as InkIMAP reports it).
        XCTAssertEqual(advise(.authenticationFailed("Application-specific password required: https://support.google.com/accounts/answer/185833"), .gmail),
                       .authenticationFailed(ProviderErrorAdvice.gmailAppPasswordRequired))
        // SMTP: `534-5.7.9 Application-specific password required. Learn more at …`.
        XCTAssertEqual(advise(.authenticationFailed("Application-specific password required. Learn more at https://support.google.com/mail/?p=InvalidSecondFactor"), .gmail, .smtp),
                       .authenticationFailed(ProviderErrorAdvice.gmailAppPasswordRequired))
        // `[AUTHENTICATIONFAILED] Invalid credentials` and `535-5.7.8 Username and Password not accepted`.
        XCTAssertEqual(advise(.authenticationFailed("Invalid credentials"), .gmail), .authenticationFailed(ProviderErrorAdvice.gmailAppPasswordRejected))
        XCTAssertEqual(advise(.authenticationFailed("Username and Password not accepted. Learn more at https://support.google.com/mail/?p=BadCredentials"), .gmail, .smtp),
                       .authenticationFailed(ProviderErrorAdvice.gmailAppPasswordRejected))
        XCTAssertEqual(advise(.authenticationFailed("Invalid credentials"), .gmail, auth: .oauth2), .authenticationFailed(ProviderErrorAdvice.googleSignInRejected))
        // Google Workspace set up as "Other" is recognised by its server.
        XCTAssertEqual(advise(.authenticationFailed("Invalid credentials"), .other, host: "imap.gmail.com"),
                       .authenticationFailed(ProviderErrorAdvice.gmailAppPasswordRejected))
        // The app's onboarding still recognises the app-password case by its words.
        XCTAssertTrue(ProviderErrorAdvice.gmailAppPasswordRequired.lowercased().contains("application-specific password"))
        // Not a sign-in problem: left alone.
        XCTAssertEqual(advise(.timeout, .gmail), .timeout)
        XCTAssertEqual(advise(.serverError("Mailbox full."), .gmail), .serverError("Mailbox full."))
    }

    func testOutlookRefusals() {
        let host = "outlook.office365.com"
        XCTAssertEqual(advise(.authenticationFailed("AUTHENTICATE failed."), .outlook, host: host),
                       .authenticationFailed(ProviderErrorAdvice.outlookNeedsOAuth))
        XCTAssertEqual(advise(.authenticationFailed("LOGIN failed."), .other, host: host),
                       .authenticationFailed(ProviderErrorAdvice.outlookNeedsOAuth))
        // LOGINDISABLED: the client won't even send the password.
        XCTAssertEqual(advise(.notSupported("password sign-in on this connection"), .outlook, host: host),
                       .authenticationFailed(ProviderErrorAdvice.outlookNeedsOAuth))
        XCTAssertEqual(advise(.authenticationFailed("AUTHENTICATE failed."), .outlook, host: host, auth: .oauth2),
                       .authenticationFailed(ProviderErrorAdvice.outlookSignInRejected))
        XCTAssertEqual(advise(.authenticationFailed("Authentication unsuccessful"), .outlook, host: "smtp-mail.outlook.com", auth: .oauth2, .smtp),
                       .authenticationFailed(ProviderErrorAdvice.outlookSendRejected))
        XCTAssertEqual(advise(.authenticationFailed("Authentication unsuccessful, SmtpClientAuthentication is disabled for the Tenant. Visit https://aka.ms/smtp_auth_disabled for more information."),
                              .outlook, host: "smtp.office365.com", auth: .oauth2, .smtp),
                       .authenticationFailed(ProviderErrorAdvice.outlookSMTPAuthDisabled))
        // Signed in, but IMAP is off in Outlook's settings: whatever the command and the error kind.
        XCTAssertEqual(advise(.protocolError("LIST was rejected: User is authenticated but not connected."), .outlook, host: host, auth: .oauth2),
                       .serverError(ProviderErrorAdvice.outlookIMAPDisabled))
        XCTAssertEqual(advise(.serverError("User is authenticated but not connected."), .other, host: "mail.contoso.example", auth: .oauth2),
                       .serverError(ProviderErrorAdvice.outlookIMAPDisabled))
    }

    func testAppPasswordProviders() {
        XCTAssertEqual(advise(.authenticationFailed("Authentication failed."), .icloud), .authenticationFailed(ProviderErrorAdvice.icloudAppPasswordRejected))
        XCTAssertEqual(advise(.authenticationFailed("LOGIN failed"), .yahoo), .authenticationFailed(ProviderErrorAdvice.yahooAppPasswordRejected))
        XCTAssertEqual(advise(.authenticationFailed("LOGIN failed"), .aol), .authenticationFailed(ProviderErrorAdvice.aolAppPasswordRejected))
        XCTAssertEqual(advise(.authenticationFailed("Authentication failed"), .fastmail), .authenticationFailed(ProviderErrorAdvice.fastmailAppPasswordRejected))
        XCTAssertEqual(advise(.authenticationFailed("Invalid credentials"), .zoho), .authenticationFailed(ProviderErrorAdvice.zohoPasswordRejected))
        XCTAssertEqual(advise(.authenticationFailed("Authentication failed."), .other, host: "p42-imap.mail.me.com"),
                       .authenticationFailed(ProviderErrorAdvice.icloudAppPasswordRejected))
        // An unknown server keeps its own words.
        XCTAssertEqual(advise(.authenticationFailed("Authentication failed."), .other, host: "imap.example.com"),
                       .authenticationFailed("Authentication failed."))
    }

    func testAdviceIsStableAndReadable() {
        let once = advise(.authenticationFailed("Application-specific password required"), .gmail)
        XCTAssertEqual(advise(once, .gmail), once, "advising twice changes nothing")
        XCTAssertTrue(ProviderErrorAdvice.isAdvice(once))
        XCTAssertFalse(ProviderErrorAdvice.isAdvice(.authenticationFailed("Invalid credentials")))
        XCTAssertFalse(ProviderErrorAdvice.isAdvice(.timeout))
        for sentence in ProviderErrorAdvice.allSentences {
            XCTAssertTrue(sentence.hasSuffix("."), sentence)
            XCTAssertLessThan(sentence.count, 300, sentence)
            // Advice never quotes the server phrases it reacts to, or it would react to itself.
            for trigger in ["application-specific password required", "user is authenticated but not connected", "smtpclientauthentication"] {
                XCTAssertNil(sentence.lowercased().range(of: trigger), sentence)
            }
        }
    }
}
