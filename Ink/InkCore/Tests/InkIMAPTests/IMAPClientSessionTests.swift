import XCTest
import InkModel
@testable import InkIMAP

/// Connecting, signing in and mailbox-level commands, against transcripts from real servers.
final class IMAPClientSessionTests: XCTestCase {
    static let gmailPreAuthCapabilities = "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 XYZZY SASL-IR AUTH=XOAUTH2 AUTH=PLAIN AUTH=PLAIN-CLIENTTOKEN AUTH=OAUTHBEARER AUTH=XOAUTH"
    static let gmailCapabilities = "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS COMPRESS=DEFLATE ENABLE MOVE CONDSTORE ESEARCH UTF8=ACCEPT LIST-EXTENDED LIST-STATUS LITERAL- SPECIAL-USE APPENDLIMIT=35651584"
    static let dovecotCapabilities = "IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE SORT SORT=DISPLAY THREAD=REFERENCES THREAD=REFS THREAD=ORDEREDSUBJECT MULTIAPPEND URL-PARTIAL CATENATE UNSELECT CHILDREN NAMESPACE UIDPLUS LIST-EXTENDED I18NLEVEL=1 CONDSTORE QRESYNC ESEARCH ESORT SEARCHRES WITHIN CONTEXT=SEARCH LIST-STATUS BINARY MOVE SNIPPET=FUZZY PREVIEW=FUZZY PREVIEW STATUS=SIZE SAVEDATE LITERAL+ NOTIFY SPECIAL-USE"

    static let gmailList = crlf("""
    * LIST (\\HasNoChildren) "/" "INBOX"
    * LIST (\\HasChildren \\Noselect) "/" "[Gmail]"
    * LIST (\\All \\HasNoChildren) "/" "[Gmail]/All Mail"
    * LIST (\\Drafts \\HasNoChildren) "/" "[Gmail]/Drafts"
    * LIST (\\HasNoChildren \\Important) "/" "[Gmail]/Important"
    * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"
    * LIST (\\HasNoChildren \\Junk) "/" "[Gmail]/Spam"
    * LIST (\\Flagged \\HasNoChildren) "/" "[Gmail]/Starred"
    * LIST (\\HasNoChildren \\Trash) "/" "[Gmail]/Trash"
    * LIST (\\HasNoChildren) "/" "Travel/2026"
    * LIST (\\HasNoChildren) "/" "&AMk-t&AOk-"
    """) + "\r\n"

    static let gmailSelect = crlf("""
    * FLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen $NotPhishing $Phishing)
    * OK [PERMANENTFLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen $NotPhishing $Phishing \\*)] Flags permitted.
    * OK [UIDVALIDITY 1] UIDs valid.
    * 2763 EXISTS
    * 0 RECENT
    * OK [UIDNEXT 35861] Predicted next UID.
    * OK [HIGHESTMODSEQ 4416219]
    """) + "\r\n"

    // MARK: Full Gmail session

