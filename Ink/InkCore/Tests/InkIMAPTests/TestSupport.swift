import Foundation
import XCTest
import InkModel
@testable import InkIMAP

/// Converts `\n` to `\r\n` (fixtures are written with plain newlines).
func crlf(_ text: String) -> String {
    text.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
}

/// `{n}\r\n` + text, with n counted in UTF-8 bytes.
func literal(_ text: String) -> String {
    "{\(text.utf8.count)}\r\n" + text
}

/// Parses every response in `text` (CRLF line endings expected).
func parseAll(_ text: String, utf8Mode: Bool = false, file: StaticString = #filePath, line: UInt = #line) -> [IMAPResponse] {
    do {
        return try IMAPResponseParser.parseAll(text, utf8Mode: utf8Mode)
    } catch {
        XCTFail("parse failed: \(error)", file: file, line: line)
        return []
    }
}

/// Parses exactly one response.
func parseOne(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> IMAPResponse? {
    let responses = parseAll(text, file: file, line: line)
    XCTAssertEqual(responses.count, 1, "expected one response", file: file, line: line)
    return responses.first
}

/// The untagged response in `text`.
func untagged(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> IMAPUntagged? {
    guard case .untagged(let response)? = parseOne(text, file: file, line: line) else {
        XCTFail("not an untagged response", file: file, line: line)
        return nil
    }
    return response
}

/// The FETCH response in `text`.
func fetchResponse(_ text: String, file: StaticString = #filePath, line: UInt = #line) -> IMAPFetchResponse? {
    guard case .fetch(let response)? = untagged(text, file: file, line: line) else {
        XCTFail("not a FETCH response", file: file, line: line)
        return nil
    }
    return response
}

/// The BODYSTRUCTURE in a `* 1 FETCH (BODYSTRUCTURE …)` built around `structure`.
func bodyStructure(_ structure: String, file: StaticString = #filePath, line: UInt = #line) -> BodyStructure? {
    let response = fetchResponse("* 1 FETCH (UID 1 BODYSTRUCTURE \(structure))\r\n", file: file, line: line)
    XCTAssertNotNil(response?.bodyStructure, "no body structure", file: file, line: line)
    return response?.bodyStructure
}

/// A deterministic random number generator (SplitMix64) so fuzz failures reproduce.
struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

/// Collects log lines from the client's logger.
final class LogCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [String] = []
    var lines: [String] { lock.withLock { storage } }
    var text: String { lines.joined(separator: "\n") }
    func append(_ line: String) { lock.withLock { storage.append(line) } }
    var logger: @Sendable (String) -> Void { { [weak self] line in self?.append(line) } }
}

/// Collects IDLE events.
final class EventBox: @unchecked Sendable {
    private let lock = NSLock()
    private var storage: [IMAPUntagged] = []
    var events: [IMAPUntagged] { lock.withLock { storage } }
    func append(_ event: IMAPUntagged) { lock.withLock { storage.append(event) } }
}

/// Fails the test (by closing the transport, which makes the client throw) if `body` hangs.
func withWatchdog<T>(_ transport: MailTransport, seconds: Double = 10, file: StaticString = #filePath, line: UInt = #line,
                     _ body: () async throws -> T) async rethrows -> T {
    let watchdog = Task {
        try await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        XCTFail("conversation hung; closing the transport", file: file, line: line)
        transport.close()
    }
    defer { watchdog.cancel() }
    return try await body()
}

/// Asserts that `body` throws a `MailError` equal to `expected`.
func assertThrowsMailError<T>(_ expected: MailError, file: StaticString = #filePath, line: UInt = #line,
                              _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected \(expected) but nothing was thrown", file: file, line: line)
    } catch let error as MailError {
        XCTAssertEqual(error, expected, file: file, line: line)
    } catch {
        XCTFail("expected MailError \(expected), got \(error)", file: file, line: line)
    }
}

/// Asserts that `body` throws some `MailError` matching `predicate`.
func assertThrowsMailError<T>(file: StaticString = #filePath, line: UInt = #line, matching predicate: (MailError) -> Bool,
                              _ body: () async throws -> T) async {
    do {
        _ = try await body()
        XCTFail("expected a MailError but nothing was thrown", file: file, line: line)
    } catch let error as MailError {
        XCTAssertTrue(predicate(error), "unexpected error \(error)", file: file, line: line)
    } catch {
        XCTFail("expected MailError, got \(error)", file: file, line: line)
    }
}

