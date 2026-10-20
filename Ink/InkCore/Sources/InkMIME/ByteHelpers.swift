import Foundation

// Small byte-level helpers shared by the parsers. Everything here works on ASCII bytes;
// the parsers never assume the input is valid UTF-8.

enum ASCII {
    static let tab: UInt8 = 0x09
    static let lf: UInt8 = 0x0A
    static let cr: UInt8 = 0x0D
    static let space: UInt8 = 0x20
    static let quote: UInt8 = 0x22
    static let hash: UInt8 = 0x23
    static let percent: UInt8 = 0x25
    static let amp: UInt8 = 0x26
    static let apostrophe: UInt8 = 0x27
    static let lparen: UInt8 = 0x28
    static let rparen: UInt8 = 0x29
    static let star: UInt8 = 0x2A
    static let comma: UInt8 = 0x2C
    static let dash: UInt8 = 0x2D
    static let dot: UInt8 = 0x2E
    static let slash: UInt8 = 0x2F
    static let colon: UInt8 = 0x3A
    static let semicolon: UInt8 = 0x3B
    static let lt: UInt8 = 0x3C
    static let equals: UInt8 = 0x3D
    static let gt: UInt8 = 0x3E
    static let question: UInt8 = 0x3F
    static let at: UInt8 = 0x40
    static let backslash: UInt8 = 0x5C
    static let underscore: UInt8 = 0x5F
    static let bang: UInt8 = 0x21
}

@inline(__always)
func isWSP(_ b: UInt8) -> Bool { b == ASCII.space || b == ASCII.tab }

@inline(__always)
func isASCIIWhitespace(_ b: UInt8) -> Bool {
    b == ASCII.space || b == ASCII.tab || b == ASCII.lf || b == ASCII.cr || b == 0x0C || b == 0x0B
}

@inline(__always)
func asciiLower(_ b: UInt8) -> UInt8 { (b >= 0x41 && b <= 0x5A) ? b | 0x20 : b }

@inline(__always)
func isASCIILetter(_ b: UInt8) -> Bool { (b >= 0x41 && b <= 0x5A) || (b >= 0x61 && b <= 0x7A) }

@inline(__always)
func isASCIIDigit(_ b: UInt8) -> Bool { b >= 0x30 && b <= 0x39 }

@inline(__always)
func hexValue(_ b: UInt8) -> UInt8? {
    switch b {
    case 0x30...0x39: return b - 0x30
    case 0x41...0x46: return b - 0x41 + 10
    case 0x61...0x66: return b - 0x61 + 10
    default: return nil
    }
}

let upperHexDigits: [UInt8] = Array("0123456789ABCDEF".utf8)

/// True when `bytes` is well-formed UTF-8 (no overlongs, surrogates or code points above U+10FFFF).
func isValidUTF8<C: Collection>(_ bytes: C) -> Bool where C.Element == UInt8, C.Index == Int {
    utf8Validation(bytes).isValid
}

struct UTF8Validation {
    /// Every byte is part of a well-formed sequence.
    var isValid: Bool
    /// At least one well-formed multi-byte sequence was seen.
    var hasMultibyte: Bool
    /// The only problem is an incomplete sequence at the very end (a truncated fetch).
    var onlyTruncatedTail: Bool
    /// Index where the incomplete tail starts, when `onlyTruncatedTail`.
    var validPrefixEnd: Int
}

func utf8Validation<C: Collection>(_ bytes: C) -> UTF8Validation where C.Element == UInt8, C.Index == Int {
    var i = bytes.startIndex
    let end = bytes.endIndex
    var hasMultibyte = false
    while i < end {
        let b0 = bytes[i]
        if b0 < 0x80 { i += 1; continue }
        let need: Int
        var lower: UInt8 = 0x80
        var upper: UInt8 = 0xBF
        switch b0 {
        case 0xC2...0xDF: need = 1
        case 0xE0: need = 2; lower = 0xA0
        case 0xE1...0xEC, 0xEE, 0xEF: need = 2
        case 0xED: need = 2; upper = 0x9F
        case 0xF0: need = 3; lower = 0x90
        case 0xF1...0xF3: need = 3
        case 0xF4: need = 3; upper = 0x8F
        default:
            return UTF8Validation(isValid: false, hasMultibyte: hasMultibyte, onlyTruncatedTail: false, validPrefixEnd: i)
        }
        var j = 1
        while j <= need {
            let k = i + j
            if k >= end {
                // Sequence runs off the end: a truncated (partial) fetch.
                return UTF8Validation(isValid: false, hasMultibyte: hasMultibyte, onlyTruncatedTail: true, validPrefixEnd: i)
            }
            let b = bytes[k]
            let lo: UInt8 = j == 1 ? lower : 0x80
            let hi: UInt8 = j == 1 ? upper : 0xBF
            if b < lo || b > hi {
                return UTF8Validation(isValid: false, hasMultibyte: hasMultibyte, onlyTruncatedTail: false, validPrefixEnd: i)
            }
            j += 1
        }
        hasMultibyte = true
        i += need + 1
    }
    return UTF8Validation(isValid: true, hasMultibyte: hasMultibyte, onlyTruncatedTail: false, validPrefixEnd: end)
}