    func testGmailOAuthSession() async throws {
        let transport = ScriptedTransport([
            .send("* OK Gimap ready for requests from 203.0.113.5 f1mb123456789abc\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(Self.gmailPreAuthCapabilities)\r\n{TAG} OK Thats all she wrote! f1mb123456789abc\r\n"),
            .expect("* AUTHENTICATE XOAUTH2 dXNlcj1hZGFAZ21haWwuY29tAWF1dGg9QmVhcmVyIHlhMjkuYTBBZkJfdG9rZW4BAQ==",
                    reply: "{TAG} OK [CAPABILITY \(Self.gmailCapabilities)] ada@gmail.com authenticated (Success)\r\n"),
            .expect("* ID (\"name\" \"Ink\" \"version\" \"1.0\")",
                    reply: "* ID (\"name\" \"GImap\" \"vendor\" \"Google, Inc.\" \"support-url\" \"https://support.google.com/mail\")\r\n{TAG} OK Success\r\n"),
            .expect("* LIST \"\" \"*\" RETURN (SPECIAL-USE)", reply: Self.gmailList + "{TAG} OK Success\r\n"),
            .expect("* SELECT INBOX (CONDSTORE)", reply: Self.gmailSelect + "{TAG} OK [READ-WRITE] INBOX selected. (Success)\r\n"),
            .expect("* LOGOUT", reply: "* BYE LOGOUT Requested\r\n{TAG} OK 73 good day (Success)\r\n"),
        ])
        let log = LogCollector()
        let client = IMAPClient(host: "imap.gmail.com", port: 993, security: .tls, transport: transport, logger: log.logger)
        try await withWatchdog(transport) {
            try await client.connect()
            XCTAssertTrue(transport.openedTLS)
            let preAuth = await client.capabilities
            XCTAssertTrue(preAuth.contains("AUTH=XOAUTH2"))
            XCTAssertFalse(preAuth.contains("MOVE"))
            try await client.authenticateXOAUTH2(username: "ada@gmail.com", accessToken: "ya29.a0AfB_token")
            let state = await client.state
            XCTAssertEqual(state, .authenticated)
            let isGmail = await client.isGmail
            XCTAssertTrue(isGmail)
            let caps = await client.capabilities
            XCTAssertTrue(caps.contains("MOVE"))
            XCTAssertTrue(caps.contains("APPENDLIMIT=35651584"))

            try await client.id(["name": "Ink", "version": "1.0"])
            let serverID = await client.serverID
            XCTAssertEqual(serverID?["vendor"], "Google, Inc.")

            let mailboxes = try await client.listMailboxes()
            XCTAssertEqual(mailboxes.count, 11)
            XCTAssertEqual(mailboxes.first(where: { $0.specialUse == .all })?.rawName, "[Gmail]/All Mail")
            XCTAssertEqual(mailboxes.first(where: { $0.specialUse == .trash })?.name, "[Gmail]/Trash")
            XCTAssertEqual(mailboxes.last?.name, "Été")
            XCTAssertEqual(mailboxes.last?.rawName, "&AMk-t&AOk-")
            XCTAssertFalse(mailboxes[1].isSelectable)

            let info = try await client.select("INBOX", condstore: true)
            XCTAssertEqual(info.exists, 2763)
            XCTAssertEqual(info.recent, 0)
            XCTAssertEqual(info.uidValidity, 1)
            XCTAssertEqual(info.uidNext, 35861)
            XCTAssertEqual(info.highestModSeq, 4_416_219)
            XCTAssertEqual(info.flags.count, 7)
            XCTAssertTrue(info.permanentFlags.contains("\\*"))
            XCTAssertFalse(info.readOnly)
            let selected = await client.selectedMailbox
            XCTAssertEqual(selected, info)

            await client.logout()
        }
        let closedState = await client.state
        XCTAssertEqual(closedState, .disconnected)
        XCTAssertFalse(transport.isOpen)
        XCTAssertFalse(log.text.contains("ya29"), "the token must never reach the log")
        XCTAssertFalse(log.text.contains("dXNlcj1hZGFAZ21haWwuY29t"))
        XCTAssertTrue(log.text.contains("C: A002 AUTHENTICATE [redacted]"))
        XCTAssertTrue(log.text.contains("S: * 2763 EXISTS"))
    }

    // MARK: STARTTLS

