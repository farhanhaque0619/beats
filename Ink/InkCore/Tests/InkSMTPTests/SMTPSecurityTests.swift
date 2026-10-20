import XCTest
import InkModel
@testable import InkSMTP

/// STARTTLS and implicit-TLS rules from docs/RESEARCH.md §3.2, plus reply text handling that
/// must be identical on Apple platforms and Linux.
final class SMTPSecurityTests: XCTestCase {
    private func client(_ transport: MailTransport, security: ConnectionSecurity) -> SMTPClient {
        SMTPClient(host: "smtp.example.org", port: security == .tls ? 465 : 587, security: security,
                   transport: GuardedTransport(transport), localHostname: "ada-mac.local", timeout: 5)
    }

    // MARK: STARTTLS (§3.2 rules 2–4)

    /// The order on the wire: EHLO, STARTTLS, the handshake, EHLO again, and only then AUTH.
    func testCredentialsFollowTheEHLOReadOverTLS() async throws {
        let script = ScriptedTransport([
            .send("220 smtp.example.org ESMTP ready\r\n"),
            .expect("EHLO ada-mac.local", reply: "250-smtp.example.org\r\n250-PIPELINING\r\n250-AUTH LOGIN\r\n250 STARTTLS\r\n"),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n"),
            .expect("EHLO ada-mac.local", reply: "250-smtp.example.org\r\n250-SIZE 36700160\r\n250 AUTH PLAIN LOGIN\r\n"),
            .expect("AUTH PLAIN", reply: "235 2.7.0 Authentication successful\r\n"),
        ])
        let smtp = client(script, security: .startTLS)
        try await smtp.connect()
        let extensions = await smtp.extensions
        XCTAssertEqual(extensions["AUTH"], "PLAIN LOGIN", "pre-TLS extensions are thrown away")
        XCTAssertNil(extensions["PIPELINING"])
        try await smtp.login(username: "ada@example.org", password: "app-password")
        let commands = script.transcript.components(separatedBy: "\r\n").filter { !$0.isEmpty }.map { $0.split(separator: " ").first.map(String.init) ?? "" }
        XCTAssertEqual(commands, ["EHLO", "STARTTLS", "EHLO", "AUTH"])
        XCTAssertTrue(script.didStartTLS)
    }

    /// A certificate problem surfaces on the first read after the handshake (the EHLO reply),
    /// so the password is never sent.
    func testTLSFailureOnTheFirstReadAfterStartTLSStopsBeforeAuth() async {
        let script = ScriptedTransport([
            .send("220 smtp.example.org ESMTP ready\r\n"),
            .expect("EHLO", reply: "250-smtp.example.org\r\n250 STARTTLS\r\n"),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n"),
        ])
        let smtp = client(ReadFailsAfterTLS(script, failure: .tlsFailed("The certificate for this server is invalid.")), security: .startTLS)
        let error = await assertThrowsMailError {
            try await smtp.connect()
            try await smtp.login(username: "ada@example.org", password: "app-password")
        }
        XCTAssertEqual(error, .tlsFailed("The certificate for this server is invalid."))
        XCTAssertEqual(script.transcript, "EHLO ada-mac.local\r\nSTARTTLS\r\nEHLO ada-mac.local\r\n")
        XCTAssertFalse(script.isOpen)
        let connected = await smtp.isConnected
        XCTAssertFalse(connected)
    }

    /// Implicit TLS: the greeting is the first read; a TLS failure there sends nothing.
    func testTLSFailureOnTheGreetingSendsNothing() async {
        let script = ScriptedTransport([.send("220 smtp.example.org ESMTP ready\r\n")])
        let smtp = client(ReadFailsAfterTLS(script, failure: .tlsFailed("The certificate has expired."), failFromFirstRead: true), security: .tls)
        let error = await assertThrowsMailError { try await smtp.connect() }
        XCTAssertEqual(error, .tlsFailed("The certificate has expired."))
        XCTAssertTrue(script.openedTLS)
        XCTAssertEqual(script.transcript, "")
    }

    /// A partial line injected after the 220 is just as untrustworthy as a complete one.
    func testPartialLineAfterStartTLSReplyAborts() async {
        let script = ScriptedTransport([
            .send("220 smtp.example.org ESMTP ready\r\n"),
            .expect("EHLO", reply: "250-smtp.example.org\r\n250 STARTTLS\r\n"),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n250-smtp.example.org"),
        ])
        let smtp = client(script, security: .startTLS)
        let error = await assertThrowsMailError { try await smtp.connect() }
        XCTAssertEqual(error, .tlsFailed("The server sent unexpected data before the secure connection started."))
        XCTAssertFalse(script.didStartTLS)
        XCTAssertEqual(script.transcript, "EHLO ada-mac.local\r\nSTARTTLS\r\n")
        XCTAssertFalse(script.isOpen)
    }

