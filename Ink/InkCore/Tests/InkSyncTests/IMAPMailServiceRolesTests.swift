import XCTest
import InkModel
import InkIMAP
@testable import InkSync

/// Folder roles and ordering from real LIST responses of the major providers.
final class IMAPMailServiceRolesTests: XCTestCase {
    private func infos(_ list: String, file: StaticString = #filePath, line: UInt = #line) -> [MailboxInfo] {
        let responses: [IMAPResponse]
        do {
            responses = try IMAPResponseParser.parseAll(IMAPServiceFixtures.crlf(list + "\n"))
        } catch {
            XCTFail("LIST fixture didn't parse: \(error)", file: file, line: line)
            return []
        }
        let mailboxes: [IMAPMailbox] = responses.compactMap {
            if case .untagged(.list(let mailbox)) = $0 { return mailbox }
            return nil
        }
        return IMAPMailServiceRoles.mailboxInfos(from: mailboxes, accountID: "a")
    }

    private func roles(_ infos: [MailboxInfo]) -> [String: MailboxRole] {
        Dictionary(infos.map { ($0.path, $0.role) }, uniquingKeysWith: { first, _ in first })
    }

    func testGmailSpecialUse() {
        let result = infos("""
        * LIST (\\HasNoChildren) "/" "INBOX"
        * LIST (\\HasChildren \\Noselect) "/" "[Gmail]"
        * LIST (\\All \\HasNoChildren) "/" "[Gmail]/All Mail"
        * LIST (\\Drafts \\HasNoChildren) "/" "[Gmail]/Drafts"
        * LIST (\\HasNoChildren \\Important) "/" "[Gmail]/Important"
        * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"
        * LIST (\\HasNoChildren \\Junk) "/" "[Gmail]/Spam"
        * LIST (\\Flagged \\HasNoChildren) "/" "[Gmail]/Starred"
        * LIST (\\HasNoChildren \\Trash) "/" "[Gmail]/Trash"
        * LIST (\\HasNoChildren) "/" "Receipts"
        * LIST (\\HasNoChildren) "/" "&AMk-t&AOk-"
        * LIST (\\HasNoChildren) "/" "Archive"
        """)
        let map = roles(result)
        XCTAssertEqual(map["INBOX"], .inbox)
        XCTAssertEqual(map["[Gmail]/All Mail"], .all)
        XCTAssertEqual(map["[Gmail]/Drafts"], .drafts)
        XCTAssertEqual(map["[Gmail]/Sent Mail"], .sent)
        XCTAssertEqual(map["[Gmail]/Spam"], .junk)
        XCTAssertEqual(map["[Gmail]/Starred"], .flagged)
        XCTAssertEqual(map["[Gmail]/Trash"], .trash)
        XCTAssertEqual(map["[Gmail]/Important"], .custom)
        XCTAssertEqual(map["[Gmail]"], .custom)
        XCTAssertEqual(map["Été"], .custom)
        // A user label called "Archive" on Gmail is still a well-known name; no \Archive attribute claimed the role.
        XCTAssertEqual(map["Archive"], .archive)
        XCTAssertEqual(result.map(\.path), [
            "INBOX", "[Gmail]/Starred", "[Gmail]/Drafts", "[Gmail]/Sent Mail", "[Gmail]/All Mail", "Archive",
            "[Gmail]/Spam", "[Gmail]/Trash", "[Gmail]", "[Gmail]/Important", "Été", "Receipts",
        ])
        XCTAssertEqual(result.first(where: { $0.path == "Été" })?.rawPath, "&AMk-t&AOk-")
        XCTAssertFalse(result.first(where: { $0.path == "[Gmail]" })?.isSelectable ?? true)
    }