    func testDovecotStartTLSThenAuthenticatePlain() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ STARTTLS LOGINDISABLED] Dovecot (Ubuntu) ready.\r\n"),
            .expect("* STARTTLS", reply: "{TAG} OK Begin TLS negotiation now.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ AUTH=PLAIN\r\n{TAG} OK Pre-login capabilities listed, post-login capabilities have more.\r\n"),
            .expect("* AUTHENTICATE PLAIN AGFkYQBodW50ZXIy", reply: "{TAG} OK [CAPABILITY \(Self.dovecotCapabilities)] Logged in\r\n"),
            .expect("* ENABLE QRESYNC", reply: "* ENABLED QRESYNC\r\n{TAG} OK Enabled (0.001 + 0.000 secs).\r\n"),
        ])
        let client = IMAPClient(host: "mail.example.org", port: 143, security: .startTLS, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            XCTAssertFalse(transport.openedTLS)
            XCTAssertTrue(transport.didStartTLS)
            let caps = await client.capabilities
            XCTAssertEqual(caps, ["IMAP4REV1", "SASL-IR", "LOGIN-REFERRALS", "ID", "ENABLE", "IDLE", "LITERAL+", "AUTH=PLAIN"])
            try await client.login(username: "ada", password: "hunter2")
            let after = await client.capabilities
            XCTAssertTrue(after.contains("QRESYNC"))
            try await client.enable(["QRESYNC", "UTF8=ACCEPT"])
            let enabled = await client.enabledExtensions
            XCTAssertEqual(enabled, ["QRESYNC", "CONDSTORE"])
        }
        XCTAssertTrue(transport.transcript.hasPrefix("A001 STARTTLS\r\nA002 CAPABILITY\r\n"))
    }

    func testStartTLSDiscardsBytesSentBeforeTheHandshake() async throws {
        // A man-in-the-middle appends a fake capability after the STARTTLS OK.
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n"),
            .expect("* STARTTLS", reply: "{TAG} OK Begin TLS\r\n* CAPABILITY IMAP4rev1 AUTH=PLAIN LOGINDISABLED X-INJECTED\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4rev1 AUTH=PLAIN\r\n{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 143, security: .startTLS, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
        }
        let caps = await client.capabilities
        XCTAssertEqual(caps, ["IMAP4REV1", "AUTH=PLAIN"])
    }

    func testStartTLSRequiredButNotOffered() async {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] plaintext only\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 143, security: .startTLS, transport: transport)
        await assertThrowsMailError(matching: { if case .tlsFailed = $0 { return true } else { return false } }) {
            try await withWatchdog(transport) { try await client.connect() }
        }
        XCTAssertFalse(transport.isOpen, "the plaintext connection is closed, not used")
        XCTAssertEqual(transport.transcript, "", "nothing, least of all credentials, was sent")
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
    }

    func testStartTLSRefused() async {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 STARTTLS] ready\r\n"),
            .expect("* STARTTLS", reply: "{TAG} BAD TLS not available right now\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 143, security: .startTLS, transport: transport)
        await assertThrowsMailError(.tlsFailed("The server refused STARTTLS: TLS not available right now")) {
            try await withWatchdog(transport) { try await client.connect() }
        }
    }

    func testPreauthIsRefusedWithStartTLS() async {
        let transport = ScriptedTransport([.send("* PREAUTH [CAPABILITY IMAP4rev1 STARTTLS] welcome\r\n")])
        let client = IMAPClient(host: "h", port: 143, security: .startTLS, transport: transport)
        await assertThrowsMailError(matching: { if case .tlsFailed = $0 { return true } else { return false } }) {
            try await withWatchdog(transport) { try await client.connect() }
        }
    }

    func testPreauthOverTLSIsSignedIn() async throws {
        let transport = ScriptedTransport([
            .send("* PREAUTH [CAPABILITY IMAP4rev2 IDLE] Logged in as ada\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "ignored", password: "ignored")
        }
        let state = await client.state
        XCTAssertEqual(state, .authenticated)
        XCTAssertEqual(transport.transcript, "", "no LOGIN after PREAUTH")
        let greeting = await client.greetingText
        XCTAssertEqual(greeting, "Logged in as ada")
    }

    func testByeGreeting() async {
        let transport = ScriptedTransport([.send("* BYE Too many simultaneous connections. (Failure)\r\n")])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.connectionFailed("The server refused the connection: Too many simultaneous connections.")) {
            try await withWatchdog(transport) { try await client.connect() }
        }
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
    }

    func testOutlookGreetingWithoutCapabilitiesAsksForThem() async throws {
        let transport = ScriptedTransport([
            .send("* OK The Microsoft Exchange IMAP4 service is ready. [TQBXADQAUABSADAANABDAEEAMAAwADAAMgAuAG4AYQBtAHAAcgBkADAANAAuAHAAcgBvAGQALgBvAHUAdABsAG8AbwBrAC4AYwBvAG0A]\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2 SASL-IR UIDPLUS ID UNSELECT CHILDREN IDLE NAMESPACE LITERAL+\r\n{TAG} OK CAPABILITY completed.\r\n"),
            .expect("* AUTHENTICATE XOAUTH2 dXNlcj1hZGFAb3V0bG9vay5jb20BYXV0aD1CZWFyZXIgRXdCd0E4bDZCQUFVAQE=", reply: "{TAG} OK AUTHENTICATE completed.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2 SASL-IR UIDPLUS MOVE ID UNSELECT CLIENTACCESSRULES CLIENTNETWORKPRESENCELOCATION BACKENDAUTHENTICATE CHILDREN IDLE NAMESPACE LITERAL+\r\n{TAG} OK CAPABILITY completed.\r\n"),
        ])
        let client = IMAPClient(host: "outlook.office365.com", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.authenticateXOAUTH2(username: "ada@outlook.com", accessToken: "EwBwA8l6BAAU")
        }
        let caps = await client.capabilities
        XCTAssertTrue(caps.contains("MOVE"), "capabilities are re-read after signing in")
        let isGmail = await client.isGmail
        XCTAssertFalse(isGmail)
    }

    // MARK: Authentication

    func testWrongPasswordWithAuthenticationFailedCode() async {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.authenticationFailed("Authentication failed.")) {
            try await withWatchdog(transport) {
                try await client.connect()
                try await client.login(username: "ada", password: "wrong")
            }
        }
        XCTAssertFalse(transport.transcript.contains("LOGIN"), "a rejected password isn't retried with LOGIN")
        let state = await client.state
        XCTAssertEqual(state, .notAuthenticated, "the connection stays usable after a NO")
    }

    func testGmailWebLoginRequiredAlertIsSurfaced() async {
        let transport = ScriptedTransport([
            .send("* OK Gimap ready\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(Self.gmailPreAuthCapabilities)\r\n{TAG} OK done\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} NO [ALERT] Please log in via your web browser: https://support.google.com/mail/accounts/answer/78754 (Failure)\r\n"),
        ])
        let client = IMAPClient(host: "imap.gmail.com", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.authenticationFailed("Please log in via your web browser: https://support.google.com/mail/accounts/answer/78754")) {
            try await withWatchdog(transport) {
                try await client.connect()
                try await client.login(username: "ada@gmail.com", password: "app-password")
            }
        }
        let alert = await client.lastAlert
        XCTAssertEqual(alert, "Please log in via your web browser: https://support.google.com/mail/accounts/answer/78754")
    }

    func testUntaggedAlertDuringLoginIsIncluded() async {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1] ready\r\n"),
            .expect("* LOGIN", reply: "* NO [ALERT] Your account is locked. Contact support.\r\n{TAG} NO LOGIN failed.\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.authenticationFailed("Your account is locked. Contact support. LOGIN failed.")) {
            try await withWatchdog(transport) {
                try await client.connect()
                try await client.login(username: "ada", password: "pw")
            }
        }
    }

    func testLoginWithQuotedStringsAndRedaction() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 IDLE] ready\r\n"),
            .expect("* LOGIN \"ada smith\" \"p@ss \\\"w\\\\rd\"", reply: "{TAG} OK [CAPABILITY IMAP4rev1 IDLE MOVE] Logged in\r\n"),
        ])
        let log = LogCollector()
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport, logger: log.logger)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "ada smith", password: "p@ss \"w\\rd")
        }
        XCTAssertTrue(log.text.contains("C: A001 LOGIN [redacted]"))
        XCTAssertFalse(log.text.contains("p@ss"))
        let caps = await client.capabilities
        XCTAssertTrue(caps.contains("MOVE"))
    }

    func testLoginWithNonASCIIPasswordWaitsForContinuation() async throws {
        let (server, handler) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1] ready\r\n", [
            ("LOGIN ada {10}<literal>", "{TAG} OK Logged in\r\n"),
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE\r\n{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server) {
            try await client.connect()
            try await client.login(username: "ada", password: "pässwörd")
        }
        XCTAssertEqual(server.commands.first?.literals, [Data("pässwörd".utf8)])
        XCTAssertFalse(server.literalSentEarly, "a synchronizing literal waits for the server's +")
        XCTAssertEqual(handler.remaining, 0)
    }

    func testAuthenticatePlainWithoutSASLIR() async throws {
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] ready\r\n", [
            ("AUTHENTICATE PLAIN", "+ \r\n"),
            ("AGFkYUBleGFtcGxlLmNvbQBjb3JyZWN0IGhvcnNl", "A001 OK [CAPABILITY IMAP4rev1 IDLE] Logged in\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server) {
            try await client.connect()
            try await client.login(username: "ada@example.com", password: "correct horse")
        }
        XCTAssertTrue(server.transcript.hasPrefix("A001 AUTHENTICATE PLAIN\r\nAGFkYUBleGFtcGxlLmNvbQBjb3JyZWN0IGhvcnNl\r\n"))
        let state = await client.state
        XCTAssertEqual(state, .authenticated)
    }

    func testPlainRejectedAsBadFallsBackToLogin() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} BAD Unsupported authentication mechanism\r\n"),
            .expect("* LOGIN ada hunter2", reply: "{TAG} OK [CAPABILITY IMAP4rev1] Logged in\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "ada", password: "hunter2")
        }
        let state = await client.state
        XCTAssertEqual(state, .authenticated)
    }

    func testLoginDisabledWithoutPlain() async {
        let transport = ScriptedTransport([.send("* OK [CAPABILITY IMAP4rev1 LOGINDISABLED AUTH=GSSAPI] ready\r\n")])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.notSupported("password sign-in on this connection")) {
            try await withWatchdog(transport) {
                try await client.connect()
                try await client.login(username: "ada", password: "pw")
            }
        }
    }

    func testXOAUTH2ErrorChallengeIsAnsweredWithEmptyLine() async {
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=XOAUTH2 AUTH=PLAIN] ready\r\n", [
            ("AUTHENTICATE XOAUTH2 ", "+ eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ==\r\n"),
            ("", "A001 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)\r\n"),
        ])
        let client = IMAPClient(host: "imap.gmail.com", port: 993, security: .tls, transport: server)
        await assertThrowsMailError(.authenticationFailed("Invalid credentials")) {
            try await withWatchdog(server) {
                try await client.connect()
                try await client.authenticateXOAUTH2(username: "ada@gmail.com", accessToken: "expired")
            }
        }
        XCTAssertEqual(server.commands.count, 2)
        XCTAssertEqual(server.commands.last?.text, "", "the error challenge gets an empty response")
    }

    func testXOAUTH2WithoutSASLIRAndBareFailure() async {
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=XOAUTH2] ready\r\n", [
            ("AUTHENTICATE XOAUTH2", "+ \r\n"),
            ("dXNlcj1hZGFAZ21haWwuY29tAWF1dGg9QmVhcmVyIHlhMjkuYTBBZkJfdG9rZW4BAQ==", "+ eyJzdGF0dXMiOiI0MDEifQ\r\n"),
            ("", "A001 NO\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        await assertThrowsMailError(.authenticationFailed("The access token was rejected (status 401).")) {
            try await withWatchdog(server) {
                try await client.connect()
                try await client.authenticateXOAUTH2(username: "ada@gmail.com", accessToken: "ya29.a0AfB_token")
            }
        }
    }

    func testXOAUTH2NotAdvertised() async {
        let transport = ScriptedTransport([.send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] ready\r\n")])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.notSupported("signing in with OAuth (XOAUTH2)")) {
            try await withWatchdog(transport) {
                try await client.connect()
                try await client.authenticateXOAUTH2(username: "a", accessToken: "t")
            }
        }
    }

    func testSASLHelpers() {
        XCTAssertEqual(IMAPSASL.plain(username: "ada", password: "hunter2"), "AGFkYQBodW50ZXIy")
        XCTAssertEqual(IMAPSASL.xoauth2(username: "ada@gmail.com", accessToken: "ya29.a0AfB_token"),
                       "dXNlcj1hZGFAZ21haWwuY29tAWF1dGg9QmVhcmVyIHlhMjkuYTBBZkJfdG9rZW4BAQ==")
        XCTAssertEqual(IMAPSASL.xoauth2ErrorStatus("eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ=="), "400")
        XCTAssertEqual(IMAPSASL.xoauth2ErrorStatus("eyJzdGF0dXMiOjQwMX0"), "401")
        XCTAssertNil(IMAPSASL.xoauth2ErrorStatus("not base64 !!"))
    }

    // MARK: Mailbox commands

    /// A Dovecot server already signed in (no network for connect/login beyond the script).
    private func dovecotClient(_ steps: [ScriptedTransport.Step], logger: (@Sendable (String) -> Void)? = nil) -> (IMAPClient, ScriptedTransport) {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY \(Self.dovecotCapabilities) AUTH=PLAIN] Dovecot ready.\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY \(Self.dovecotCapabilities)] Logged in\r\n"),
        ] + steps)
        return (IMAPClient(host: "imap.example.org", port: 993, security: .tls, transport: transport, logger: logger), transport)
    }

    func testDovecotListSelectStatusCreate() async throws {
        let (client, transport) = dovecotClient([
            .expect("* LIST \"\" \"*\" RETURN (SPECIAL-USE)", reply: crlf("""
            * LIST (\\HasNoChildren) "." INBOX
            * LIST (\\HasNoChildren \\Drafts) "." Drafts
            * LIST (\\HasNoChildren \\Sent) "." Sent
            * LIST (\\HasNoChildren \\Junk) "." Junk
            * LIST (\\HasNoChildren \\Trash) "." Trash
            * LIST (\\HasChildren \\Archive) "." Archive
            * LIST (\\HasNoChildren) "." Archive.2025
            * LIST (\\HasNoChildren) "." "Entw&APw-rfe alt"
            * LIST (\\HasNoChildren) "." INBOX
            {TAG} OK List completed (0.001 + 0.000 secs).
            """) + "\r\n"),
            .expect("* EXAMINE \"Entw&APw-rfe alt\"", reply: crlf("""
            * FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft $Forwarded $Junk NonJunk)
            * OK [PERMANENTFLAGS ()] Read-only mailbox.
            * 18 EXISTS
            * 0 RECENT
            * OK [UNSEEN 12] First unseen.
            * OK [UIDVALIDITY 1704067200] UIDs valid
            * OK [UIDNEXT 245] Predicted next UID
            * OK [NOMODSEQ] No permanent modsequences
            {TAG} OK [READ-ONLY] Examine completed (0.001 + 0.000 secs).
            """) + "\r\n"),
            .expect("* STATUS \"Sent\" (MESSAGES UIDNEXT UIDVALIDITY UNSEEN HIGHESTMODSEQ)",
                    reply: "* STATUS Sent (MESSAGES 431 UIDNEXT 2208 UIDVALIDITY 1704067201 UNSEEN 0 HIGHESTMODSEQ 3301)\r\n{TAG} OK Status completed (0.001 + 0.000 secs).\r\n"),
            .expect("* CREATE \"Archive\"", reply: "{TAG} NO [ALREADYEXISTS] Mailbox already exists\r\n"),
            .expect("* CREATE \"Projekte/&AMQ-hnliches\"", reply: "{TAG} OK Create completed (0.004 + 0.000 + 0.003 secs).\r\n"),
            .expect("* SUBSCRIBE \"Projekte/&AMQ-hnliches\"", reply: "{TAG} OK Subscribe completed.\r\n"),
            .expect("* SELECT \"Nope\"", reply: "{TAG} NO [NONEXISTENT] Mailbox doesn't exist: Nope\r\n"),
            .expect("* STATUS \"Gone\"", reply: "{TAG} NO Mailbox doesn't exist: Gone\r\n"),
        ])
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "ada", password: "hunter2")
            let mailboxes = try await client.listMailboxes()
            XCTAssertEqual(mailboxes.map(\.name), ["INBOX", "Drafts", "Sent", "Junk", "Trash", "Archive", "Archive.2025", "Entwürfe alt"])
            XCTAssertEqual(mailboxes.map(\.specialUse), [.inbox, .drafts, .sent, .junk, .trash, .archive, nil, nil])
            XCTAssertEqual(mailboxes.first?.delimiter, ".")

            let info = try await client.select("Entw&APw-rfe alt", readOnly: true)
            XCTAssertTrue(info.readOnly)
            XCTAssertEqual(info.exists, 18)
            XCTAssertEqual(info.firstUnseen, 12)
            XCTAssertEqual(info.uidValidity, 1_704_067_200)
            XCTAssertEqual(info.uidNext, 245)
            XCTAssertTrue(info.noModSeq)
            XCTAssertNil(info.highestModSeq)
            XCTAssertEqual(info.permanentFlags, [])

            let status = try await client.status("Sent")
            XCTAssertEqual(status, IMAPStatus(messages: 431, uidNext: 2208, uidValidity: 1_704_067_201, unseen: 0, highestModSeq: 3301))

            try await client.create("Archive")
            try await client.create("Projekte/Ähnliches")
            try await client.subscribe("Projekte/Ähnliches")

            await assertThrowsMailError(.mailboxNotFound("Nope")) { try await client.select("Nope") }
            let selected = await client.selectedMailbox
            XCTAssertNil(selected, "a failed SELECT leaves nothing selected")
            await assertThrowsMailError(.mailboxNotFound("Gone")) { try await client.status("Gone") }
            let state = await client.state
            XCTAssertEqual(state, .authenticated)
        }
    }

    func testListFallsBackWhenExtendedFormIsRefused() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SPECIAL-USE LIST-EXTENDED AUTH=PLAIN SASL-IR] ready\r\n"),
            .expect("* AUTHENTICATE", reply: "{TAG} OK [CAPABILITY IMAP4rev1 SPECIAL-USE LIST-EXTENDED] ok\r\n"),
            .expect("* LIST \"\" \"*\" RETURN (SPECIAL-USE)", reply: "{TAG} BAD Error in IMAP command LIST: Unknown return option\r\n"),
            .expect("* LIST \"\" \"*\"", reply: "* LIST (\\HasNoChildren \\Sent) \"/\" Sent\r\n{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        let mailboxes = try await withWatchdog(transport) { () -> [IMAPMailbox] in
            try await client.connect()
            try await client.login(username: "a", password: "b")
            return try await client.listMailboxes()
        }
        XCTAssertEqual(mailboxes.map(\.specialUse), [.sent])
    }

    func testXListWithLocalizedInbox() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 XLIST AUTH=PLAIN SASL-IR] ready\r\n"),
            .expect("* AUTHENTICATE", reply: "{TAG} OK [CAPABILITY IMAP4rev1 XLIST] ok\r\n"),
            .expect("* XLIST \"\" \"*\"", reply: crlf("""
            * XLIST (\\HasNoChildren \\Inbox) "/" "Posteingang"
            * XLIST (\\HasNoChildren \\AllMail) "/" "[Google Mail]/Alle Nachrichten"
            * XLIST (\\HasNoChildren \\Spam) "/" "[Google Mail]/Spam"
            {TAG} OK Success
            """) + "\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        let mailboxes = try await withWatchdog(transport) { () -> [IMAPMailbox] in
            try await client.connect()
            try await client.login(username: "a", password: "b")
            return try await client.listMailboxes()
        }
        XCTAssertEqual(mailboxes.map(\.rawName), ["INBOX", "[Google Mail]/Alle Nachrichten", "[Google Mail]/Spam"])
        XCTAssertEqual(mailboxes.map(\.specialUse), [.inbox, .all, .junk])
    }

    func testEnableUTF8AcceptSwitchesMailboxEncoding() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n"),
            .expect("* AUTHENTICATE", reply: "{TAG} OK [CAPABILITY IMAP4rev1 ENABLE UTF8=ACCEPT LITERAL+] ok\r\n"),
            .expect("* ENABLE UTF8=ACCEPT", reply: "* ENABLED UTF8=ACCEPT\r\n{TAG} OK enabled\r\n"),
            .expect("* LIST \"\" \"*\"", reply: "* LIST (\\HasNoChildren) \"/\" \"Entwürfe\"\r\n* LIST (\\HasNoChildren) \"/\" \"A&-B\"\r\n{TAG} OK done\r\n"),
            .expect("* SELECT \"Entwürfe\"", reply: "* 0 EXISTS\r\n{TAG} OK [READ-WRITE] done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "a", password: "b")
            try await client.enable(["utf8=accept", "QRESYNC"])
            let mailboxes = try await client.listMailboxes()
            XCTAssertEqual(mailboxes.map(\.name), ["Entwürfe", "A&-B"], "no modified UTF-7 decoding in UTF-8 mode")
            _ = try await client.select("Entwürfe")
        }
    }

    func testEnableAndIDAreSkippedWithoutSupport() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n"),
            .expect("* AUTHENTICATE", reply: "{TAG} OK [CAPABILITY IMAP4rev1] ok\r\n"),
            .expect("* NOOP", reply: "{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "a", password: "b")
            try await client.enable(["QRESYNC"])
            try await client.id(["name": "Ink"])
            _ = try await client.noop()
        }
        XCTAssertFalse(transport.transcript.contains("ENABLE"))
        XCTAssertFalse(transport.transcript.contains("ID "))
    }

    func testCommandsBeforeConnectingOrSelecting() async {
        let transport = ScriptedTransport([])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.connectionFailed("Not connected.")) { try await client.noop() }
        await assertThrowsMailError(.connectionFailed("Not connected.")) { try await client.listMailboxes() }
        let (dovecot, dovecotTransport) = dovecotClient([])
        await assertThrowsMailError(.protocolError("Not signed in yet.")) {
            try await withWatchdog(dovecotTransport) {
                try await dovecot.connect()
                return try await dovecot.listMailboxes()
            }
        }
        await assertThrowsMailError(.protocolError("Not signed in yet.")) { try await dovecot.fetch(.all, byUID: true, items: [.flags]) }
    }

    func testConnectIsIdempotentAndLogoutWithoutConnectionIsHarmless() async throws {
        let transport = ScriptedTransport([.send("* OK [CAPABILITY IMAP4rev1] ready\r\n")])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.connect()
        }
        XCTAssertEqual(transport.transcript, "")
        let other = IMAPClient(host: "h", port: 993, security: .tls, transport: ScriptedTransport([]))
        await other.logout()
    }

    func testUnselectRefreshAndSupports() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY IMAP4rev1 UNSELECT] in\r\n"),
            .expect("* SELECT INBOX", reply: "* 1 EXISTS\r\n{TAG} OK [READ-WRITE] ok\r\n"),
            .expect("* UNSELECT", reply: "{TAG} OK Unselect completed\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4rev1 UNSELECT IDLE\r\n{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "a", password: "b")
            _ = try await client.select("INBOX")
            try await client.unselect()
            let selected = await client.selectedMailbox
            XCTAssertNil(selected)
            try await client.unselect()
            let caps = try await client.refreshCapabilities()
            XCTAssertTrue(caps.contains("IDLE"))
            let supportsIdle = await client.supports("idle")
            XCTAssertTrue(supportsIdle)
        }
    }

    func testConnectFailureIsMapped() async {
        final class FailingTransport: MailTransport, @unchecked Sendable {
            func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws { throw TransportError.connectFailed("No route to host") }
            func startTLS() async throws {}
            func read(timeout: TimeInterval) async throws -> Data { throw TransportError.notConnected }
            func write(_ data: Data) async throws { throw TransportError.notConnected }
            func close() {}
        }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: FailingTransport())
        await assertThrowsMailError(.connectionFailed("No route to host")) { try await client.connect() }
    }
}
