#if canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#elseif canImport(Darwin)
import Darwin
#endif
import Foundation
import InkModel

/// A plaintext TCP `MailTransport` over POSIX sockets (a copy of the one in InkSyncTests; test
/// targets cannot share sources), for integration tests against local
/// mail servers (GreenMail, Dovecot). TLS is not supported: `open(tls: true)` and `startTLS()`
/// throw.
///
/// Blocking socket calls run on two serial dispatch queues (one for reads, one for writes, as
/// the protocol requires one concurrent read and one concurrent write) and are bridged with
/// continuations, so they never block the cooperative thread pool. Reads poll in short slices so
/// `close()` is noticed promptly; the descriptor is only released once no call is using it.
final class SocketTransport: MailTransport, @unchecked Sendable {
    private let lock = NSLock()
    private var descriptor: Int32 = -1
    private var isClosed = true
    private var inFlight = 0
    private let readQueue = DispatchQueue(label: "ink.tests.socket.read")
    private let writeQueue = DispatchQueue(label: "ink.tests.socket.write")

    /// Every byte written, for assertions (protocol text only in these tests).
    private(set) var bytesWritten = 0

    init() {}

    deinit {
        if descriptor >= 0 { _ = systemClose(descriptor) }
    }

    func open(host: String, port: Int, tls: Bool, timeout: TimeInterval) async throws {
        if tls { throw TransportError.tlsFailed("The test socket transport is plaintext only.") }
        let fd = try await perform(on: readQueue) { try Self.connect(host: host, port: port, timeout: timeout) }
        lock.withLock {
            if descriptor >= 0, inFlight == 0 { _ = systemClose(descriptor) }
            descriptor = fd
            isClosed = false
        }
    }

    func startTLS() async throws {
        throw TransportError.tlsFailed("The test socket transport is plaintext only.")
    }

    func read(timeout: TimeInterval) async throws -> Data {
        try await perform(on: readQueue) { [self] in try blockingRead(timeout: timeout) }
    }