/// A fake IMAP server that understands command framing: it collects each client command
/// together with its literals (answering `{n}` with `+` and checking the client waited for it),
/// then asks `handler` what to reply. Replies can be delivered in small random chunks to
/// exercise the client's incremental parsing, and reads honour their timeout.
final class MockIMAPServer: MailTransport, @unchecked Sendable {
    /// One client command: its first line (literal markers included), the literals it carried,
    /// and the tag.
    struct Command {
        var tag: String
        /// Everything after the tag, literal data replaced by `<literal>`.
        var text: String
        var literals: [Data]
    }

    typealias Handler = (_ command: Command, _ server: MockIMAPServer) -> [String]

    private let lock = NSLock()
    private var outbound: [UInt8] = []
    private var waiter: (id: Int, continuation: CheckedContinuation<Data, Error>)?
    private var nextWaiterID = 0
    private var inbound: [UInt8] = []
    private var currentText: [UInt8] = []
    private var currentLiterals: [Data] = []
    private var literalRemaining = 0
    private var literalBuffer: [UInt8] = []
    private var awaitingPlusDelivery = false
    private var rng: SeededGenerator
    private let handler: Handler
    private let greeting: String?

    var maxChunk: Int
    private(set) var commands: [Command] = []
    private(set) var isOpen = false
    private(set) var didStartTLS = false
    private(set) var openedWithTLS = false
    /// The client sent literal bytes before the server's `+` reached it.
    private(set) var literalSentEarly = false
    /// Everything the client wrote.
    private(set) var written: [UInt8] = []
    /// A command arrived while replies to an earlier one were still unread (pipelining).
    private(set) var commandArrivedWithUnreadReplies = false

    init(greeting: String? = "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Mock ready\r\n", maxChunk: Int = Int.max, seed: UInt64 = 1,
         handler: @escaping Handler) {
        self.greeting = greeting
        self.maxChunk = maxChunk
        self.rng = SeededGenerator(seed: seed)
        self.handler = handler
    }

    var transcript: String { lock.withLock { String(decoding: written, as: UTF8.self) } }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        lock.withLock {
            isOpen = true
            openedWithTLS = tls
            if let greeting { outbound.append(contentsOf: greeting.utf8) }
        }
        deliver()
    }

    func startTLS() async throws { lock.withLock { didStartTLS = true } }

    /// Queues raw server output (for unsolicited data).
    func push(_ text: String) {
        lock.withLock { outbound.append(contentsOf: text.utf8) }
        deliver()
    }

    func read(timeout: TimeInterval) async throws -> Data {
        let id: Int = lock.withLock {
            nextWaiterID += 1
            return nextWaiterID
        }
        if timeout.isFinite, timeout < 3600 {
            Task {
                try? await Task.sleep(nanoseconds: UInt64(max(0, timeout) * 1_000_000_000))
                self.expire(id)
            }
        }
        return try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if let chunk = takeChunkLocked() {
                lock.unlock()
                continuation.resume(returning: chunk)
            } else if !isOpen {
                lock.unlock()
                continuation.resume(throwing: TransportError.closed)
            } else {
                waiter = (id, continuation)
                lock.unlock()
            }
        }
    }

    private func expire(_ id: Int) {
        lock.lock()
        guard let current = waiter, current.id == id else {
            lock.unlock()
            return
        }
        waiter = nil
        lock.unlock()
        current.continuation.resume(throwing: TransportError.timeout)
    }

    func write(_ data: Data) async throws {
        var replies: [String] = []
        lock.withLock {
            guard isOpen else { return }
            written.append(contentsOf: data)
            if awaitingPlusDelivery, literalRemaining > 0, !data.isEmpty { literalSentEarly = true }
            inbound.append(contentsOf: data)
            replies = processInboundLocked()
        }
        for reply in replies { lock.withLock { outbound.append(contentsOf: reply.utf8) } }
        deliver()
    }

    func close() {
        lock.lock()
        isOpen = false
        let pending = waiter
        waiter = nil
        lock.unlock()
        pending?.continuation.resume(throwing: TransportError.closed)
    }

    /// Takes the next chunk (at most `maxChunk` bytes, random size) from `outbound`.
    private func takeChunkLocked() -> Data? {
        guard !outbound.isEmpty else { return nil }
        let size = maxChunk >= outbound.count ? outbound.count : Int.random(in: 1...maxChunk, using: &rng)
        let chunk = Data(outbound.prefix(size))
        outbound.removeFirst(size)
        if outbound.isEmpty { awaitingPlusDelivery = false }
        return chunk
    }

    private func deliver() {
        lock.lock()
        guard let current = waiter else {
            lock.unlock()
            return
        }
        if let chunk = takeChunkLocked() {
            waiter = nil
            lock.unlock()
            current.continuation.resume(returning: chunk)
        } else if !isOpen {
            waiter = nil
            lock.unlock()
            current.continuation.resume(throwing: TransportError.closed)
        } else {
            lock.unlock()
        }
    }

    /// Frames client bytes into commands; returns the replies to queue.
    private func processInboundLocked() -> [String] {
        var replies: [String] = []
        while !inbound.isEmpty {
            if literalRemaining > 0 {
                let take = min(literalRemaining, inbound.count)
                literalBuffer.append(contentsOf: inbound.prefix(take))
                inbound.removeFirst(take)
                literalRemaining -= take
                if literalRemaining == 0 {
                    currentLiterals.append(Data(literalBuffer))
                    literalBuffer.removeAll()
                    currentText.append(contentsOf: Array("<literal>".utf8))
                }
                continue
            }
            guard let lf = inbound.firstIndex(of: 0x0A) else { break }
            var line = Array(inbound[..<lf])
            inbound.removeFirst(lf + 1)
            if line.last == 0x0D { line.removeLast() }
            currentText.append(contentsOf: line)
            if let (length, synchronizing) = Self.trailingLiteral(line) {
                literalRemaining = length
                if synchronizing {
                    outbound.append(contentsOf: Array("+ Ready for literal data\r\n".utf8))
                    awaitingPlusDelivery = true
                    // Literal bytes in the same write as the header didn't wait for the "+".
                    if !inbound.isEmpty, length > 0 { literalSentEarly = true }
                }
                if length == 0 {
                    currentLiterals.append(Data())
                    currentText.append(contentsOf: Array("<literal>".utf8))
                }
                continue
            }
            let text = String(decoding: currentText, as: UTF8.self)
            currentText.removeAll()
            let literals = currentLiterals
            currentLiterals.removeAll()
            let parts = text.split(separator: " ", maxSplits: 1, omittingEmptySubsequences: false)
            let command = Command(tag: parts.count > 1 ? String(parts[0]) : "", text: parts.count > 1 ? String(parts[1]) : text, literals: literals)
            if !outbound.isEmpty || !replies.isEmpty { commandArrivedWithUnreadReplies = true }
            commands.append(command)
            lock.unlock()
            let reply = handler(command, self)
            lock.lock()
            replies.append(contentsOf: reply)
        }
        return replies
    }

    private static func trailingLiteral(_ line: [UInt8]) -> (Int, Bool)? {
        guard line.last == UInt8(ascii: "}"), let open = line.lastIndex(of: UInt8(ascii: "{")) else { return nil }
        var digits = Array(line[(open + 1)..<(line.count - 1)])
        var synchronizing = true
        if digits.last == UInt8(ascii: "+") {
            synchronizing = false
            digits.removeLast()
        }
        guard !digits.isEmpty, digits.allSatisfy({ $0 >= 0x30 && $0 <= 0x39 }), let length = Int(String(decoding: digits, as: UTF8.self)) else { return nil }
        return (length, synchronizing)
    }
}

