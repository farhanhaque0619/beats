import Foundation
import XCTest
@testable import InkMIME

/// Helpers for building raw message fixtures.
///
/// Fixtures are written as Swift multi-line string literals and converted to CRLF line endings
/// (the wire format) with `crlf`. Non-ASCII bytes in other charsets are spliced in with `bytes`.
enum Raw {
    /// Converts LF line endings to CRLF (leaving existing CRLF alone).
    static func crlf(_ s: String) -> String {
        s.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\n", with: "\r\n")
    }

    /// The fixture as CRLF bytes.
    static func data(_ s: String) -> Data {
        Data(crlf(s).utf8)
    }

    /// Concatenates text (converted to CRLF) and raw byte runs.
    static func bytes(_ pieces: Any...) -> Data {
        var data = Data()
        for piece in pieces {
            if let s = piece as? String {
                data.append(contentsOf: Array(crlf(s).utf8))
            } else if let b = piece as? [UInt8] {
                data.append(contentsOf: b)
            } else if let ints = piece as? [Int] {
                // Untyped literals like [0xE9] arrive as [Int].
                data.append(contentsOf: ints.map { UInt8(truncatingIfNeeded: $0) })
            } else if let d = piece as? Data {
                data.append(d)
            }
        }
        return data
    }
}

/// A small deterministic PRNG for robustness tests.
struct SplitMix64: RandomNumberGenerator {
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

extension Date {
    /// Builds a UTC date for assertions.
    static func utc(_ year: Int, _ month: Int, _ day: Int, _ hour: Int = 0, _ minute: Int = 0, _ second: Int = 0) -> Date {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar.date(from: DateComponents(year: year, month: month, day: day, hour: hour, minute: minute, second: second))!
    }
}

/// Every line of `data` ends with CRLF and no line exceeds `limit` octets (excluding CRLF).
func assertWireFormat(_ data: Data, limit: Int = 998, file: StaticString = #filePath, line: UInt = #line) {
    let bytes = [UInt8](data)
    var lineLength = 0
    for (i, b) in bytes.enumerated() {
        if b == 0x0A {
            XCTAssertTrue(i > 0 && bytes[i - 1] == 0x0D, "bare LF at offset \(i)", file: file, line: line)
            lineLength = 0
        } else if b == 0x0D {
            XCTAssertTrue(i + 1 < bytes.count && bytes[i + 1] == 0x0A, "bare CR at offset \(i)", file: file, line: line)
        } else {
            lineLength += 1
            if lineLength > limit {
                XCTFail("line longer than \(limit) at offset \(i)", file: file, line: line)
                return
            }
        }
    }
}
