import XCTest
import InkModel
@testable import InkSMTP

/// End-to-end sessions against scripted transcripts modelled on real provider servers.
final class SMTPClientTranscriptTests: XCTestCase {
    // MARK: Fixtures

    static let gmailGreeting = "220 smtp.gmail.com ESMTP d9443c01a7336-29245ed2a4fsm1428375ad.16 - gsmtp\r\n"
    static let gmailEHLO = """
    250-smtp.gmail.com at your service, [203.0.113.42]\r
    250-SIZE 35882577\r
    250-8BITMIME\r
    250-AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH\r
    250-ENHANCEDSTATUSCODES\r
    250-PIPELINING\r
    250-CHUNKING\r
    250 SMTPUTF8\r

    """
    static let gmailID = "d9443c01a7336-29245ed2a4fsm1428375ad.16 - gsmtp"

    static let icloudGreeting = "220 p00-icloudmta-asmtp-us-west-2a-60-percent-3 ESMTP Service Ready\r\n"
    static let icloudHost = "p00-icloudmta-asmtp-us-west-2a-60-percent-3.p00-icloudmta-asmtp-vip.icloud-mail-production.svc.kube.us-west-2a.k8s.cloud.apple.com"
    static let icloudEHLOPlain = """
    250-\(icloudHost)\r
    250-8BITMIME\r
    250-PIPELINING\r
    250-ENHANCEDSTATUSCODES\r
    250-SIZE 28311552\r
    250-STARTTLS\r
    250 SMTPUTF8\r

    """
    static let icloudEHLOTLS = """
    250-\(icloudHost)\r
    250-8BITMIME\r
    250-AUTH PLAIN LOGIN ATOKEN WSTOKEN WETOKEN\r
    250-PIPELINING\r
    250-ENHANCEDSTATUSCODES\r
    250-SIZE 28311552\r
    250 SMTPUTF8\r

    """

    static let outlookGreeting = "220 PH8PR07CA0012.outlook.office365.com Microsoft ESMTP MAIL Service ready at Tue, 20 Oct 2026 14:03:11 +0000 08DEF0A1B2C3D4E5\r\n"
    static let outlookEHLOPlain = """
    250-PH8PR07CA0012.outlook.office365.com Hello [203.0.113.42]\r
    250-SIZE 157286400\r
    250-PIPELINING\r
    250-DSN\r
    250-ENHANCEDSTATUSCODES\r
    250-STARTTLS\r
    250-8BITMIME\r
    250-BINARYMIME\r
    250-CHUNKING\r
    250 SMTPUTF8\r

    """
    static let outlookEHLOTLS = """
    250-PH8PR07CA0012.outlook.office365.com Hello [203.0.113.42]\r
    250-SIZE 157286400\r
    250-PIPELINING\r
    250-DSN\r
    250-ENHANCEDSTATUSCODES\r
    250-AUTH LOGIN XOAUTH2\r
    250-8BITMIME\r
    250-BINARYMIME\r
    250-CHUNKING\r
    250 SMTPUTF8\r

    """

    static let fastmailGreeting = "220 smtp.fastmail.com ESMTP ready\r\n"
    static let fastmailEHLO = """
    250-smtp.fastmail.com\r
    250-PIPELINING\r
    250-SIZE 71000000\r
    250-ENHANCEDSTATUSCODES\r
    250-8BITMIME\r
    250-AUTH PLAIN LOGIN\r
    250 AUTH=PLAIN LOGIN\r

    """

    static let yahooGreeting = "220 smtp.mail.yahoo.com ESMTP ready\r\n"
    static let yahooEHLO = """
    250-hermes--production-gq1-5c5d8c8fd8-7xk2p Hello localhost [203.0.113.42])\r
    250-PIPELINING\r
    250-ENHANCEDSTATUSCODES\r
    250-8BITMIME\r
    250-SIZE 41697280\r
    250 AUTH PLAIN LOGIN XOAUTH2 OAUTHBEARER\r

    """

