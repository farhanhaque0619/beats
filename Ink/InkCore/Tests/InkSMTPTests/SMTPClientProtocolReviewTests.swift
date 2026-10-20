import XCTest
import InkModel
@testable import InkSMTP

/// RFC 4954 §4: "If use of the initial response argument would cause the AUTH command to
/// exceed [the 512-octet command line limit], the client MUST NOT use the initial response
/// parameter". Real OAuth access tokens (Microsoft's run to 2 KB and more) always do, which is
/// why RESEARCH §3.7 makes the two-step form the default for them.
final class SMTPClientProtocolReviewTests: XCTestCase {
    private let outlookEHLO = "250-PH8PR07CA0012.outlook.office365.com Hello [203.0.113.42]\r\n250-SIZE 157286400\r\n250-PIPELINING\r\n250-8BITMIME\r\n250-AUTH LOGIN XOAUTH2\r\n250-ENHANCEDSTATUSCODES\r\n250 SMTPUTF8\r\n"

    private func scripted(_ steps: [ScriptedTransport.Step], logger: (@Sendable (String) -> Void)? = nil) -> (SMTPClient, ScriptedTransport) {
        let script = ScriptedTransport(steps)
        let client = SMTPClient(host: "smtp-mail.outlook.com", port: 465, security: .tls, transport: GuardedTransport(script), timeout: 5, logger: logger)
        return (client, script)
    }

    /// Every AUTH command line the client wrote, CRLF included, is within SMTP's 512-octet
    /// command limit. (SASL response lines after a `334` may be up to 12288 octets, RFC 4954 §4.)
    private func assertLinesWithinLimit(_ transcript: String, file: StaticString = #filePath, line: UInt = #line) {
        var current: [UInt8] = []
        var longest = 0
        for byte in transcript.utf8 {
            current.append(byte)
            if byte == 0x0A {
                if current.starts(with: Array("AUTH ".utf8)) { longest = max(longest, current.count) }
                current = []
            }
        }
        XCTAssertLessThanOrEqual(longest, 512, "an AUTH command line exceeded 512 octets", file: file, line: line)
    }

    private static let longToken = "EwBwA8l6BAAUbDba3x2OMJElkF7gJ4z" + String(repeating: "Vb_CPEz0AAZ8XfQKr-", count: 90)

    func testLongOAuthTokenIsSentAfterTheChallengeNotOnTheAUTHLine() async throws {
        let payload = SASL.xoauth2(username: "ada@outlook.com", accessToken: Self.longToken)
        XCTAssertGreaterThan(payload.utf8.count, 512)
        let logs = LogCollector()
        let (client, script) = scripted([
            .send("220 PH8PR07CA0012.outlook.office365.com Microsoft ESMTP MAIL Service ready\r\n"),
            .expect("EHLO", reply: outlookEHLO),
            .expect("AUTH XOAUTH2", reply: "334 \r\n"),
            .expect(payload, reply: "235 2.7.0 Authentication successful\r\n"),
        ], logger: logs.logger)
        try await client.connect()
        try await client.authenticateXOAUTH2(username: "ada@outlook.com", accessToken: Self.longToken)
        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)
        XCTAssertTrue(script.transcript.contains("AUTH XOAUTH2\r\n"))
        assertLinesWithinLimit(script.transcript)
        XCTAssertFalse(logs.lines.joined().contains(Self.longToken))
        XCTAssertFalse(logs.lines.joined().contains(payload))
    }

    func testLongOAuthTokenRejectedWithErrorChallengeAfterTheResponse() async throws {
        let payload = SASL.xoauth2(username: "ada@gmail.com", accessToken: Self.longToken)
        let (client, script) = scripted([
            .send("220 smtp.gmail.com ESMTP - gsmtp\r\n"),
            .expect("EHLO", reply: "250-smtp.gmail.com at your service\r\n250 AUTH LOGIN PLAIN XOAUTH2\r\n"),
            .expect("AUTH XOAUTH2", reply: "334 \r\n"),
            .expect(payload, reply: "334 eyJzdGF0dXMiOiI0MDEiLCJzY2hlbWVzIjoiYmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ==\r\n"),
            .expect("", reply: "535 5.7.8 Username and Password not accepted.\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.authenticateXOAUTH2(username: "ada@gmail.com", accessToken: Self.longToken) }
        guard case .authenticationFailed(let text)? = error else { return XCTFail("\(String(describing: error))") }
        XCTAssertTrue(text.contains("Username and Password not accepted"))
        XCTAssertTrue(text.contains("Sign in again"))
        assertLinesWithinLimit(script.transcript)
    }

    func testLongPasswordUsesTheTwoStepPlainForm() async throws {
        let password = String(repeating: "correct horse battery staple ", count: 20)
        let payload = SASL.plain(username: "ada@example.org", password: password)
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 AUTH PLAIN LOGIN\r\n"),
            .expect("AUTH PLAIN", reply: "334 \r\n"),
            .expect(payload, reply: "235 2.7.0 Authentication successful\r\n"),
        ])
        try await client.connect()
        try await client.login(username: "ada@example.org", password: password)
        let authenticated = await client.isAuthenticated
        XCTAssertTrue(authenticated)
        XCTAssertTrue(script.transcript.contains("AUTH PLAIN\r\n"))
        assertLinesWithinLimit(script.transcript)
    }

    /// A server that keeps challenging after the credentials must not be left mid-exchange:
    /// the client cancels with `*` so the next command isn't taken as a SASL response.
    func testUnexpectedSecondChallengeIsCancelled() async throws {
        let (client, script) = scripted([
            .send("220 mail.example.org ESMTP\r\n"),
            .expect("EHLO", reply: "250-mail.example.org\r\n250 AUTH PLAIN\r\n"),
            .expect("AUTH PLAIN", reply: "334 \r\n"),
            .expect(SASL.plain(username: "ada", password: "pw"), reply: "334 \r\n"),
            .expect("*", reply: "501 5.7.0 Authentication cancelled\r\n"),
        ])
        try await client.connect()
        let error = await assertThrowsMailError { try await client.login(username: "ada", password: "pw") }
        XCTAssertNotNil(error)
        XCTAssertTrue(script.transcript.hasSuffix("*\r\n"))
    }
}
