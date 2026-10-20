import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import InkModel

/// Small URLSession helpers shared by autodiscovery and OAuth. Completion-handler based so they
/// behave the same on Apple platforms and swift-corelibs-foundation, and cancellable.
enum HTTP {
    struct Response: Sendable {
        var status: Int
        var data: Data
        var contentType: String?
    }

    /// Default limit on response bodies: config files and token replies are a few kilobytes.
    static let defaultMaxBytes = 512 * 1024

    /// Performs `request`. Throws `URLError` for transport failures and `CancellationError` when
    /// the task is cancelled. Bodies over `maxBytes` throw `URLError(.dataLengthExceedsMaximum)`.
    static func perform(_ request: URLRequest, session: URLSession, maxBytes: Int = defaultMaxBytes) async throws -> Response {
        try Task.checkCancellation()
        let box = TaskBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Response, Error>) in
                let task = session.dataTask(with: request) { data, response, error in
                    if let error {
                        continuation.resume(throwing: error)
                        return
                    }
                    let http = response as? HTTPURLResponse
                    let body = data ?? Data()
                    if body.count > maxBytes {
                        continuation.resume(throwing: URLError(.dataLengthExceedsMaximum))
                        return
                    }
                    let contentType = http?.value(forHTTPHeaderField: "Content-Type")
                    continuation.resume(returning: Response(status: http?.statusCode ?? 0, data: body, contentType: contentType))
                }
                box.set(task)
                task.resume()
            }
        } onCancel: {
            box.cancel()
        }
    }

    /// `application/x-www-form-urlencoded` body for `fields`, in order.
    static func formBody(_ fields: [(String, String)]) -> Data {
        Data(fields.map { "\(percentEncode($0.0))=\(percentEncode($0.1))" }.joined(separator: "&").utf8)
    }

    /// RFC 3986 percent-encoding that leaves only unreserved characters (`A-Z a-z 0-9 - . _ ~`) as is.
    /// Unlike `URLComponents` it encodes `+`, `&`, `=` and `/`, so values survive form decoding.
    static func percentEncode(_ value: String) -> String {
        var result = ""
        result.reserveCapacity(value.utf8.count)
        for byte in value.utf8 {
            switch byte {
            case UInt8(ascii: "A")...UInt8(ascii: "Z"), UInt8(ascii: "a")...UInt8(ascii: "z"),
                 UInt8(ascii: "0")...UInt8(ascii: "9"), UInt8(ascii: "-"), UInt8(ascii: "."), UInt8(ascii: "_"), UInt8(ascii: "~"):
                result.unicodeScalars.append(Unicode.Scalar(byte))
            default:
                let hex = String(byte, radix: 16, uppercase: true)
                result += "%" + (hex.count == 1 ? "0" + hex : hex)
            }
        }
        return result
    }

    /// Maps a transport failure to a `MailError` for showing to the user.
    static func mailError(for error: Error) -> MailError {
        if let mailError = error as? MailError { return mailError }
        if error is CancellationError { return .cancelled }
        if let urlError = error as? URLError {
            switch urlError.code {
            case .timedOut: return .timeout
            case .cancelled: return .cancelled
            case .notConnectedToInternet, .networkConnectionLost:
                return .connectionFailed("You appear to be offline.")
            case .cannotFindHost, .dnsLookupFailed:
                return .connectionFailed("The server's name couldn't be found.")
            case .secureConnectionFailed, .serverCertificateUntrusted, .serverCertificateHasBadDate,
                 .serverCertificateNotYetValid, .serverCertificateHasUnknownRoot:
                return .tlsFailed("The server's certificate wasn't accepted.")
            default:
                return .connectionFailed(urlError.localizedDescription)
            }
        }
        return .connectionFailed(error.localizedDescription)
    }
}

/// Holds the data task so the cancellation handler (which may run first) can cancel it.
private final class TaskBox: @unchecked Sendable {
    private let lock = NSLock()
    private var task: URLSessionDataTask?
    private var cancelled = false

    func set(_ task: URLSessionDataTask) {
        lock.lock()
        self.task = task
        let shouldCancel = cancelled
        lock.unlock()
        if shouldCancel { task.cancel() }
    }

    func cancel() {
        lock.lock()
        cancelled = true
        let task = self.task
        lock.unlock()
        task?.cancel()
    }
}
