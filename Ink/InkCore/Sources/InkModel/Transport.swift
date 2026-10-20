import Foundation

/// A byte stream to a mail server. The app provides a TLS-capable implementation on Apple
/// platforms (URLSessionStreamTask); tests use `ScriptedTransport` or `SocketTransport`.
///
/// Implementations must allow one concurrent `read` and one concurrent `write`.
public protocol MailTransport: AnyObject, Sendable {
    /// Opens a TCP connection. With `tls`, negotiates TLS immediately (implicit TLS: 993, 465).
    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws
    /// Upgrades the open plaintext connection to TLS (STARTTLS). Call only after the server
    /// accepted STARTTLS and every byte of its reply was read.
    func startTLS() async throws
    /// Returns the next bytes from the server (at least one). Throws `TransportError.closed`
    /// at end of stream and `TransportError.timeout` if nothing arrives within `timeout`.
    func read(timeout: TimeInterval) async throws -> Data
    func write(_ data: Data) async throws
    func close()
}

public typealias MailTransportFactory = @Sendable () -> MailTransport

public enum TransportError: Error, Sendable, Equatable, LocalizedError {
    case notConnected
    case closed
    case timeout
    case connectFailed(String)
    case tlsFailed(String)
    case io(String)

    public var errorDescription: String? {
        switch self {
        case .notConnected: return "Not connected."
        case .closed: return "The server closed the connection."
        case .timeout: return "The connection timed out."
        case .connectFailed(let detail): return "Couldn't connect: \(detail)"
        case .tlsFailed(let detail): return "Secure connection failed: \(detail)"
        case .io(let detail): return detail
        }
    }
}

/// A fake server for tests: replies to each write with the next scripted chunk(s).
///
/// Script it as a list of steps. `.send(text)` queues server output immediately (greetings,
/// untagged data); `.expect(prefix, reply)` waits for the client to write a line starting with
/// `prefix` (after the tag for IMAP, use `*` to match any tag), then queues `reply`. `{TAG}` in a
/// reply is replaced with the tag of the matched client line.
public final class ScriptedTransport: MailTransport, @unchecked Sendable {
    public enum Step: Sendable {
        case send(String)
        case expect(String, reply: String)
    }

    private let lock = NSLock()
    private var steps: [Step]
    private var outbound = Data()
    private var waiters: [CheckedContinuation<Data, Error>] = []
    private var pendingClientText = ""
    public private(set) var written: [String] = []
    public private(set) var didStartTLS = false
    public private(set) var isOpen = false
    public private(set) var openedTLS = false

    public init(_ steps: [Step]) { self.steps = steps }

    public func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        lock.withLock {
            isOpen = true
            openedTLS = tls
            drainSendSteps()
        }
        deliver()
    }

    public func startTLS() async throws { lock.withLock { didStartTLS = true } }

    public func read(timeout: TimeInterval) async throws -> Data {
        try await withCheckedThrowingContinuation { continuation in
            lock.lock()
            if !outbound.isEmpty {
                let chunk = outbound
                outbound = Data()
                lock.unlock()
                continuation.resume(returning: chunk)
            } else if steps.isEmpty && !isOpen {
                lock.unlock()
                continuation.resume(throwing: TransportError.closed)
            } else {
                waiters.append(continuation)
                lock.unlock()
            }
        }
    }

    public func write(_ data: Data) async throws {
        lock.withLock {
            let text = String(decoding: data, as: UTF8.self)
            written.append(text)
            pendingClientText += text
            // Match complete client lines against `expect` steps, in order.
            while let newline = pendingClientText.range(of: "\r\n") {
                let line = String(pendingClientText[..<newline.lowerBound])
                pendingClientText = String(pendingClientText[newline.upperBound...])
                handleClientLine(line)
            }
        }
        deliver()
    }

    public func close() {
        lock.withLock { isOpen = false }
        deliver()
    }

    /// Everything the client wrote, joined.
    public var transcript: String { lock.withLock { written.joined() } }

    private func handleClientLine(_ line: String) {
        guard case .expect(let prefix, let reply)? = steps.first else { return }
        let parts = line.split(separator: " ", maxSplits: 1).map(String.init)
        let tag = parts.first ?? ""
        let rest = parts.count > 1 ? parts[1] : ""
        let matches: Bool
        if prefix.hasPrefix("* ") {
            matches = rest.uppercased().hasPrefix(prefix.dropFirst(2).uppercased())
        } else {
            matches = line.uppercased().hasPrefix(prefix.uppercased())
        }
        guard matches else { return }
        steps.removeFirst()
        outbound.append(Data(reply.replacingOccurrences(of: "{TAG}", with: tag).utf8))
        drainSendSteps()
    }

    private func drainSendSteps() {
        while case .send(let text)? = steps.first {
            steps.removeFirst()
            outbound.append(Data(text.utf8))
        }
    }

    private func deliver() {
        lock.lock()
        var ready: [(CheckedContinuation<Data, Error>, Result<Data, Error>)] = []
        while !waiters.isEmpty {
            if !outbound.isEmpty {
                ready.append((waiters.removeFirst(), .success(outbound)))
                outbound = Data()
            } else if !isOpen {
                ready.append((waiters.removeFirst(), .failure(TransportError.closed)))
            } else {
                break
            }
        }
        lock.unlock()
        for (continuation, result) in ready { continuation.resume(with: result) }
    }
}