    func testGoogleMailGermanXListStyleNames() {
        // Older German Gmail accounts: "[Google Mail]" with localized names and XLIST attributes.
        let result = infos("""
        * LIST (\\HasNoChildren \\Inbox) "/" "Posteingang"
        * LIST (\\Noselect \\HasChildren) "/" "[Google Mail]"
        * LIST (\\HasNoChildren \\AllMail) "/" "[Google Mail]/Alle Nachrichten"
        * LIST (\\HasNoChildren \\Drafts) "/" "[Google Mail]/Entw&APw-rfe"
        * LIST (\\HasNoChildren \\Sent) "/" "[Google Mail]/Gesendet"
        * LIST (\\HasNoChildren \\Spam) "/" "[Google Mail]/Spam"
        * LIST (\\HasNoChildren \\Starred) "/" "[Google Mail]/Markiert"
        * LIST (\\HasNoChildren \\Trash) "/" "[Google Mail]/Papierkorb"
        """)
        let map = roles(result)
        XCTAssertEqual(map["INBOX"], .inbox, "the \\Inbox attribute marks the inbox whatever it's called")
        XCTAssertEqual(map["[Google Mail]/Alle Nachrichten"], .all)
        XCTAssertEqual(map["[Google Mail]/Entwürfe"], .drafts)
        XCTAssertEqual(map["[Google Mail]/Gesendet"], .sent)
        XCTAssertEqual(map["[Google Mail]/Spam"], .junk)
        XCTAssertEqual(map["[Google Mail]/Markiert"], .flagged)
        XCTAssertEqual(map["[Google Mail]/Papierkorb"], .trash)
        XCTAssertEqual(result.first?.rawPath, "Posteingang")
    }

    func testICloudNamesWithoutSpecialUse() {
        // iCloud's classic folder names; roles come from the names.
        let result = infos("""
        * LIST (\\HasNoChildren) "/" "Archive"
        * LIST (\\HasNoChildren) "/" "Deleted Messages"
        * LIST (\\HasNoChildren) "/" "Drafts"
        * LIST (\\HasNoChildren) "/" INBOX
        * LIST (\\HasNoChildren) "/" "Junk"
        * LIST (\\HasNoChildren) "/" "Notes"
        * LIST (\\HasNoChildren) "/" "Sent Messages"
        * LIST (\\HasChildren) "/" "Projects"
        * LIST (\\HasNoChildren) "/" "Projects/Archive"
        """)
        let map = roles(result)
        XCTAssertEqual(map["Archive"], .archive)
        XCTAssertEqual(map["Deleted Messages"], .trash)
        XCTAssertEqual(map["Drafts"], .drafts)
        XCTAssertEqual(map["Junk"], .junk)
        XCTAssertEqual(map["Sent Messages"], .sent)
        XCTAssertEqual(map["Notes"], .custom)
        XCTAssertEqual(map["Projects/Archive"], .custom, "nested user folders never take a system role")
        XCTAssertEqual(result.map(\.path), ["INBOX", "Drafts", "Sent Messages", "Archive", "Junk", "Deleted Messages",
                                            "Notes", "Projects", "Projects/Archive"])
    }

    func testOutlookSpecialUseBeatsLegacyNames() {
        // Outlook.com / Office 365 mark the real folders; a stray legacy "Sent" stays custom.
        let result = infos("""
        * LIST (\\HasNoChildren) "/" Archive
        * LIST (\\HasNoChildren) "/" Calendar
        * LIST (\\HasNoChildren \\Trash) "/" "Deleted Items"
        * LIST (\\HasNoChildren \\Drafts) "/" Drafts
        * LIST (\\Marked \\HasNoChildren) "/" Inbox
        * LIST (\\HasNoChildren \\Junk) "/" "Junk Email"
        * LIST (\\HasNoChildren) "/" Outbox
        * LIST (\\HasNoChildren \\Sent) "/" "Sent Items"
        * LIST (\\HasNoChildren) "/" Sent
        """)
        let map = roles(result)
        XCTAssertEqual(map["INBOX"], .inbox, "Outlook's \"Inbox\" is the inbox (normalized path)")
        XCTAssertEqual(result.first?.rawPath, "Inbox")
        XCTAssertEqual(map["Deleted Items"], .trash)
        XCTAssertEqual(map["Junk Email"], .junk)
        XCTAssertEqual(map["Sent Items"], .sent)
        XCTAssertEqual(map["Sent"], .custom)
        XCTAssertEqual(map["Archive"], .archive)
        XCTAssertEqual(map["Outbox"], .custom)
    }

