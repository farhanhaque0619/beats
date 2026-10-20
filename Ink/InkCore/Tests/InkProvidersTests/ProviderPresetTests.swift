import Foundation
import InkModel
import XCTest
@testable import InkProviders

final class ProviderPresetTests: XCTestCase {
    func testAllPresetsInPickerOrder() {
        XCTAssertEqual(Providers.all.map(\.id), [.gmail, .icloud, .outlook, .yahoo, .aol, .fastmail, .zoho])
        XCTAssertEqual(Set(Providers.all.map(\.id)).count, Providers.all.count)
        XCTAssertNil(Providers.preset(for: .other))
        XCTAssertNil(Providers.preset(for: .demo))
        for preset in Providers.all {
            XCTAssertEqual(Providers.preset(for: preset.id)?.name, preset.name)
        }
    }

    func testGmail() throws {
        let gmail = try XCTUnwrap(Providers.preset(for: .gmail))
        XCTAssertEqual(gmail.name, "Gmail")
        XCTAssertEqual(gmail.imap.host, "imap.gmail.com")
        XCTAssertEqual(gmail.imap.port, 993)
        XCTAssertEqual(gmail.imap.security, .tls)
        XCTAssertEqual(gmail.smtp.host, "smtp.gmail.com")
        XCTAssertEqual(gmail.smtp.port, 465)
        XCTAssertEqual(gmail.smtp.security, .tls)
        XCTAssertEqual(gmail.domains, ["gmail.com", "googlemail.com"])
        XCTAssertEqual(gmail.mxSuffixes, ["google.com", "googlemail.com"])
        XCTAssertTrue(gmail.savesSentAutomatically)
        XCTAssertEqual(gmail.archiveRole, .all)
        XCTAssertEqual(gmail.oauthProvider, .google)
        XCTAssertFalse(gmail.requiresOAuth)
        XCTAssertEqual(gmail.appPassword?.url?.absoluteString, "https://myaccount.google.com/apppasswords")
        XCTAssertTrue(gmail.appPassword?.steps.contains { $0.contains("2-Step Verification") } ?? false)
        XCTAssertTrue(gmail.authOptions.contains(.oauth(.google)))
    }

    func testICloud() throws {
        let icloud = try XCTUnwrap(Providers.preset(for: .icloud))
        XCTAssertEqual(icloud.imap.host, "imap.mail.me.com")
        XCTAssertEqual(icloud.imap.port, 993)
        XCTAssertEqual(icloud.imap.security, .tls)
        XCTAssertEqual(icloud.smtp.host, "smtp.mail.me.com")
        XCTAssertEqual(icloud.smtp.port, 587)
        XCTAssertEqual(icloud.smtp.security, .startTLS)
        XCTAssertEqual(icloud.domains, ["icloud.com", "me.com", "mac.com"])
        XCTAssertEqual(icloud.mxSuffixes, ["icloud.com"])
        XCTAssertFalse(icloud.savesSentAutomatically)
        XCTAssertEqual(icloud.archiveRole, .archive)
        XCTAssertNil(icloud.oauthProvider)
        XCTAssertEqual(icloud.appPassword?.url?.absoluteString, "https://account.apple.com")
        XCTAssertTrue(icloud.appPassword?.steps.joined().contains("App-Specific Passwords") ?? false)
        XCTAssertTrue(icloud.appPassword?.steps.joined().contains("Sign-In and Security") ?? false)
        XCTAssertTrue(icloud.notes.contains { $0.contains("full iCloud address") })
        XCTAssertTrue(icloud.usernameHint.contains("iCloud"))
    }

    func testOutlookIsOAuthOnly() throws {
        let outlook = try XCTUnwrap(Providers.preset(for: .outlook))
        XCTAssertEqual(outlook.imap.host, "outlook.office365.com")
        XCTAssertEqual(outlook.imap.port, 993)
        XCTAssertEqual(outlook.imap.security, .tls)
        XCTAssertEqual(outlook.smtp.host, "smtp-mail.outlook.com")
        XCTAssertEqual(outlook.smtp.port, 587)
        XCTAssertEqual(outlook.smtp.security, .startTLS)
        XCTAssertEqual(outlook.authOptions, [.oauth(.microsoft)])
        XCTAssertTrue(outlook.requiresOAuth)
        XCTAssertNil(outlook.appPassword)
        XCTAssertTrue(outlook.savesSentAutomatically)
        for domain in ["outlook.com", "hotmail.com", "live.com", "msn.com", "hotmail.co.uk"] {
            XCTAssertTrue(outlook.domains.contains(domain), domain)
        }
        XCTAssertTrue(outlook.mxSuffixes.contains("outlook.com"))
        XCTAssertTrue(outlook.mxSuffixes.contains("protection.outlook.com"))
        XCTAssertTrue(outlook.notes.contains { $0.contains("2024") })
    }

