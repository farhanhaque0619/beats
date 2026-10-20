import XCTest
import InkModel
@testable import InkIMAP

// IMAPClient against real servers over plain TCP. Plain `swift test` skips these; they read the
// same INK_IT_* variables as the InkSync integration tests (see Scripts/integration-servers.sh):
//
//   INK_IT_HOST=127.0.0.1 INK_IT_GREENMAIL_IMAP_PORT=3143 INK_IT_DOVECOT_IMAP_PORT=31143 \
//   INK_IT_DOVECOT_PASSWORD=pass swift test --filter IMAPClientIntegrationTests
//
// The socket transport can't do TLS, so the STARTTLS scenarios check everything up to the
// handshake: that real servers' STARTTLS replies don't trip the injection check, and that a
// server without STARTTLS is refused before any credentials are sent.
final class IMAPClientIntegrationTests: XCTestCase {
    private struct Server {
        var host: String
        var port: Int
        var password: String
    }

    private func greenMail() throws -> Server {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["INK_IT_GREENMAIL_IMAP_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Set INK_IT_GREENMAIL_IMAP_PORT to run against GreenMail.")
        }
        return Server(host: env["INK_IT_HOST"] ?? "127.0.0.1", port: port, password: "secret")
    }

    private func dovecot() throws -> Server {
        let env = ProcessInfo.processInfo.environment
        guard let port = env["INK_IT_DOVECOT_IMAP_PORT"].flatMap(Int.init) else {
            throw XCTSkip("Set INK_IT_DOVECOT_IMAP_PORT to run against Dovecot.")
        }
        return Server(host: env["INK_IT_HOST"] ?? "127.0.0.1", port: port, password: env["INK_IT_DOVECOT_PASSWORD"] ?? "pass")
    }

    private func uniqueUser(_ domain: String) -> String {
        "fp-\(UUID().uuidString.prefix(8).lowercased())@\(domain)"
    }

    private func message(subject: String, text: String) -> Data {
        let lines = [
            "From: Ada <ada@example.org>",
            "To: Grace <grace@example.org>",
            "Subject: \(subject)",
            "Message-ID: <\(UUID().uuidString)@example.org>",
            "MIME-Version: 1.0",
            "Content-Type: multipart/alternative; boundary=\"b1\"",
            "",
            "--b1",
            "Content-Type: text/plain; charset=utf-8",
            "",
            text,
            "--b1",
            "Content-Type: text/html; charset=utf-8",
            "",
            "<p>\(text)</p>",
            "--b1--",
            "",
        ]
        return Data(lines.joined(separator: "\r\n").utf8)
    }

    /// GreenMail sends `BODY[1]<0>{n}` with no space before the literal; the section must
    /// still arrive. Also IDLE's timeout path and keyword STORE on a real server.
    func testGreenMailPartialBodyIdleAndKeywords() async throws {
        let server = try greenMail()
        let transport = SocketTransport()
        let log = LogCollector()
        let client = IMAPClient(host: server.host, port: server.port, security: .none, transport: transport, timeout: 10, logger: log.logger)
        let user = uniqueUser("example.com")
        let text = "Lunch on Thursday? The usual place at noon."
        try await client.connect()
        try await client.login(username: user, password: server.password)
        let uid = try await client.append(to: "INBOX", message: message(subject: "Partial body", text: text))
        let info = try await client.select("INBOX")
        XCTAssertGreaterThanOrEqual(info.exists, 1)
        let uids = try await client.uidSearch(.all)
        let target = try XCTUnwrap(uid ?? uids.last)
        let responses = try await client.fetch(IMAPSequenceSet(target), byUID: true,
                                               items: [.bodyStructure, .bodyPeek(section: "1", partial: (0, 2048))])
        let response = try XCTUnwrap(responses.first, log.text)
        XCTAssertEqual(response.bodyStructure?.preferredTextPart()?.section, "1")
        let section = try XCTUnwrap(response.section("1"), "the partial section was dropped:\n\(log.text)")
        XCTAssertEqual(String(decoding: section, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), text)
        XCTAssertEqual(response.sectionOrigins["1"], 0)

        try await client.uidStore(IMAPSequenceSet(target), flags: ["\\Answered", "$Forwarded"], mode: .add)
        let flags = try await client.fetch(IMAPSequenceSet(target), byUID: true, items: [.flags])
        XCTAssertTrue(flags.first?.flags?.contains("\\Answered") ?? false, "\(String(describing: flags.first?.flags))")

        if await client.supports("IDLE") {
            let started = Date()
            try await client.idle(timeout: 0.5) { _ in true }
            XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.45)
            _ = try await client.noop()
        }
        await client.logout()
    }

    /// GreenMail offers no STARTTLS: a `.startTLS` account must fail before signing in.
    func testGreenMailWithoutStartTLSIsRefused() async throws {
        let server = try greenMail()
        let transport = SocketTransport()
        let log = LogCollector()
        let client = IMAPClient(host: server.host, port: server.port, security: .startTLS, transport: transport, timeout: 10, logger: log.logger)
        await assertThrowsMailError(.tlsFailed("The server doesn't offer STARTTLS.")) {
            try await client.connect()
            try await client.login(username: uniqueUser("example.com"), password: server.password)
        }
        XCTAssertFalse(log.text.contains("LOGIN"), log.text)
        XCTAssertFalse(log.text.contains("AUTHENTICATE"), log.text)
    }

    /// Dovecot's real reply to STARTTLS leaves nothing buffered, so the client goes on to the
    /// handshake (which this plaintext transport can't do) instead of reporting injected data.
    func testDovecotStartTLSReachesTheHandshake() async throws {
        let server = try dovecot()
        let transport = SocketTransport()
        let log = LogCollector()
        let client = IMAPClient(host: server.host, port: server.port, security: .startTLS, transport: transport, timeout: 10, logger: log.logger)
        await assertThrowsMailError(.tlsFailed("The test socket transport is plaintext only.")) {
            try await client.connect()
        }
        XCTAssertTrue(log.text.contains("C: A001 STARTTLS") || log.text.contains("C: A002 STARTTLS"), log.text)
        XCTAssertFalse(log.text.contains("AUTHENTICATE"), log.text)
    }

    /// Capabilities after login, ENABLE, PERMANENTFLAGS with `\*`, partial bodies with the
    /// usual spacing, keywords and IDLE on Dovecot.
    func testDovecotSessionCapabilitiesEnableAndFlags() async throws {
        let server = try dovecot()
        let transport = SocketTransport()
        let log = LogCollector()
        let client = IMAPClient(host: server.host, port: server.port, security: .none, transport: transport, timeout: 10, logger: log.logger)
        try await client.connect()
        let preLogin = await client.capabilities
        XCTAssertFalse(preLogin.contains("QRESYNC"), "Dovecot lists QRESYNC only after login")
        try await client.login(username: uniqueUser("example.org"), password: server.password)
        let postLogin = await client.capabilities
        XCTAssertTrue(postLogin.contains("QRESYNC"), "\(postLogin.sorted())")
        try await client.enable(["QRESYNC", "UTF8=ACCEPT"])
        let enabled = await client.enabledExtensions
        XCTAssertTrue(enabled.isSuperset(of: ["QRESYNC", "CONDSTORE"]), "\(enabled.sorted())")

        let text = "Dovecot partial body."
        _ = try await client.append(to: "INBOX", message: message(subject: "Dovecot", text: text), flags: ["\\Seen"])
        let info = try await client.select("INBOX", condstore: true)
        XCTAssertTrue(info.hasPermanentFlags)
        XCTAssertTrue(info.allowsNewKeywords, "\(info.permanentFlags)")
        let uids = try await client.uidSearch(.all)
        let target = try XCTUnwrap(uids.last)
        let responses = try await client.fetch(IMAPSequenceSet(target), byUID: true, items: [.bodyPeek(section: "1", partial: (0, 2048))])
        let section = try XCTUnwrap(responses.first?.section("1"), log.text)
        XCTAssertEqual(String(decoding: section, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines), text)

        try await client.uidStore(IMAPSequenceSet(target), flags: ["$Forwarded"], mode: .add)
        let flags = try await client.fetch(IMAPSequenceSet(target), byUID: true, items: [.flags])
        XCTAssertTrue(flags.first?.flags?.contains("$Forwarded") ?? false, "\(String(describing: flags.first?.flags))")

        let interval = await client.idleReissueInterval
        XCTAssertEqual(interval, IMAPClient.standardIdleInterval)
        try await client.idle(timeout: 0.5) { _ in true }
        _ = try await client.noop()
        await client.logout()
    }
}
