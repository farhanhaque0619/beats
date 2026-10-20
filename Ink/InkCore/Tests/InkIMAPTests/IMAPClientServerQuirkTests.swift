import XCTest
import InkModel
@testable import InkIMAP

/// The protocol corrections from docs/RESEARCH.md, each against a scripted server conversation:
/// STARTTLS hardening (§3.2), re-reading capabilities after TLS and sign-in (§3.4), iCloud's
/// silent ENABLE (§3.3, §3.4), the IDLE re-issue interval (§3.4, §3.5), Exchange's
/// PERMANENTFLAGS without `\*` (§3.4), and GreenMail's literal without a leading space.
final class IMAPClientServerQuirkTests: XCTestCase {
    // MARK: STARTTLS (RESEARCH §3.2)

    /// The reply to STARTTLS ends mid-chunk with the start of an injected tagged response.
    func testStartTLSAbortsOnAPartialLineAfterTheOK() async {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] ready\r\n"),
            .expect("* STARTTLS", reply: "{TAG} OK Begin TLS negotiation now.\r\nA002 OK [CAPABILITY IMAP4rev1 AUTH=PLAIN"),
        ])
        let client = IMAPClient(host: "mail.example.org", port: 143, security: .startTLS, transport: transport)
        await assertThrowsMailError(.tlsFailed("The server sent unexpected data before the secure connection started, so it can't be used safely.")) {
            try await withWatchdog(transport) { try await client.connect() }
        }
        XCTAssertFalse(transport.didStartTLS)
        XCTAssertEqual(transport.transcript, "A001 STARTTLS\r\n")
    }

    /// Untagged data that arrives with the STARTTLS reply (before the tagged OK) is plaintext
    /// too: an injected `* ENABLED UTF8=ACCEPT` or capability list must not survive the upgrade.
    func testStartTLSForgetsWhatTheServerSaidBeforeTheHandshake() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] Dovecot ready.\r\n"),
            .expect("* STARTTLS", reply: "* ENABLED UTF8=ACCEPT\r\n* CAPABILITY IMAP4rev1 AUTH=PLAIN X-INJECTED\r\n{TAG} OK [CAPABILITY IMAP4rev1 X-PRE-TLS] Begin TLS negotiation now.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4rev1 SASL-IR ID ENABLE IDLE LITERAL+ AUTH=PLAIN\r\n{TAG} OK Pre-login capabilities listed.\r\n"),
        ])
        let client = IMAPClient(host: "mail.example.org", port: 143, security: .startTLS, transport: transport)
        try await withWatchdog(transport) { try await client.connect() }
        XCTAssertTrue(transport.didStartTLS)
        let caps = await client.capabilities
        XCTAssertEqual(caps, ["IMAP4REV1", "SASL-IR", "ID", "ENABLE", "IDLE", "LITERAL+", "AUTH=PLAIN"])
        let enabled = await client.enabledExtensions
        XCTAssertEqual(enabled, [], "an injected ENABLED doesn't switch on UTF-8 mailbox names")
        let utf8 = await client.utf8Accepted
        XCTAssertFalse(utf8)
    }

    /// Certificate problems surface on the first read after the handshake (Apple's
    /// `startSecureConnection()` has no completion handler). That read is the post-STARTTLS
    /// CAPABILITY, so the failure comes before any credentials are sent.
    func testTLSFailureAfterStartTLSStopsBeforeCredentials() async {
        let script = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 STARTTLS LOGINDISABLED] ready\r\n"),
            .expect("* STARTTLS", reply: "{TAG} OK Begin TLS negotiation now.\r\n"),
        ])
        let transport = TLSFailingTransport(script, failure: .tlsFailed("The certificate for this server is invalid."))
        let client = IMAPClient(host: "mail.example.org", port: 143, security: .startTLS, transport: transport)
        await assertThrowsMailError(.tlsFailed("The certificate for this server is invalid.")) {
            try await withWatchdog(script) {
                try await client.connect()
                try await client.login(username: "ada", password: "hunter2")
            }
        }
        XCTAssertTrue(script.didStartTLS)
        XCTAssertEqual(script.transcript, "A001 STARTTLS\r\nA002 CAPABILITY\r\n", "no LOGIN or AUTHENTICATE")
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
        await assertThrowsMailError(.connectionFailed("Not connected.")) {
            try await client.login(username: "ada", password: "hunter2")
        }
    }

    /// Implicit TLS: the greeting is the first read, and a TLS failure there ends the attempt
    /// with nothing written.
    func testTLSFailureOnTheGreetingSendsNothing() async {
        let script = ScriptedTransport([.send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] ready\r\n")])
        let transport = TLSFailingTransport(script, failure: .tlsFailed("The certificate has expired."), failFromFirstRead: true)
        let client = IMAPClient(host: "imap.example.org", port: 993, security: .tls, transport: transport)
        await assertThrowsMailError(.tlsFailed("The certificate has expired.")) {
            try await withWatchdog(script) { try await client.connect() }
        }
        XCTAssertTrue(script.openedTLS)
        XCTAssertEqual(script.transcript, "")
    }

    /// A greeting without capabilities: CAPABILITY is asked for in plaintext, and when it lacks
    /// STARTTLS the client stops instead of signing in without encryption (§3.2 rule 4).
    func testMissingStartTLSAfterAskingNeverFallsBackToPlaintext() async {
        let transport = ScriptedTransport([
            .send("* OK IMAP server ready\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4rev1 AUTH=PLAIN IDLE\r\n{TAG} OK CAPABILITY completed\r\n"),
        ])
        let client = IMAPClient(host: "mail.example.org", port: 143, security: .startTLS, transport: transport)
        await assertThrowsMailError(.tlsFailed("The server doesn't offer STARTTLS.")) {
            try await withWatchdog(transport) {
                try await client.connect()
                try await client.login(username: "ada", password: "hunter2")
            }
        }
        XCTAssertEqual(transport.transcript, "A001 CAPABILITY\r\n")
        XCTAssertFalse(transport.isOpen)
    }

    // MARK: Capabilities after sign-in and silent ENABLE (RESEARCH §3.3, §3.4)

    /// iCloud lists IDLE only after login and its auth reply carries no capability code, so
    /// CAPABILITY is asked again; ENABLE answers OK without an untagged ENABLED.
    func testICloudCapabilitiesAfterLoginAndSilentEnable() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY XAPPLEPUSHSERVICE IMAP4 IMAP4rev1 SASL-IR AUTH=ATOKEN AUTH=PLAIN] iCloud IMAP4 service is available\r\n"),
            .expect("* AUTHENTICATE PLAIN AGFkYUBpY2xvdWQuY29tAGFiY2QtZWZnaC1pamtsLW1ub3A=",
                    reply: "{TAG} OK ada@icloud.com authenticated (Success)\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY XAPPLEPUSHSERVICE IMAP4 IMAP4rev1 ACL QUOTA ID UIDPLUS ESEARCH ENABLE CONDSTORE QRESYNC SORT LIST-STATUS IDLE NAMESPACE CHILDREN UNSELECT\r\n{TAG} OK CAPABILITY completed\r\n"),
            .expect("* ENABLE QRESYNC CONDSTORE", reply: "{TAG} OK ENABLE completed\r\n"),
        ])
        let client = IMAPClient(host: "imap.mail.me.com", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            let before = await client.supports("IDLE")
            XCTAssertFalse(before)
            try await client.login(username: "ada@icloud.com", password: "abcd-efgh-ijkl-mnop")
            let after = await client.supports("IDLE")
            XCTAssertTrue(after, "capabilities are re-read after signing in")
            let move = await client.supports("MOVE")
            XCTAssertFalse(move)
            try await client.enable(["QRESYNC", "CONDSTORE", "UTF8=ACCEPT"])
        }
        let enabled = await client.enabledExtensions
        XCTAssertEqual(enabled, ["QRESYNC", "CONDSTORE"], "a tagged OK without ENABLED counts as success")
        let interval = await client.idleReissueInterval
        XCTAssertEqual(interval, 25 * 60)
    }

    /// When the server does report ENABLED, only what it lists is on, even if that's nothing.
    func testEnableHonoursTheServersList() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR ENABLE CONDSTORE QRESYNC UTF8=ACCEPT] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY IMAP4rev1 ENABLE CONDSTORE QRESYNC UTF8=ACCEPT] Logged in\r\n"),
            .expect("* ENABLE QRESYNC UTF8=ACCEPT", reply: "* ENABLED CONDSTORE\r\n{TAG} OK Enabled\r\n"),
            .expect("* ENABLE QRESYNC UTF8=ACCEPT", reply: "* ENABLED\r\n{TAG} OK Nothing enabled\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "ada", password: "pw")
            try await client.enable(["QRESYNC", "UTF8=ACCEPT"])
            let first = await client.enabledExtensions
            XCTAssertEqual(first, ["CONDSTORE"])
            try await client.enable(["QRESYNC", "UTF8=ACCEPT"])
        }
        let enabled = await client.enabledExtensions
        XCTAssertEqual(enabled, ["CONDSTORE"])
        let utf8 = await client.utf8Accepted
        XCTAssertFalse(utf8)
    }

    /// A STARTTLS session's tagged OK to AUTHENTICATE without a capability code also triggers a
    /// fresh CAPABILITY (Exchange style), and pre-login-only capabilities disappear.
    func testCapabilitiesAreReplacedAfterSignInOverStartTLS() async throws {
        let transport = ScriptedTransport([
            .send("* OK The Microsoft Exchange IMAP4 service is ready.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4 IMAP4rev1 LOGINDISABLED STARTTLS UIDPLUS CHILDREN IDLE NAMESPACE LITERAL+\r\n{TAG} OK CAPABILITY completed.\r\n"),
            .expect("* STARTTLS", reply: "{TAG} OK Begin TLS negotiation now.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2 SASL-IR UIDPLUS ID UNSELECT CHILDREN IDLE NAMESPACE LITERAL+\r\n{TAG} OK CAPABILITY completed.\r\n"),
            .expect("* AUTHENTICATE XOAUTH2", reply: "{TAG} OK AUTHENTICATE completed.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2 SASL-IR UIDPLUS MOVE ID UNSELECT CHILDREN IDLE NAMESPACE LITERAL+\r\n{TAG} OK CAPABILITY completed.\r\n"),
        ])
        let client = IMAPClient(host: "outlook.office365.com", port: 143, security: .startTLS, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            let preAuth = await client.capabilities
            XCTAssertFalse(preAuth.contains("STARTTLS"), "pre-TLS capabilities are thrown away")
            XCTAssertFalse(preAuth.contains("LOGINDISABLED"))
            try await client.authenticateXOAUTH2(username: "ada@outlook.com", accessToken: "EwBwA8l6BAAU")
        }
        let caps = await client.capabilities
        XCTAssertTrue(caps.contains("MOVE"))
        XCTAssertEqual(transport.transcript.components(separatedBy: "\r\n").filter { !$0.isEmpty }.map { $0.split(separator: " ")[1] },
                       ["CAPABILITY", "STARTTLS", "CAPABILITY", "AUTHENTICATE", "CAPABILITY"])
    }

    // MARK: IDLE re-issue interval (RESEARCH §3.4, §3.5 item 9)

    func testIdleIntervalIsShorterOnGmail() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 IDLE X-GM-EXT-1 SASL-IR AUTH=PLAIN] Gimap ready\r\n"),
        ])
        let client = IMAPClient(host: "imap.gmail.com", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) { try await client.connect() }
        let gmail = await client.idleReissueInterval
        XCTAssertEqual(gmail, 9 * 60)
        XCTAssertEqual(IMAPClient.gmailIdleInterval, 540)
        XCTAssertEqual(IMAPClient.standardIdleInterval, 1500)
        let defaulted = await client.effectiveIdleTimeout(nil)
        XCTAssertEqual(defaulted, 540)
        let capped = await client.effectiveIdleTimeout(25 * 60)
        XCTAssertEqual(capped, 540, "Gmail drops IDLE after about 10 minutes, so longer waits are capped")
        let shorter = await client.effectiveIdleTimeout(120)
        XCTAssertEqual(shorter, 120)
        let negative = await client.effectiveIdleTimeout(-5)
        XCTAssertEqual(negative, 0)
    }

    func testIdleIntervalElsewhere() async throws {
        let transport = ScriptedTransport([.send("* OK [CAPABILITY IMAP4rev1 IDLE AUTH=PLAIN] Dovecot ready.\r\n")])
        let client = IMAPClient(host: "mail.example.org", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) { try await client.connect() }
        let interval = await client.idleReissueInterval
        XCTAssertEqual(interval, 25 * 60)
        let defaulted = await client.effectiveIdleTimeout(nil)
        XCTAssertEqual(defaulted, 25 * 60)
        let capped = await client.effectiveIdleTimeout(29 * 60)
        XCTAssertEqual(capped, 25 * 60)
    }

    /// With the default interval the IDLE runs until it's stopped and then says DONE as usual.
    func testIdleWithDefaultIntervalStopsOnRequest() async throws {
        let transport = ScriptedTransport([
            .send("* PREAUTH [CAPABILITY IMAP4rev1 IDLE X-GM-EXT-1] ready\r\n"),
            .expect("* IDLE", reply: "+ idling\r\n* 4 EXISTS\r\n"),
            .expect("DONE", reply: "A001 OK IDLE terminated (Success)\r\n"),
        ])
        let client = IMAPClient(host: "imap.gmail.com", port: 993, security: .tls, transport: transport)
        let box = EventBox()
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.idle { event in
                box.append(event)
                return !event.isExists
            }
        }
        XCTAssertEqual(box.events, [.exists(4)])
        XCTAssertEqual(transport.transcript, "A001 IDLE\r\nDONE\r\n")
    }

    // MARK: PERMANENTFLAGS without \* (RESEARCH §3.4)

    static let exchangeSelect = crlf("""
    * 12 EXISTS
    * 0 RECENT
    * FLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft $MDNSent)
    * OK [PERMANENTFLAGS (\\Seen \\Answered \\Flagged \\Deleted \\Draft $MDNSent)] Permanent flags
    * OK [UIDVALIDITY 14] UIDVALIDITY value
    * OK [UIDNEXT 513] The next unique identifier value
    """) + "\r\n"

    func testExchangeKeywordsAreLeftOutOfStore() async throws {
        let transport = ScriptedTransport([
            .send("* PREAUTH [CAPABILITY IMAP4 IMAP4rev1 UIDPLUS MOVE IDLE LITERAL+] ready\r\n"),
            .expect("* SELECT INBOX", reply: Self.exchangeSelect + "{TAG} OK [READ-WRITE] SELECT completed.\r\n"),
            .expect("* UID STORE 7 +FLAGS.SILENT (\\Answered)", reply: "{TAG} OK STORE completed.\r\n"),
            .expect("* UID STORE 7 +FLAGS.SILENT ($MDNSent)", reply: "{TAG} OK STORE completed.\r\n"),
        ])
        let client = IMAPClient(host: "outlook.office365.com", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            let info = try await client.select("INBOX")
            XCTAssertTrue(info.hasPermanentFlags)
            XCTAssertFalse(info.allowsNewKeywords)
            XCTAssertFalse(info.canStore("$Forwarded"))
            XCTAssertTrue(info.canStore("$mdnsent"))
            XCTAssertTrue(info.canStore("\\Seen"))
            try await client.uidStore(IMAPSequenceSet(7), flags: ["\\Answered", "$Forwarded"], mode: .add)
            // Only keywords the folder can't keep: nothing to send.
            try await client.uidStore(IMAPSequenceSet(7), flags: ["$Forwarded", "$Junk"], mode: .add)
            try await client.uidStore(IMAPSequenceSet(7), flags: ["$MDNSent"], mode: .add)
        }
        XCTAssertFalse(transport.transcript.contains("$Forwarded"))
        XCTAssertFalse(transport.transcript.contains("$Junk"))
    }

    func testKeywordsAreSentWhenTheServerAllowsThem() async throws {
        let transport = ScriptedTransport([
            .send("* PREAUTH [CAPABILITY IMAP4rev1 UIDPLUS] ready\r\n"),
            // No PERMANENTFLAGS at all: RFC 3501 says to assume everything can be stored.
            .expect("* SELECT \"Archive\"", reply: "* 3 EXISTS\r\n* OK [UIDVALIDITY 5] ok\r\n{TAG} OK [READ-WRITE] done\r\n"),
            .expect("* UID STORE 1 +FLAGS.SILENT (\\Answered $Forwarded)", reply: "{TAG} OK done\r\n"),
            .expect("* SELECT INBOX", reply: "* OK [PERMANENTFLAGS (\\Seen \\Deleted \\*)] ok\r\n{TAG} OK [READ-WRITE] done\r\n"),
            .expect("* UID STORE 1 +FLAGS.SILENT ($Forwarded)", reply: "{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            let archive = try await client.select("Archive")
            XCTAssertFalse(archive.hasPermanentFlags)
            XCTAssertTrue(archive.canStore("$Forwarded"))
            try await client.uidStore(IMAPSequenceSet(1), flags: ["\\Answered", "$Forwarded"], mode: .add)
            let inbox = try await client.select("INBOX")
            XCTAssertTrue(inbox.allowsNewKeywords)
            try await client.uidStore(IMAPSequenceSet(1), flags: ["$Forwarded"], mode: .add)
        }
    }

    /// A server that advertises keywords but refuses them anyway: the system flags still get
    /// stored; a keyword-only STORE reports the failure for the caller to ignore.
    func testRefusedKeywordStoreRetriesWithSystemFlags() async throws {
        let transport = ScriptedTransport([
            .send("* PREAUTH [CAPABILITY IMAP4rev1] ready\r\n"),
            .expect("* SELECT INBOX", reply: "* OK [PERMANENTFLAGS (\\Seen \\Answered \\*)] ok\r\n{TAG} OK [READ-WRITE] done\r\n"),
            .expect("* UID STORE 9 +FLAGS.SILENT (\\Answered $Forwarded)", reply: "{TAG} BAD Command Argument Error. 11\r\n"),
            .expect("* UID STORE 9 +FLAGS.SILENT (\\Answered)", reply: "{TAG} OK STORE completed.\r\n"),
            .expect("* UID STORE 9 +FLAGS.SILENT ($Forwarded)", reply: "{TAG} NO Keywords aren't supported here\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            _ = try await client.select("INBOX")
            try await client.uidStore(IMAPSequenceSet(9), flags: ["\\Answered", "$Forwarded"], mode: .add)
            await assertThrowsMailError(.serverError("Keywords aren't supported here.")) {
                try await client.uidStore(IMAPSequenceSet(9), flags: ["$Forwarded"], mode: .add)
            }
        }
        let state = await client.state
        XCTAssertEqual(state, .authenticated, "a refused STORE leaves the connection usable")
    }

    // MARK: Literal without a leading space (GreenMail 2.1)

    func testGreenMailPartialBodyLiteralWithoutSpace() async throws {
        let body = "Hello from GreenMail!\r\n"
        XCTAssertEqual(body.utf8.count, 23)
        let (server, _) = MockIMAPServer.scripted(greeting: "* PREAUTH [CAPABILITY IMAP4rev1 LITERAL+ UIDPLUS] GreenMail ready\r\n", maxChunk: 7, [
            ("SELECT INBOX", "* 1 EXISTS\r\n* OK [UIDVALIDITY 1] ok\r\n{TAG} OK [READ-WRITE] SELECT completed.\r\n"),
            ("UID FETCH 5 (UID BODY.PEEK[1]<0.2048>)", "* 1 FETCH (UID 5 BODY[1]<0>{23}\r\n\(body))\r\n{TAG} OK FETCH completed.\r\n"),
        ])
        let client = IMAPClient(host: "localhost", port: 3143, security: .none, transport: server)
        let responses = try await withWatchdog(server) { () -> [IMAPFetchResponse] in
            try await client.connect()
            _ = try await client.select("INBOX")
            return try await client.fetch(IMAPSequenceSet(5), byUID: true, items: [.bodyPeek(section: "1", partial: (0, 2048))])
        }
        XCTAssertEqual(responses.count, 1)
        XCTAssertEqual(responses.first?.uid, 5)
        XCTAssertEqual(responses.first?.section("1").map { String(decoding: $0, as: UTF8.self) }, body)
        XCTAssertEqual(responses.first?.sectionOrigins["1"], 0)
    }
}

/// Wraps a transport so reads fail the way a TLS failure surfaces on Apple platforms: on the
/// first read after `startTLS()` (or, with `failFromFirstRead`, on the very first read).
final class TLSFailingTransport: MailTransport, @unchecked Sendable {
    private let inner: MailTransport
    private let failure: TransportError
    private let lock = NSLock()
    private var failing: Bool

    init(_ inner: MailTransport, failure: TransportError, failFromFirstRead: Bool = false) {
        self.inner = inner
        self.failure = failure
        self.failing = failFromFirstRead
    }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        try await inner.open(host: host, port: port, tls: tls, timeout: timeout)
    }

    func startTLS() async throws {
        try await inner.startTLS()
        lock.withLock { failing = true }
    }

    func read(timeout: TimeInterval) async throws -> Data {
        if lock.withLock({ failing }) { throw failure }
        return try await inner.read(timeout: timeout)
    }

    func write(_ data: Data) async throws { try await inner.write(data) }
    func close() { inner.close() }
}