    private func makeClient(_ steps: [ScriptedTransport.Step], host: String = "smtp.gmail.com", port: Int = 465, security: ConnectionSecurity = .tls, logger: (@Sendable (String) -> Void)? = nil) -> (SMTPClient, ScriptedTransport) {
        let script = ScriptedTransport(steps)
        let client = SMTPClient(host: host, port: port, security: security, transport: GuardedTransport(script), localHostname: "ada-iphone.local", timeout: 5, logger: logger)
        return (client, script)
    }

    private func lines(_ transcript: String) -> [String] {
        transcript.components(separatedBy: "\r\n")
    }

    // MARK: Gmail (465, implicit TLS)

    func testGmailImplicitTLSPasswordSend() async throws {
        let message = sampleMessage(from: "ada@gmail.com", to: "grace@example.org")
        let size = SMTPDataEncoder.encodedLength(of: message)
        let (client, script) = makeClient([
            .send(Self.gmailGreeting),
            .expect("EHLO ada-iphone.local", reply: Self.gmailEHLO),
            .expect("AUTH PLAIN AGFkYUBnbWFpbC5jb20AYWJjZCBlZmdoIGlqa2wgbW5vcA==", reply: "235 2.7.0 Accepted\r\n"),
            .expect("MAIL FROM:<ada@gmail.com> SIZE=\(size)", reply: "250 2.1.0 OK \(Self.gmailID)\r\n"),
            .expect("RCPT TO:<grace@example.org>", reply: "250 2.1.5 OK \(Self.gmailID)\r\n"),
            .expect("DATA", reply: "354  Go ahead \(Self.gmailID)\r\n"),
            .expect(".", reply: "250 2.0.0 OK  1760961234 \(Self.gmailID)\r\n"),
            .expect("QUIT", reply: "221 2.0.0 closing connection \(Self.gmailID)\r\n"),
        ])
        try await client.connect()
        XCTAssertTrue(script.openedTLS)
        XCTAssertFalse(script.didStartTLS)
        let extensions = await client.extensions
        XCTAssertEqual(extensions["SIZE"], "35882577")
        let mechanisms = await client.authMechanisms
        XCTAssertEqual(mechanisms, ["LOGIN", "PLAIN", "XOAUTH2", "PLAIN-CLIENTTOKEN", "OAUTHBEARER", "XOAUTH"])
        let limit = await client.maxMessageSize
        XCTAssertEqual(limit, 35_882_577)

        try await client.login(username: "ada@gmail.com", password: "abcd efgh ijkl mnop")
        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)

        let result = try await client.send(from: "ada@gmail.com", recipients: ["grace@example.org"], message: message)
        XCTAssertEqual(result.accepted, ["grace@example.org"])
        XCTAssertTrue(result.rejected.isEmpty)
        XCTAssertFalse(result.isPartial)
        XCTAssertEqual(result.finalReplies.first?.code, 250)
        await client.quit()
        let connected = await client.isConnected
        XCTAssertFalse(connected)