    func testYahooAOLFastmailZoho() throws {
        let yahoo = try XCTUnwrap(Providers.preset(for: .yahoo))
        XCTAssertEqual([yahoo.imap.host, yahoo.smtp.host], ["imap.mail.yahoo.com", "smtp.mail.yahoo.com"])
        XCTAssertEqual([yahoo.imap.port, yahoo.smtp.port], [993, 465])
        XCTAssertEqual(yahoo.smtp.security, .tls)
        XCTAssertEqual(yahoo.appPassword?.url?.absoluteString, "https://login.yahoo.com/account/security")
        XCTAssertTrue(yahoo.domains.contains("ymail.com"))

        let aol = try XCTUnwrap(Providers.preset(for: .aol))
        XCTAssertEqual([aol.imap.host, aol.smtp.host], ["imap.aol.com", "smtp.aol.com"])
        XCTAssertEqual([aol.imap.port, aol.smtp.port], [993, 465])
        XCTAssertNotNil(aol.appPassword)

        let fastmail = try XCTUnwrap(Providers.preset(for: .fastmail))
        XCTAssertEqual([fastmail.imap.host, fastmail.smtp.host], ["imap.fastmail.com", "smtp.fastmail.com"])
        XCTAssertEqual([fastmail.imap.port, fastmail.smtp.port], [993, 465])
        XCTAssertTrue(fastmail.appPassword?.steps.first?.contains("Privacy & Security") ?? false)
        XCTAssertTrue(fastmail.mxSuffixes.contains("messagingengine.com"))

        let zoho = try XCTUnwrap(Providers.preset(for: .zoho))
        XCTAssertEqual([zoho.imap.host, zoho.smtp.host], ["imap.zoho.com", "smtp.zoho.com"])
        XCTAssertEqual([zoho.imap.port, zoho.smtp.port], [993, 465])
        XCTAssertTrue(zoho.authOptions.contains(.password))
        XCTAssertNotNil(zoho.appPassword)
        XCTAssertTrue(zoho.notes.contains { $0.contains("IMAP") })
    }

    func testEveryPresetIsWellFormed() {
        for preset in Providers.all {
            XCTAssertFalse(preset.name.isEmpty)
            XCTAssertFalse(preset.domains.isEmpty, preset.name)
            XCTAssertFalse(preset.mxSuffixes.isEmpty, preset.name)
            XCTAssertFalse(preset.notes.isEmpty, preset.name)
            XCTAssertFalse(preset.authOptions.isEmpty, preset.name)
            XCTAssertNotEqual(preset.imap.security, ConnectionSecurity.none, preset.name)
            XCTAssertNotEqual(preset.smtp.security, ConnectionSecurity.none, preset.name)
            XCTAssertEqual(preset.imap.port, 993, preset.name)
            XCTAssertTrue([465, 587].contains(preset.smtp.port), preset.name)
            XCTAssertEqual(preset.smtp.port == 465, preset.smtp.security == .tls, preset.name)
            XCTAssertEqual(preset.archiveRole, preset.id == .gmail ? .all : .archive, preset.name)
            for domain in preset.domains {
                XCTAssertEqual(domain, domain.lowercased())
                XCTAssertFalse(domain.hasPrefix("."))
            }
            if let appPassword = preset.appPassword {
                XCTAssertTrue((3...5).contains(appPassword.steps.count), "\(preset.name) has \(appPassword.steps.count) steps")
                XCTAssertEqual(appPassword.url?.scheme, "https", preset.name)
                for step in appPassword.steps {
                    XCTAssertLessThan(step.count, 130, "keep steps short: \(step)")
                }
            }
            for note in preset.notes { XCTAssertTrue(note.hasSuffix(".") || note.hasSuffix(")"), note) }
        }
        // No domain belongs to two presets.
        let allDomains = Providers.all.flatMap(\.domains)
        XCTAssertEqual(Set(allDomains).count, allDomains.count)
    }

