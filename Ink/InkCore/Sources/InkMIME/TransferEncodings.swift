import Foundation

/// Quoted-printable (RFC 2045 §6.7).
public enum QuotedPrintable {
    /// Decodes quoted-printable bytes. Lenient: lowercase hex is accepted, soft line breaks may
    /// have trailing whitespace after the `=`, a malformed `=` is kept literally, and a truncated
    /// `=` / `=X` at the very end (partial fetches) is dropped. Line breaks are kept as they are.
    public static func decode(_ data: Data) -> Data {
        Data(decode(bytes: [UInt8](data)))
    }

    /// Decodes quoted-printable text.
    public static func decode(_ s: String) -> Data {
        Data(decode(bytes: Array(s.utf8)))
    }

    static func decode<C: Collection>(bytes: C) -> [UInt8] where C.Element == UInt8, C.Index == Int {
        if let fast = bytes.withContiguousStorageIfAvailable({ decodeBuffer($0) }) { return fast }
        return Array(bytes).withUnsafeBufferPointer { decodeBuffer($0) }
    }

    private static func decodeBuffer(_ b: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            guard c == ASCII.equals else { out.append(c); i += 1; continue }
            if i + 1 >= n { break }   // "=" at the very end
            let c1 = b[i + 1]
            if let hi = hexValue(c1) {
                if i + 2 < n, let lo = hexValue(b[i + 2]) {
                    out.append(hi << 4 | lo)
                    i += 3
                    continue
                }
                if i + 2 >= n { break }   // truncated "=X"
            }
            // Soft line break: "=" [whitespace] CRLF / LF / CR / end.
            var j = i + 1
            while j < n && isWSP(b[j]) { j += 1 }
            if j >= n { i = n; break }
            if b[j] == ASCII.lf { i = j + 1; continue }
            if b[j] == ASCII.cr {
                i = j + 1
                if i < n && b[i] == ASCII.lf { i += 1 }
                continue
            }
            // Malformed escape: keep the "=" literally.
            out.append(ASCII.equals)
            i += 1
        }
        return out
    }

    /// Encodes text bytes as quoted-printable with lines of at most `lineLength` characters
    /// (including the trailing `=` of soft breaks). CRLF and LF in the input are hard line breaks
    /// (written as CRLF); whitespace before a line break is encoded, and so is a leading "From ".
    public static func encode(_ data: Data, lineLength: Int = 76) -> String {
        let b = [UInt8](data)
        let limit = max(lineLength, 4) - 1   // room for the soft-break "="
        var out: [UInt8] = []
        out.reserveCapacity(b.count + b.count / 3 + 8)
        var lineLen = 0
        var i = 0
        let n = b.count

        func emit(_ token: [UInt8]) {
            if lineLen + token.count > limit {
                out.append(contentsOf: [ASCII.equals, ASCII.cr, ASCII.lf])
                lineLen = 0
            }
            out.append(contentsOf: token)
            lineLen += token.count
        }
        func escaped(_ c: UInt8) -> [UInt8] {
            [ASCII.equals, upperHexDigits[Int(c >> 4)], upperHexDigits[Int(c & 0x0F)]]
        }

        while i < n {
            let c = b[i]
            if c == ASCII.lf || (c == ASCII.cr && i + 1 < n && b[i + 1] == ASCII.lf) {
                out.append(contentsOf: [ASCII.cr, ASCII.lf])
                lineLen = 0
                i += c == ASCII.cr ? 2 : 1
                continue
            }
            if c == ASCII.space || c == ASCII.tab {
                let next = i + 1 < n ? b[i + 1] : ASCII.lf
                let atLineEnd = next == ASCII.lf || next == ASCII.cr
                emit(atLineEnd ? escaped(c) : [c])
            } else if c == 0x46 && lineLen == 0 && i + 4 < n && b[i + 1] == 0x72 && b[i + 2] == 0x6F && b[i + 3] == 0x6D && b[i + 4] == ASCII.space {
                emit(escaped(c))   // "From " at line start confuses mbox tools
            } else if c == ASCII.dot && lineLen == 0 {
                emit(escaped(c))   // a lone "." line ends SMTP DATA on broken relays
            } else if c >= 33 && c <= 126 && c != ASCII.equals {
                emit([c])
            } else {
                emit(escaped(c))
            }
            i += 1
        }
        return String(decoding: out, as: UTF8.self)
    }
}

