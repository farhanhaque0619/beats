import Foundation

/// Turns a message into the bytes sent after `DATA`: every line ending becomes CRLF (bare LF and
/// bare CR included), lines starting with `.` get a second dot (RFC 5321 §4.5.2), and `finish()`
/// adds the final CRLF (if the message didn't end with one) and the `.` terminator.
///
/// It works incrementally so a large message can be streamed in chunks without a second full copy.
public struct SMTPDataEncoder: Sendable {
    private var atLineStart = true
    private var pendingCR = false

    public init() {}

    /// Encodes the next chunk of the message.
    public mutating func encode(_ chunk: Data) -> Data {
        var output = [UInt8]()
        output.reserveCapacity(chunk.count + chunk.count / 32 + 4)
        chunk.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw { process(byte, into: &output) }
        }
        return Data(output)
    }

    /// Ends the message: a trailing CRLF if needed, then `.` CRLF.
    public mutating func finish() -> Data {
        var output = [UInt8]()
        if pendingCR {
            output.append(contentsOf: [0x0D, 0x0A])
            pendingCR = false
            atLineStart = true
        }
        if !atLineStart { output.append(contentsOf: [0x0D, 0x0A]) }
        output.append(contentsOf: [0x2E, 0x0D, 0x0A])
        atLineStart = true
        return Data(output)
    }

    /// The whole message encoded in one go, terminator included.
    public static func encode(_ message: Data) -> Data {
        var encoder = SMTPDataEncoder()
        var result = encoder.encode(message)
        result.append(encoder.finish())
        return result
    }

    /// Size of the encoded message without the terminating `.` CRLF (what `SIZE=` declares).
    public static func encodedLength(of message: Data) -> Int {
        var count = 0
        var atLineStart = true
        var pendingCR = false
        message.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            for byte in raw {
                if pendingCR {
                    pendingCR = false
                    count += 2
                    atLineStart = true
                    if byte == 0x0A { continue }
                }
                switch byte {
                case 0x0D:
                    pendingCR = true
                case 0x0A:
                    count += 2
                    atLineStart = true
                default:
                    if atLineStart && byte == 0x2E { count += 1 }
                    count += 1
                    atLineStart = false
                }
            }
        }
        if pendingCR { count += 2; atLineStart = true }
        if !atLineStart { count += 2 }
        return count
    }

    @inline(__always)
    private mutating func process(_ byte: UInt8, into output: inout [UInt8]) {
        if pendingCR {
            pendingCR = false
            output.append(0x0D)
            output.append(0x0A)
            atLineStart = true
            if byte == 0x0A { return }
        }
        switch byte {
        case 0x0D:
            pendingCR = true
        case 0x0A:
            output.append(0x0D)
            output.append(0x0A)
            atLineStart = true
        default:
            if atLineStart && byte == 0x2E { output.append(0x2E) }
            output.append(byte)
            atLineStart = false
        }
    }
}

/// What a message needs from the server's extensions.
struct MessageTraits: Equatable {
    /// Any byte ≥ 0x80 anywhere: needs `BODY=8BITMIME`.
    var hasEightBit: Bool
    /// Any byte ≥ 0x80 in the header section: needs `SMTPUTF8` (RFC 6532 headers).
    var hasEightBitHeaders: Bool

    static func scan(_ message: Data) -> MessageTraits {
        var eightBit = false
        var eightBitHeaders = false
        message.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            var inHeaders = true
            var previous: UInt8 = 0
            var beforePrevious: UInt8 = 0
            for byte in raw {
                if byte >= 0x80 {
                    // The first 8-bit byte answers both questions: it is either in the headers or after them.
                    eightBit = true
                    eightBitHeaders = inHeaders
                    break
                }
                if inHeaders, byte == 0x0A {
                    // Blank line: LF LF or LF CR LF ends the header section.
                    if previous == 0x0A || (previous == 0x0D && beforePrevious == 0x0A) { inHeaders = false }
                }
                beforePrevious = previous
                previous = byte
            }
        }
        return MessageTraits(hasEightBit: eightBit, hasEightBitHeaders: eightBitHeaders)
    }
}

/// Validation and IDNA handling for envelope addresses.
enum SMTPAddress {
    enum Problem: Error, Equatable {
        case empty
        case invalid(String)
    }