        let transcript = script.transcript
        // Gmail offers PIPELINING: MAIL FROM and RCPT TO went in one write.
        XCTAssertTrue(script.written.contains { $0.hasPrefix("MAIL FROM:") && $0.contains("\r\nRCPT TO:<grace@example.org>\r\n") })
        XCTAssertFalse(transcript.contains("BODY=8BITMIME"), "7-bit message must not claim 8BITMIME")
        XCTAssertFalse(transcript.contains("SMTPUTF8"))
        XCTAssertTrue(transcript.contains("Subject: Lunch on Thursday?\r\n"))
        XCTAssertTrue(transcript.hasSuffix("--ink-boundary-1--\r\n.\r\nQUIT\r\n"))
    }

    func testGmailBadCredentials() async throws {
        let (client, script) = makeClient([
            .send(Self.gmailGreeting),
            .expect("EHLO", reply: Self.gmailEHLO),
            .expect("AUTH PLAIN", reply: "535-5.7.8 Username and Password not accepted. For more information, go to\r\n535 5.7.8  https://support.google.com/mail/?p=BadCredentials \(Self.gmailID)\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada@gmail.com", password: "wrong") }
        XCTAssertEqual(error, .authenticationFailed("Username and Password not accepted. For more information, go to https://support.google.com/mail/?p=BadCredentials"))
        XCTAssertTrue(script.transcript.contains("AUTH PLAIN "))
        let authenticated = await client.isAuthenticated
        XCTAssertFalse(authenticated)
    }

    func testGmailApplicationSpecificPasswordRequired() async throws {
        let (client, _) = makeClient([
            .send(Self.gmailGreeting),
            .expect("EHLO", reply: Self.gmailEHLO),
            .expect("AUTH PLAIN", reply: "534-5.7.9 Application-specific password required. For more information, go to\r\n534 5.7.9  https://support.google.com/mail/?p=InvalidSecondFactor \(Self.gmailID)\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada@gmail.com", password: "account-password") }
        guard case .authenticationFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.hasPrefix("Application-specific password required."))
    }

    func testGmailXOAUTH2Success() async throws {
        let token = "ya29.a0AfB_byC-EXAMPLE-TOKEN"
        let (client, script) = makeClient([
            .send(Self.gmailGreeting),
            .expect("EHLO", reply: Self.gmailEHLO),
            .expect("AUTH XOAUTH2 \(SASL.xoauth2(username: "ada@gmail.com", accessToken: token))", reply: "235 2.7.0 Accepted\r\n"),
        ])
        try await client.connect()
        try await client.authenticateXOAUTH2(username: "ada@gmail.com", accessToken: token)
        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)
        XCTAssertFalse(script.transcript.contains("OAUTHBEARER"))
    }

    func testGmailXOAUTH2ErrorChallengeRoundTrip() async throws {
        let logs = LogCollector()
        let (client, script) = makeClient([
            .send(Self.gmailGreeting),
            .expect("EHLO", reply: Self.gmailEHLO),
            .expect("AUTH XOAUTH2", reply: "334 eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ==\r\n"),
            .expect("", reply: "535-5.7.8 Username and Password not accepted. For more information, go to\r\n535 5.7.8  https://support.google.com/mail/?p=BadCredentials \(Self.gmailID)\r\n"),
            .expect("QUIT", reply: "221 2.0.0 closing connection\r\n"),
        ], logger: logs.logger)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.authenticateXOAUTH2(username: "ada@gmail.com", accessToken: "ya29.expired") }
        guard case .authenticationFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("Username and Password not accepted"))
        XCTAssertTrue(text.contains("Sign in again"))
        // The client answered the challenge with an empty line.
        XCTAssertTrue(script.transcript.contains("\r\n\r\n"))
        // The connection stays usable after a failed AUTH.
        await client.quit()
        XCTAssertTrue(script.transcript.hasSuffix("QUIT\r\n"))
        XCTAssertFalse(logs.lines.joined().contains("ya29.expired"))
        XCTAssertFalse(logs.lines.joined().contains(SASL.xoauth2(username: "ada@gmail.com", accessToken: "ya29.expired")))
    }

    func testGmailMessageTooLargeAtEndOfData() async throws {
        let (client, _) = makeClient([
            .send(Self.gmailGreeting),
            .expect("EHLO", reply: Self.gmailEHLO),
            .expect("AUTH PLAIN", reply: "235 2.7.0 Accepted\r\n"),
            .expect("MAIL FROM", reply: "250 2.1.0 OK\r\n"),
            .expect("RCPT TO", reply: "250 2.1.5 OK\r\n"),
            .expect("DATA", reply: "354  Go ahead\r\n"),
            .expect(".", reply: "552-5.3.4 Your message exceeded Google's message size limits. For more information, visit\r\n552 5.3.4  https://support.google.com/mail/?p=MaxSizeError \(Self.gmailID)\r\n"),
        ])
        try await client.connect()
        try await client.login(username: "ada@gmail.com", password: "pw")
        let error = await assertThrowsMailError { try await client.send(from: "ada@gmail.com", recipients: ["grace@example.org"], message: sampleMessage()) }
        guard case .sendFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("too large"))
        XCTAssertTrue(text.contains("exceeded Google's message size limits"), text)
        XCTAssertFalse(text.contains("MB"), "sizes are only quoted when Ink knows the message is over the limit")
    }

    func testGmailDailyLimitAtMailFrom() async throws {
        let (client, script) = makeClient([
            .send(Self.gmailGreeting),
            .expect("EHLO", reply: Self.gmailEHLO),
            .expect("AUTH PLAIN", reply: "235 2.7.0 Accepted\r\n"),
            .expect("MAIL FROM", reply: "550-5.4.5 Daily user sending limit exceeded. For more information on Gmail\r\n550-5.4.5 sending limits go to\r\n550 5.4.5  https://support.google.com/a/answer/166852 \(Self.gmailID)\r\n"),
            .expect("RCPT TO", reply: "503 5.5.1 MAIL first. \(Self.gmailID)\r\n"),
            .expect("RSET", reply: "250 2.1.5 Flushed \(Self.gmailID)\r\n"),
        ])
        try await client.connect()
        try await client.login(username: "ada@gmail.com", password: "pw")
        let error = await assertThrowsMailError { try await client.send(from: "ada@gmail.com", recipients: ["grace@example.org"], message: sampleMessage()) }
        XCTAssertEqual(error, .sendFailed("Daily user sending limit exceeded. For more information on Gmail sending limits go to https://support.google.com/a/answer/166852"))
        XCTAssertFalse(script.transcript.contains("DATA\r\n"))
        XCTAssertTrue(script.transcript.hasSuffix("RSET\r\n"))
    }

    // MARK: iCloud (587, STARTTLS)

    func testICloudStartTLSThenPlain() async throws {
        let (client, script) = makeClient([
            .send(Self.icloudGreeting),
            .expect("EHLO ada-iphone.local", reply: Self.icloudEHLOPlain),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n"),
            .expect("EHLO ada-iphone.local", reply: Self.icloudEHLOTLS),
            .expect("AUTH PLAIN", reply: "235 2.7.0 Authentication successful\r\n"),
            .expect("MAIL FROM:<ada@icloud.com>", reply: "250 2.1.0 Sender OK\r\n"),
            .expect("RCPT TO:<grace@example.org>", reply: "250 2.1.5 Recipient OK\r\n"),
            .expect("RCPT TO:<alan@example.net>", reply: "250 2.1.5 Recipient OK\r\n"),
            .expect("DATA", reply: "354 Start mail input; end with <CRLF>.<CRLF>\r\n"),
            .expect(".", reply: "250 2.0.0 Ok: queued as 4C1D2F3A0B\r\n"),
            .expect("QUIT", reply: "221 2.0.0 Bye\r\n"),
        ], host: "smtp.mail.me.com", port: 587, security: .startTLS)
        try await client.connect()
        XCTAssertFalse(script.openedTLS)
        XCTAssertTrue(script.didStartTLS)
        let extensions = await client.extensions
        XCTAssertNil(extensions["STARTTLS"], "extensions must come from the EHLO after TLS")
        XCTAssertEqual(extensions["AUTH"], "PLAIN LOGIN ATOKEN WSTOKEN WETOKEN")

        try await client.login(username: "ada@icloud.com", password: "abcd-efgh-ijkl-mnop")
        try await client.send(from: "ada@icloud.com", recipients: ["grace@example.org", "Alan@Example.net", "grace@example.org", "<alan@example.net>"], message: sampleMessage(from: "ada@icloud.com"))
        await client.quit()
        let rcpts = lines(script.transcript).filter { $0.hasPrefix("RCPT TO:") }
        XCTAssertEqual(rcpts, ["RCPT TO:<grace@example.org>", "RCPT TO:<Alan@Example.net>"], "duplicates are dropped case-insensitively")
        let ehloCount = lines(script.transcript).filter { $0.hasPrefix("EHLO") }.count
        XCTAssertEqual(ehloCount, 2)
    }

    func testICloudWrongAppPassword() async throws {
        let (client, _) = makeClient([
            .send(Self.icloudGreeting),
            .expect("EHLO", reply: Self.icloudEHLOPlain),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n"),
            .expect("EHLO", reply: Self.icloudEHLOTLS),
            .expect("AUTH PLAIN", reply: "535 5.7.8 Authentication credentials invalid\r\n"),
        ], host: "smtp.mail.me.com", port: 587, security: .startTLS)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada@icloud.com", password: "my-apple-id-password") }
        XCTAssertEqual(error, .authenticationFailed("Authentication credentials invalid"))
    }

    func testICloudSenderNotOwned() async throws {
        let (client, _) = makeClient([
            .send(Self.icloudGreeting),
            .expect("EHLO", reply: Self.icloudEHLOPlain),
            .expect("STARTTLS", reply: "220 2.0.0 Ready to start TLS\r\n"),
            .expect("EHLO", reply: Self.icloudEHLOTLS),
            .expect("AUTH PLAIN", reply: "235 2.7.0 Authentication successful\r\n"),
            .expect("MAIL FROM", reply: "550 5.7.0 From address is not one of your addresses\r\n"),
            .expect("RCPT TO", reply: "503 5.5.1 Bad sequence of commands\r\n"),
            .expect("RSET", reply: "250 2.0.0 Ok\r\n"),
        ], host: "smtp.mail.me.com", port: 587, security: .startTLS)
        try await client.connect()
        try await client.login(username: "ada@icloud.com", password: "pw")
        let error = await assertThrowsMailError { try await client.send(from: "ceo@bigcorp.example", recipients: ["grace@example.org"], message: sampleMessage()) }
        XCTAssertEqual(error, .sendFailed("From address is not one of your addresses"))
    }

    // MARK: Outlook (587, STARTTLS, OAuth only)

    func testOutlookStartTLSXOAUTH2Send() async throws {
        let token = "EwBwA8l6BAAUbDba3x2OMJElkF7gJ4z/VbCPEz0AAZ8XfQKr"
        let message = sampleMessage(from: "ada@outlook.com")
        let (client, script) = makeClient([
            .send(Self.outlookGreeting),
            .expect("EHLO", reply: Self.outlookEHLOPlain),
            .expect("STARTTLS", reply: "220 2.0.0 SMTP server ready\r\n"),
            .expect("EHLO", reply: Self.outlookEHLOTLS),
            .expect("AUTH XOAUTH2 \(SASL.xoauth2(username: "ada@outlook.com", accessToken: token))", reply: "235 2.7.0 Authentication successful\r\n"),
            .expect("MAIL FROM:<ada@outlook.com> SIZE=\(SMTPDataEncoder.encodedLength(of: message))", reply: "250 2.1.0 Sender OK\r\n"),
            .expect("RCPT TO:<grace@example.org>", reply: "250 2.1.5 Recipient OK\r\n"),
            .expect("DATA", reply: "354 Start mail input; end with <CRLF>.<CRLF>\r\n"),
            .expect(".", reply: "250 2.0.0 OK <6F9619FF-8B86-D011-B42D-00C04FC964FF@example.com> [Hostname=PH0PR07MB8510.namprd07.prod.outlook.com]\r\n"),
            .expect("QUIT", reply: "221 2.0.0 Service closing transmission channel\r\n"),
        ], host: "smtp-mail.outlook.com", port: 587, security: .startTLS)
        try await client.connect()
        try await client.authenticateXOAUTH2(username: "ada@outlook.com", accessToken: token)
        let result = try await client.send(from: "ada@outlook.com", recipients: ["grace@example.org"], message: message)
        XCTAssertEqual(result.accepted, ["grace@example.org"])
        await client.quit()
        XCTAssertTrue(script.didStartTLS)
    }

    func testOutlookBasicAuthDisabledViaLOGIN() async throws {
        let (client, script) = makeClient([
            .send(Self.outlookGreeting),
            .expect("EHLO", reply: Self.outlookEHLOPlain),
            .expect("STARTTLS", reply: "220 2.0.0 SMTP server ready\r\n"),
            .expect("EHLO", reply: Self.outlookEHLOTLS),
            .expect("AUTH LOGIN", reply: "334 VXNlcm5hbWU6\r\n"),
            .expect(SASL.login("ada@outlook.com"), reply: "334 UGFzc3dvcmQ6\r\n"),
            .expect(SASL.login("hunter2"), reply: "535 5.7.139 Authentication unsuccessful, basic authentication is disabled. [PH8PR07CA0012.namprd07.prod.outlook.com 2026-10-20T14:03:12.345Z 08DEF0A1B2C3D4E5]\r\n"),
        ], host: "smtp-mail.outlook.com", port: 587, security: .startTLS)
        try await client.connect()
        // Outlook offers LOGIN but not PLAIN.
        let error = await assertThrowsMailError { try await client.login(username: "ada@outlook.com", password: "hunter2") }
        XCTAssertEqual(error, .authenticationFailed("Authentication unsuccessful, basic authentication is disabled."))
        XCTAssertFalse(script.transcript.contains("AUTH PLAIN"))
    }

    func testOutlookXOAUTH2Rejected() async throws {
        let (client, _) = makeClient([
            .send(Self.outlookGreeting),
            .expect("EHLO", reply: Self.outlookEHLOPlain),
            .expect("STARTTLS", reply: "220 2.0.0 SMTP server ready\r\n"),
            .expect("EHLO", reply: Self.outlookEHLOTLS),
            .expect("AUTH XOAUTH2", reply: "535 5.7.3 Authentication unsuccessful [PH8PR07CA0012.namprd07.prod.outlook.com 2026-10-20T14:03:12.345Z 08DEF0A1B2C3D4E5]\r\n"),
        ], host: "smtp-mail.outlook.com", port: 587, security: .startTLS)
        try await client.connect()
        let error = await assertThrowsMailError { try await client.authenticateXOAUTH2(username: "ada@outlook.com", accessToken: "bad") }
        XCTAssertEqual(error, .authenticationFailed("Authentication unsuccessful"))
    }

    func testOutlookSendAsDeniedAtEndOfData() async throws {
        let (client, _) = makeClient([
            .send(Self.outlookGreeting),
            .expect("EHLO", reply: Self.outlookEHLOPlain),
            .expect("STARTTLS", reply: "220 2.0.0 SMTP server ready\r\n"),
            .expect("EHLO", reply: Self.outlookEHLOTLS),
            .expect("AUTH XOAUTH2", reply: "235 2.7.0 Authentication successful\r\n"),
            .expect("MAIL FROM", reply: "250 2.1.0 Sender OK\r\n"),
            .expect("RCPT TO", reply: "250 2.1.5 Recipient OK\r\n"),
            .expect("DATA", reply: "354 Start mail input; end with <CRLF>.<CRLF>\r\n"),
            .expect(".", reply: "554 5.2.252 SendAsDenied; ada@outlook.com not allowed to send as other@example.com; STOREDRV.Submission.Exception:SendAsDeniedException.MapiExceptionSendAsDenied\r\n"),
        ], host: "smtp-mail.outlook.com", port: 587, security: .startTLS)
        try await client.connect()
        try await client.authenticateXOAUTH2(username: "ada@outlook.com", accessToken: "tok")
        let error = await assertThrowsMailError { try await client.send(from: "other@example.com", recipients: ["grace@example.org"], message: sampleMessage()) }
        guard case .sendFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.hasPrefix("SendAsDenied; ada@outlook.com not allowed to send as other@example.com"))
    }

    // MARK: Fastmail (465)

    func testFastmailOldStyleAuthAndPartialRecipientFailure() async throws {
        let logs = LogCollector()
        let (client, script) = makeClient([
            .send(Self.fastmailGreeting),
            .expect("EHLO", reply: Self.fastmailEHLO),
            .expect("AUTH PLAIN", reply: "235 2.0.0 OK\r\n"),
            .expect("MAIL FROM:<ada@fastmail.com>", reply: "250 2.1.0 Ok\r\n"),
            .expect("RCPT TO:<grace@example.org>", reply: "250 2.1.5 Ok\r\n"),
            .expect("RCPT TO:<nobody@example.org>", reply: "550 5.1.1 <nobody@example.org>: Recipient address rejected: User unknown in virtual mailbox table\r\n"),
            .expect("RCPT TO:<alan@example.net>", reply: "250 2.1.5 Ok\r\n"),
            .expect("DATA", reply: "354 End data with <CR><LF>.<CR><LF>\r\n"),
            .expect(".", reply: "250 2.0.0 Ok: queued as 4Xk2Qp1Lz9z9sQ\r\n"),
        ], host: "smtp.fastmail.com", logger: logs.logger)
        try await client.connect()
        let mechanisms = await client.authMechanisms
        XCTAssertEqual(mechanisms, ["PLAIN", "LOGIN"])
        try await client.login(username: "ada@fastmail.com", password: "app-password-1234")
        let result = try await client.send(from: "ada@fastmail.com", recipients: ["grace@example.org", "nobody@example.org", "alan@example.net"], message: sampleMessage(from: "ada@fastmail.com"))
        XCTAssertEqual(result.accepted, ["grace@example.org", "alan@example.net"])
        XCTAssertEqual(result.rejected.map(\.address), ["nobody@example.org"])
        XCTAssertEqual(result.rejected.first?.reply.code, 550)
        XCTAssertTrue(result.isPartial)
        XCTAssertEqual(result.rejectionSummary, "Not delivered to nobody@example.org: <nobody@example.org>: Recipient address rejected: User unknown in virtual mailbox table")
        let last = await client.lastSendResult
        XCTAssertEqual(last, result)
        XCTAssertTrue(script.transcript.contains("DATA\r\n"))
        XCTAssertFalse(logs.lines.contains { $0.contains(SASL.plain(username: "ada@fastmail.com", password: "app-password-1234")) })
        XCTAssertTrue(logs.lines.contains("C: AUTH PLAIN [redacted]"))
        XCTAssertFalse(logs.lines.contains { $0.contains("Lunch on Thursday") }, "message contents are not logged")
    }

    func testFastmailAllRecipientsRejected() async throws {
        let (client, script) = makeClient([
            .send(Self.fastmailGreeting),
            .expect("EHLO", reply: Self.fastmailEHLO),
            .expect("AUTH PLAIN", reply: "235 2.0.0 OK\r\n"),
            .expect("MAIL FROM", reply: "250 2.1.0 Ok\r\n"),
            .expect("RCPT TO:<nobody@example.org>", reply: "550 5.1.1 <nobody@example.org>: Recipient address rejected: User unknown\r\n"),
            .expect("RCPT TO:<blocked@example.com>", reply: "554 5.7.1 <blocked@example.com>: Relay access denied\r\n"),
            .expect("RSET", reply: "250 2.0.0 Ok\r\n"),
        ], host: "smtp.fastmail.com")
        try await client.connect()
        try await client.login(username: "ada@fastmail.com", password: "pw")
        let error = await assertThrowsMailError { try await client.send(from: "ada@fastmail.com", recipients: ["nobody@example.org", "blocked@example.com"], message: sampleMessage()) }
        XCTAssertEqual(error, .sendFailed("nobody@example.org: <nobody@example.org>: Recipient address rejected: User unknown; blocked@example.com: <blocked@example.com>: Relay access denied"))
        XCTAssertFalse(script.transcript.contains("DATA"))
    }

    // MARK: Yahoo (465)

    func testYahooTooManyBadAttempts() async throws {
        let (client, _) = makeClient([
            .send(Self.yahooGreeting),
            .expect("EHLO", reply: Self.yahooEHLO),
            .expect("AUTH PLAIN", reply: "535 5.7.0 (#AUTH005) Too many bad auth attempts.\r\n"),
        ], host: "smtp.mail.yahoo.com")
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada@yahoo.com", password: "pw") }
        XCTAssertEqual(error, .authenticationFailed("(#AUTH005) Too many bad auth attempts."))
    }

    func testYahooPolicyRejectionAndReuseAfterwards() async throws {
        let (client, _) = makeClient([
            .send(Self.yahooGreeting),
            .expect("EHLO", reply: Self.yahooEHLO),
            .expect("AUTH PLAIN", reply: "235 2.0.0 OK\r\n"),
            .expect("MAIL FROM", reply: "250 2.1.0 Sender <ada@yahoo.com> OK\r\n"),
            .expect("RCPT TO", reply: "250 2.1.5 Recipient <grace@example.org> OK\r\n"),
            .expect("DATA", reply: "354 Ok Send data ending with <CRLF>.<CRLF>\r\n"),
            .expect(".", reply: "554 5.7.9 Message not accepted for policy reasons.  See https://senders.yahooinc.com/error-codes\r\n"),
            .expect("MAIL FROM", reply: "250 2.1.0 Sender <ada@yahoo.com> OK\r\n"),
            .expect("RCPT TO", reply: "250 2.1.5 Recipient <grace@example.org> OK\r\n"),
            .expect("DATA", reply: "354 Ok Send data ending with <CRLF>.<CRLF>\r\n"),
            .expect(".", reply: "250 OK , completed\r\n"),
        ], host: "smtp.mail.yahoo.com")
        try await client.connect()
        try await client.login(username: "ada@yahoo.com", password: "pw")
        let error = await assertThrowsMailError { try await client.send(from: "ada@yahoo.com", recipients: ["grace@example.org"], message: sampleMessage()) }
        XCTAssertEqual(error, .sendFailed("Message not accepted for policy reasons. See https://senders.yahooinc.com/error-codes"))
        let second = try await client.send(from: "ada@yahoo.com", recipients: ["grace@example.org"], message: sampleMessage(subject: "Second try"))
        XCTAssertEqual(second.accepted.count, 1)
    }

    func testYahooOAuthBearerWhenXOAUTH2Missing() async throws {
        let ehlo = "250-hermes Hello\r\n250 AUTH PLAIN LOGIN OAUTHBEARER\r\n"
        let token = "yahoo-token"
        let (client, script) = makeClient([
            .send(Self.yahooGreeting),
            .expect("EHLO", reply: ehlo),
            .expect("AUTH OAUTHBEARER \(SASL.oauthBearer(username: "ada@yahoo.com", accessToken: token, host: "smtp.mail.yahoo.com", port: 465))", reply: "334 eyJzdGF0dXMiOiI0MDEiLCJzY2hlbWVzIjoiYmVhcmVyIn0=\r\n"),
            .expect("AQ==", reply: "535 5.7.0 (#AUTH005) Too many bad auth attempts.\r\n"),
        ], host: "smtp.mail.yahoo.com")
        try await client.connect()
        let error = await assertThrowsMailError { try await client.authenticateXOAUTH2(username: "ada@yahoo.com", accessToken: token) }
        guard case .authenticationFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("expired"))
        XCTAssertTrue(script.transcript.contains("AQ==\r\n"))
    }
}