    func write(_ data: Data) async throws {
        try await perform(on: writeQueue) { [self] in try blockingWrite(data) }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            guard descriptor >= 0 else { return }
            _ = shutdown(descriptor, Int32(SHUT_RDWR))
            if inFlight == 0 {
                _ = systemClose(descriptor)
                descriptor = -1
            }
        }
    }

    // MARK: Plumbing

    private func perform<T: Sendable>(on queue: DispatchQueue, _ body: @escaping @Sendable () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                continuation.resume(with: Result { try body() })
            }
        }
    }

    /// Marks a call as using the descriptor; nil when the transport is closed.
    private func begin() -> Int32? {
        lock.withLock {
            guard !isClosed, descriptor >= 0 else { return nil }
            inFlight += 1
            return descriptor
        }
    }

    private func end() {
        lock.withLock {
            inFlight -= 1
            if isClosed, inFlight == 0, descriptor >= 0 {
                _ = systemClose(descriptor)
                descriptor = -1
            }
        }
    }

    private var closed: Bool { lock.withLock { isClosed } }

    private func blockingRead(timeout: TimeInterval) throws -> Data {
        guard let fd = begin() else { throw TransportError.closed }
        defer { end() }
        let deadline = Date().addingTimeInterval(max(0, timeout))
        var buffer = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            if closed { throw TransportError.closed }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 { throw TransportError.timeout }
            var request = pollfd(fd: fd, events: Int16(POLLIN), revents: 0)
            let slice = Int32(max(1, min(remaining, 0.25) * 1000))
            let ready = poll(&request, 1, slice)
            if ready < 0 {
                if errno == EINTR { continue }
                throw TransportError.io("poll failed (errno \(errno))")
            }
            if ready == 0 { continue }
            let count = buffer.withUnsafeMutableBytes { raw in recv(fd, raw.baseAddress, raw.count, 0) }
            if count > 0 { return Data(buffer[0..<count]) }
            if count == 0 { throw TransportError.closed }
            if errno == EINTR || errno == EAGAIN { continue }
            throw closed ? TransportError.closed : TransportError.io("recv failed (errno \(errno))")
        }
    }

    private func blockingWrite(_ data: Data) throws {
        guard let fd = begin() else { throw TransportError.notConnected }
        defer { end() }
        #if os(Linux)
        let flags = Int32(MSG_NOSIGNAL)
        #else
        let flags: Int32 = 0
        #endif
        try data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            guard let base = raw.baseAddress else { return }
            var offset = 0
            while offset < raw.count {
                let sent = send(fd, base + offset, raw.count - offset, flags)
                if sent < 0 {
                    if errno == EINTR { continue }
                    throw TransportError.io("send failed (errno \(errno))")
                }
                offset += sent
            }
        }
        lock.withLock { bytesWritten += data.count }
    }

    /// Resolves `host` and connects with a timeout (non-blocking connect + poll).
    private static func connect(host: String, port: Int, timeout: TimeInterval) throws -> Int32 {
        var hints = addrinfo()
        hints.ai_family = AF_UNSPEC
        #if os(Linux)
        hints.ai_socktype = Int32(SOCK_STREAM.rawValue)
        #else
        hints.ai_socktype = SOCK_STREAM
        #endif
        var list: UnsafeMutablePointer<addrinfo>?
        let status = getaddrinfo(host, String(port), &hints, &list)
        guard status == 0, let first = list else {
            throw TransportError.connectFailed("Couldn't resolve \(host).")
        }
        defer { freeaddrinfo(first) }
        var lastError = "Couldn't connect to \(host):\(port)."
        var cursor: UnsafeMutablePointer<addrinfo>? = first
        while let info = cursor {
            cursor = info.pointee.ai_next
            let fd = socket(info.pointee.ai_family, info.pointee.ai_socktype, info.pointee.ai_protocol)
            guard fd >= 0 else { continue }
            #if canImport(Darwin)
            var noSigPipe: Int32 = 1
            _ = setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &noSigPipe, socklen_t(MemoryLayout<Int32>.size))
            #endif
            var noDelay: Int32 = 1
            _ = setsockopt(fd, Int32(IPPROTO_TCP), TCP_NODELAY, &noDelay, socklen_t(MemoryLayout<Int32>.size))
            let originalFlags = fcntl(fd, F_GETFL, 0)
            _ = fcntl(fd, F_SETFL, originalFlags | O_NONBLOCK)
            var result = Glue.connect(fd, info.pointee.ai_addr, info.pointee.ai_addrlen)
            if result < 0, errno == EINPROGRESS {
                var request = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
                let ready = poll(&request, 1, Int32(max(1, timeout * 1000)))
                if ready > 0 {
                    var socketError: Int32 = 0
                    var length = socklen_t(MemoryLayout<Int32>.size)
                    _ = getsockopt(fd, SOL_SOCKET, SO_ERROR, &socketError, &length)
                    result = socketError == 0 ? 0 : -1
                    if socketError != 0 { lastError = "Connection to \(host):\(port) failed (errno \(socketError))." }
                } else {
                    lastError = "Connection to \(host):\(port) timed out."
                }
            } else if result < 0 {
                lastError = "Connection to \(host):\(port) failed (errno \(errno))."
            }
            if result == 0 {
                _ = fcntl(fd, F_SETFL, originalFlags)
                return fd
            }
            _ = systemClose(fd)
        }
        throw TransportError.connectFailed(lastError)
    }
}

/// Names that clash with methods on the transport.
private enum Glue {
    static func connect(_ fd: Int32, _ address: UnsafePointer<sockaddr>!, _ length: socklen_t) -> Int32 {
        #if canImport(Glibc)
        return Glibc.connect(fd, address, length)
        #elseif canImport(Musl)
        return Musl.connect(fd, address, length)
        #else
        return Darwin.connect(fd, address, length)
        #endif
    }
}

private func systemClose(_ fd: Int32) -> Int32 {
    #if canImport(Glibc)
    return Glibc.close(fd)
    #elseif canImport(Musl)
    return Musl.close(fd)
    #else
    return Darwin.close(fd)
    #endif
}