    /// A server that doesn't understand EHLO gets HELO, which has no extensions at all, so
    /// STARTTLS can't be offered: the client stops rather than continue in plaintext.
    func testHELOFallbackNeverSkipsStartTLS() async {
        let script = ScriptedTransport([
            .send("220 old.example.org SMTP\r\n"),
            .expect("EHLO", reply: "502 5.5.2 Command not recognized\r\n"),
            .expect("HELO", reply: "250 old.example.org\r\n"),
        ])
        let smtp = client(script, security: .startTLS)
        let error = await assertThrowsMailError {
            try await smtp.connect()
            try await smtp.login(username: "ada", password: "pw")
        }
        guard case .tlsFailed? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertFalse(script.transcript.contains("AUTH"))
        XCTAssertFalse(script.transcript.contains("STARTTLS"))
        XCTAssertFalse(script.isOpen)
    }

    // MARK: Reply text

    /// Some servers end lines with CR CR LF; the stray CR must not end up in parameters.
    func testCRCRLFLineEndings() throws {
        var parser = SMTPReplyParser()
        parser.append(Data("250-smtp.example.org\r\r\n250-SIZE 10240000\r\r\n250 AUTH PLAIN LOGIN\r\r\n".utf8))
        let reply = try XCTUnwrap(try parser.nextReply())
        XCTAssertEqual(reply.lines, ["smtp.example.org", "SIZE 10240000", "AUTH PLAIN LOGIN"])
        let extensions = SMTPClient.parseExtensions(reply)
        XCTAssertEqual(extensions["SIZE"], "10240000")
        XCTAssertEqual(extensions["AUTH"], "PLAIN LOGIN")
        XCTAssertFalse(parser.hasBufferedBytes)
    }

    func testTooManyRecipientsTextIsMatchedIgnoringCase() async throws {
        // No enhanced status code, so only the text says why: one recipient per transaction.
        let counter = Counter()
        let server = FakeSMTPServer { line in
            let upper = line.uppercased()
            if upper.hasPrefix("EHLO") { return "250-test.example\r\n250 AUTH PLAIN\r\n" }
            if upper.hasPrefix("MAIL FROM") {
                counter.reset()
                return "250 OK\r\n"
            }
            if upper.hasPrefix("RCPT TO") { return counter.next() <= 1 ? "250 OK\r\n" : "452 Too Many Recipients in this message\r\n" }
            if upper == "DATA" { return "354 Go ahead\r\n" }
            return "250 OK\r\n"
        }
        let smtp = SMTPClient(host: "h", port: 465, security: .tls, transport: GuardedTransport(server), timeout: 5)
        try await smtp.connect()
        let result = try await smtp.send(from: "ada@example.org", recipients: ["a@example.org", "b@example.org"], message: sampleMessage())
        XCTAssertEqual(result.accepted, ["a@example.org", "b@example.org"], "the deferred recipient goes in a second transaction")
        XCTAssertEqual(result.finalReplies.count, 2)
    }

    func testReplyTextContainsIsByteLevel() {
        XCTAssertTrue(SMTPText.contains("Too Many Recipients\r\n", "\n"))
        XCTAssertTrue(SMTPText.contains("a\r\nb", "\r"))
        XCTAssertTrue(SMTPText.contains("Delivery FAILED [AM0PR01MB1234.EURPRD01.PROD.OUTLOOK.COM]", "outlook.com"))
        XCTAssertTrue(SMTPText.contains("Cafe\u{301}", "cafe"))
        XCTAssertFalse(SMTPText.contains("ab", "abc"))
        XCTAssertTrue(SMTPText.contains("x", ""))
    }

    func testTraceTokensAreStrippedWithMixedCaseHosts() {
        let reply = SMTPReply(code: 550, lines: ["5.7.60 SMTP; Client does not have permissions to send as this sender [DB9PR01MB1234.EURPRD01.PROD.OUTLOOK.COM 2026-10-20T10:00:00.000Z 08DCF1234567]"])
        XCTAssertEqual(reply.text, "SMTP; Client does not have permissions to send as this sender")
        let gmail = SMTPReply(code: 535, lines: ["5.7.8 Username and Password not accepted. For more information, go to", "5.7.8  https://support.google.com/mail/?p=BadCredentials d9443c01a7336-2e8f9d2a3cbsm1234567.31 - gsmtp"])
        XCTAssertEqual(gmail.text, "Username and Password not accepted. For more information, go to https://support.google.com/mail/?p=BadCredentials")
    }
}

/// Wraps a transport so reads fail the way a TLS failure surfaces with URLSessionStreamTask: on
/// the first read after `startTLS()` (or, with `failFromFirstRead`, on the very first read).
final class ReadFailsAfterTLS: MailTransport, @unchecked Sendable {
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