extension IMAPUntagged {
    var isExists: Bool { if case .exists = self { return true } else { return false } }
}

/// Ordered expectations for `MockIMAPServer`: each command's text (after the tag) must start
/// with the next prefix (case-insensitive); `{TAG}` in the reply becomes the command's tag.
/// A mismatch fails the test and answers BAD.
final class ScriptedHandler: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [(prefix: String, reply: String)]
    private let file: StaticString
    private let line: UInt

    init(_ steps: [(String, String)], file: StaticString = #filePath, line: UInt = #line) {
        self.steps = steps.map { (prefix: $0.0, reply: $0.1) }
        self.file = file
        self.line = line
    }

    var remaining: Int { lock.withLock { steps.count } }

    func handle(_ command: MockIMAPServer.Command, _ server: MockIMAPServer) -> [String] {
        let step: (prefix: String, reply: String)? = lock.withLock {
            guard let first = steps.first, command.text.uppercased().hasPrefix(first.prefix.uppercased()) else { return nil }
            steps.removeFirst()
            return first
        }
        guard let step else {
            XCTFail("unexpected command: \(command.tag) \(command.text)", file: file, line: line)
            return ["\(command.tag) BAD Unexpected command\r\n"]
        }
        return [step.reply.replacingOccurrences(of: "{TAG}", with: command.tag)]
    }
}

extension MockIMAPServer {
    /// A server that follows `steps` in order (see `ScriptedHandler`).
    static func scripted(greeting: String? = "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] Mock ready\r\n", maxChunk: Int = Int.max, seed: UInt64 = 1,
                         _ steps: [(String, String)], file: StaticString = #filePath, line: UInt = #line) -> (MockIMAPServer, ScriptedHandler) {
        let handler = ScriptedHandler(steps, file: file, line: line)
        let server = MockIMAPServer(greeting: greeting, maxChunk: maxChunk, seed: seed) { command, server in handler.handle(command, server) }
        return (server, handler)
    }
}
