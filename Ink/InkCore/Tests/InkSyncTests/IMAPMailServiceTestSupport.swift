import Foundation
import XCTest
import InkModel
import InkIMAP
@testable import InkSync

/// Helpers shared by the IMAPMailService tests (names are prefixed so they can't clash with
/// other InkSync test files).
enum IMAPServiceFixtures {
    /// `\n` → `\r\n`.
    static func crlf(_ text: String) -> String {
        text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// An IMAP literal: `{n}\r\n` + text (n in UTF-8 bytes).
    static func literal(_ text: String) -> String {
        "{\(text.utf8.count)}\r\n" + text
    }

    static func account(provider: ProviderID = .other, email: String = "ada@example.com", host: String = "imap.example.com",
                        smtpHost: String = "smtp.example.com", authMethod: AuthMethod = .password,
                        savesSentAutomatically: Bool = false) -> AccountConfig {
        AccountConfig(id: "acct-\(provider.rawValue)", provider: provider, displayName: "Ada Lovelace", emailAddress: email,
                      imap: ServerConfig(host: host, port: 993, security: .tls, username: email),
                      smtp: ServerConfig(host: smtpHost, port: 465, security: .tls, username: email),
                      authMethod: authMethod, savesSentAutomatically: savesSentAutomatically)
    }

    static let fastOptions = IMAPMailService.Options(timeout: 3, reconnectDelays: [0.05], maxWatchFailures: 2, clientID: nil)

    /// A service whose connections come from `transports`, in order.
    static func service(_ account: AccountConfig, credential: Credential = .password("correct horse"),
                        transports: IMAPServiceTransportQueue, options: IMAPMailService.Options = fastOptions,
                        log: IMAPServiceLog? = nil) -> IMAPMailService {
        let credentials = InMemoryCredentialStore([account.id: credential])
        return IMAPMailService(account: account, credentials: credentials, transportFactory: transports.factory,
                               options: options, logger: log?.logger)
    }

    static func mailbox(_ path: String, rawPath: String? = nil, role: MailboxRole, accountID: String = "acct-other") -> MailboxInfo {
        MailboxInfo(accountID: accountID, path: path, rawPath: rawPath ?? path, delimiter: "/", role: role)
    }

    /// Parses `* … FETCH` lines into responses (fixtures use plain newlines).
    static func fetchResponses(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> [IMAPFetchResponse] {
        do {
            let complete = text.hasSuffix("\n") ? text : text + "\n"
            return try IMAPResponseParser.parseAll(crlf(complete)).compactMap { response in
                if case .untagged(.fetch(let fetch)) = response { return fetch }
                return nil
            }
        } catch {
            XCTFail("fixture didn't parse: \(error)", file: file, line: line)
            return []
        }
    }

    /// The header-fields literal the service asks for, with the given header lines.
    static func headerFields(_ lines: [String]) -> String {
        "BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE AUTO-SUBMITTED)] "
            + literal(lines.map { $0 + "\r\n" }.joined() + "\r\n")
    }
}

/// Hands the service prepared transports, one per connection, and records what it took.
final class IMAPServiceTransportQueue: @unchecked Sendable {
    private let lock = NSLock()
    private var pending: [MailTransport]
    private var taken: [MailTransport] = []

    /// Closes every transport after `watchdog` seconds, so a script that doesn't match what the
    /// service sends fails the test instead of hanging it (ScriptedTransport has no read timeout).
    init(_ transports: [MailTransport], watchdog: TimeInterval = 20) {
        pending = transports
        let all = transports
        Task.detached {
            try? await Task.sleep(nanoseconds: UInt64(watchdog * 1_000_000_000))
            for transport in all { transport.close() }
        }
    }

    var factory: MailTransportFactory {
        { [self] in self.next() }
    }

    func next() -> MailTransport {
        lock.withLock {
            guard !pending.isEmpty else { return IMAPServiceRefusingTransport() }
            let transport = pending.removeFirst()
            taken.append(transport)
            return transport
        }
    }

    /// Connections opened so far.
    var openedCount: Int { lock.withLock { taken.count } }
    var remaining: Int { lock.withLock { pending.count } }
}

/// A server that isn't there.
final class IMAPServiceRefusingTransport: MailTransport, @unchecked Sendable {
    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        throw TransportError.connectFailed("Connection refused (test: no more scripted connections).")
    }
    func startTLS() async throws { throw TransportError.notConnected }
    func read(timeout: TimeInterval) async throws -> Data { throw TransportError.notConnected }
    func write(_ data: Data) async throws { throw TransportError.notConnected }
    func close() {}
}

/// Wraps a scripted connection and kills it when the client writes a line containing
/// `trigger` (like a NAT box that forgot the connection): the write vanishes, reads fail.
final class IMAPServiceDroppingTransport: MailTransport, @unchecked Sendable {
    let inner: ScriptedTransport
    let trigger: String
    private let lock = NSLock()
    private var dropped = false