    /// Strips whitespace and one pair of angle brackets; rejects anything that could smuggle a
    /// second command (CR, LF, NUL, other controls) or isn't a single mailbox.
    static func clean(_ raw: String, allowEmpty: Bool) throws -> String {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<") && value.hasSuffix(">") && value.count >= 2 {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        if value.isEmpty {
            if allowEmpty { return "" }
            throw Problem.empty
        }
        for scalar in value.unicodeScalars where scalar.value < 0x20 || scalar.value == 0x7F {
            throw Problem.invalid(printable(raw))
        }
        if value.contains("<") || value.contains(">") { throw Problem.invalid(printable(raw)) }
        guard let at = value.lastIndex(of: "@"), at != value.startIndex, value.index(after: at) != value.endIndex else {
            throw Problem.invalid(printable(raw))
        }
        let local = value[..<at]
        let domain = value[value.index(after: at)...]
        let quotedLocal = local.hasPrefix("\"") && local.hasSuffix("\"") && local.count >= 2
        if !quotedLocal, local.contains(where: { $0 == " " || $0 == "\t" || $0 == "@" }) { throw Problem.invalid(printable(raw)) }
        if domain.contains(where: { $0 == " " || $0 == "\t" || $0 == "@" }) { throw Problem.invalid(printable(raw)) }
        return value
    }

    static func isASCII(_ value: String) -> Bool { value.utf8.allSatisfy { $0 < 0x80 } }

    /// The address with a non-ASCII domain converted to its `xn--` form, or nil when the local
    /// part itself is non-ASCII (only SMTPUTF8 can carry that).
    static func asciiForm(_ address: String) -> String? {
        if isASCII(address) { return address }
        guard let at = address.lastIndex(of: "@") else { return nil }
        let local = String(address[..<at])
        guard isASCII(local) else { return nil }
        let domain = String(address[address.index(after: at)...])
        guard let ascii = Punycode.idnaDomain(domain) else { return nil }
        return "\(local)@\(ascii)"
    }

    private static func printable(_ raw: String) -> String {
        let cleaned = raw.unicodeScalars.map { $0.value < 0x20 || $0.value == 0x7F ? " " : String($0) }.joined()
        return cleaned.trimmingCharacters(in: .whitespaces)
    }
}

/// RFC 3492 Punycode, enough for turning internationalised domain labels into `xn--` labels.
enum Punycode {
    private static let base = 36, tMin = 1, tMax = 26, skew = 38, damp = 700, initialBias = 72, initialN = 128

    /// `bücher.example` → `xn--bcher-kva.example`. Labels are NFC-normalised and lowercased first.
    static func idnaDomain(_ domain: String) -> String? {
        let normalized = domain.precomposedStringWithCanonicalMapping.lowercased()
        let separators: Set<Character> = [".", "\u{3002}", "\u{FF0E}", "\u{FF61}"]
        var labels: [String] = []
        var current = ""
        for character in normalized {
            if separators.contains(character) { labels.append(current); current = "" } else { current.append(character) }
        }
        labels.append(current)
        var output: [String] = []
        for label in labels {
            if label.unicodeScalars.allSatisfy({ $0.isASCII }) {
                output.append(label)
            } else {
                guard let encoded = encode(label) else { return nil }
                let full = "xn--" + encoded
                guard full.utf8.count <= 63 else { return nil }
                output.append(full)
            }
        }
        return output.joined(separator: ".")
    }

    /// Encodes one label (without the `xn--` prefix).
    static func encode(_ input: String) -> String? {
        let codePoints = input.unicodeScalars.map { Int($0.value) }
        var output: [UInt8] = codePoints.filter { $0 < 0x80 }.map { UInt8($0) }
        let basicCount = output.count
        var handled = basicCount
        if basicCount > 0 { output.append(UInt8(ascii: "-")) }
        var n = initialN
        var delta = 0
        var bias = initialBias
        while handled < codePoints.count {
            guard let m = codePoints.filter({ $0 >= n }).min() else { return nil }
            let (product, overflow) = (m - n).multipliedReportingOverflow(by: handled + 1)
            guard !overflow else { return nil }
            delta += product
            n = m
            for c in codePoints {
                if c < n { delta += 1 }
                if c == n {
                    var q = delta
                    var k = base
                    while true {
                        let t = k <= bias ? tMin : (k >= bias + tMax ? tMax : k - bias)
                        if q < t { break }
                        output.append(digit(t + (q - t) % (base - t)))
                        q = (q - t) / (base - t)
                        k += base
                    }
                    output.append(digit(q))
                    bias = adapt(delta, numPoints: handled + 1, firstTime: handled == basicCount)
                    delta = 0
                    handled += 1
                }
            }
            delta += 1
            n += 1
        }
        return String(decoding: output, as: UTF8.self)
    }

    private static func digit(_ value: Int) -> UInt8 {
        value < 26 ? UInt8(value + 97) : UInt8(value - 26 + 48)
    }

    private static func adapt(_ delta: Int, numPoints: Int, firstTime: Bool) -> Int {
        var delta = firstTime ? delta / damp : delta / 2
        delta += delta / numPoints
        var k = 0
        while delta > ((base - tMin) * tMax) / 2 {
            delta /= base - tMin
            k += base
        }
        return k + (base - tMin + 1) * delta / (delta + skew)
    }
}
