import Foundation
import InkCore

/// The byte stream IMAP and SMTP run over on Apple platforms: a `URLSessionStreamTask`, so TLS
/// (certificate and host-name checks, SNI) is the system's. Implicit TLS (993, 465) and STARTTLS
/// (143, 587) both use `startSecureConnection()`.
///
/// Each connection gets its own ephemeral `URLSession` with no cache, cookies or credential
/// storage, torn down by `close()`. The TCP connect and TLS handshake happen lazily on the first
/// read or write, so that first operation runs with the `open` timeout and reports a silent host as
/// a connection failure rather than a slow reply.
///
/// Cancelling the task that is waiting in `read` or `write` closes the connection: a protocol
/// stream can't be resumed halfway through a response.
final class URLSessionMailTransport: MailTransport, @unchecked Sendable {
    private static let maxReadLength = 64 * 1024
    /// Slowest upload rate a write is given time for (bytes per second), so a message with large
    /// attachments isn't cut off by a fixed timeout.
    private static let minimumUploadRate: Double = 32 * 1024

    private let lock = NSLock()
    private var session: URLSession?
    private var task: URLSessionStreamTask?
    private var host = ""
    private var port = 0
    /// Set by `open` and consumed by the first read or write.
    private var connectTimeout: TimeInterval?
    /// Base timeout for writes; the protocol's `write` doesn't pass one.
    private var writeTimeout: TimeInterval = 60
    private var reachedEndOfStream = false

    init() {}

    deinit {
        Self.tearDown(task: task, session: session)
    }

    // MARK: MailTransport

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        let trimmedHost = host.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedHost.isEmpty, (1...65_535).contains(port) else {
            throw TransportError.connectFailed("“\(host):\(port)” isn't a valid server address.")
        }
        let session = URLSession(configuration: Self.makeConfiguration())
        let task = session.streamTask(withHostName: trimmedHost, port: port)
        let previous = lock.withLock { () -> (URLSessionStreamTask?, URLSession?) in
            let old = (self.task, self.session)
            self.session = session
            self.task = task
            self.host = trimmedHost
            self.port = port
            self.connectTimeout = timeout
            self.writeTimeout = max(timeout, 30)
            self.reachedEndOfStream = false
            return old
        }
        Self.tearDown(task: previous.0, session: previous.1)
        task.resume()
        if tls { task.startSecureConnection() }
    }

    func startTLS() async throws {
        let task = try lock.withLock { () throws -> URLSessionStreamTask in
            guard let task = self.task else { throw TransportError.notConnected }
            return task
        }
        // Queued after everything already read and written; the handshake runs before the next I/O.
        task.startSecureConnection()
    }

    func read(timeout: TimeInterval) async throws -> Data {
        let operation = try beginOperation()
        if operation.atEndOfStream { throw TransportError.closed }
        let task = operation.task
        let effectiveTimeout = operation.connectTimeout ?? timeout
        do {
            let (data, atEOF) = try await withTaskCancellationHandler {
                try await task.readData(ofMinLength: 1, maxLength: Self.maxReadLength, timeout: effectiveTimeout)
            } onCancel: { [weak self] in
                self?.close()
            }
            if atEOF { lock.withLock { reachedEndOfStream = true } }
            guard let data, !data.isEmpty else { throw TransportError.closed }
            return data
        } catch {
            throw failure(for: error, connecting: operation.connectTimeout != nil)
        }
    }

    func write(_ data: Data) async throws {
        guard !data.isEmpty else { return }
        let operation = try beginOperation()
        let task = operation.task
        let sized = operation.writeTimeout + Double(data.count) / Self.minimumUploadRate
        let effectiveTimeout = max(operation.connectTimeout ?? 0, sized)
        do {
            try await withTaskCancellationHandler {
                try await task.write(data, timeout: effectiveTimeout)
            } onCancel: { [weak self] in
                self?.close()
            }
        } catch {
            throw failure(for: error, connecting: operation.connectTimeout != nil)
        }
    }

    func close() {
        let current = lock.withLock { () -> (URLSessionStreamTask?, URLSession?) in
            let current = (self.task, self.session)
            self.task = nil
            self.session = nil
            self.connectTimeout = nil
            return current
        }
        Self.tearDown(task: current.0, session: current.1)
    }

    // MARK: Helpers

    private struct Operation {
        var task: URLSessionStreamTask
        /// Non-nil for the first operation after `open`, which also connects.
        var connectTimeout: TimeInterval?
        var writeTimeout: TimeInterval
        var atEndOfStream: Bool
    }

    private func beginOperation() throws -> Operation {
        try lock.withLock { () throws -> Operation in
            guard let task = self.task else { throw TransportError.notConnected }
            let connect = self.connectTimeout
            self.connectTimeout = nil
            return Operation(task: task, connectTimeout: connect, writeTimeout: self.writeTimeout, atEndOfStream: self.reachedEndOfStream)
        }
    }

    private static func makeConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.httpCookieAcceptPolicy = .never
        configuration.urlCredentialStorage = nil
        configuration.waitsForConnectivity = false
        // IDLE connections stay quiet for many minutes; every read and write passes its own timeout.
        configuration.timeoutIntervalForRequest = 60 * 60
        return configuration
    }

    private static func tearDown(task: URLSessionStreamTask?, session: URLSession?) {
        task?.closeWrite()
        task?.closeRead()
        task?.cancel()
        session?.invalidateAndCancel()
    }

    /// Turns URLSession errors into `TransportError`s with sentences fit to show the user.
    private func failure(for error: Error, connecting: Bool) -> Error {
        if Task.isCancelled || error is CancellationError { return CancellationError() }
        if let transportError = error as? TransportError { return transportError }
        let (host, port) = lock.withLock { (self.host, self.port) }

        if let urlError = error as? URLError {
            switch urlError.code {
            case .cancelled:
                return TransportError.closed
            case .timedOut:
                return connecting ? TransportError.connectFailed("\(host) didn't answer on port \(port).") : TransportError.timeout
            case .secureConnectionFailed:
                return TransportError.tlsFailed("The secure handshake with \(host) failed.")
            case .serverCertificateUntrusted, .serverCertificateHasUnknownRoot:
                return TransportError.tlsFailed("The certificate of \(host) isn't trusted.")
            case .serverCertificateHasBadDate, .serverCertificateNotYetValid:
                return TransportError.tlsFailed("The certificate of \(host) has expired or isn't valid yet.")
            case .clientCertificateRejected, .clientCertificateRequired:
                return TransportError.tlsFailed("\(host) asked for a client certificate.")
            case .cannotFindHost, .dnsLookupFailed:
                return TransportError.connectFailed("No server named \(host) was found.")
            case .cannotConnectToHost:
                return TransportError.connectFailed("\(host) isn't accepting connections on port \(port).")
            case .notConnectedToInternet, .dataNotAllowed, .internationalRoamingOff:
                return TransportError.connectFailed("You're offline.")
            case .networkConnectionLost:
                return TransportError.connectFailed("The network connection was lost.")
            default:
                return TransportError.io(urlError.localizedDescription)
            }
        }

        let nsError = error as NSError
        // Secure Transport / Network.framework TLS failures (errSSL…) arrive as OSStatus codes.
        if nsError.domain == NSOSStatusErrorDomain, (-9899 ... -9800).contains(nsError.code) {
            return TransportError.tlsFailed("The secure handshake with \(host) failed.")
        }
        return TransportError.io(nsError.localizedDescription)
    }
}