    func testYahooBulkMailAndDraft() {
        let result = infos("""
        * LIST (\\HasNoChildren) "/" "Archive"
        * LIST (\\Junk \\HasNoChildren) "/" "Bulk"
        * LIST (\\HasNoChildren \\Drafts) "/" "Draft"
        * LIST (\\HasNoChildren) "/" "Inbox"
        * LIST (\\HasNoChildren \\Sent) "/" "Sent"
        * LIST (\\HasNoChildren \\Trash) "/" "Trash"
        * LIST (\\HasNoChildren) "/" "Bulk Mail"
        """)
        let map = roles(result)
        XCTAssertEqual(map["Bulk"], .junk)
        XCTAssertEqual(map["Bulk Mail"], .custom, "the \\Junk folder already claimed the role")
        XCTAssertEqual(map["Draft"], .drafts)
        XCTAssertEqual(map["Archive"], .archive)
    }

    func testCourierInboxNamespaceAndDovecotDot() {
        // cPanel/Courier: every folder lives under INBOX with "." as delimiter.
        let result = infos("""
        * LIST (\\Unmarked \\HasChildren) "." "INBOX"
        * LIST (\\HasNoChildren) "." "INBOX.Sent"
        * LIST (\\HasNoChildren) "." "INBOX.Drafts"
        * LIST (\\HasNoChildren) "." "INBOX.Trash"
        * LIST (\\HasNoChildren) "." "INBOX.spam"
        * LIST (\\HasNoChildren) "." "INBOX.Clients.Acme"
        * LIST (\\HasNoChildren) "." "INBOX.Clients"
        """)
        let map = roles(result)
        XCTAssertEqual(map["INBOX.Sent"], .sent)
        XCTAssertEqual(map["INBOX.Drafts"], .drafts)
        XCTAssertEqual(map["INBOX.Trash"], .trash)
        XCTAssertEqual(map["INBOX.spam"], .junk)
        XCTAssertEqual(map["INBOX.Clients"], .custom)
        XCTAssertEqual(result.suffix(2).map(\.path), ["INBOX.Clients", "INBOX.Clients.Acme"], "children follow their parent")
        XCTAssertEqual(IMAPMailServiceRoles.newFolderRawName("Archive", existing: result), "INBOX.Archive")
    }

    func testGermanAndFrenchProviderNames() {
        let result = infos("""
        * LIST (\\HasNoChildren) "/" "INBOX"
        * LIST (\\HasNoChildren) "/" "Gesendet"
        * LIST (\\HasNoChildren) "/" "Entw&APw-rfe"
        * LIST (\\HasNoChildren) "/" "Papierkorb"
        * LIST (\\HasNoChildren) "/" "Spamverdacht"
        * LIST (\\HasNoChildren) "/" "Archiv"
        * LIST (\\HasNoChildren) "/" "&AMk-l&AOk-ments envoy&AOk-s"
        """)
        let map = roles(result)
        XCTAssertEqual(map["Gesendet"], .sent)
        XCTAssertEqual(map["Entwürfe"], .drafts)
        XCTAssertEqual(map["Papierkorb"], .trash)
        XCTAssertEqual(map["Spamverdacht"], .junk)
        XCTAssertEqual(map["Archiv"], .archive)
        XCTAssertEqual(map["Éléments envoyés"], .custom, "\"Gesendet\" is the better Sent match; only one folder per role")
    }

    func testBestNameWinsWhenSeveralMatch() {
        let result = infos("""
        * LIST () "/" INBOX
        * LIST () "/" "Sent Items"
        * LIST () "/" "Sent"
        * LIST () "/" "Trash"
        * LIST () "/" "Deleted Items"
        * LIST (\\Noselect) "/" "Archive"
        """)
        let map = roles(result)
        XCTAssertEqual(map["Sent"], .sent)
        XCTAssertEqual(map["Sent Items"], .custom)
        XCTAssertEqual(map["Trash"], .trash)
        XCTAssertEqual(map["Deleted Items"], .custom)
        XCTAssertEqual(map["Archive"], .custom, "a \\Noselect placeholder can't be the archive")
    }

