import Foundation
import XCTest
import InkModel
@testable import InkSMTP

/// Wraps a transport so a read the script never answers fails with `.timeout` after `limit`
/// seconds instead of hanging the test run.
final class GuardedTransport: MailTransport, @unchecked Sendable {
    let inner: MailTransport
    let limit: TimeInterval

    init(_ inner: MailTransport, limit: TimeInterval = 5) {
        self.inner = inner
        self.limit = limit
    }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        try await inner.open(host: host, port: port, tls: tls, timeout: timeout)
    }

    func startTLS() async throws { try await inner.startTLS() }

    func read(timeout: TimeInterval) async throws -> Data {
        let gate = ResumeOnce<Data>()
        let inner = self.inner
        let limit = min(self.limit, timeout)
        return try await withCheckedThrowingContinuation { continuation in
            gate.set(continuation)
            Task {
                do { gate.resume(.success(try await inner.read(timeout: timeout))) } catch { gate.resume(.failure(error)) }
            }
            Task {
                try? await Task.sleep(nanoseconds: UInt64(limit * 1_000_000_000))
                gate.resume(.failure(TransportError.timeout))
            }
        }
    }

    func write(_ data: Data) async throws { try await inner.write(data) }
    func close() { inner.close() }
}

final class ResumeOnce<T: Sendable>: @unchecked Sendable {
    private let lock = NSLock()
    private var continuation: CheckedContinuation<T, Error>?

    func set(_ continuation: CheckedContinuation<T, Error>) { lock.withLock { self.continuation = continuation } }

    func resume(_ result: Result<T, Error>) {
        let pending: CheckedContinuation<T, Error>? = lock.withLock {
            defer { continuation = nil }
            return continuation
        }
        pending?.resume(with: result)
    }
}

/// A tiny SMTP server for tests that need exact byte-level checks of what arrives after DATA.
/// `respond` gets each command line and returns the reply text (CRLF included), or nil for none.
final class FakeSMTPServer: MailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private let greeting: String
    private let respond: @Sendable (String) -> String?
    private let finalReply: String
    private var outbound = Data()
    private var waiter: CheckedContinuation<Data, Error>?
    private var inbound = [UInt8]()
    private var inData = false
    private var currentMessage = [UInt8]()
    private(set) var commands: [String] = []
    /// Raw bytes received between `354` and the terminating `.` line (still dot-stuffed).
    private(set) var rawMessages: [Data] = []
    private(set) var isOpen = false
    private(set) var tlsStarted = false

    init(greeting: String = "220 test.example ESMTP\r\n", finalReply: String = "250 2.0.0 queued\r\n", respond: @escaping @Sendable (String) -> String?) {
        self.greeting = greeting
        self.finalReply = finalReply
        self.respond = respond
    }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        lock.withLock {
            isOpen = true
            outbound.append(Data(greeting.utf8))
        }
        deliver()
    }

    func startTLS() async throws { lock.withLock { tlsStarted = true } }

    func read(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !outbound.isEmpty {
                let chunk = outbound
                outbound = Data()
                lock.unlock()
                continuation.resume(returning: chunk)
            } else if !isOpen {
                lock.unlock()
                continuation.resume(throwing: TransportError.closed)
            } else {
                waiter = continuation
                lock.unlock()
            }
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock {
            inbound.append(contentsOf: data)
            while let lf = inbound.firstIndex(of: 0x0A) {
                let lineBytes = Array(inbound[..<(lf + 1)])
                inbound.removeFirst(lf + 1)
                handle(lineBytes)
            }
        }
        deliver()
    }

    func close() {
        lock.withLock { isOpen = false }
        deliver()
    }

    var messages: [String] { lock.withLock { rawMessages.map { String(decoding: $0, as: UTF8.self) } } }
    var receivedCommands: [String] { lock.withLock { commands } }

    private func handle(_ lineBytes: [UInt8]) {
        if inData {
            if lineBytes == [0x2E, 0x0D, 0x0A] {
                inData = false
                rawMessages.append(Data(currentMessage))
                currentMessage = []
                outbound.append(Data(finalReply.utf8))
            } else {
                currentMessage.append(contentsOf: lineBytes)
            }
            return
        }
        // Strip the line ending as bytes: "\r\n" is a single Character in Swift strings.
        var end = lineBytes.count
        if end > 0, lineBytes[end - 1] == 0x0A { end -= 1 }
        if end > 0, lineBytes[end - 1] == 0x0D { end -= 1 }
        let line = String(decoding: lineBytes[..<end], as: UTF8.self)
        commands.append(line)
        if let reply = respond(line) {
            outbound.append(Data(reply.utf8))
            if reply.hasPrefix("354") { inData = true }
        }
    }

    private func deliver() {
        lock.lock()
        guard let waiter else { lock.unlock(); return }
        if !outbound.isEmpty {
            let chunk = outbound
            outbound = Data()
            self.waiter = nil
            lock.unlock()
            waiter.resume(returning: chunk)
        } else if !isOpen {
            self.waiter = nil
            lock.unlock()
            waiter.resume(throwing: TransportError.closed)
        } else {
            lock.unlock()
        }
    }
}

