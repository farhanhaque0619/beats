import XCTest
import InkModel
@testable import InkSMTP

final class SMTPClientEdgeCaseTests: XCTestCase {
    private func scripted(_ steps: [ScriptedTransport.Step], security: ConnectionSecurity = .tls, logger: (@Sendable (String) -> Void)? = nil) -> (SMTPClient, ScriptedTransport) {
        let script = ScriptedTransport(steps)
        let client = SMTPClient(host: "mail.example.org", port: security == .startTLS ? 587 : 465, security: security, transport: GuardedTransport(script), timeout: 5, logger: logger)
        return (client, script)
    }

    private func fake(_ server: FakeSMTPServer) -> SMTPClient {
        SMTPClient(host: "mail.example.org", port: 465, security: .tls, transport: GuardedTransport(server), timeout: 5)
    }

    private let simpleEHLO = "250-mail.example.org\r\n250-SIZE 10240000\r\n250-8BITMIME\r\n250-AUTH PLAIN LOGIN\r\n250 ENHANCEDSTATUSCODES\r\n"

    // MARK: Greeting and EHLO

    func testMultilineGreetingAndHELOFallback() async throws {
        let (client, script) = scripted([
            .send("220-mail.example.org ESMTP Sendmail 8.14.4/8.14.4\r\n220-This system is for authorized use only.\r\n220 Please behave.\r\n"),
            .expect("EHLO localhost", reply: "500 5.5.1 Command unrecognized: \"EHLO localhost\"\r\n"),
            .expect("HELO localhost", reply: "250 mail.example.org Hello localhost [203.0.113.42], pleased to meet you\r\n"),
            .expect("AUTH PLAIN", reply: "235 2.0.0 OK Authenticated\r\n"),
        ])
        try await client.connect()
        let usedHELO = await client.usedHELO
        XCTAssertTrue(usedHELO)
        let greeting = await client.greeting
        XCTAssertEqual(greeting?.lines.count, 3)
        let extensions = await client.extensions
        XCTAssertTrue(extensions.isEmpty)
        // Nothing advertised: PLAIN is tried anyway.
        try await client.login(username: "ada", password: "pw")
        XCTAssertTrue(script.transcript.contains("AUTH PLAIN "))
    }

    func testHELOFallbackWithoutExtensionsSendsPlainMailFrom() async throws {
        let server = FakeSMTPServer(respond: { line in
            if line.hasPrefix("EHLO") { return "502 5.5.2 Error: command not recognized\r\n" }
            if line.hasPrefix("HELO") { return "250 test.example\r\n" }
            return standardResponder()(line)
        })
        let client = fake(server)
        try await client.connect()
        try await client.send(from: "ada@example.org", recipients: ["grace@example.org"], message: Data("Subject: Grüße\r\n\r\nHallo\r\n".utf8))
        XCTAssertTrue(server.receivedCommands.contains("MAIL FROM:<ada@example.org>"), "no SIZE/BODY parameters without EHLO: \(server.receivedCommands)")
    }

