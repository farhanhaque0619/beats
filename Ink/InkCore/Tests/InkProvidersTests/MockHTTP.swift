import Foundation
#if canImport(FoundationNetworking)
import FoundationNetworking
#endif
import XCTest

/// A canned HTTP server behind `URLProtocol`, so URLSession-based code runs without a network.
///
/// Routes match on the start of the URL string; the first matching route wins. Unmatched
/// requests get a 404. Every request is recorded (with its body, read from the stream on Linux).
final class MockHTTP: @unchecked Sendable {
    struct Reply {
        var status: Int
        var body: Data
        var headers: [String: String]
        var error: URLError?

        static func ok(_ body: String, contentType: String = "application/xml") -> Reply {
            Reply(status: 200, body: Data(body.utf8), headers: ["Content-Type": contentType], error: nil)
        }
        static func json(_ body: String, status: Int = 200) -> Reply {
            Reply(status: status, body: Data(body.utf8), headers: ["Content-Type": "application/json"], error: nil)
        }
        static func status(_ code: Int, _ body: String = "") -> Reply {
            Reply(status: code, body: Data(body.utf8), headers: ["Content-Type": "text/html"], error: nil)
        }
        static func failure(_ code: URLError.Code) -> Reply {
            Reply(status: 0, body: Data(), headers: [:], error: URLError(code))
        }
    }

    struct Recorded {
        var url: String
        var method: String
        var headers: [String: String]
        var body: Data
    }

    private static let lock = NSLock()
    nonisolated(unsafe) private static var current: MockHTTP?

    private let lock = NSLock()
    private var routes: [(prefix: String, reply: Reply)] = []
    private var recorded: [Recorded] = []

    let session: URLSession

    init() {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.protocolClasses = [MockURLProtocol.self]
        configuration.timeoutIntervalForRequest = 5
        session = URLSession(configuration: configuration)
        MockHTTP.lock.withLock { MockHTTP.current = self }
    }

    func route(_ prefix: String, _ reply: Reply) {
        lock.withLock { routes.append((prefix, reply)) }
    }

    var requests: [Recorded] { lock.withLock { recorded } }
    var requestedURLs: [String] { requests.map(\.url) }

    static func handle(_ request: URLRequest) -> Reply {
        guard let server = lock.withLock({ current }) else { return .status(404) }
        return server.respond(to: request)
    }

    private func respond(to request: URLRequest) -> Reply {
        let url = request.url?.absoluteString ?? ""
        var body = request.httpBody ?? Data()
        if body.isEmpty, let stream = request.httpBodyStream {
            stream.open()
            var buffer = [UInt8](repeating: 0, count: 4096)
            while stream.hasBytesAvailable {
                let count = stream.read(&buffer, maxLength: buffer.count)
                if count <= 0 { break }
                body.append(contentsOf: buffer[0..<count])
            }
            stream.close()
        }
        return lock.withLock {
            recorded.append(Recorded(url: url, method: request.httpMethod ?? "GET",
                                     headers: request.allHTTPHeaderFields ?? [:], body: body))
            return routes.first { url.hasPrefix($0.prefix) }?.reply ?? .status(404)
        }
    }
}

final class MockURLProtocol: URLProtocol {
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }

    override func startLoading() {
        let reply = MockHTTP.handle(request)
        if let error = reply.error {
            client?.urlProtocol(self, didFailWithError: error)
            return
        }
        guard let url = request.url,
              let response = HTTPURLResponse(url: url, statusCode: reply.status, httpVersion: "HTTP/1.1", headerFields: reply.headers) else {
            client?.urlProtocol(self, didFailWithError: URLError(.badURL))
            return
        }
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        if !reply.body.isEmpty { client?.urlProtocol(self, didLoad: reply.body) }
        client?.urlProtocolDidFinishLoading(self)
    }

    override func stopLoading() {}
}

/// Decodes an `application/x-www-form-urlencoded` body.
func formFields(_ data: Data) -> [String: String] {
    var fields: [String: String] = [:]
    for pair in String(decoding: data, as: UTF8.self).split(separator: "&") {
        let parts = pair.split(separator: "=", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        let key = parts[0].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[0]
        let value = parts.count > 1 ? (parts[1].replacingOccurrences(of: "+", with: " ").removingPercentEncoding ?? parts[1]) : ""
        fields[key] = value
    }
    return fields
}

/// Query items of a URL as a dictionary (first value wins).
func queryItems(_ url: URL) -> [String: String] {
    var result: [String: String] = [:]
    for item in URLComponents(url: url, resolvingAgainstBaseURL: false)?.queryItems ?? [] where result[item.name] == nil {
        result[item.name] = item.value ?? ""
    }
    return result
}
