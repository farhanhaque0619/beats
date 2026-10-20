import XCTest
import InkModel
@testable import InkSMTP

// SMTPClient against real servers over plain TCP. Plain `swift test` skips these; they read the
// same INK_IT_* variables as the InkSync integration tests (see Scripts/integration-servers.sh):
//
//   INK_IT_HOST=127.0.0.1 INK_IT_GREENMAIL_SMTP_PORT=3025 INK_IT_DOVECOT_SMTP_PORT=31587 \
//   swift test --filter SMTPClientIntegrationTests
//
// The socket transport can't do TLS, so the STARTTLS scenarios check everything up to the
// handshake.
final class SMTPClientIntegrationTests: XCTestCase {
    private func port(_ name: String) throws -> (host: String, port: Int) {
        let env = ProcessInfo.processInfo.environment
        guard let port = env[name].flatMap(Int.init) else { throw XCTSkip("Set \(name) to run against a real server.") }
        return (env["INK_IT_HOST"] ?? "127.0.0.1", port)
    }

    /// Dovecot's submission service offers STARTTLS; its 220 leaves nothing buffered, so the
    /// client proceeds to the handshake (which this plaintext transport can't do).
    func testDovecotSubmissionStartTLSReachesTheHandshake() async throws {
        let server = try port("INK_IT_DOVECOT_SMTP_PORT")
        let log = SMTPLogLines()
        let client = SMTPClient(host: server.host, port: server.port, security: .startTLS, transport: SocketTransport(),
                                localHostname: "ink-test.local", timeout: 10, logger: log.append)
        let error = await assertThrowsMailError {
            try await client.connect()
            try await client.login(username: "ada@example.org", password: "pass")
        }
        XCTAssertEqual(error, .tlsFailed("The test socket transport is plaintext only."), log.text)
        XCTAssertTrue(log.text.contains("C: STARTTLS"), log.text)
        XCTAssertFalse(log.text.contains("C: AUTH"), log.text)
    }

    /// GreenMail offers no STARTTLS: a `.startTLS` account fails before AUTH.
    func testGreenMailWithoutStartTLSIsRefused() async throws {
        let server = try port("INK_IT_GREENMAIL_SMTP_PORT")
        let log = SMTPLogLines()
        let client = SMTPClient(host: server.host, port: server.port, security: .startTLS, transport: SocketTransport(),
                                localHostname: "ink-test.local", timeout: 10, logger: log.append)
        let error = await assertThrowsMailError {
            try await client.connect()
            try await client.login(username: "ada@example.com", password: "secret")
        }
        guard case .tlsFailed? = error else { return XCTFail("\(String(describing: error))\n\(log.text)") }
        XCTAssertFalse(log.text.contains("C: AUTH"), log.text)
    }

    /// The whole plaintext flow on a real server: EHLO, AUTH PLAIN, MAIL/RCPT/DATA, QUIT.
    func testGreenMailSend() async throws {
        let server = try port("INK_IT_GREENMAIL_SMTP_PORT")
        let client = SMTPClient(host: server.host, port: server.port, security: .none, transport: SocketTransport(),
                                localHostname: "ink-test.local", timeout: 10)
        try await client.connect()
        try await client.login(username: "ada@example.com", password: "secret")
        let result = try await client.send(from: "ada@example.com", recipients: ["grace@example.com"],
                                           message: sampleMessage(from: "ada@example.com", to: "grace@example.com"))
        XCTAssertEqual(result.accepted, ["grace@example.com"])
        XCTAssertFalse(result.isPartial)
        await client.quit()
    }
}

/// Collects SMTP log lines.
final class SMTPLogLines: @unchecked Sendable {
    private let lock = NSLock()
    private var lines: [String] = []
    var text: String { lock.withLock { lines.joined(separator: "\n") } }
    var append: @Sendable (String) -> Void { { [weak self] line in self?.add(line) } }
    private func add(_ line: String) { lock.withLock { lines.append(line) } }
}