    func testPresetForEmail() {
        XCTAssertEqual(Providers.preset(forEmail: "Ada.Lovelace@GMail.com")?.id, .gmail)
        XCTAssertEqual(Providers.preset(forEmail: "  someone@googlemail.com \n")?.id, .gmail)
        XCTAssertEqual(Providers.preset(forEmail: "steve@me.com")?.id, .icloud)
        XCTAssertEqual(Providers.preset(forEmail: "old@mac.com")?.id, .icloud)
        XCTAssertEqual(Providers.preset(forEmail: "x@icloud.com.")?.id, .icloud)
        XCTAssertEqual(Providers.preset(forEmail: "x@hotmail.co.uk")?.id, .outlook)
        XCTAssertEqual(Providers.preset(forEmail: "x@live.com")?.id, .outlook)
        XCTAssertEqual(Providers.preset(forEmail: "x@ymail.com")?.id, .yahoo)
        XCTAssertEqual(Providers.preset(forEmail: "x@aol.com")?.id, .aol)
        XCTAssertEqual(Providers.preset(forEmail: "x@fastmail.fm")?.id, .fastmail)
        XCTAssertEqual(Providers.preset(forEmail: "x@zohomail.eu")?.id, .zoho)
        // A quoted local part with an @ still uses the last @.
        XCTAssertEqual(Providers.preset(forEmail: "\"a@b\"@gmail.com")?.id, .gmail)
        XCTAssertNil(Providers.preset(forEmail: "x@example.org"))
        XCTAssertNil(Providers.preset(forEmail: "x@mail.gmail.com.evil.example"))
        XCTAssertNil(Providers.preset(forEmail: "gmail.com"))
        XCTAssertNil(Providers.preset(forEmail: "x@"))
        XCTAssertNil(Providers.preset(forEmail: "@gmail.com"))
        XCTAssertNil(Providers.preset(forEmail: ""))
    }

    func testPresetForMXHosts() {
        XCTAssertEqual(Providers.preset(forMXHosts: ["aspmx.l.google.com."])?.id, .gmail)
        XCTAssertEqual(Providers.preset(forMXHosts: ["SMTP.GOOGLE.COM"])?.id, .gmail)
        XCTAssertEqual(Providers.preset(forMXHosts: ["alt1.gmail-smtp-in.l.google.com"])?.id, .gmail)
        XCTAssertEqual(Providers.preset(forMXHosts: ["aspmx2.googlemail.com"])?.id, .gmail)
        XCTAssertEqual(Providers.preset(forMXHosts: ["contoso-com.mail.protection.outlook.com"])?.id, .outlook)
        XCTAssertEqual(Providers.preset(forMXHosts: ["hotmail-com.olc.protection.outlook.com"])?.id, .outlook)
        XCTAssertEqual(Providers.preset(forMXHosts: ["in1-smtp.messagingengine.com", "in2-smtp.messagingengine.com"])?.id, .fastmail)
        XCTAssertEqual(Providers.preset(forMXHosts: ["mx.zoho.com"])?.id, .zoho)
        XCTAssertEqual(Providers.preset(forMXHosts: ["mx2.zoho.eu"])?.id, .zoho)
        XCTAssertEqual(Providers.preset(forMXHosts: ["mx01.mail.icloud.com", "mx02.mail.icloud.com"])?.id, .icloud)
        XCTAssertEqual(Providers.preset(forMXHosts: ["mta5.am0.yahoodns.net"])?.id, .yahoo)
        XCTAssertEqual(Providers.preset(forMXHosts: ["mx-aol.mail.gm0.yahoodns.net"])?.id, .aol)
        XCTAssertEqual(Providers.preset(forMXHosts: ["mx-aol.mail.gm1.yahoodns.net"])?.id, .aol)
        // The first recognised host decides; unknown hosts are skipped.
        XCTAssertEqual(Providers.preset(forMXHosts: ["mx1.mailgun.example", "aspmx.l.google.com"])?.id, .gmail)
        XCTAssertNil(Providers.preset(forMXHosts: ["mx.example.com"]))
        XCTAssertNil(Providers.preset(forMXHosts: ["notgoogle.com"]))
        XCTAssertNil(Providers.preset(forMXHosts: ["google.com.evil.example"]))
        XCTAssertNil(Providers.preset(forMXHosts: ["", " "]))
        XCTAssertNil(Providers.preset(forMXHosts: []))
    }

    func testPresetForServerHost() {
        XCTAssertEqual(Providers.preset(forServerHost: "imap.gmail.com")?.id, .gmail)
        XCTAssertEqual(Providers.preset(forServerHost: "IMAP.GMAIL.COM.")?.id, .gmail)
        XCTAssertEqual(Providers.preset(forServerHost: "smtp.office365.com")?.id, .outlook)
        XCTAssertEqual(Providers.preset(forServerHost: "imap-mail.outlook.com")?.id, .outlook)
        XCTAssertEqual(Providers.preset(forServerHost: "p02-imap.mail.me.com")?.id, .icloud)
        XCTAssertEqual(Providers.preset(forServerHost: "imappro.zoho.eu")?.id, .zoho)
        XCTAssertEqual(Providers.preset(forServerHost: "mail.messagingengine.com")?.id, .fastmail)
        XCTAssertNil(Providers.preset(forServerHost: "imap.example.com"))
        XCTAssertNil(Providers.preset(forServerHost: ""))
    }

