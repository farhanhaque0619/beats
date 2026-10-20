import Foundation

/// Byte constants used by the parser and encoder.
enum Byte {
    static let space: UInt8 = 0x20
    static let tab: UInt8 = 0x09
    static let cr: UInt8 = 0x0D
    static let lf: UInt8 = 0x0A
    static let quote: UInt8 = 0x22
    static let backslash: UInt8 = 0x5C
    static let openParen: UInt8 = 0x28
    static let closeParen: UInt8 = 0x29
    static let openBracket: UInt8 = 0x5B
    static let closeBracket: UInt8 = 0x5D
    static let openBrace: UInt8 = 0x7B
    static let closeBrace: UInt8 = 0x7D
    static let plus: UInt8 = 0x2B
    static let star: UInt8 = 0x2A
    static let tilde: UInt8 = 0x7E
    static let zero: UInt8 = 0x30
    static let nine: UInt8 = 0x39

    @inline(__always) static func isDigit(_ byte: UInt8) -> Bool { byte >= zero && byte <= nine }
}

/// Text decoding for protocol strings: UTF-8 when valid, else Latin-1 (which maps every byte).
enum IMAPText {
    static func decode(_ bytes: [UInt8]) -> String {
        if bytes.allSatisfy({ $0 < 0x80 }) { return String(decoding: bytes, as: UTF8.self) }
        if let text = String(bytes: bytes, encoding: .utf8) { return text }
        return latin1(bytes)
    }

    static func decode(_ data: Data) -> String {
        decode([UInt8](data))
    }

    /// Whether `needle` occurs in `haystack`, compared byte for byte (ASCII letters ignoring
    /// case). `String.contains(String)` resolves to different algorithms on Apple platforms
    /// (Character-level) and Linux (Foundation), so protocol text uses this instead.
    static func contains(_ haystack: String, _ needle: String, ignoringASCIICase: Bool = false) -> Bool {
        let source = Array(haystack.utf8)
        let target = Array(needle.utf8)
        guard !target.isEmpty else { return true }
        guard source.count >= target.count else { return false }
        func fold(_ byte: UInt8) -> UInt8 {
            ignoringASCIICase && byte >= 0x41 && byte <= 0x5A ? byte + 0x20 : byte
        }
        for start in 0...(source.count - target.count) {
            var offset = 0
            while offset < target.count, fold(source[start + offset]) == fold(target[offset]) { offset += 1 }
            if offset == target.count { return true }
        }
        return false
    }

    static func latin1(_ bytes: [UInt8]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for byte in bytes { scalars.append(Unicode.Scalar(byte)) }
        return String(scalars)
    }
}

/// A generic protocol value: atom, string (quoted or literal), NIL, or parenthesised list.
/// Responses are tokenized into these first, then interpreted, which keeps interpretation
/// tolerant of odd spacing, missing fields and extension data.
indirect enum IMAPValue: Hashable, Sendable {
    case atom(String)
    case string(Data)
    case nilValue
    case list([IMAPValue])

    /// Atom or string as text; nil for NIL and lists.
    var text: String? {
        switch self {
        case .atom(let atom): return atom
        case .string(let data): return IMAPText.decode(data)
        case .nilValue, .list: return nil
        }
    }

    /// An `nstring`: strings decode to text, NIL is nil. Atoms (sent by sloppy servers) pass through.
    var nstring: String? { text }

    var data: Data? {
        switch self {
        case .string(let data): return data
        case .atom(let atom): return Data(atom.utf8)
        case .nilValue, .list: return nil
        }
    }

    var list: [IMAPValue]? {
        if case .list(let items) = self { return items }
        return nil
    }

    var isNil: Bool {
        if case .nilValue = self { return true }
        return false
    }

    /// A non-negative number written as an atom (or, from sloppy servers, a quoted string).
    var uint64: UInt64? {
        guard let text, !text.isEmpty, text.utf8.count <= 20, text.utf8.allSatisfy(Byte.isDigit) else { return nil }
        return UInt64(text)
    }

    var uint32: UInt32? { uint64.flatMap { UInt32(exactly: $0) } }

    var int: Int? { uint64.flatMap { Int(exactly: $0) } }

    /// The texts of a list's atoms and strings (`(\Seen "a b")` → `["\\Seen", "a b"]`).
    var stringList: [String]? {
        guard case .list(let items) = self else { return nil }
        return items.compactMap(\.text)
    }
}

/// A cursor over the bytes of one complete response.
struct IMAPReader {
    let bytes: [UInt8]
    var position: Int
    let end: Int

    /// Nesting limit for lists; deeper input is skipped so hostile data can't blow the stack.
    static let maxDepth = 48

    init(bytes: [UInt8], start: Int = 0, end: Int? = nil) {
        self.bytes = bytes
        self.position = start
        self.end = min(end ?? bytes.count, bytes.count)
    }

    var isAtEnd: Bool { position >= end }

    /// True at the end of the line (CR, LF or the end of input).
    var isAtLineEnd: Bool {
        guard position < end else { return true }
        let byte = bytes[position]
        return byte == Byte.cr || byte == Byte.lf
    }

