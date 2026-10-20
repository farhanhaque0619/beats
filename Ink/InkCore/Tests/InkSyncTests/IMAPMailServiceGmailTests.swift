import XCTest
import InkModel
import InkIMAP
@testable import InkSync

/// Gmail (X-GM-EXT-1) behaviour against transcripts of Gmail's IMAP server: X-GM-* fetches,
/// archive via All Mail / label removal, X-GM-RAW search, X-GM-MSGID lookups, Trash handling.
final class IMAPMailServiceGmailTests: XCTestCase {
    typealias T = IMAPServiceTranscripts
    typealias F = IMAPServiceFixtures

    let account = F.account(provider: .gmail, email: "ada@gmail.com", host: "imap.gmail.com", smtpHost: "smtp.gmail.com",
                            authMethod: .oauth2, savesSentAutomatically: true)
    let token = Credential.oauth(OAuthToken(accessToken: "ya29.a0AfB_token", refreshToken: "1//refresh", expiresAt: nil))
    var inbox: MailboxInfo { MailboxInfo(accountID: account.id, path: "INBOX", rawPath: "INBOX", role: .inbox) }

    static let gmailItems = "X-GM-THRID X-GM-MSGID X-GM-LABELS)"

    private func gmailSummary(_ uid: UInt32, path: String = "INBOX", gmailID: UInt64, messageID: String) -> MessageSummary {
        MessageSummary(accountID: account.id, mailboxPath: path, uid: uid, uidValidity: 1, messageID: messageID,
                       gmailThreadID: gmailID, gmailMessageID: gmailID, subject: "S", from: [], date: Date())
    }