    func testAccountConfigWithAppPassword() throws {
        let icloud = try XCTUnwrap(Providers.preset(for: .icloud))
        let account = icloud.accountConfig(email: " grace@icloud.com ", displayName: " Grace Hopper ", authMethod: .password)
        XCTAssertEqual(account.provider, .icloud)
        XCTAssertEqual(account.emailAddress, "grace@icloud.com")
        XCTAssertEqual(account.displayName, "Grace Hopper")
        XCTAssertEqual(account.imap, ServerConfig(host: "imap.mail.me.com", port: 993, security: .tls, username: "grace@icloud.com"))
        XCTAssertEqual(account.smtp, ServerConfig(host: "smtp.mail.me.com", port: 587, security: .startTLS, username: "grace@icloud.com"))
        XCTAssertEqual(account.authMethod, .password)
        XCTAssertNil(account.oauthProvider)
        XCTAssertFalse(account.savesSentAutomatically)
    }

    func testAccountConfigWithOAuth() throws {
        let gmail = try XCTUnwrap(Providers.preset(for: .gmail))
        let account = gmail.accountConfig(email: "ada@gmail.com", displayName: "Ada", authMethod: .oauth2)
        XCTAssertEqual(account.authMethod, .oauth2)
        XCTAssertEqual(account.oauthProvider, .google)
        XCTAssertTrue(account.savesSentAutomatically)
        XCTAssertEqual(account.imap.username, "ada@gmail.com")
        XCTAssertEqual(account.smtp.host, "smtp.gmail.com")

        let outlook = try XCTUnwrap(Providers.preset(for: .outlook))
        let work = outlook.accountConfig(email: "sam@hotmail.com", displayName: "Sam", authMethod: .oauth2)
        XCTAssertEqual(work.oauthProvider, .microsoft)
        XCTAssertTrue(work.savesSentAutomatically)

        // A password account on a provider without OAuth never records an OAuth provider.
        let yahoo = try XCTUnwrap(Providers.preset(for: .yahoo))
        XCTAssertNil(yahoo.accountConfig(email: "a@yahoo.com", displayName: "A", authMethod: .oauth2).oauthProvider)
    }

    func testZohoRegionalHosts() throws {
        let zoho = try XCTUnwrap(Providers.preset(for: .zoho))
        XCTAssertEqual(zoho.accountConfig(email: "a@zohomail.com", displayName: "", authMethod: .password).imap.host, "imap.zoho.com")
        let eu = zoho.accountConfig(email: "a@zohomail.eu", displayName: "", authMethod: .password)
        XCTAssertEqual(eu.imap.host, "imap.zoho.eu")
        XCTAssertEqual(eu.smtp.host, "smtp.zoho.eu")
        XCTAssertEqual(zoho.accountConfig(email: "a@zohomail.in", displayName: "", authMethod: .password).smtp.host, "smtp.zoho.in")
        XCTAssertEqual(zoho.accountConfig(email: "a@zoho.com.au", displayName: "", authMethod: .password).imap.host, "imap.zoho.com.au")
        XCTAssertEqual(ZohoRegion.forMXHost("mx.zoho.com.au"), .australia)
        XCTAssertEqual(ZohoRegion.forMXHost("mx.zoho.com"), .us)
        XCTAssertEqual(ZohoRegion.forMXHost("mx3.zohocloud.ca"), .canada)
        XCTAssertNil(ZohoRegion.forMXHost("mx.notzoho.com"))
    }

    func testHandlesEmail() throws {
        let gmail = try XCTUnwrap(Providers.preset(for: .gmail))
        XCTAssertTrue(gmail.handles(email: "x@GMAIL.com"))
        XCTAssertFalse(gmail.handles(email: "x@workspace.example"))
    }

    func testCleanedAppPassword() throws {
        let gmail = try XCTUnwrap(Providers.preset(for: .gmail))
        XCTAssertEqual(gmail.cleanedAppPassword(" abcd efgh ijkl mnop\n"), "abcdefghijklmnop")
        XCTAssertEqual(gmail.cleanedAppPassword("abcd\u{00A0}efgh"), "abcdefgh")
        let icloud = try XCTUnwrap(Providers.preset(for: .icloud))
        XCTAssertEqual(icloud.cleanedAppPassword(" abcd-efgh-ijkl-mnop "), "abcd-efgh-ijkl-mnop")
        let zoho = try XCTUnwrap(Providers.preset(for: .zoho))
        XCTAssertEqual(zoho.cleanedAppPassword("my pass phrase"), "my pass phrase")
    }

    func testAuthOptionHelpers() {
        XCTAssertEqual(ProviderAuthOption.oauth(.google).authMethod, .oauth2)
        XCTAssertEqual(ProviderAuthOption.password.authMethod, .password)
        XCTAssertEqual(ProviderAuthOption.appPassword(url: nil, steps: []).authMethod, .password)
        XCTAssertEqual(ProviderAuthOption.oauth(.microsoft).oauthProvider, .microsoft)
        XCTAssertNil(ProviderAuthOption.password.oauthProvider)
    }
}
