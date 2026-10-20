import Foundation

/// RFC 2047 encoded words (`=?charset?B|Q?text?=`).
public enum EncodedWord {
    /// Decodes every encoded word in a header value.
    ///
    /// - Whitespace between adjacent encoded words is dropped; other text is kept as is.
    /// - Adjacent words in the same charset are joined at the byte level before charset decoding,
    ///   so a multi-byte character split across two words (a common encoder bug) survives.
    /// - Words not separated by whitespace from surrounding text are decoded too.
    /// - Malformed words (unknown encoding, bad base64, no closing `?=`) are left untouched.
    /// - The RFC 2231 language suffix (`=?utf-8*en?Q?...?=`) is ignored.
    public static func decode(_ s: String) -> String {
        guard s.containsASCII("=?") else { return s }
        let b = Array(s.utf8)
        let n = b.count
        var out = ""
        out.reserveCapacity(n)
        var literalStart = 0
        var lastWasEncoded = false
        var pendingBytes: [UInt8] = []
        var pendingCharset: String?

        func flush() {
            if let cs = pendingCharset {
                out += sanitize(Charset.decode(Data(pendingBytes), charset: cs))
            }
            pendingBytes.removeAll(keepingCapacity: true)
            pendingCharset = nil
        }

        var i = 0
        while i + 1 < n {
            guard b[i] == ASCII.equals, b[i + 1] == ASCII.question, let word = parseWord(b, at: i) else {
                i += 1
                continue
            }
            let literal = b[literalStart..<i]
            if lastWasEncoded && literal.allSatisfy(isASCIIWhitespace) {
                // Whitespace between encoded words is not part of the text.
            } else {
                flush()
                out += String(decoding: literal, as: UTF8.self)
            }
            if let cs = pendingCharset, Charset.isSame(cs, word.charset) {
                pendingBytes.append(contentsOf: word.bytes)
            } else {
                flush()
                pendingCharset = word.charset
                pendingBytes = word.bytes
            }
            lastWasEncoded = true
            i = word.end
            literalStart = i
        }
        flush()
        if literalStart < n { out += String(decoding: b[literalStart..<n], as: UTF8.self) }
        return out
    }

    struct Word {
        var charset: String
        var bytes: [UInt8]
        var end: Int
    }

    /// Parses `=?charset?X?text?=` starting at `start`.
    static func parseWord(_ b: [UInt8], at start: Int) -> Word? {
        let n = b.count
        var i = start + 2
        let csStart = i
        while i < n && b[i] != ASCII.question {
            let c = b[i]
            if c <= 32 || c >= 127 || c == ASCII.equals { return nil }
            i += 1
            if i - csStart > 64 { return nil }
        }
        guard i < n, i > csStart, i + 2 < n, b[i + 2] == ASCII.question else { return nil }
        let charset = String(decoding: b[csStart..<i], as: UTF8.self)
        let enc = asciiLower(b[i + 1])
        guard enc == 0x62 || enc == 0x71 else { return nil }   // b / q
        let textStart = i + 3
        var j = textStart
        var textEnd: Int?
        while j + 1 < n && j - textStart < 4096 {
            let c = b[j]
            if c == ASCII.cr || c == ASCII.lf { return nil }
            if c == ASCII.question && b[j + 1] == ASCII.equals { textEnd = j; break }
            j += 1
        }
        guard let te = textEnd else { return nil }
        let text = b[textStart..<te]
        let bytes: [UInt8]
        if enc == 0x62 {
            // B: must look like base64 (whitespace tolerated), otherwise leave the word alone.
            for c in text where Base64Lenient.table[Int(c)] == 0xFF && c != ASCII.equals && !isASCIIWhitespace(c) { return nil }
            bytes = Base64Lenient.decode(bytes: text)
        } else {
            bytes = decodeQ(text)
        }
        return Word(charset: charset, bytes: bytes, end: te + 2)
    }

    static func decodeQ(_ text: ArraySlice<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let c = text[i]
            if c == ASCII.underscore {
                out.append(ASCII.space)
            } else if c == ASCII.equals, i + 2 < text.endIndex, let hi = hexValue(text[i + 1]), let lo = hexValue(text[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
                continue
            } else {
                out.append(c)
            }
            i += 1
        }
        return out
    }

    /// Header text must stay on one line: CR/LF/NUL from a decoded word become spaces.
    static func sanitize(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { $0.value < 0x20 && $0 != "\t" }) else { return s }
        return String(String.UnicodeScalarView(s.unicodeScalars.map { $0.value < 0x20 ? " " : $0 }))
    }

    /// Encodes `s` for a header as UTF-8 encoded words (each at most 75 characters, separated by
    /// spaces, never splitting a character). Printable ASCII that doesn't look like an encoded
    /// word is returned unchanged. Uses Q or B, whichever is shorter.
    public static func encode(_ s: String) -> String {
        encode(s, force: false)
    }

    /// Like `encode(_:)`; with `force` the text is encoded even when it is plain ASCII (for header
    /// parameters and over-long words that must be split).
    static func encode(_ s: String, force: Bool, maxWordLength: Int = 75) -> String {
        if !force && !needsEncoding(s) { return s }
        if s.isEmpty { return s }
        let bytes = Array(s.utf8)
        var qLength = 0
        for c in bytes { qLength += qSafe(c) ? 1 : 3 }
        let useQ = qLength <= (bytes.count + 2) / 3 * 4
        let prefix = useQ ? "=?UTF-8?Q?" : "=?UTF-8?B?"
        // At least room for one 4-byte character, whatever the caller asks for.
        let maxPayload = max(min(maxWordLength, 75) - prefix.utf8.count - 2, useQ ? 12 : 8)

        var words: [String] = []
        var chunk: [UInt8] = []
        var chunkLength = 0
        func encodedLength(_ count: Int) -> Int { (count + 2) / 3 * 4 }
        func flush() {
            guard !chunk.isEmpty else { return }
            let payload = useQ ? qEncode(chunk) : Base64Lenient.encode(Data(chunk), lineLength: 0)
            words.append(prefix + payload + "?=")
            chunk.removeAll(keepingCapacity: true)
            chunkLength = 0
        }
        for ch in s {
            let cb = Array(String(ch).utf8)
            let add: Int
            if useQ {
                add = cb.reduce(0) { $0 + (qSafe($1) ? 1 : 3) }
                if chunkLength + add > maxPayload { flush() }
                chunkLength += add
            } else {
                if encodedLength(chunk.count + cb.count) > maxPayload { flush() }
            }
            chunk.append(contentsOf: cb)
        }
        flush()
        return words.joined(separator: " ")
    }

    static func needsEncoding(_ s: String) -> Bool {
        if s.containsASCII("=?") { return true }
        for b in s.utf8 where b < 0x20 || b > 0x7E { return true }
        return false
    }

    @inline(__always)
    static func qSafe(_ c: UInt8) -> Bool {
        isASCIILetter(c) || isASCIIDigit(c) || c == ASCII.bang || c == ASCII.star || c == 0x2B || c == ASCII.dash || c == ASCII.slash || c == ASCII.space
    }

    static func qEncode(_ bytes: [UInt8]) -> String {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 2)
        for c in bytes {
            if c == ASCII.space {
                out.append(ASCII.underscore)
            } else if qSafe(c) {
                out.append(c)
            } else {
                out.append(ASCII.equals)
                out.append(upperHexDigits[Int(c >> 4)])
                out.append(upperHexDigits[Int(c & 0x0F)])
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}