    func testMissingInboxIsAddedAndDuplicateSpecialUseDemoted() {
        let result = infos("""
        * LIST (\\Sent) "/" "Sent"
        * LIST (\\Sent) "/" "Sent Messages"
        * LIST () "/" "Work"
        """)
        XCTAssertEqual(result.first?.path, "INBOX")
        XCTAssertEqual(result.first?.role, .inbox)
        let map = roles(result)
        XCTAssertEqual(map["Sent"], .sent)
        XCTAssertEqual(map["Sent Messages"], .custom)
    }

    func testGreenMailOnlyInboxAndNewFolderNames() {
        let result = infos("""
        * LIST () "." "INBOX"
        """)
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(IMAPMailServiceRoles.newFolderRawName("Archive", existing: result), "Archive")
        XCTAssertEqual(IMAPMailServiceRoles.newFolderRawName("Éléments", existing: result), "&AMk-l&AOk-ments")
        let mixed = infos("""
        * LIST () "/" "INBOX"
        * LIST () "/" "Sent"
        * LIST () "/" "INBOX/Receipts"
        """)
        XCTAssertEqual(IMAPMailServiceRoles.newFolderRawName("Archive", existing: mixed), "Archive")
        let courierMixedCase = infos("""
        * LIST () "." "Inbox"
        * LIST () "." "Inbox.Sent"
        """)
        XCTAssertEqual(IMAPMailServiceRoles.newFolderRawName("Archive", existing: courierMixedCase), "Inbox.Archive")
    }

    func testCustomFoldersSortNaturallyAndCaseInsensitively() {
        let result = infos("""
        * LIST () "/" INBOX
        * LIST () "/" "zeta"
        * LIST () "/" "Alpha"
        * LIST () "/" "Projects-Old"
        * LIST () "/" "Projects/Ink"
        * LIST () "/" "Projects"
        * LIST () "/" "Item 10"
        * LIST () "/" "Item 9"
        """)
        XCTAssertEqual(result.map(\.path), ["INBOX", "Alpha", "Item 9", "Item 10", "Projects", "Projects/Ink", "Projects-Old", "zeta"])
    }

    func testSearchTerms() {
        XCTAssertEqual(IMAPMailService.searchTerms("invoice  march"), ["invoice", "march"])
        XCTAssertEqual(IMAPMailService.searchTerms("\"board meeting\" notes"), ["board meeting", "notes"])
        XCTAssertEqual(IMAPMailService.searchTerms("Ada ada ADA"), ["Ada"])
        XCTAssertEqual(IMAPMailService.searchTerms("   "), [])
        XCTAssertEqual(IMAPMailService.searchTerms("\"unterminated phrase"), ["unterminated phrase"])
        XCTAssertEqual(IMAPMailService.searchTerms("a b c d e f g h i j").count, 8)
    }

    func testSentCopyGetsBccHeader() {
        let data = Data("Date: Tue, 20 Oct 2026 09:00:00 +0000\r\nSubject: Hi\r\n\r\nBody\r\n".utf8)
        XCTAssertEqual(IMAPMailService.sentCopy(data, bcc: []), data)
        let copy = IMAPMailService.sentCopy(data, bcc: [
            EmailAddress(name: "Grace Hopper", address: "grace@example.com"),
            EmailAddress(name: "Zoë Kravitz", address: "zoe@example.com"),
            EmailAddress(address: "grace@EXAMPLE.com"),
        ])
        let text = String(decoding: copy, as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("Bcc: Grace Hopper <grace@example.com>,\r\n =?UTF-8?"), text)
        XCTAssertTrue(text.contains("<zoe@example.com>\r\nDate: Tue"), text)
        XCTAssertEqual(text.components(separatedBy: "grace@").count - 1, 1, "duplicates removed")
    }

    func testGoogleSMTPHosts() {
        XCTAssertTrue(IMAPMailService.isGoogleSMTP("smtp.gmail.com"))
        XCTAssertTrue(IMAPMailService.isGoogleSMTP("SMTP.GoogleMail.com"))
        XCTAssertTrue(IMAPMailService.isGoogleSMTP("smtp-relay.google.com"))
        XCTAssertFalse(IMAPMailService.isGoogleSMTP("smtp.fastmail.com"))
    }
}