    func testGmailSessionEndToEnd() async throws {
        let newsletterHeaders = ["List-Unsubscribe: <https://acmebank.example/u/abc123>", "List-Unsubscribe-Post: List-Unsubscribe=One-Click"]
        let rawMessage = F.crlf("""
        From: Acme Bank <statements@acmebank.example>
        To: ada@gmail.com
        Subject: Your October statement
        Date: Mon, 19 Oct 2026 09:02:03 -0700
        Message-ID: <stmt-2026-10@acmebank.example>
        MIME-Version: 1.0
        Content-Type: multipart/alternative; boundary="b"

        --b
        Content-Type: text/plain; charset=utf-8

        Your statement is ready.
        --b
        Content-Type: text/html; charset=utf-8

        <p>Your statement is <b>ready</b>.</p>
        --b--

        """)
        let script = ScriptedTransport(T.gmailLogin() + [
            // mailboxes()
            T.listStep(T.gmailList),
            // sync(INBOX): the newest two messages, with Gmail's ids and labels.
            T.gmailSelect("INBOX", exists: 2763, uidNext: 35861),
            .expect("* FETCH 2762:2763 \(T.summaryItemsPrefix) \(Self.gmailItems)", reply:
                T.summary(seq: 2762, uid: 35859, flags: "\\Seen", subject: "Re: Lunch Thursday?", fromName: "Grace Hopper",
                          fromAddress: ("grace", "gmail.com"), messageID: "CAF=lunch@mail.gmail.com", structure: T.mixedStructure,
                          gmail: .init(threadID: 1781000000000000001, messageID: 1781000000000000009, labels: "(\"\\\\Inbox\" \"\\\\Important\" \"Friends\")"))
                + T.summary(seq: 2763, uid: 35860, subject: "Your October statement", fromName: "Acme Bank",
                            fromAddress: ("statements", "acmebank.example"), messageID: "stmt-2026-10@acmebank.example",
                            structure: T.alternativeStructure, headers: newsletterHeaders,
                            gmail: .init(threadID: 1781234567890123456, messageID: 1781234567890123457, labels: "(\"\\\\Inbox\")"))
                + "{TAG} OK Success\r\n"),
            .expect("* UID FETCH 35859 (UID BODY.PEEK[1.1]<0.2048>)", reply: T.snippet(seq: 2762, uid: 35859, section: "1.1", text: "Thursday works. Noon at the usual place?") + "{TAG} OK Success\r\n"),
            .expect("* UID FETCH 35860 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 2763, uid: 35860, text: "Your statement is ready.=0D=0A") + "{TAG} OK Success\r\n"),
            // body(for:)
            .expect("* UID FETCH 35860 (UID BODY.PEEK[])", reply: "* 2763 FETCH (UID 35860 BODY[] \(F.literal(rawMessage)))\r\n{TAG} OK Success\r\n"),
            // read
            .expect("* UID STORE 35860 +FLAGS.SILENT (\\Seen)", reply: "{TAG} OK Success\r\n"),
            // archive from INBOX: MOVE to All Mail drops the Inbox label.
            .expect("* UID MOVE 35860 \"[Gmail]/All Mail\"", reply: "* OK [COPYUID 1 35860 9001] (Success)\r\n* 2763 EXPUNGE\r\n{TAG} OK Success\r\n"),
            // archive from a label: remove \Inbox, keep the label.
            T.gmailSelect("Receipts", exists: 80, uidNext: 81, uidValidity: 7),
            .expect("* UID STORE 77 -X-GM-LABELS (\\Inbox)", reply: "* 77 FETCH (X-GM-LABELS (\"Receipts\") UID 77)\r\n{TAG} OK Success\r\n"),
            // search: X-GM-RAW in All Mail.
            T.gmailSelect("[Gmail]/All Mail", exists: 9100, uidNext: 9101),
            .expect("* UID SEARCH RETURN (ALL) X-GM-RAW \"from:acme has:attachment\"", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 8800,9001\r\n{TAG} OK SEARCH completed (Success)\r\n"),
            .expect("* UID FETCH 8800,9001 \(T.summaryItemsPrefix) \(Self.gmailItems)", reply:
                T.summary(seq: 8790, uid: 8800, subject: "September statement", fromName: "Acme Bank", fromAddress: ("statements", "acmebank.example"),
                          date: "Sat, 19 Sep 2026 09:02:03 -0700", messageID: "stmt-2026-09@acmebank.example",
                          gmail: .init(threadID: 1779000000000000001, messageID: 1779000000000000001, labels: "()"))
                + T.summary(seq: 9000, uid: 9001, subject: "Your October statement", fromName: "Acme Bank", fromAddress: ("statements", "acmebank.example"),
                            messageID: "stmt-2026-10@acmebank.example",
                            gmail: .init(threadID: 1781234567890123456, messageID: 1781234567890123457, labels: "()"))
                + "{TAG} OK Success\r\n"),
            .expect("* UID FETCH 8800,9001 (UID BODY.PEEK[1]<0.2048>)", reply: "{TAG} OK Success\r\n"),
            // moveToInbox (e.g. a snooze waking up): the INBOX copy is gone; found in All Mail by X-GM-MSGID and copied back.
            T.gmailSelect("INBOX", exists: 2762, uidNext: 35861),
            .expect("* UID SEARCH RETURN (ALL) UID 35860 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK SEARCH completed (Success)\r\n"),
            .expect("* UID SEARCH RETURN (ALL) X-GM-MSGID 1781234567890123457 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK SEARCH completed (Success)\r\n"),
            T.gmailSelect("[Gmail]/All Mail", exists: 9100, uidNext: 9101),
            .expect("* UID SEARCH RETURN (ALL) X-GM-MSGID 1781234567890123457 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 9001\r\n{TAG} OK SEARCH completed (Success)\r\n"),
            .expect("* UID COPY 9001 INBOX", reply: "{TAG} OK [COPYUID 1 9001 35862] (Success)\r\n"),
            T.logoutStep,
        ])
        let log = IMAPServiceLog()
        let service = F.service(account, credential: token, transports: IMAPServiceTransportQueue([script]), log: log)

        let boxes = try await service.mailboxes()
        XCTAssertEqual(boxes.first(where: { $0.role == .all })?.rawPath, "[Gmail]/All Mail")

        let result = try await service.sync(mailbox: inbox, previous: nil, limit: 2)
        XCTAssertEqual(result.upserted.map(\.uid), [35860, 35859])
        let statement = result.upserted[0], lunch = result.upserted[1]
        XCTAssertEqual(statement.gmailThreadID, 1781234567890123456)
        XCTAssertEqual(statement.gmailMessageID, 1781234567890123457)
        XCTAssertEqual(statement.gmailLabels, ["\\Inbox"])
        XCTAssertTrue(statement.isBulk)
        XCTAssertEqual(statement.listUnsubscribePost, "List-Unsubscribe=One-Click")
        XCTAssertEqual(statement.snippet, "Your statement is ready.")
        XCTAssertEqual(lunch.gmailLabels, ["\\Inbox", "\\Important", "Friends"])
        XCTAssertEqual(lunch.snippet, "Thursday works. Noon at the usual place?")
        XCTAssertEqual(lunch.dedupeKey, "\(account.id)|gm:1781000000000000009")
        XCTAssertTrue(lunch.hasAttachments)
        XCTAssertEqual(result.state.highestModSeq, 4416219)

        let body = try await service.body(for: statement)
        XCTAssertEqual(body.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Your statement is ready.")
        XCTAssertTrue(body.html?.contains("<b>ready</b>") ?? false)

        try await service.perform(.markRead, on: [statement])
        try await service.perform(.archive, on: [statement])
        let receipt = MessageSummary(accountID: account.id, mailboxPath: "Receipts", uid: 77, uidValidity: 7, subject: "Receipt", from: [], date: Date())
        try await service.perform(.archive, on: [receipt])

        let found = try await service.search("from:acme has:attachment", in: inbox, limit: 10)
        XCTAssertEqual(found.map(\.uid), [9001, 8800])
        XCTAssertEqual(Set(found.map(\.mailboxPath)), ["[Gmail]/All Mail"], "Gmail searches All Mail")

        try await service.perform(.moveToInbox, on: [statement])
        await service.disconnect()
        XCTAssertFalse(script.transcript.contains("UID MOVE 9001 INBOX"), "copying from All Mail adds the label; moving would drop others")
        XCTAssertFalse(log.text.contains("ya29.a0AfB_token"), "tokens never reach the log")
        XCTAssertFalse(log.text.contains(T.xoauth2("ada@gmail.com", "ya29.a0AfB_token")))
    }

    func testGmailTrashSpamAndDeleteForGood() async throws {
        let script = ScriptedTransport(T.gmailLogin() + [
            T.listStep(T.gmailList),
            T.gmailSelect("Receipts", exists: 80, uidNext: 81, uidValidity: 1),
            .expect("* UID MOVE 77 \"[Gmail]/Trash\"", reply: "{TAG} OK Success\r\n"),
            // Deleting for good outside Trash: move to Trash first, then expunge there.
            T.gmailSelect("INBOX", exists: 2763, uidNext: 35861),
            .expect("* UID MOVE 35850 \"[Gmail]/Trash\"", reply: "* OK [COPYUID 1 35850 4242] (Success)\r\n* 2750 EXPUNGE\r\n{TAG} OK Success\r\n"),
            T.gmailSelect("[Gmail]/Trash", exists: 12, uidNext: 4243),
            .expect("* UID STORE 4242 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Success\r\n"),
            .expect("* UID EXPUNGE 4242", reply: "* 12 EXPUNGE\r\n{TAG} OK Success\r\n"),
            // Without COPYUID the Trash copy is found by X-GM-MSGID.
            T.gmailSelect("INBOX", exists: 2762, uidNext: 35861),
            .expect("* UID MOVE 35849 \"[Gmail]/Trash\"", reply: "{TAG} OK Success\r\n"),
            T.gmailSelect("[Gmail]/Trash", exists: 12, uidNext: 4244),
            .expect("* UID SEARCH RETURN (ALL) X-GM-MSGID 1777 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 4243\r\n{TAG} OK SEARCH completed (Success)\r\n"),
            .expect("* UID STORE 4243 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Success\r\n"),
            .expect("* UID EXPUNGE 4243", reply: "{TAG} OK Success\r\n"),
            // Spam.
            T.gmailSelect("INBOX", exists: 2761, uidNext: 35861),
            .expect("* UID MOVE 35851 \"[Gmail]/Spam\"", reply: "{TAG} OK Success\r\n"),
            // Out of Trash: the stated folder still has it.
            T.gmailSelect("[Gmail]/Trash", exists: 11, uidNext: 4244),
            .expect("* UID SEARCH RETURN (ALL) UID 4100 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 4100\r\n{TAG} OK SEARCH completed (Success)\r\n"),
            .expect("* UID MOVE 4100 INBOX", reply: "{TAG} OK Success\r\n"),
        ])
        let service = F.service(account, credential: token, transports: IMAPServiceTransportQueue([script]))
        let receipt = MessageSummary(accountID: account.id, mailboxPath: "Receipts", uid: 77, uidValidity: 1, subject: "R", from: [], date: Date())
        try await service.perform(.trash, on: [receipt])
        try await service.perform(.deletePermanently, on: [gmailSummary(35850, gmailID: 1776, messageID: "x@y")])
        try await service.perform(.deletePermanently, on: [gmailSummary(35849, gmailID: 1777, messageID: "z@y")])
        try await service.perform(.markSpam, on: [gmailSummary(35851, gmailID: 1778, messageID: "s@y")])
        try await service.perform(.moveToInbox, on: [gmailSummary(4100, path: "[Gmail]/Trash", gmailID: 1779, messageID: "t@y")])
    }

    func testGmailWithHiddenSystemLabels() async throws {
        // Gmail lets users hide All Mail and Trash from IMAP.
        let hidden = F.crlf("""
        * LIST (\\HasNoChildren) "/" "INBOX"
        * LIST (\\HasChildren \\Noselect) "/" "[Gmail]"
        * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"

        """)
        let script = ScriptedTransport(T.gmailLogin() + [
            T.listStep(hidden),
            T.gmailSelect("INBOX", exists: 10, uidNext: 11),
            .expect("* UID STORE 9 -X-GM-LABELS (\\Inbox)", reply: "* 9 EXPUNGE\r\n{TAG} OK Success\r\n"),
            // An unknown search target falls back to the mailbox asked for.
            .expect("* UID SEARCH RETURN (ALL) X-GM-RAW \"is:unread\"", reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK SEARCH completed (Success)\r\n"),
        ])
        let service = F.service(account, credential: token, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.archive, on: [gmailSummary(9, gmailID: 1, messageID: "a@b")])
        await assertIMAPServiceThrows(where: { if case .notSupported = $0 { return true } else { return false } }) {
            try await service.perform(.trash, on: [self.gmailSummary(8, gmailID: 2, messageID: "c@d")])
        }
        let results = try await service.search("is:unread", in: inbox, limit: 20)
        XCTAssertTrue(results.isEmpty)
    }

    func testGmailSendDoesNotAppendSentCopy() async throws {
        // Even when the account isn't flagged, Gmail's SMTP files the Sent copy itself.
        let account = F.account(provider: .other, email: "ada@gmail.com", host: "imap.gmail.com", smtpHost: "smtp.gmail.com",
                                authMethod: .oauth2, savesSentAutomatically: false)
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: "grace@gmail.com")], subject: "Hi", body: "Hello")
        let payload = T.xoauth2("ada@gmail.com", "ya29.a0AfB_token")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@gmail.com", recipients: ["grace@gmail.com"], auth: "AUTH XOAUTH2 \(payload)") + T.smtpData)
        let imap = ScriptedTransport(T.gmailLogin())
        let queue = IMAPServiceTransportQueue([smtp, imap])
        let service = F.service(account, credential: token, transports: queue)
        try await service.send(message)
        XCTAssertFalse(imap.transcript.contains("APPEND"))
        XCTAssertFalse(imap.transcript.contains("LIST"))
    }

    func testRejectedTokenIsAnAuthenticationError() async throws {
        let challenge = Data(#"{"status":"401","schemes":"Bearer","scope":"https://mail.google.com/"}"#.utf8).base64EncodedString()
        let script = ScriptedTransport([
            .send("* OK Gimap ready for requests from 203.0.113.5 f1mb123456789abc\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(T.gmailPreAuthCapabilities)\r\n{TAG} OK Thats all she wrote!\r\n"),
            .expect("* AUTHENTICATE XOAUTH2", reply: "+ \(challenge)\r\n"),
            .expect("", reply: "A002 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"),
        ])
        let service = F.service(account, credential: token, transports: IMAPServiceTransportQueue([script]))
        await assertIMAPServiceThrows(where: { if case .authenticationFailed = $0 { return true } else { return false } }) {
            try await service.mailboxes()
        }
    }
}