/// Decodes bytes as UTF-8 when valid, else with the given fallback charset (Windows-1252 by default).
/// Used for raw 8-bit header values (RFC 6532 allows UTF-8; older mailers send Latin-1 and friends).
func decodeHeaderBytes<C: Collection>(_ bytes: C, fallbackCharset: String?) -> String where C.Element == UInt8, C.Index == Int {
    var ascii = true
    for b in bytes where b >= 0x80 { ascii = false; break }
    if ascii { return String(decoding: bytes, as: UTF8.self) }
    if isValidUTF8(bytes) { return String(decoding: bytes, as: UTF8.self) }
    return Charset.decode(Data(bytes), charset: fallbackCharset ?? "windows-1252")
}

/// Case-insensitive comparison of two ASCII strings without allocating.
func asciiCaseInsensitiveEquals(_ a: String, _ b: String) -> Bool {
    let au = a.utf8, bu = b.utf8
    guard au.count == bu.count else { return false }
    var ai = au.makeIterator(), bi = bu.makeIterator()
    while let x = ai.next(), let y = bi.next() {
        if asciiLower(x) != asciiLower(y) { return false }
    }
    return true
}

extension String {
    /// Lowercases ASCII letters only (header names, MIME tokens). Cheaper and locale-independent.
    var asciiLowercased: String {
        var needs = false
        for b in utf8 where b >= 0x41 && b <= 0x5A { needs = true; break }
        guard needs else { return self }
        return String(decoding: utf8.map(asciiLower), as: UTF8.self)
    }

    /// Trims spaces, tabs, CR and LF.
    var trimmedWhitespace: String {
        trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Converts CRLF and lone CR line endings to LF.
    var normalizedNewlines: String {
        guard contains("\r") else { return self }
        return replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n")
    }

    /// Replaces runs of whitespace (including newlines) with single spaces and trims the ends.
    var collapsingWhitespace: String {
        var out = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in unicodeScalars {
            if scalar.properties.isWhitespace || scalar == "\u{00A0}" {
                pendingSpace = !out.isEmpty
                continue
            }
            if pendingSpace { out.append(" "); pendingSpace = false }
            out.append(scalar)
        }
        return String(out)
    }
}

extension Array where Element == UInt8 {
    /// Index of the first occurrence of `needle` at or after `from`, before `to`.
    func firstIndex(of needle: UInt8, from: Int, to: Int) -> Int? {
        if from >= to { return nil }
        return withUnsafeBufferPointer { buf -> Int? in
            var i = from
            while i < to {
                if buf[i] == needle { return i }
                i += 1
            }
            return nil
        }
    }

    /// True when the bytes at `index` equal `prefix`.
    func hasBytes(_ prefix: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + prefix.count <= count else { return false }
        var i = 0
        while i < prefix.count {
            if self[index + i] != prefix[i] { return false }
            i += 1
        }
        return true
    }

    /// Like `hasBytes` but ASCII case-insensitive; `prefix` must be lowercase.
    func hasBytesCaseInsensitive(_ prefix: [UInt8], at index: Int) -> Bool {
        guard index >= 0, index + prefix.count <= count else { return false }
        var i = 0
        while i < prefix.count {
            if asciiLower(self[index + i]) != prefix[i] { return false }
            i += 1
        }
        return true
    }

    /// Finds `needle` (lowercase) case-insensitively in `from..<to`.
    func firstRangeCaseInsensitive(of needle: [UInt8], from: Int, to: Int) -> Int? {
        guard let first = needle.first, needle.count <= to - from else { return nil }
        let upperFirst = (first >= 0x61 && first <= 0x7A) ? first - 0x20 : first
        var i = from
        let last = to - needle.count
        while i <= last {
            let b = self[i]
            if (b == first || b == upperFirst) && hasBytesCaseInsensitive(needle, at: i) { return i }
            i += 1
        }
        return nil
    }

    /// Finds `needle` exactly in `from..<to`.
    func firstRange(of needle: [UInt8], from: Int, to: Int) -> Int? {
        guard let first = needle.first, needle.count <= to - from else { return nil }
        var i = from
        let last = to - needle.count
        while i <= last {
            if self[i] == first && hasBytes(needle, at: i) { return i }
            i += 1
        }
        return nil
    }
}
