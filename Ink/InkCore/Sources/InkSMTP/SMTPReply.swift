import Foundation

/// One complete SMTP server reply, possibly spanning several lines (`250-…` / `250 …`).
public struct SMTPReply: Sendable, Equatable, CustomStringConvertible {
    /// The three-digit reply code of the final line.
    public var code: Int
    /// The text of each line after the code and separator, in order (enhanced status codes kept).
    public var lines: [String]

    public init(code: Int, lines: [String]) {
        self.code = code
        self.lines = lines
    }

    /// The RFC 3463 enhanced status code (`5.7.8`) at the start of the first line, if any.
    public var enhancedStatus: String? {
        guard let first = lines.first else { return nil }
        return Self.enhancedStatusPrefix(of: first).map { String(first[$0]) }
    }

    /// 2xx.
    public var isPositiveCompletion: Bool { (200..<300).contains(code) }
    /// 3xx (334 AUTH challenges, 354 for DATA).
    public var isPositiveIntermediate: Bool { (300..<400).contains(code) }
    /// 4xx: try again later.
    public var isTransientFailure: Bool { (400..<500).contains(code) }
    /// 5xx: don't retry as is.
    public var isPermanentFailure: Bool { (500..<600).contains(code) }

    /// The reply text in one line: enhanced status codes removed, whitespace collapsed, and
    /// servers' trace tokens (Gmail's `… - gsmtp` session ids, Outlook's `[HOST.prod.outlook.com …]`)
    /// dropped. Suitable for showing to people.
    public var text: String {
        var parts: [String] = []
        for line in lines {
            var body = Substring(line)
            if let range = Self.enhancedStatusPrefix(of: line) {
                body = line[range.upperBound...]
            }
            let trimmed = body.trimmingCharacters(in: .whitespaces)
            if !trimmed.isEmpty { parts.append(trimmed) }
        }
        let joined = parts.joined(separator: " ")
            .split(whereSeparator: { $0 == " " || $0 == "\t" })
            .joined(separator: " ")
        return Self.stripTraceTokens(joined)
    }

    public var description: String {
        lines.isEmpty ? "\(code)" : lines.map { "\(code) \($0)" }.joined(separator: "\n")
    }

    /// Range of a leading `d.ddd.ddd` status code (plus trailing spaces) in `line`.
    static func enhancedStatusPrefix(of line: String) -> Range<String.Index>? {
        let scalars = Array(line.utf8.prefix(12))
        guard scalars.count >= 5, let cls = scalars.first, cls == UInt8(ascii: "2") || cls == UInt8(ascii: "4") || cls == UInt8(ascii: "5"),
              scalars[1] == UInt8(ascii: ".") else { return nil }
        var index = 2
        var digits = 0
        while index < scalars.count, isDigit(scalars[index]) { index += 1; digits += 1 }
        guard (1...3).contains(digits), index < scalars.count, scalars[index] == UInt8(ascii: ".") else { return nil }
        index += 1
        digits = 0
        while index < scalars.count, isDigit(scalars[index]) { index += 1; digits += 1 }
        guard (1...3).contains(digits) else { return nil }
        // Must be followed by a space or the end of the line, not more token characters.
        if index < scalars.count, scalars[index] != UInt8(ascii: " ") { return nil }
        let start = line.startIndex
        let end = line.utf8.index(start, offsetBy: index)
        return start..<end
    }

    private static func isDigit(_ byte: UInt8) -> Bool { byte >= 0x30 && byte <= 0x39 }

    /// Removes Gmail's `<session-id> - gsmtp` tail and Outlook's bracketed `[…prod.outlook.com …]` trace.
    static func stripTraceTokens(_ text: String) -> String {
        var words = text.split(separator: " ").map(String.init)
        if words.count >= 2, words[words.count - 1] == "gsmtp", words[words.count - 2] == "-" {
            words.removeLast(2)
            if let last = words.last, looksLikeTraceID(last) { words.removeLast() }
        }
        var result = words.joined(separator: " ")
        if result.hasSuffix("]"), let open = result.range(of: " [", options: .backwards) {
            let bracket = String(result[open.upperBound...])
            if SMTPText.contains(bracket, "outlook.com") || SMTPText.contains(bracket, ".prod.") || SMTPText.contains(bracket, "protection.") {
                result = String(result[..<open.lowerBound])
            }
        }
        return result.trimmingCharacters(in: .whitespaces)
    }