/// Base64 that survives real-world mail.
public enum Base64Lenient {
    static let table: [UInt8] = {
        var t = [UInt8](repeating: 0xFF, count: 256)
        let alphabet = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)
        for (i, c) in alphabet.enumerated() { t[Int(c)] = UInt8(i) }
        t[Int(ASCII.dash)] = 62        // URL-safe alphabet
        t[Int(ASCII.underscore)] = 63
        return t
    }()

    static let alphabet: [UInt8] = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/".utf8)

    /// Decodes base64, ignoring whitespace and any other non-alphabet bytes. Missing padding is
    /// tolerated, padded blocks may be concatenated, and a truncated tail decodes as far as whole
    /// bytes go (a single dangling character is dropped).
    public static func decode(_ s: String) -> Data {
        Data(decode(bytes: Array(s.utf8)))
    }

    /// Decodes base64 bytes. See `decode(_:)` for the tolerance rules.
    public static func decode(_ data: Data) -> Data {
        Data(decode(bytes: [UInt8](data)))
    }

    static func decode<C: Collection>(bytes: C) -> [UInt8] where C.Element == UInt8 {
        if let fast = bytes.withContiguousStorageIfAvailable({ decodeBuffer($0) }) { return fast }
        return Array(bytes).withUnsafeBufferPointer { decodeBuffer($0) }
    }

    private static func decodeBuffer(_ bytes: UnsafeBufferPointer<UInt8>) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(bytes.count * 3 / 4 + 3)
        var quad: UInt32 = 0
        var count = 0
        let t = table
        func flushPartial() {
            if count == 2 {
                out.append(UInt8(truncatingIfNeeded: quad >> 4))
            } else if count == 3 {
                out.append(UInt8(truncatingIfNeeded: quad >> 10))
                out.append(UInt8(truncatingIfNeeded: quad >> 2))
            }
            quad = 0
            count = 0
        }
        for c in bytes {
            let v = t[Int(c)]
            if v == 0xFF {
                if c == ASCII.equals && count > 0 { flushPartial() }
                continue
            }
            quad = quad << 6 | UInt32(v)
            count += 1
            if count == 4 {
                out.append(UInt8(truncatingIfNeeded: quad >> 16))
                out.append(UInt8(truncatingIfNeeded: quad >> 8))
                out.append(UInt8(truncatingIfNeeded: quad))
                quad = 0
                count = 0
            }
        }
        flushPartial()
        return out
    }

    /// Encodes as standard padded base64, wrapped at `lineLength` characters with CRLF
    /// (no wrapping when `lineLength` is 0).
    public static func encode(_ data: Data, lineLength: Int = 76) -> String {
        String(decoding: encodeBytes(data, lineLength: lineLength), as: UTF8.self)
    }

    /// `encode(_:lineLength:)` as ASCII bytes.
    static func encodeBytes(_ data: Data, lineLength: Int = 76) -> [UInt8] {
        let b = [UInt8](data)
        var out: [UInt8] = []
        out.reserveCapacity(b.count * 4 / 3 + b.count / 38 + 8)
        let a = alphabet
        var lineLen = 0
        let wrap = lineLength > 0 ? max(4, lineLength - lineLength % 4) : Int.max
        func put(_ c: UInt8) {
            if lineLen == wrap {
                out.append(ASCII.cr); out.append(ASCII.lf)
                lineLen = 0
            }
            out.append(c)
            lineLen += 1
        }
        var i = 0
        while i + 2 < b.count {
            let v = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8 | UInt32(b[i + 2])
            put(a[Int(v >> 18 & 0x3F)]); put(a[Int(v >> 12 & 0x3F)]); put(a[Int(v >> 6 & 0x3F)]); put(a[Int(v & 0x3F)])
            i += 3
        }
        let rest = b.count - i
        if rest == 1 {
            let v = UInt32(b[i]) << 16
            put(a[Int(v >> 18 & 0x3F)]); put(a[Int(v >> 12 & 0x3F)]); put(ASCII.equals); put(ASCII.equals)
        } else if rest == 2 {
            let v = UInt32(b[i]) << 16 | UInt32(b[i + 1]) << 8
            put(a[Int(v >> 18 & 0x3F)]); put(a[Int(v >> 12 & 0x3F)]); put(a[Int(v >> 6 & 0x3F)]); put(ASCII.equals)
        }
        return out
    }
}