/// Standard replies for `FakeSMTPServer`.
func standardResponder(extensions: [String] = ["SIZE 10485760", "8BITMIME", "AUTH PLAIN LOGIN", "ENHANCEDSTATUSCODES", "SMTPUTF8"]) -> @Sendable (String) -> String? {
    let ehlo = (["250-test.example"] + extensions.dropLast().map { "250-\($0)" } + extensions.suffix(1).map { "250 \($0)" })
        .joined(separator: "\r\n") + "\r\n"
    let ehloReply = extensions.isEmpty ? "250 test.example\r\n" : ehlo
    return { line in
        let upper = line.uppercased()
        if upper.hasPrefix("EHLO") { return ehloReply }
        if upper.hasPrefix("AUTH") { return "235 2.7.0 Accepted\r\n" }
        if upper.hasPrefix("MAIL FROM") { return "250 2.1.0 OK\r\n" }
        if upper.hasPrefix("RCPT TO") { return "250 2.1.5 OK\r\n" }
        if upper == "DATA" { return "354 Go ahead\r\n" }
        if upper == "RSET" { return "250 2.0.0 OK\r\n" }
        if upper == "QUIT" { return "221 2.0.0 Bye\r\n" }
        return "502 5.5.2 Unknown command\r\n"
    }
}

/// A transport whose open or reads fail in a chosen way.
final class FailingTransport: MailTransport, @unchecked Sendable {
    enum Mode { case openFails(TransportError), greetingThenTimeout, closedAfterGreeting }
    let mode: Mode
    private let lock = NSLock()
    private var reads = 0
    private(set) var written: [String] = []

    init(_ mode: Mode) { self.mode = mode }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        if case .openFails(let error) = mode { throw error }
    }

    func startTLS() async throws {}

    func read(timeout: TimeInterval) async throws -> Data {
        let count: Int = lock.withLock { reads += 1; return reads }
        if count == 1 { return Data("220 slow.example ESMTP\r\n".utf8) }
        switch mode {
        case .greetingThenTimeout: throw TransportError.timeout
        case .closedAfterGreeting, .openFails: throw TransportError.closed
        }
    }

    func write(_ data: Data) async throws {
        lock.withLock { written.append(String(decoding: data, as: UTF8.self)) }
    }

    func close() {}
}

/// Collects logger output from any thread.
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    var logger: @Sendable (String) -> Void { { [weak self] line in self?.append(line) } }
    private func append(_ line: String) { lock.withLock { storage.append(line) } }
}

/// Asserts that `body` throws a `MailError` and returns it.
@discardableResult
func assertThrowsMailError<T>(_ body: () async throws -> T, file: StaticString = #filePath, line: UInt = #line) async -> MailError? {
    do {
        _ = try await body()
        XCTFail("Expected a MailError, got success", file: file, line: line)
        return nil
    } catch let error as MailError {
        return error
    } catch {
        XCTFail("Expected a MailError, got \(error)", file: file, line: line)
        return nil
    }
}

/// A realistic message as InkMIME's MessageBuilder would produce it (CRLF, quoted-printable).
func sampleMessage(from: String = "ada@example.com", to: String = "grace@example.org", subject: String = "Lunch on Thursday?") -> Data {
    let text = [
        "Date: Tue, 20 Oct 2026 09:41:00 +0000",
        "From: Ada Lovelace <\(from)>",
        "To: Grace Hopper <\(to)>",
        "Subject: \(subject)",
        "Message-ID: <6F9619FF-8B86-D011-B42D-00C04FC964FF@example.com>",
        "MIME-Version: 1.0",
        "User-Agent: Ink",
        "Content-Type: multipart/alternative; boundary=\"ink-boundary-1\"",
        "",
        "--ink-boundary-1",
        "Content-Type: text/plain; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
        "",
        "Hi Grace,",
        "",
        "Are you free for lunch on Thursday? The usual place at 12:30.",
        "",
        "Ada",
        "--ink-boundary-1",
        "Content-Type: text/html; charset=utf-8",
        "Content-Transfer-Encoding: quoted-printable",
        "",
        "<p>Hi Grace,</p><p>Are you free for lunch on Thursday? The usual place at 12:30.</p><p>Ada</p>",
        "--ink-boundary-1--",
        "",
    ].joined(separator: "\r\n")
    return Data(text.utf8)
}