    /// Gmail ids look like `d9443c01a7336-2e8f9d2a3cbsm1234567.31` or `a640c23a62f3a-ab1f3ed9e6bsm4.66`.
    private static func looksLikeTraceID(_ word: String) -> Bool {
        let bytes = Array(word.utf8)
        guard bytes.count >= 12 else { return false }
        let allowed = bytes.allSatisfy { byte in
            (byte >= 0x30 && byte <= 0x39) || (byte | 0x20 >= 0x61 && byte | 0x20 <= 0x7A) || byte == UInt8(ascii: "-") || byte == UInt8(ascii: ".")
        }
        let hasDigit = bytes.contains { $0 >= 0x30 && $0 <= 0x39 }
        return hasDigit && allowed && SMTPText.contains(word, "sm")
    }
}

/// Text helpers for protocol strings that behave the same on every platform.
enum SMTPText {
    /// Whether `needle` occurs in `haystack`, compared byte for byte with ASCII letters folded to
    /// lowercase. `String.contains(String)` resolves to a Character-level algorithm on Apple
    /// platforms and to Foundation's search on Linux; reply text is checked with this instead.
    static func contains(_ haystack: String, _ needle: String) -> Bool {
        let source = Array(haystack.utf8).map(lower)
        let target = Array(needle.utf8).map(lower)
        guard !target.isEmpty else { return true }
        guard source.count >= target.count else { return false }
        for start in 0...(source.count - target.count) where source[start] == target[0] {
            if source[start..<(start + target.count)].elementsEqual(target) { return true }
        }
        return false
    }

    private static func lower(_ byte: UInt8) -> UInt8 {
        byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
    }
}

/// Incremental parser for SMTP replies: feed it bytes as they arrive, take complete replies out.
///
/// Tolerates bare LF line endings and replies that change code mid-way (the last line's code wins).
/// Lines longer than `maxLineLength` or replies with more than `maxLines` lines are protocol errors,
/// so a misbehaving server can't make the client buffer without bound.
struct SMTPReplyParser {
    enum ParseError: Error, Equatable {
        case malformedLine(String)
        case lineTooLong
        case tooManyLines
    }

    var maxLineLength = 64 * 1024
    var maxLines = 2_000

    private var buffer: [UInt8] = []
    private var readIndex = 0
    private var pendingLines: [String] = []

    /// True when bytes beyond the last complete reply are buffered.
    var hasBufferedBytes: Bool { readIndex < buffer.count || !pendingLines.isEmpty }

    mutating func append(_ data: Data) {
        if readIndex > 0, readIndex >= buffer.count / 2 {
            buffer.removeFirst(readIndex)
            readIndex = 0
        }
        buffer.append(contentsOf: data)
    }

    /// Discards everything buffered (used right after STARTTLS is refused, never to skip data silently).
    mutating func reset() {
        buffer.removeAll(keepingCapacity: false)
        readIndex = 0
        pendingLines.removeAll()
    }

    /// Returns the next complete reply, or nil if more bytes are needed.
    mutating func nextReply() throws -> SMTPReply? {
        while true {
            guard let newline = buffer[readIndex...].firstIndex(of: 0x0A) else {
                if buffer.count - readIndex > maxLineLength { throw ParseError.lineTooLong }
                return nil
            }
            var end = newline
            // CRLF, and the CR CR LF some servers send, both end the line.
            while end > readIndex, buffer[end - 1] == 0x0D { end -= 1 }
            let line = buffer[readIndex..<end]
            readIndex = newline + 1
            if line.count > maxLineLength { throw ParseError.lineTooLong }
            if line.isEmpty, pendingLines.isEmpty { continue }   // stray blank line between replies

            guard let (code, isLast, text) = Self.split(line) else {
                let excerpt = String(decoding: line.prefix(80), as: UTF8.self)
                throw ParseError.malformedLine(excerpt)
            }
            pendingLines.append(text)
            if pendingLines.count > maxLines { throw ParseError.tooManyLines }
            if isLast {
                let reply = SMTPReply(code: code, lines: pendingLines)
                pendingLines.removeAll()
                return reply
            }
        }
    }

    /// Splits `250-text` / `250 text` / `250` into its parts.
    private static func split(_ line: ArraySlice<UInt8>) -> (code: Int, isLast: Bool, text: String)? {
        guard line.count >= 3 else { return nil }
        let start = line.startIndex
        var code = 0
        for offset in 0..<3 {
            let byte = line[start + offset]
            guard byte >= 0x30, byte <= 0x39 else { return nil }
            code = code * 10 + Int(byte - 0x30)
        }
        guard code >= 200, code < 600 else { return nil }
        if line.count == 3 { return (code, true, "") }
        let separator = line[start + 3]
        let rest = line[(start + 4)...]
        switch separator {
        case UInt8(ascii: "-"):
            return (code, false, String(decoding: rest, as: UTF8.self))
        case UInt8(ascii: " "), UInt8(ascii: "\t"):
            return (code, true, String(decoding: rest, as: UTF8.self))
        default:
            return nil
        }
    }
}
