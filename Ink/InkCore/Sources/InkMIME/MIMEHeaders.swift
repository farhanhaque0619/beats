import Foundation

/// One header field. `value` is unfolded but otherwise raw (encoded words are not decoded).
public struct MIMEHeader: Hashable, Sendable {
    public var name: String
    public var value: String

    public init(name: String, value: String) {
        self.name = name
        self.value = value
    }
}

/// A header block, in order. Lookups are case-insensitive.
public struct MIMEHeaders: Hashable, Sendable {
    /// Every header in message order, duplicates included.
    public var all: [MIMEHeader]

    public init(_ all: [MIMEHeader] = []) {
        self.all = all
    }

    /// The first header with this name (case-insensitive), raw.
    public subscript(_ name: String) -> String? {
        for header in all where asciiCaseInsensitiveEquals(header.name, name) { return header.value }
        return nil
    }

    /// Every value of the header, in order.
    public func values(_ name: String) -> [String] {
        all.filter { asciiCaseInsensitiveEquals($0.name, name) }.map(\.value)
    }

    /// The first value with RFC 2047 encoded words decoded and whitespace tidied.
    public func decoded(_ name: String) -> String? {
        self[name].map { EncodedWord.decode($0).trimmedWhitespace }
    }

    public func contains(_ name: String) -> Bool { self[name] != nil }

    public var isEmpty: Bool { all.isEmpty }

    /// Appends a header.
    public mutating func add(_ name: String, _ value: String) {
        all.append(MIMEHeader(name: name, value: value))
    }

    /// Parses a header block (everything up to the first empty line; the rest is ignored).
    public static func parse(_ data: Data) -> MIMEHeaders {
        let bytes = [UInt8](data)
        return parseBlock(bytes, range: 0..<bytes.count).headers
    }

    /// Parses a header block given as text.
    public static func parse(_ string: String) -> MIMEHeaders {
        let bytes = Array(string.utf8)
        return parseBlock(bytes, range: 0..<bytes.count).headers
    }

    // MARK: - Parsing

    private struct RawHeader {
        var name: String
        var value: [UInt8]
    }

    /// Parses the header block at the start of `range`. Returns the headers and the index where
    /// the body starts (after the blank line). Tolerates LF-only line endings, an mbox `From `
    /// line, folded lines that start with tabs, broken folding, and a missing blank line.
    static func parseBlock(_ b: [UInt8], range: Range<Int>) -> (headers: MIMEHeaders, bodyStart: Int) {
        var raw: [RawHeader] = []
        var i = range.lowerBound
        let end = range.upperBound
        var firstLine = true

        while i < end {
            let lf = b.firstIndex(of: ASCII.lf, from: i, to: end)
            let lineEnd = lf ?? end
            var contentEnd = lineEnd
            while contentEnd > i && b[contentEnd - 1] == ASCII.cr { contentEnd -= 1 }
            let next = lf.map { $0 + 1 } ?? end

            if contentEnd == i {
                // Blank line: end of headers.
                return (finish(raw), next)
            }

            if isWSP(b[i]) {
                if raw.isEmpty {
                    if firstLine {
                        // Leading whitespace before any header: not a header block.
                        return (MIMEHeaders(), range.lowerBound)
                    }
                } else {
                    appendContinuation(&raw[raw.count - 1].value, b, i, contentEnd)
                }
                firstLine = false
                i = next
                continue
            }

            if let (name, valueStart) = headerName(b, i, contentEnd) {
                var vs = valueStart
                while vs < contentEnd && isWSP(b[vs]) { vs += 1 }
                raw.append(RawHeader(name: name, value: Array(b[vs..<contentEnd])))
            } else if firstLine && b.hasBytes(Array("From ".utf8), at: i) {
                // mbox separator line.
            } else if raw.isEmpty {
                // The first line isn't a header: there is no header block.
                return (MIMEHeaders(), range.lowerBound)
            } else if headerLinesFollow(b, from: next, to: end) {
                // Broken folding (continuation without leading whitespace): glue it on.
                raw[raw.count - 1].value.append(ASCII.space)
                raw[raw.count - 1].value.append(contentsOf: b[i..<contentEnd])
            } else {
                // Missing blank line: the body starts here.
                return (finish(raw), i)
            }
            firstLine = false
            i = next
        }
        return (finish(raw), end)
    }

    private static func appendContinuation(_ value: inout [UInt8], _ b: [UInt8], _ start: Int, _ end: Int) {
        // Unfold: drop the line break, keep one space in place of the folding whitespace.
        var s = start
        while s < end && isWSP(b[s]) { s += 1 }
        if s == end { return }
        if !value.isEmpty { value.append(ASCII.space) }
        value.append(contentsOf: b[s..<end])
    }

    /// Returns the header name and the index after the colon when the line looks like `Name: value`.
    private static func headerName(_ b: [UInt8], _ start: Int, _ end: Int) -> (String, Int)? {
        var i = start
        while i < end {
            let c = b[i]
            if c == ASCII.colon { break }
            // Field names are printable ASCII without spaces; allow "Name :" (space before colon).
            if c <= 32 || c >= 127 {
                if isWSP(c) {
                    var j = i
                    while j < end && isWSP(b[j]) { j += 1 }
                    if j < end && b[j] == ASCII.colon { i = j; break }
                }
                return nil
            }
            i += 1
        }
        guard i < end, b[i] == ASCII.colon else { return nil }
        var nameEnd = i
        while nameEnd > start && isWSP(b[nameEnd - 1]) { nameEnd -= 1 }
        guard nameEnd > start, nameEnd - start <= 128 else { return nil }
        return (String(decoding: b[start..<nameEnd], as: UTF8.self), i + 1)
    }

    /// True when one of the next few lines (before a blank line) is a `Name: value` header.
    private static func headerLinesFollow(_ b: [UInt8], from: Int, to end: Int) -> Bool {
        var i = from
        var checked = 0
        while i < end && checked < 3 {
            let lf = b.firstIndex(of: ASCII.lf, from: i, to: end) ?? end
            var contentEnd = lf
            while contentEnd > i && b[contentEnd - 1] == ASCII.cr { contentEnd -= 1 }
            if contentEnd == i { return false }
            if !isWSP(b[i]), headerName(b, i, contentEnd) != nil { return true }
            checked += 1
            i = lf + 1
        }
        return false
    }

    private static func finish(_ raw: [RawHeader]) -> MIMEHeaders {
        // Raw 8-bit values that aren't UTF-8 are decoded with the charset the message declares.
        var fallback: String?
        if raw.contains(where: { $0.value.contains(where: { $0 >= 0x80 }) }) {
            if let ct = raw.first(where: { asciiCaseInsensitiveEquals($0.name, "Content-Type") }) {
                let value = String(decoding: ct.value, as: UTF8.self)
                if let cs = ContentType.parse(value).parameters["charset"] {
                    let canonical = Charset.canonicalName(cs)
                    if canonical != "us-ascii" && canonical != "utf-8" { fallback = cs }
                }
            }
        }
        var headers: [MIMEHeader] = []
        headers.reserveCapacity(raw.count)
        for h in raw {
            var value = h.value
            while let last = value.last, isASCIIWhitespace(last) { value.removeLast() }
            headers.append(MIMEHeader(name: h.name, value: decodeHeaderBytes(value, fallbackCharset: fallback)))
        }
        return MIMEHeaders(headers)
    }
}