    func peek() -> UInt8? { position < end ? bytes[position] : nil }

    mutating func skipSpaces() {
        while position < end, bytes[position] == Byte.space || bytes[position] == Byte.tab { position += 1 }
    }

    /// Reads up to the next space, CR/LF, `(` or `[` (tags, status words, response names).
    mutating func readWord() -> String {
        let start = position
        while position < end {
            let byte = bytes[position]
            if byte == Byte.space || byte == Byte.cr || byte == Byte.lf || byte == Byte.openParen || byte == Byte.openBracket { break }
            position += 1
        }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    /// Reads a run of digits as a number; nil (and nothing consumed) if there isn't one.
    mutating func readNumber() -> UInt64? {
        var value: UInt64 = 0
        var index = position
        while index < end, Byte.isDigit(bytes[index]) {
            let (multiplied, overflow1) = value.multipliedReportingOverflow(by: 10)
            let (added, overflow2) = multiplied.addingReportingOverflow(UInt64(bytes[index] - Byte.zero))
            if overflow1 || overflow2 { return nil }
            value = added
            index += 1
        }
        guard index > position else { return nil }
        position = index
        return value
    }

    /// The rest of the line as text, without the line break, trimmed.
    mutating func readRestOfLine() -> String {
        skipSpaces()
        let start = position
        while position < end, bytes[position] != Byte.cr, bytes[position] != Byte.lf { position += 1 }
        var stop = position
        while stop > start, bytes[stop - 1] == Byte.space || bytes[stop - 1] == Byte.tab { stop -= 1 }
        return IMAPText.decode(Array(bytes[start..<stop]))
    }

    /// Reads one value. Returns nil at the end of the line or at a `)` (not consumed).
    mutating func readValue(depth: Int = 0) -> IMAPValue? {
        skipSpaces()
        guard position < end else { return nil }
        switch bytes[position] {
        case Byte.cr, Byte.lf, Byte.closeParen:
            return nil
        case Byte.openParen:
            position += 1
            if depth >= Self.maxDepth {
                skipBalancedList()
                return .list([])
            }
            return .list(readListItems(depth: depth + 1))
        case Byte.quote:
            return .string(readQuoted())
        case Byte.openBrace:
            if let literal = readLiteral() { return .string(literal) }
        case Byte.tilde:
            if position + 1 < end, bytes[position + 1] == Byte.openBrace {
                let saved = position
                position += 1
                if let literal = readLiteral() { return .string(literal) }
                position = saved
            }
        default:
            break
        }
        let atom = readAtom()
        if atom.utf8.count == 3, atom.uppercased() == "NIL" { return .nilValue }
        return .atom(atom)
    }

    /// Reads list items after the opening `(`, through the matching `)`. An unterminated list
    /// ends at the end of the line.
    mutating func readListItems(depth: Int) -> [IMAPValue] {
        var items: [IMAPValue] = []
        while true {
            skipSpaces()
            guard position < end else { return items }
            let byte = bytes[position]
            if byte == Byte.closeParen {
                position += 1
                return items
            }
            if byte == Byte.cr || byte == Byte.lf { return items }
            if let value = readValue(depth: depth) {
                items.append(value)
            } else {
                position += 1
            }
        }
    }

    /// Reads values until the end of the line, skipping stray `)`.
    mutating func readValuesToLineEnd() -> [IMAPValue] {
        var values: [IMAPValue] = []
        while true {
            skipSpaces()
            guard !isAtLineEnd else { return values }
            if let value = readValue() {
                values.append(value)
            } else {
                position += 1
            }
        }
    }

    /// An atom-like token. A fetch attribute's section is kept whole, spaces and parentheses
    /// included, so `BODY[HEADER.FIELDS (A B)]<0>` is one token; elsewhere brackets are ordinary
    /// characters (`[Gmail]/Sent`), so a stray `[` can't swallow the rest of the line.
    /// A literal announced right after the token with no space (`BODY[1]<0>{22}`, as GreenMail
    /// sends it) ends the token, so the literal is read as the next value.
    mutating func readAtom() -> String {
        let start = position
        while position < end {
            let byte = bytes[position]
            if byte == Byte.space || byte == Byte.tab || byte == Byte.openParen || byte == Byte.closeParen
                || byte == Byte.cr || byte == Byte.lf || byte == Byte.quote {
                break
            }
            if position > start, byte == Byte.openBrace || byte == Byte.tilde, isLiteralHeader(at: position) {
                break
            }
            if byte == Byte.openBracket, Self.isSectionAttribute(bytes, from: start, to: position) {
                var index = position + 1
                while index < end, bytes[index] != Byte.closeBracket, bytes[index] != Byte.cr, bytes[index] != Byte.lf { index += 1 }
                if index < end, bytes[index] == Byte.closeBracket {
                    position = index + 1
                    continue
                }
            }
            position += 1
        }
        if position == start, position < end { position += 1 }
        return String(decoding: bytes[start..<position], as: UTF8.self)
    }

    private static let sectionAttributes: [[UInt8]] = ["BODY", "BODY.PEEK", "BINARY", "BINARY.PEEK", "BINARY.SIZE"].map { Array($0.utf8) }

    /// Whether `bytes[from..<to]` is a fetch attribute that takes a `[section]` (case-insensitive).
    static func isSectionAttribute(_ bytes: [UInt8], from start: Int, to end: Int) -> Bool {
        let length = end - start
        guard length >= 4, length <= 11 else { return false }
        return sectionAttributes.contains { name in
            guard name.count == length else { return false }
            for offset in 0..<length {
                var byte = bytes[start + offset]
                if byte >= 0x61, byte <= 0x7A { byte -= 0x20 }
                if byte != name[offset] { return false }
            }
            return true
        }
    }

    /// A quoted string with `\"` and `\\` escapes. Stops at a line break if unterminated.
    mutating func readQuoted() -> Data {
        position += 1  // opening quote
        let start = position
        // Fast path: no escapes.
        while position < end {
            let byte = bytes[position]
            if byte == Byte.quote {
                let data = Data(bytes[start..<position])
                position += 1
                return data
            }
            if byte == Byte.backslash || byte == Byte.cr || byte == Byte.lf { break }
            position += 1
        }
        var output = [UInt8](bytes[start..<position])
        while position < end {
            let byte = bytes[position]
            if byte == Byte.quote {
                position += 1
                break
            }
            if byte == Byte.cr || byte == Byte.lf { break }
            if byte == Byte.backslash, position + 1 < end, bytes[position + 1] != Byte.cr, bytes[position + 1] != Byte.lf {
                output.append(bytes[position + 1])
                position += 2
                continue
            }
            output.append(byte)
            position += 1
        }
        return Data(output)
    }

    /// Whether a literal header (`{n}`, `{n+}` or literal8 `~{n}`) followed by the line break
    /// starts at `index`. Atoms can't contain `{`, so this only ever ends a malformed token.
    func isLiteralHeader(at index: Int) -> Bool {
        var cursor = index
        if cursor < end, bytes[cursor] == Byte.tilde { cursor += 1 }
        guard cursor < end, bytes[cursor] == Byte.openBrace else { return false }
        cursor += 1
        var digits = 0
        while cursor < end, Byte.isDigit(bytes[cursor]) {
            digits += 1
            cursor += 1
        }
        guard digits > 0, digits <= 12 else { return false }
        if cursor < end, bytes[cursor] == Byte.plus { cursor += 1 }
        guard cursor < end, bytes[cursor] == Byte.closeBrace else { return false }
        cursor += 1
        if cursor < end, bytes[cursor] == Byte.cr { cursor += 1 }
        return cursor < end && bytes[cursor] == Byte.lf
    }

    /// `{n}` / `{n+}` + CRLF + n bytes. Returns nil (consuming nothing) if this isn't a literal.
    mutating func readLiteral() -> Data? {
        guard position < end, bytes[position] == Byte.openBrace else { return nil }
        var index = position + 1
        var length = 0
        var digits = 0
        while index < end, Byte.isDigit(bytes[index]) {
            length = length * 10 + Int(bytes[index] - Byte.zero)
            digits += 1
            index += 1
            if digits > 12 { return nil }
        }
        guard digits > 0 else { return nil }
        if index < end, bytes[index] == Byte.plus { index += 1 }
        guard index < end, bytes[index] == Byte.closeBrace else { return nil }
        index += 1
        if index < end, bytes[index] == Byte.cr { index += 1 }
        guard index < end, bytes[index] == Byte.lf else { return nil }
        index += 1
        let available = max(0, min(length, end - index))
        let data = Data(bytes[index..<(index + available)])
        position = index + available
        return data
    }

    /// Skips the rest of a list whose `(` was consumed, honouring strings and literals.
    mutating func skipBalancedList() {
        var depth = 1
        while position < end, depth > 0 {
            let byte = bytes[position]
            switch byte {
            case Byte.openParen:
                depth += 1
                position += 1
            case Byte.closeParen:
                depth -= 1
                position += 1
            case Byte.quote:
                _ = readQuoted()
            case Byte.openBrace:
                if readLiteral() == nil { position += 1 }
            case Byte.cr, Byte.lf:
                return
            default:
                position += 1
            }
        }
    }

    /// Index of the `]` closing a response code that starts at `position` (`[`), honouring
    /// quotes and parentheses; nil if it isn't closed on this line.
    func responseCodeEnd() -> Int? {
        var index = position + 1
        var depth = 0
        var inQuote = false
        while index < end {
            let byte = bytes[index]
            if byte == Byte.cr || byte == Byte.lf { return nil }
            if inQuote {
                if byte == Byte.backslash {
                    index += 2
                    continue
                }
                if byte == Byte.quote { inQuote = false }
            } else {
                switch byte {
                case Byte.quote: inQuote = true
                case Byte.openParen: depth += 1
                case Byte.closeParen: depth = max(0, depth - 1)
                case Byte.closeBracket where depth == 0: return index
                default: break
                }
            }
            index += 1
        }
        return nil
    }
}