    init(_ inner: ScriptedTransport, dropOn trigger: String) {
        self.inner = inner
        self.trigger = trigger.uppercased()
    }

    var didDrop: Bool { lock.withLock { dropped } }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        try await inner.open(host: host, port: port, tls: tls, timeout: timeout)
    }
    func startTLS() async throws { try await inner.startTLS() }
    func read(timeout: TimeInterval) async throws -> Data {
        if lock.withLock({ dropped }) { throw TransportError.closed }
        return try await inner.read(timeout: timeout)
    }
    func write(_ data: Data) async throws {
        let text = String(decoding: data, as: UTF8.self).uppercased()
        if text.contains(trigger) {
            lock.withLock { dropped = true }
            inner.close()
            return
        }
        try await inner.write(data)
    }
    func close() { inner.close() }
}

/// Collects log lines.
final class IMAPServiceLog: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    var text: String { lines.joined(separator: "\n") }
    var logger: @Sendable (String) -> Void { { [weak self] line in self?.append(line) } }
    private func append(_ line: String) { lock.withLock { storage.append(line) } }
}

/// Collects verification steps.
final class IMAPServiceSteps: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [VerificationStep] = []
    var steps: [VerificationStep] { lock.withLock { storage } }
    func append(_ step: VerificationStep) { lock.withLock { storage.append(step) } }
}

/// Asserts that `body` throws the given `MailError`.
func assertIMAPServiceThrows<T>(_ expected: MailError, file: StaticString = #filePath, line: UInt = #line,
                                _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected), nothing was thrown", file: file, line: line)
    } catch let error as MailError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected \(expected), got \(error)", file: file, line: line)
    }
}

/// Asserts that `body` throws a `MailError` matching `predicate`.
func assertIMAPServiceThrows<T>(file: StaticString = #filePath, line: UInt = #line, where predicate: (MailError) -> Bool,
                                _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected an error, nothing was thrown", file: file, line: line)
    } catch let error as MailError {
        XCTAssertTrue(predicate(error), "unexpected error \(error)", file: file, line: line)
    } catch {
        XCTFail("expected a MailError, got \(error)", file: file, line: line)
    }
}

/// A fake server that answers each client command through a closure (order-independent),
/// for tests where several calls race. Literal continuation lines are not supported.
final class IMAPServiceResponderTransport: MailTransport, @unchecked Sendable {
    typealias Responder = (_ line: String, _ tag: String, _ state: inout [String: String]) -> String
    private let lock = NSLock()
    private let responder: Responder
    private let greeting: String
    private var state: [String: String] = [:]
    private var outbound = Data()
    private var pending = ""
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var open = false
    private(set) var commands: [String] = []

    init(greeting: String, _ responder: @escaping Responder) {
        self.responder = responder
        self.greeting = greeting
    }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        lock.withLock {
            open = true
            outbound.append(Data(greeting.utf8))
        }
        deliver()
    }

    func startTLS() async throws {}

    func read(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !outbound.isEmpty {
                let chunk = outbound
                outbound = Data()
                lock.unlock()
                continuation.resume(returning: chunk)
            } else if !open {
                lock.unlock()
                continuation.resume(throwing: TransportError.closed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            pending += String(decoding: data, as: UTF8.self)
            while let range = pending.range(of: "\r\n") {
                let line = String(pending[..<range.lowerBound])
                pending = String(pending[range.upperBound...])
                let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
                guard parts.count == 2 else { continue }
                commands.append(parts[1])
                outbound.append(Data(responder(parts[1], parts[0], &state).utf8))
            }
        }
        deliver()
    }

    func close() {
        lock.withLock { open = false }
        deliver()
    }

    private func deliver() {
        lock.lock()
        var ready: [(CheckedContinuation<Data, Error>, Result<Data, Error>)] = []
        while !waiters.isEmpty {
            if !outbound.isEmpty {
                ready.append((waiters.removeFirst(), .success(outbound)))
                outbound = Data()
            } else if !open {
                ready.append((waiters.removeFirst(), .failure(TransportError.closed)))
            } else {
                break
            }
        }
        lock.unlock()
        for (continuation, result) in ready { continuation.resume(with: result) }
    }
}