/// uuencode (`Content-Transfer-Encoding: x-uuencode`).
public enum UUEncode {
    /// Decodes a uuencoded block. Lines before `begin` and after `end` are ignored; without a
    /// `begin` line every line is decoded.
    public static func decode(_ data: Data) -> Data {
        decodeWithName([UInt8](data)).data
    }

    /// The file name on the `begin <mode> <name>` line, if any.
    public static func filename(in data: Data) -> String? {
        decodeWithName([UInt8](data)).filename
    }

    static func decodeWithName(_ b: [UInt8]) -> (data: Data, filename: String?) {
        var out: [UInt8] = []
        var filename: String?
        var started = false
        let hasBegin = b.firstRange(of: Array("begin ".utf8), from: 0, to: b.count) != nil
        var lineStart = 0
        while lineStart < b.count {
            let lf = b.firstIndex(of: ASCII.lf, from: lineStart, to: b.count) ?? b.count
            var lineEnd = lf
            while lineEnd > lineStart && (b[lineEnd - 1] == ASCII.cr || b[lineEnd - 1] == ASCII.space) { lineEnd -= 1 }
            let line = b[lineStart..<lineEnd]
            defer { lineStart = lf + 1 }
            if !started {
                if hasBegin {
                    if line.starts(with: Array("begin ".utf8)) {
                        started = true
                        let parts = String(decoding: line, as: UTF8.self).split(separator: " ", maxSplits: 2)
                        if parts.count == 3 { filename = String(parts[2]) }
                    }
                    continue
                }
                started = true
            }
            if line.elementsEqual(Array("end".utf8)) { break }
            guard let first = line.first else { continue }
            let count = Int((first &- 0x20) & 0x3F)
            if count == 0 { continue }
            var produced = 0
            var i = line.startIndex + 1
            while produced < count && i < line.endIndex {
                var chunk = [UInt8](repeating: 0, count: 4)
                for k in 0..<4 {
                    let idx = i + k
                    chunk[k] = idx < line.endIndex ? (line[idx] &- 0x20) & 0x3F : 0
                }
                let bytes = [chunk[0] << 2 | chunk[1] >> 4, chunk[1] << 4 | chunk[2] >> 2, chunk[2] << 6 | chunk[3]]
                for byte in bytes where produced < count {
                    out.append(byte)
                    produced += 1
                }
                i += 4
            }
        }
        return (Data(out), filename)
    }
}

/// Content-Transfer-Encoding dispatch.
public enum TransferEncoding {
    /// Normalises a Content-Transfer-Encoding value: lowercased, trimmed, quotes and comments removed.
    /// Missing or empty → "7bit".
    public static func normalize(_ value: String?) -> String {
        guard var v = value?.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'")), !v.isEmpty else { return "7bit" }
        if let paren = v.firstIndex(of: "(") { v = String(v[..<paren]) }
        if let semi = v.firstIndex(of: ";") { v = String(v[..<semi]) }
        v = v.trimmingCharacters(in: .whitespaces).asciiLowercased
        switch v {
        case "base64", "base-64", "b64": return "base64"
        case "quoted-printable", "quoted printable", "quotedprintable", "qp": return "quoted-printable"
        case "x-uuencode", "uuencode", "x-uue", "uue": return "x-uuencode"
        case "": return "7bit"
        default: return v
        }
    }

    /// Decodes a body according to its Content-Transfer-Encoding. 7bit, 8bit, binary and unknown
    /// encodings pass through unchanged.
    public static func decode(_ data: Data, encoding: String?) -> Data {
        decode(bytes: [UInt8](data)[...], encoding: normalize(encoding))
    }

    static func decode(bytes: ArraySlice<UInt8>, encoding normalized: String) -> Data {
        switch normalized {
        case "base64": return Data(Base64Lenient.decode(bytes: bytes))
        case "quoted-printable": return Data(QuotedPrintable.decode(bytes: bytes))
        case "x-uuencode": return UUEncode.decodeWithName(Array(bytes)).data
        default: return Data(bytes)
        }
    }
}