    func testGreetingRefusal() async {
        let (client, _) = scripted([.send("554 5.7.1 mail.example.org ESMTP not accepting connections from 203.0.113.42 (listed at zen.spamhaus.org)\r\n")])
        let error = await assertThrowsMailError { try await client.connect() }
        XCTAssertEqual(error, .connectionFailed("mail.example.org ESMTP not accepting connections from 203.0.113.42 (listed at zen.spamhaus.org)"))
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func test421DuringEHLOClosesTheConnection() async {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "421 4.7.0 mail.example.org Too many concurrent SMTP connections; please try again later.\r\n"),
        ])
        let error = await assertThrowsMailError { try await client.connect() }
        XCTAssertEqual(error, .connectionFailed("mail.example.org Too many concurrent SMTP connections; please try again later."))
        XCTAssertFalse(script.isOpen)
    }

    func testEHLOAndHELOBothRefused() async {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "550 5.7.1 Go away\r\n"),
            .expect("HELO", reply: "550 5.7.1 Still go away\r\n"),
        ])
        let error = await assertThrowsMailError { try await client.connect() }
        XCTAssertEqual(error, .serverError("Still go away"))
    }

    func testConnectIsIdempotent() async throws {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: simpleEHLO),
        ])
        try await client.connect()
        try await client.connect()
        XCTAssertEqual(script.written.count, 1)
    }

    // MARK: STARTTLS

    func testStartTLSRequiredButNotOffered() async {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP Postfix\r\n"),
            .expect("EHLO", reply: simpleEHLO),
        ], security: .startTLS)
        let error = await assertThrowsMailError { try await client.connect() }
        guard case .tlsFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("STARTTLS"))
        XCTAssertFalse(script.didStartTLS)
        XCTAssertFalse(script.transcript.contains("AUTH"))
        XCTAssertFalse(script.isOpen)
    }

    func testStartTLSRefused() async {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP Postfix\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 STARTTLS\r\n"),
            .expect("STARTTLS", reply: "454 4.7.0 TLS not available due to local problem\r\n"),
        ], security: .startTLS)
        let error = await assertThrowsMailError { try await client.connect() }
        XCTAssertEqual(error, .tlsFailed("TLS not available due to local problem"))
        XCTAssertFalse(script.didStartTLS)
    }

    /// Bytes injected after the 220 to STARTTLS arrive unencrypted; acting on them would let a
    /// man in the middle answer for the server (CVE-2011-0411).
    func testDataInjectedAfterStartTLSIsRejected() async {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP Postfix\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 STARTTLS\r\n"),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n250-evil\r\n250 AUTH PLAIN\r\n"),
        ], security: .startTLS)
        let error = await assertThrowsMailError { try await client.connect() }
        guard case .tlsFailed? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertFalse(script.didStartTLS)
    }

    func testStartTLSHandshakeFailure() async {
        final class TLSFailing: MailTransport, @unchecked Sendable {
            let inner: ScriptedTransport
            init(_ inner: ScriptedTransport) { self.inner = inner }
            func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws { try await inner.open(host: host, port: port, tls: tls, timeout: timeout) }
            func startTLS() async throws { throw TransportError.tlsFailed("The certificate for this server is invalid.") }
            func read(timeout: TimeInterval) async throws -> Data { try await inner.read(timeout: timeout) }
            func write(_ data: Data) async throws { try await inner.write(data) }
            func close() { inner.close() }
        }
        let script = ScriptedTransport([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 STARTTLS\r\n"),
            .expect("STARTTLS", reply: "220 2.0.0 go ahead\r\n"),
        ])
        let client = SMTPClient(host: "mail.example.org", port: 587, security: .startTLS, transport: TLSFailing(script), timeout: 5)
        let error = await assertThrowsMailError { try await client.connect() }
        XCTAssertEqual(error, .tlsFailed("The certificate for this server is invalid."))
    }

    // MARK: Transport failures

    func testOpenFailureMapsToConnectionFailed() async {
        let client = SMTPClient(host: "smtp.example.invalid", port: 465, security: .tls, transport: FailingTransport(.openFails(.connectFailed("No such host"))))
        let error = await assertThrowsMailError { try await client.connect() }
        XCTAssertEqual(error, .connectionFailed("No such host"))
    }

    func testTimeoutWaitingForEHLOReply() async {
        let client = SMTPClient(host: "slow.example", port: 465, security: .tls, transport: FailingTransport(.greetingThenTimeout), timeout: 1)
        let error = await assertThrowsMailError { try await client.connect() }
        XCTAssertEqual(error, .timeout)
    }

    func testServerClosesMidSession() async {
        let client = SMTPClient(host: "flaky.example", port: 465, security: .tls, transport: FailingTransport(.closedAfterGreeting))
        let error = await assertThrowsMailError { try await client.connect() }
        guard case .connectionFailed? = error else { return XCTFail("\(String(describing: error))") }
    }

    func testMalformedReplyIsProtocolError() async {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "HTTP/1.1 400 Bad Request\r\n\r\n"),
        ])
        let error = await assertThrowsMailError { try await client.connect() }
        guard case .protocolError(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("HTTP/1.1 400"))
    }

    func testCallsBeforeConnectFail() async {
        let client = SMTPClient(host: "x.example", port: 465, security: .tls, transport: ScriptedTransport([]))
        let sendError = await assertThrowsMailError { try await client.send(from: "a@x.example", recipients: ["b@x.example"], message: Data()) }
        XCTAssertEqual(sendError, .connectionFailed("Not connected to the sending server."))
        let loginError = await assertThrowsMailError { try await client.login(username: "a", password: "b") }
        guard case .connectionFailed? = loginError else { return XCTFail() }
        await client.quit()   // no-op, must not hang
    }

    // MARK: Authentication variants

    func testPlainWithoutInitialResponseSupport() async throws {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: simpleEHLO),
            .expect("AUTH PLAIN", reply: "334 \r\n"),
            .expect(SASL.plain(username: "ada", password: "pw"), reply: "235 2.7.0 Authentication successful\r\n"),
        ])
        try await client.connect()
        try await client.login(username: "ada", password: "pw")
        XCTAssertEqual(script.transcript.components(separatedBy: SASL.plain(username: "ada", password: "pw")).count - 1, 2)
    }

    func testPlainFallsBackToLoginOn504() async throws {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: simpleEHLO),
            .expect("AUTH PLAIN", reply: "504 5.5.4 Unrecognized authentication type\r\n"),
            .expect("AUTH LOGIN", reply: "334 VXNlcm5hbWU6\r\n"),
            .expect(SASL.login("ada"), reply: "334 UGFzc3dvcmQ6\r\n"),
            .expect(SASL.login("pw"), reply: "235 2.7.0 Authentication successful\r\n"),
        ])
        try await client.connect()
        try await client.login(username: "ada", password: "pw")
        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)
    }

    func testLoginUnsupportedWhenOnlyOAuthOffered() async throws {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 AUTH XOAUTH2\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada", password: "pw") }
        guard case .notSupported(let what)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(what.contains("password"))
        XCTAssertFalse(script.transcript.contains("AUTH"))
    }

    func testOAuthUnsupportedWhenOnlyPasswordsOffered() async throws {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: simpleEHLO),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.authenticateXOAUTH2(username: "ada", accessToken: "t") }
        guard case .notSupported? = error else { return XCTFail("\(String(describing: error))") }
    }

    func testAuthNotEnabledOnServer() async throws {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP Postfix\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 8BITMIME\r\n"),
            .expect("AUTH PLAIN", reply: "503 5.5.1 Error: authentication not enabled\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada", password: "pw") }
        guard case .notSupported? = error else { return XCTFail("\(String(describing: error))") }
    }

    func testTemporaryAuthFailureIsServerError() async throws {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: simpleEHLO),
            .expect("AUTH PLAIN", reply: "454 4.7.0 Temporary authentication failure\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada", password: "pw") }
        XCTAssertEqual(error, .serverError("Temporary authentication failure"))
    }

    func testEncryptionRequired538() async throws {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: simpleEHLO),
            .expect("AUTH PLAIN", reply: "538 5.7.11 Encryption required for requested authentication mechanism\r\n"),
        ], security: .none)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada", password: "pw") }
        XCTAssertEqual(error, .authenticationFailed("Encryption required for requested authentication mechanism"))
    }

    func testLoggerRedactsLoginSecrets() async throws {
        let logs = LogCollector()
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 AUTH LOGIN\r\n"),
            .expect("AUTH LOGIN", reply: "334 VXNlcm5hbWU6\r\n"),
            .expect(SASL.login("ada@example.org"), reply: "334 UGFzc3dvcmQ6\r\n"),
            .expect(SASL.login("correct horse battery staple"), reply: "235 2.7.0 OK\r\n"),
        ], logger: logs.logger)
        try await client.connect()
        try await client.login(username: "ada@example.org", password: "correct horse battery staple")
        let joined = logs.lines.joined(separator: "\n")
        XCTAssertFalse(joined.contains(SASL.login("correct horse battery staple")))
        XCTAssertFalse(joined.contains("correct horse"))
        XCTAssertTrue(joined.contains("C: AUTH LOGIN"))
        XCTAssertTrue(joined.contains("S: 235 2.7.0 OK"))
    }

    // MARK: Sending details

    func testSizePrecheckRefusesBeforeMailFrom() async throws {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 SIZE 1024\r\n"),
        ])
        try await client.connect()
        let big = Data(("Subject: big\r\n\r\n" + String(repeating: "0123456789abcdef\r\n", count: 2048)).utf8)
        let error = await assertThrowsMailError { try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: big) }
        guard case .sendFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("too large"))
        XCTAssertTrue(text.contains("the limit is 1 KB"), text)
        XCTAssertFalse(script.transcript.contains("MAIL FROM"))
    }

    func testSizeRejectedAtMailFrom() async throws {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 SIZE\r\n"),
            .expect("MAIL FROM", reply: "552 5.3.4 Message size exceeds fixed limit\r\n"),
            .expect("RSET", reply: "250 2.0.0 Ok\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: sampleMessage()) }
        guard case .sendFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("too large"))
    }

    func testAuthRequiredAtMailFrom() async throws {
        let (client, _) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: simpleEHLO),
            .expect("MAIL FROM", reply: "530 5.7.0 Authentication required\r\n"),
            .expect("RSET", reply: "250 2.0.0 Ok\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: sampleMessage()) }
        XCTAssertEqual(error, .authenticationFailed("Authentication required"))
    }

    func testEightBitBodyDeclaresBody8BITMIME() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["8BITMIME", "SIZE 0"]))
        let client = fake(server)
        try await client.connect()
        let message = Data("From: a@example.org\r\nSubject: Grüße\r\nContent-Type: text/plain; charset=utf-8\r\nContent-Transfer-Encoding: 8bit\r\n\r\nGrüße aus Köln\r\n".utf8)
        try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: message)
        let mailFrom = server.receivedCommands.first { $0.hasPrefix("MAIL FROM") }
        // Raw UTF-8 in a header but no SMTPUTF8 on this server: still sent, as most servers accept it.
        XCTAssertEqual(mailFrom, "MAIL FROM:<a@example.org> SIZE=\(SMTPDataEncoder.encodedLength(of: message)) BODY=8BITMIME")
        XCTAssertEqual(server.messages.first, String(decoding: message, as: UTF8.self))
    }

    func testUTF8HeadersUseSMTPUTF8WhenOffered() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["8BITMIME", "SMTPUTF8"]))
        let client = fake(server)
        try await client.connect()
        try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: Data("Subject: Grüße\r\n\r\nhi\r\n".utf8))
        XCTAssertEqual(server.receivedCommands.first { $0.hasPrefix("MAIL FROM") }, "MAIL FROM:<a@example.org> BODY=8BITMIME SMTPUTF8")
    }

    func testInternationalMailboxNeedsSMTPUTF8() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["8BITMIME", "SMTPUTF8"]))
        let client = fake(server)
        try await client.connect()
        try await client.send(from: "ada@example.org", recipients: ["用户@例子.广告"], message: sampleMessage())
        XCTAssertEqual(server.receivedCommands.first { $0.hasPrefix("MAIL FROM") }, "MAIL FROM:<ada@example.org> SMTPUTF8")
        XCTAssertTrue(server.receivedCommands.contains("RCPT TO:<用户@例子.广告>"))
    }

    func testInternationalMailboxWithoutSMTPUTF8Fails() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["8BITMIME"]))
        let client = fake(server)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.send(from: "ada@example.org", recipients: ["jürgen@example.de"], message: sampleMessage()) }
        guard case .sendFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("jürgen@example.de"))
        XCTAssertFalse(server.receivedCommands.contains { $0.hasPrefix("MAIL") })
    }

    func testInternationalDomainBecomesPunycodeWithoutSMTPUTF8() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["8BITMIME"]))
        let client = fake(server)
        try await client.connect()
        let result = try await client.send(from: "ada@example.org", recipients: ["info@bücher.example"], message: sampleMessage())
        XCTAssertTrue(server.receivedCommands.contains("RCPT TO:<info@xn--bcher-kva.example>"))
        XCTAssertFalse(server.receivedCommands.contains { $0.contains("SMTPUTF8") })
        XCTAssertEqual(result.accepted, ["info@bücher.example"], "results speak in the caller's addresses")
    }

    func testDotStuffingAndLineEndingsOnTheWire() async throws {
        let server = FakeSMTPServer(respond: standardResponder())
        let client = fake(server)
        try await client.connect()
        let message = Data("Subject: dots\n\n.leading dot\nmiddle.dot\n.\n..double\r\nlast line without newline".utf8)
        try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: message)
        XCTAssertEqual(server.messages, ["Subject: dots\r\n\r\n..leading dot\r\nmiddle.dot\r\n..\r\n...double\r\nlast line without newline\r\n"])
    }

    func testLargeMessageIsStreamedInChunks() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["SIZE 52428800", "8BITMIME"]))
        let client = fake(server)
        try await client.connect()
        var text = "Subject: big attachment\r\nContent-Type: application/octet-stream\r\nContent-Transfer-Encoding: base64\r\n\r\n"
        let line = String(repeating: "QUJD", count: 19) + "\r\n"
        text += String(repeating: line, count: 20_000)
        let message = Data(text.utf8)
        try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: message)
        XCTAssertEqual(server.messages.first?.utf8.count, message.count)
        XCTAssertTrue(server.receivedCommands.contains("MAIL FROM:<a@example.org> SIZE=\(message.count)"))
    }

    func testTooManyRecipientsSplitsIntoTransactions() async throws {
        let counter = Counter()
        let server = FakeSMTPServer(respond: { line in
            if line.hasPrefix("RCPT TO") {
                // Accept two recipients per transaction, like a server with a low per-message limit.
                return counter.next() <= 2 ? "250 2.1.5 OK\r\n" : "452 4.5.3 Too many recipients\r\n"
            }
            if line.hasPrefix("MAIL FROM") { counter.reset() }
            return standardResponder(extensions: ["PIPELINING", "ENHANCEDSTATUSCODES"])(line)
        })
        let client = fake(server)
        try await client.connect()
        let recipients = (1...5).map { "person\($0)@example.org" }
        let result = try await client.send(from: "a@example.org", recipients: recipients, message: sampleMessage())
        XCTAssertEqual(result.accepted, recipients)
        XCTAssertTrue(result.rejected.isEmpty)
        XCTAssertEqual(result.finalReplies.count, 3)
        XCTAssertEqual(server.messages.count, 3)
        XCTAssertEqual(server.receivedCommands.filter { $0.hasPrefix("MAIL FROM") }.count, 3)
    }

    func testMailboxFull452IsARejectionNotADeferral() async throws {
        let server = FakeSMTPServer(respond: { line in
            if line == "RCPT TO:<full@example.org>" { return "452 4.2.2 The email account that you tried to reach is over quota.\r\n" }
            return standardResponder()(line)
        })
        let client = fake(server)
        try await client.connect()
        let result = try await client.send(from: "a@example.org", recipients: ["ok@example.org", "full@example.org"], message: sampleMessage())
        XCTAssertEqual(result.accepted, ["ok@example.org"])
        XCTAssertEqual(result.rejected.map(\.message), ["full@example.org: The email account that you tried to reach is over quota."])
        XCTAssertEqual(server.messages.count, 1)
    }

    func testRecipient530IsAuthenticationFailure() async throws {
        let server = FakeSMTPServer(respond: { line in
            if line.hasPrefix("RCPT TO") { return "530 5.7.0 Must issue a STARTTLS command first\r\n" }
            return standardResponder()(line)
        })
        let client = fake(server)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: sampleMessage()) }
        XCTAssertEqual(error, .authenticationFailed("Must issue a STARTTLS command first"))
        XCTAssertTrue(server.receivedCommands.contains("RSET"))
    }

    func testDataCommandRefused() async throws {
        let server = FakeSMTPServer(respond: { line in
            if line == "DATA" { return "554 5.5.1 Error: no valid recipients\r\n" }
            return standardResponder()(line)
        })
        let client = fake(server)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: sampleMessage()) }
        XCTAssertEqual(error, .sendFailed("Error: no valid recipients"))
    }

    func testTransientFailureAtEndOfData() async throws {
        let server = FakeSMTPServer(finalReply: "451 4.7.1 Greylisted, please try again in 300 seconds\r\n", respond: standardResponder())
        let client = fake(server)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: sampleMessage()) }
        XCTAssertEqual(error, .sendFailed("Greylisted, please try again in 300 seconds"))
    }

    func testInvalidAddressesAreRefusedLocally() async throws {
        let server = FakeSMTPServer(respond: standardResponder())
        let client = fake(server)
        try await client.connect()
        let injected = await assertThrowsMailError {
            try await client.send(from: "a@example.org", recipients: ["b@example.org>\r\nRCPT TO:<eve@evil.example"], message: sampleMessage())
        }
        guard case .sendFailed? = injected else { return XCTFail("\(String(describing: injected))") }
        let badSender = await assertThrowsMailError { try await client.send(from: "not an address", recipients: ["b@example.org"], message: sampleMessage()) }
        guard case .sendFailed? = badSender else { return XCTFail() }
        let nobody = await assertThrowsMailError { try await client.send(from: "a@example.org", recipients: ["", "  "], message: sampleMessage()) }
        XCTAssertEqual(nobody, .sendFailed("There's no one to send this to."))
        XCTAssertFalse(server.receivedCommands.contains { $0.hasPrefix("MAIL") || $0.contains("eve@") })
    }

    func testNullSenderIsAllowed() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["8BITMIME"]))
        let client = fake(server)
        try await client.connect()
        try await client.send(from: "<>", recipients: ["b@example.org"], message: sampleMessage())
        XCTAssertTrue(server.receivedCommands.contains("MAIL FROM:<>"))
    }

    func testSequentialCommandsWithoutPipelining() async throws {
        let server = FakeSMTPServer(respond: { line in
            if line == "RCPT TO:<bad@example.org>" { return "550 5.1.1 No such user\r\n" }
            return standardResponder(extensions: ["8BITMIME"])(line)
        })
        let client = fake(server)
        try await client.connect()
        let result = try await client.send(from: "a@example.org", recipients: ["b@example.org", "bad@example.org", "c@example.org"], message: sampleMessage())
        XCTAssertEqual(result.accepted, ["b@example.org", "c@example.org"])
        XCTAssertEqual(server.receivedCommands.prefix(6), ["EHLO localhost", "MAIL FROM:<a@example.org>", "RCPT TO:<b@example.org>", "RCPT TO:<bad@example.org>", "RCPT TO:<c@example.org>", "DATA"])
    }

    func testConcurrentSendsAreSerialised() async throws {
        let server = FakeSMTPServer(respond: standardResponder(extensions: ["8BITMIME"]))
        let client = fake(server)
        try await client.connect()
        try await withThrowingTaskGroup(of: Void.self) { group in
            for index in 0..<5 {
                group.addTask {
                    try await client.send(from: "a@example.org", recipients: ["r\(index)@example.org"], message: sampleMessage(subject: "Message \(index)"))
                }
            }
            try await group.waitForAll()
        }
        XCTAssertEqual(server.messages.count, 5)
        // Each transaction is MAIL, RCPT, DATA in order with nothing interleaved.
        let transaction = server.receivedCommands.dropFirst().map { String($0.prefix(4)) }
        XCTAssertEqual(transaction, Array(repeating: ["MAIL", "RCPT", "DATA"], count: 5).flatMap { $0 })
    }

    func testQuitClosesEvenWhenServerDoesNotAnswer() async throws {
        let server = FakeSMTPServer(respond: { line in line == "QUIT" ? nil : standardResponder()(line) })
        let client = SMTPClient(host: "mail.example.org", port: 465, security: .tls, transport: GuardedTransport(server, limit: 0.5), timeout: 0.5)
        try await client.connect()
        await client.quit()
        XCTAssertFalse(server.isOpen)
        let connected = await client.isConnected
        XCTAssertFalse(connected)
    }

    func testCancelledTaskDoesNotSend() async throws {
        let server = FakeSMTPServer(respond: standardResponder())
        let client = fake(server)
        try await client.connect()
        let task = Task {
            withUnsafeCurrentTask { $0?.cancel() }
            return try await client.send(from: "a@example.org", recipients: ["b@example.org"], message: sampleMessage())
        }
        do {
            _ = try await task.value
            XCTFail("expected cancellation")
        } catch {
            XCTAssertEqual(error as? MailError, .cancelled)
        }
        XCTAssertFalse(server.receivedCommands.contains { $0.hasPrefix("MAIL") })
    }
}

final class Counter: @unchecked Sendable {
    private let lock = NSLock()
    private var value = 0
    func next() -> Int { lock.withLock { value += 1; return value } }
    func reset() { lock.withLock { value = 0 } }
}
