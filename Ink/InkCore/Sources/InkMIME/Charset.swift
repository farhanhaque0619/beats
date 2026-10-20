import Foundation
#if canImport(CoreFoundation)
import CoreFoundation
#endif

/// Turns bytes in a MIME charset into a `String`, never failing.
///
/// Supported: UTF-8, US-ASCII, ISO-8859-1…16, Windows-1250…1258, KOI8-R/U, GB2312/GBK/GB18030,
/// HZ, Big5, Shift_JIS (CP932), EUC-JP, ISO-2022-JP, EUC-KR (CP949), UTF-16/32 (with or without
/// BOM), UTF-7, Mac Roman, common DOS code pages, TIS-620. Labels are matched case-insensitively
/// with the usual aliases (`latin1`, `cp1252`, `ks_c_5601-1987`, `x-sjis`, ...).
///
/// Real mail is often mislabelled or damaged, so decoding degrades gracefully:
/// - `us-ascii` / unknown / missing labels decode as UTF-8 when the bytes are valid UTF-8, else Windows-1252.
/// - ISO-8859-1 is decoded as Windows-1252 (as browsers do), so "smart quotes" survive.
/// - A truncated multi-byte sequence at the end (partial IMAP fetches) is dropped, not turned into garbage.
/// - When a multi-byte charset has a few invalid bytes, only those bytes become U+FFFD.
/// - When nothing else works: UTF-8 if valid, else Windows-1252.
public enum Charset {
    /// Decodes `data` using the MIME charset label `charset` (nil means unknown).
    public static func decode(_ data: Data, charset: String?) -> String {
        if data.isEmpty { return "" }
        let bytes = [UInt8](data)
        return decode(bytes: bytes, charset: charset)
    }

    /// The canonical lowercase name for a charset label (`"Latin1"` → `"iso-8859-1"`), or the
    /// trimmed lowercased label when it is not one Ink knows.
    public static func canonicalName(_ label: String) -> String {
        let key = normalizeLabel(label)
        return kind(for: key).canonical ?? key
    }

    /// True when `canonicalName` of both labels is the same.
    public static func isSame(_ a: String, _ b: String) -> Bool {
        canonicalName(a) == canonicalName(b)
    }

    // MARK: - Implementation

    static func decode(bytes: [UInt8], charset: String?) -> String {
        if bytes.isEmpty { return "" }
        let key = charset.map(normalizeLabel) ?? ""
        switch kind(for: key) {
        case .utf8:
            return decodeUTF8(bytes)
        case .asciiOrUnknown:
            return decodeFallback(bytes)
        case .windows1252:
            if isMislabelledUTF8(bytes) { return decodeUTF8(bytes) }
            return decodeSingleByte(bytes, table: SingleByteTables.windows1252High)
        case .latin9:
            if isMislabelledUTF8(bytes) { return decodeUTF8(bytes) }
            return decodeSingleByte(bytes, table: SingleByteTables.latin9High)
        case .macRoman:
            return decodeSingleByte(bytes, table: SingleByteTables.macRomanHigh)
        case .table(_, let table):
            return decodeSingleByte(bytes, table: table)
        case .utf16(let bigEndian):
            return decodeUTF16(bytes, bigEndian: bigEndian)
        case .utf32(let bigEndian):
            return decodeUTF32(bytes, bigEndian: bigEndian)
        case .eucJP:
            return decodeEUCJP(bytes)
        case .encodings(let candidates, let family):
            return decodeWithFoundation(bytes, candidates: candidates, family: family)
        case .other(let label):
            return decodeOther(bytes, label: label)
        }
    }

    /// Byte layout of a multi-byte charset, used to resynchronise after invalid bytes.
    enum Family: Equatable {
        case singleByte
        /// Lead byte 0x81–0xFE followed by one trail byte (Big5, EUC-KR/CP949, GBK).
        case doubleByte
        /// Like `doubleByte`, plus four-byte sequences whose second byte is a digit.
        case gb18030
        case shiftJIS
        case eucJP
        /// Escape-sequence based (ISO-2022-*, HZ, UTF-7): only line-level recovery.
        case stateful
    }

    enum Kind {
        case utf8
        case asciiOrUnknown
        case windows1252
        case latin9
        case macRoman
        /// A single-byte charset decoded with a built-in table (same result on every platform).
        case table(String, [UInt16])
        case utf16(bigEndian: Bool?)
        case utf32(bigEndian: Bool?)
        case eucJP
        case encodings([String.Encoding], Family)
        case other(String)

        var canonical: String? {
            switch self {
            case .utf8: return "utf-8"
            case .asciiOrUnknown: return "us-ascii"
            case .windows1252: return "windows-1252"
            case .latin9: return "iso-8859-15"
            case .macRoman: return "macintosh"
            case .table(let name, _): return name
            case .utf16(let be):
                switch be { case .none: return "utf-16"; case .some(true): return "utf-16be"; case .some(false): return "utf-16le" }
            case .utf32(let be):
                switch be { case .none: return "utf-32"; case .some(true): return "utf-32be"; case .some(false): return "utf-32le" }
            case .eucJP: return "euc-jp"
            case .encodings, .other: return nil
            }
        }
    }

    static func normalizeLabel(_ label: String) -> String {
        var s = label.trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"'"))
        s = s.asciiLowercased
        // "utf-8*en" (RFC 2231 language suffix) and stray parameters.
        if let star = s.firstIndex(of: "*") { s = String(s[..<star]) }
        if let semi = s.firstIndex(of: ";") { s = String(s[..<semi]) }
        return s.trimmingCharacters(in: .whitespaces)
    }

    // swiftlint:disable:next cyclomatic_complexity function_body_length
    static func kind(for key: String) -> Kind {
        switch key {
        case "", "us-ascii", "ascii", "us", "ansi_x3.4-1968", "iso-ir-6", "iso646-us", "646", "cp367", "ibm367", "csascii", "x-unknown", "unknown", "default", "none", "8bit", "7bit":
            return .asciiOrUnknown
        case "utf-8", "utf8", "unicode-1-1-utf-8", "x-unicode20utf8", "unicode-2-0-utf-8", "x-utf8", "utf-8-sig":
            return .utf8
        case "iso-8859-1", "iso8859-1", "iso_8859-1", "iso_8859-1:1987", "latin1", "latin-1", "l1", "cp819", "ibm819", "iso-ir-100", "8859-1", "csisolatin1", "iso88591",
             "windows-1252", "cp1252", "x-cp1252", "win-1252", "windows1252", "ms-ansi", "ansi":
            return .windows1252
        case "iso-8859-15", "iso8859-15", "iso_8859-15", "latin9", "latin-9", "l9", "8859-15", "iso885915", "csisolatin9", "latin0":
            return .latin9
        case "utf-16", "utf16", "ucs-2", "iso-10646-ucs-2", "csunicode", "unicode":
            return .utf16(bigEndian: nil)
        case "utf-16be", "utf16be", "unicodefffe":
            return .utf16(bigEndian: true)
        case "utf-16le", "utf16le", "unicodefeff":
            return .utf16(bigEndian: false)
        case "utf-32", "utf32", "ucs-4", "iso-10646-ucs-4":
            return .utf32(bigEndian: nil)
        case "utf-32be", "utf32be":
            return .utf32(bigEndian: true)
        case "utf-32le", "utf32le":
            return .utf32(bigEndian: false)
        case "euc-jp", "eucjp", "x-euc-jp", "x-euc", "cseucpkdfmtjapanese", "ujis", "x-eucjp":
            return .eucJP
        case "shift_jis", "shift-jis", "sjis", "x-sjis", "ms_kanji", "csshiftjis", "windows-31j", "cp932", "ms932", "x-ms-cp932", "shiftjis", "s-jis", "x-shift_jis":
            return .encodings(encodings(cf: [0x0420], foundation: [.shiftJIS]), .shiftJIS)
        case "iso-2022-jp", "csiso2022jp", "iso2022jp", "jis", "iso-2022-jp-1", "iso-2022-jp-2", "iso-2022-jp-3", "csiso2022jp2":
            return .encodings(encodings(cf: [0x0821, 0x0822, 0x0820], foundation: [.iso2022JP]), .stateful)
        case "gb2312", "gbk", "gb18030", "cp936", "x-gbk", "euc-cn", "euccn", "x-euc-cn", "csgb2312", "chinese", "gb_2312-80", "gb_2312", "iso-ir-58", "csiso58gb231280", "windows-936", "ms936", "gb-2312", "x-gb2312", "gb18030-2000", "gb18030-2005":
            return .encodings(encodings(cf: [0x0632, 0x0421, 0x0930], foundation: []), .gb18030)
        case "hz-gb-2312", "hz", "hz-gb2312":
            return .encodings(encodings(cf: [0x0A05], foundation: []), .stateful)
        case "big5", "big-5", "cn-big5", "csbig5", "x-x-big5", "cp950", "big5-hkscs", "big5hkscs", "x-big5", "windows-950", "ms950", "big5-eten":
            return .encodings(encodings(cf: [0x0A06, 0x0423, 0x0A03], foundation: []), .doubleByte)
        case "euc-kr", "euckr", "ks_c_5601-1987", "ks_c_5601", "ks_c_5601-1989", "ksc5601", "ksc_5601", "korean", "cseuckr", "csksc56011987", "iso-ir-149", "windows-949", "cp949", "uhc", "x-windows-949", "ms949", "ks_c_5601_1987", "x-euc-kr":
            return .encodings(encodings(cf: [0x0422, 0x0940], foundation: []), .doubleByte)
        case "iso-2022-kr", "csiso2022kr":
            return .encodings(encodings(cf: [0x0840], foundation: []), .stateful)
        case "iso-2022-cn", "iso-2022-cn-ext":
            return .encodings(encodings(cf: [0x0830, 0x0831], foundation: []), .stateful)
        case "koi8-r", "koi8r", "cskoi8r", "koi", "koi8":
            return tableKind("koi8-r")
        case "koi8-u", "koi8u", "koi8-ru":
            return tableKind("koi8-u")
        case "macintosh", "mac", "x-mac-roman", "macroman", "csmacintosh", "x-mac", "mac-roman":
            return .macRoman
        case "utf-7", "utf7", "unicode-1-1-utf-7", "csunicode11utf7", "x-utf-7":
            return .encodings(encodings(cf: [0x0400_0100], foundation: []), .stateful)
        case "windows-874", "cp874", "tis-620", "tis620", "iso-8859-11", "iso8859-11", "x-windows-874", "dos-874", "cstis620":
            // Windows-874 is a superset of TIS-620 / ISO-8859-11.
            return tableKind("windows-874")
        case "cp866", "ibm866", "866", "csibm866", "x-cp866", "dos-866":
            return tableKind("ibm866")
        case "cp850", "ibm850", "850", "csibm850":
            return .encodings(encodings(cf: [0x0410], foundation: []), .singleByte)
        case "cp437", "ibm437", "437", "cspc8codepage437":
            return .encodings(encodings(cf: [0x0400], foundation: []), .singleByte)
        default:
            if let n = isoLatinNumber(key) { return isoKind(n) }
            if let n = windowsNumber(key) { return windowsKind(n) }
            return .other(key)
        }
    }

    /// "iso-8859-5", "iso8859-5", "iso_8859-5:1988", "8859-5", "latin2", "cyrillic", ... → 5
    static let isoLatinAliases: [String: Int] = [
            "latin2": 2, "l2": 2, "latin-2": 2, "latin3": 3, "l3": 3, "latin4": 4, "l4": 4,
            "cyrillic": 5, "arabic": 6, "greek": 7, "greek8": 7, "ecma-118": 7, "elot_928": 7, "hebrew": 8, "latin5": 9, "l5": 9,
            "latin6": 10, "l6": 10, "latin7": 13, "l7": 13, "latin8": 14, "l8": 14, "latin10": 16, "l10": 16,
            "csisolatin2": 2, "csisolatin3": 3, "csisolatin4": 4, "csisolatincyrillic": 5, "csisolatinarabic": 6,
            "csisolatingreek": 7, "csisolatinhebrew": 8, "csisolatin5": 9, "csisolatin6": 10, "visual": 8, "logical": 8,
    ]

    static func isoLatinNumber(_ key: String) -> Int? {
        if let n = isoLatinAliases[key] { return n }
        var s = Substring(key)
        for prefix in ["iso-8859-", "iso8859-", "iso_8859-", "iso-8859_", "iso8859_", "8859-", "iso-8859", "iso8859"] where s.hasPrefix(prefix) {
            s = s.dropFirst(prefix.count)
            break
        }
        guard s.count < key.count else { return nil }
        // "8-i", "6-e", "1:1987"
        let digits = s.prefix(while: { $0.isASCII && $0.isNumber })
        guard let n = Int(digits), (1...16).contains(n), n != 12 else { return nil }
        return n
    }

    /// "windows-1251", "cp1251", "x-cp1251", "win-1251", "windows1251" → 1251
    static func windowsNumber(_ key: String) -> Int? {
        var s = Substring(key)
        for prefix in ["windows-", "windows", "x-cp", "cp", "win-", "win", "ms-", "ibm-"] where s.hasPrefix(prefix) {
            s = s.dropFirst(prefix.count)
            break
        }
        guard s.count < key.count, let n = Int(s), (1250...1258).contains(n) else { return nil }
        return n
    }

    static func isoKind(_ n: Int) -> Kind {
        switch n {
        case 1: return .windows1252
        case 15: return .latin9
        default:
            if let table = SingleByteTables.iso(n) { return .table("iso-8859-\(n)", table) }
            return .encodings(encodings(cf: [UInt32(0x0200 + n)], foundation: n == 2 ? [.isoLatin2] : []), .singleByte)
        }
    }

    static func windowsKind(_ n: Int) -> Kind {
        if n == 1252 { return .windows1252 }
        return tableKind("windows-\(n)")
    }

    /// A built-in single-byte table by canonical name (falls back to the platform when missing).
    static func tableKind(_ name: String) -> Kind {
        if let table = SingleByteTables.named(name) { return .table(name, table) }
        return .other(name)
    }

    /// Foundation encodings for CoreFoundation charset constants (when CoreFoundation is available),
    /// followed by the given Foundation built-ins.
    static func encodings(cf: [UInt32], foundation: [String.Encoding]) -> [String.Encoding] {
        var result: [String.Encoding] = []
        #if canImport(CoreFoundation)
        for value in cf {
            let ns = CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value))
            if UInt64(ns) == 0xFFFF_FFFF { continue }
            result.append(String.Encoding(rawValue: UInt(ns)))
        }
        #endif
        for enc in foundation where !result.contains(enc) { result.append(enc) }
        return result
    }

    /// Unknown labels: ask CoreFoundation's IANA registry, else fall back.
    static func decodeOther(_ bytes: [UInt8], label: String) -> String {
        #if canImport(CoreFoundation)
        if label.count < 64, label.allSatisfy({ $0.isASCII }),
           let cfName = CFStringCreateWithCString(nil, label, CFStringBuiltInEncodings.UTF8.rawValue) {
            let cf = CFStringConvertIANACharSetNameToEncoding(cfName)
            if UInt64(cf) != 0xFFFF_FFFF {
                let ns = CFStringConvertEncodingToNSStringEncoding(cf)
                if UInt64(ns) != 0xFFFF_FFFF {
                    let enc = String.Encoding(rawValue: UInt(ns))
                    return decodeWithFoundation(bytes, candidates: [enc], family: .singleByte)
                }
            }
        }
        #endif
        return decodeFallback(bytes)
    }

    // MARK: UTF-8 and fallbacks

    static func stripUTF8BOM(_ bytes: [UInt8]) -> ArraySlice<UInt8> {
        if bytes.count >= 3, bytes[0] == 0xEF, bytes[1] == 0xBB, bytes[2] == 0xBF { return bytes[3...] }
        return bytes[...]
    }

    static func decodeUTF8(_ bytes: [UInt8]) -> String {
        let body = stripUTF8BOM(bytes)
        let check = utf8Validation(body)
        if check.isValid { return String(decoding: body, as: UTF8.self) }
        if check.onlyTruncatedTail { return String(decoding: body[body.startIndex..<check.validPrefixEnd], as: UTF8.self) }
        // Labelled UTF-8 but not a single valid multi-byte sequence: almost certainly Latin-1/CP1252.
        if !check.hasMultibyte && !containsValidMultibyte(body) {
            return decodeSingleByte(Array(body), table: SingleByteTables.windows1252High)
        }
        return String(decoding: body, as: UTF8.self)
    }

    /// Web forms and scripts often label UTF-8 text "ISO-8859-1": when Latin-labelled bytes are
    /// entirely well-formed UTF-8 with multi-byte sequences in them ("CafÃ©" otherwise), they are
    /// UTF-8. Real Latin-1 text almost never forms valid UTF-8 sequences.
    static func isMislabelledUTF8(_ bytes: [UInt8]) -> Bool {
        let check = utf8Validation(stripUTF8BOM(bytes))
        return check.hasMultibyte && (check.isValid || check.onlyTruncatedTail)
    }

    /// True when the bytes contain at least one well-formed UTF-8 multi-byte sequence anywhere.
    static func containsValidMultibyte(_ bytes: ArraySlice<UInt8>) -> Bool {
        var i = bytes.startIndex
        while i < bytes.endIndex {
            let b = bytes[i]
            if b >= 0xC2 && b <= 0xF4 {
                let need = b < 0xE0 ? 1 : (b < 0xF0 ? 2 : 3)
                if i + need < bytes.endIndex {
                    var ok = true
                    for k in 1...need where bytes[i + k] & 0xC0 != 0x80 { ok = false; break }
                    if ok { return true }
                }
            }
            i += 1
        }
        return false
    }

    /// UTF-8 when the bytes are valid UTF-8 (ignoring a truncated tail), else Windows-1252.
    static func decodeFallback(_ bytes: [UInt8]) -> String {
        let body = stripUTF8BOM(bytes)
        let check = utf8Validation(body)
        if check.isValid { return String(decoding: body, as: UTF8.self) }
        if check.onlyTruncatedTail && check.hasMultibyte {
            return String(decoding: body[body.startIndex..<check.validPrefixEnd], as: UTF8.self)
        }
        return decodeSingleByte(Array(body), table: SingleByteTables.windows1252High)
    }

    static func decodeSingleByte(_ bytes: [UInt8], table: [UInt16]) -> String {
        var scalars = String.UnicodeScalarView()
        scalars.reserveCapacity(bytes.count)
        for b in bytes {
            if b < 0x80 {
                scalars.append(Unicode.Scalar(b))
            } else if let s = Unicode.Scalar(UInt32(table[Int(b) - 0x80])) {
                scalars.append(s)
            }
        }
        return String(scalars)
    }

    // MARK: UTF-16 / UTF-32

    static func decodeUTF16(_ bytes: [UInt8], bigEndian: Bool?) -> String {
        var start = 0
        var be = bigEndian
        if bytes.count >= 2 {
            if bytes[0] == 0xFE && bytes[1] == 0xFF { be = be ?? true; if be == true { start = 2 } }
            else if bytes[0] == 0xFF && bytes[1] == 0xFE { be = be ?? false; if be == false { start = 2 } }
        }
        if be == nil {
            // No BOM: guess from where the zero bytes of ASCII characters sit.
            var evenZeros = 0, oddZeros = 0
            var i = 0
            while i + 1 < bytes.count && i < 4096 {
                if bytes[i] == 0 { evenZeros += 1 }
                if bytes[i + 1] == 0 { oddZeros += 1 }
                i += 2
            }
            be = evenZeros >= oddZeros
        }
        let bigEndianOrder = be ?? true
        var units: [UInt16] = []
        units.reserveCapacity(bytes.count / 2)
        var i = start
        while i + 1 < bytes.count {
            let hi = bigEndianOrder ? bytes[i] : bytes[i + 1]
            let lo = bigEndianOrder ? bytes[i + 1] : bytes[i]
            units.append(UInt16(hi) << 8 | UInt16(lo))
            i += 2
        }
        // A trailing lone high surrogate is a truncation, not an error worth showing.
        if let last = units.last, (0xD800...0xDBFF).contains(last) { units.removeLast() }
        return String(decoding: units, as: UTF16.self)
    }

    static func decodeUTF32(_ bytes: [UInt8], bigEndian: Bool?) -> String {
        var start = 0
        var be = bigEndian
        if bytes.count >= 4 {
            if bytes[0] == 0 && bytes[1] == 0 && bytes[2] == 0xFE && bytes[3] == 0xFF { be = be ?? true; if be == true { start = 4 } }
            else if bytes[0] == 0xFF && bytes[1] == 0xFE && bytes[2] == 0 && bytes[3] == 0 { be = be ?? false; if be == false { start = 4 } }
        }
        if be == nil { be = bytes.count >= 4 ? bytes[0] == 0 : true }
        var scalars = String.UnicodeScalarView()
        var i = start
        while i + 3 < bytes.count {
            let v: UInt32
            if be == true {
                v = UInt32(bytes[i]) << 24 | UInt32(bytes[i + 1]) << 16 | UInt32(bytes[i + 2]) << 8 | UInt32(bytes[i + 3])
            } else {
                v = UInt32(bytes[i + 3]) << 24 | UInt32(bytes[i + 2]) << 16 | UInt32(bytes[i + 1]) << 8 | UInt32(bytes[i])
            }
            scalars.append(Unicode.Scalar(v) ?? "\u{FFFD}")
            i += 4
        }
        return String(scalars)
    }

    // MARK: EUC-JP

    /// Whether this platform's Foundation decodes EUC-JP natively (Apple platforms do; Linux doesn't).
    static let nativeEUCJP: String.Encoding? = {
        let candidates = encodings(cf: [0x0920], foundation: [.japaneseEUC])
        for enc in candidates where String(data: Data([0xA4, 0xA2]), encoding: enc) == "あ" { return enc }
        return nil
    }()

    static func decodeEUCJP(_ bytes: [UInt8]) -> String {
        if let native = nativeEUCJP {
            return decodeWithFoundation(bytes, candidates: [native], family: .eucJP)
        }
        // EUC-JP and Shift_JIS encode the same JIS X 0208 table, so transcode arithmetically.
        let sjis = eucJPToShiftJIS(bytes)
        return decodeWithFoundation(sjis, candidates: encodings(cf: [0x0420], foundation: [.shiftJIS]), family: .shiftJIS)
    }

    static func eucJPToShiftJIS(_ b: [UInt8]) -> [UInt8] {
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c < 0x80 {
                out.append(c); i += 1
            } else if c == 0x8E {
                // SS2: half-width katakana, single byte in Shift_JIS.
                if i + 1 < n, (0xA1...0xDF).contains(b[i + 1]) { out.append(b[i + 1]); i += 2 } else { out.append(ASCII.question); i += 1 }
            } else if c == 0x8F {
                // SS3: JIS X 0212, not representable in Shift_JIS. Geta mark (〓) as placeholder.
                if i + 2 < n { out.append(contentsOf: [0x81, 0xAC]); i += 3 } else { i = n }
            } else if (0xA1...0xFE).contains(c) {
                guard i + 1 < n else { i = n; break }   // truncated
                let c2 = b[i + 1]
                guard (0xA1...0xFE).contains(c2) else { out.append(ASCII.question); i += 1; continue }
                let j1 = c - 0x80, j2 = c2 - 0x80
                var s1 = ((j1 - 0x21) >> 1) + 0x81
                if s1 > 0x9F { s1 += 0x40 }
                var s2: UInt8
                if j1 & 1 == 1 {
                    s2 = j2 - 0x21 + 0x40
                    if s2 >= 0x7F { s2 += 1 }
                } else {
                    s2 = j2 - 0x21 + 0x9F
                }
                out.append(s1); out.append(s2)
                i += 2
            } else {
                out.append(ASCII.question); i += 1
            }
        }
        return out
    }

    // MARK: Foundation-backed decoding with recovery

    static func isUsable(_ enc: String.Encoding) -> Bool {
        String(data: Data([0x61]), encoding: enc) == "a"
    }

    static func decodeWithFoundation(_ bytes: [UInt8], candidates: [String.Encoding], family: Family) -> String {
        let usable = candidates.filter(isUsable)
        guard let primary = usable.first else { return decodeFallback(bytes) }
        let data = Data(bytes)
        for enc in usable {
            if let s = String(data: data, encoding: enc) { return s }
        }
        // Something in there is invalid (or truncated). Recover line by line, then token by token.
        var budget = DecodeBudget(remaining: 4096)
        var out = ""
        out.reserveCapacity(bytes.count)
        var lineStart = 0
        var badLines = 0
        var lineCount = 0
        while lineStart < bytes.count {
            let lf = bytes.firstIndex(of: ASCII.lf, from: lineStart, to: bytes.count)
            let lineEnd = lf.map { $0 + 1 } ?? bytes.count
            let line = bytes[lineStart..<lineEnd]
            lineCount += 1
            if let s = decodeLine(line, usable: usable) {
                out += s
            } else {
                badLines += 1
                guard let s = decodeTolerant(line, encoding: primary, family: family, budget: &budget) else {
                    // Hopeless (likely the wrong charset label): fall back for the whole text.
                    return decodeFallback(bytes)
                }
                out += s
            }
            lineStart = lineEnd
        }
        return out
    }

    static func decodeLine(_ line: ArraySlice<UInt8>, usable: [String.Encoding]) -> String? {
        let data = Data(line)
        for enc in usable {
            if let s = String(data: data, encoding: enc) { return s }
        }
        return nil
    }

    struct DecodeBudget {
        var remaining: Int
    }

    /// Decodes a line that contains invalid bytes: splits it into characters by the charset's byte
    /// layout and bisects until only the bad characters are left, which become U+FFFD.
    static func decodeTolerant(_ line: ArraySlice<UInt8>, encoding: String.Encoding, family: Family, budget: inout DecodeBudget) -> String? {
        if family == .stateful {
            return decodeStatefulLine(line, encoding: encoding)
        }
        let starts = tokenStarts(line, family: family)
        var bounds = starts
        bounds.append(line.endIndex)
        var replacements = 0
        func run(_ lo: Int, _ hi: Int, _ budget: inout DecodeBudget) -> String? {
            budget.remaining -= 1
            if budget.remaining < 0 { return nil }
            let slice = line[bounds[lo]..<bounds[hi]]
            if let s = String(data: Data(slice), encoding: encoding) { return s }
            if hi - lo == 1 {
                // A truncated character at the very end of the input is dropped silently.
                if hi == bounds.count - 1, isTruncatedTail(slice, family: family) { return "" }
                replacements += 1
                return "\u{FFFD}"
            }
            let mid = (lo + hi) / 2
            guard let a = run(lo, mid, &budget), let b = run(mid, hi, &budget) else { return nil }
            return a + b
        }
        guard !starts.isEmpty, let result = run(0, starts.count, &budget) else { return nil }
        // Mostly replacement characters means the label is wrong; let the caller fall back.
        if replacements > 8 && replacements * 4 > starts.count { return nil }
        return result
    }

    static func isTruncatedTail(_ token: ArraySlice<UInt8>, family: Family) -> Bool {
        guard let lead = token.first else { return false }
        switch family {
        case .doubleByte, .gb18030: return token.count == 1 && lead >= 0x81
        case .shiftJIS: return token.count == 1 && ((0x81...0x9F).contains(lead) || (0xE0...0xFC).contains(lead))
        case .eucJP: return token.count < 2 && lead >= 0x8E
        default: return false
        }
    }

    static func tokenStarts(_ line: ArraySlice<UInt8>, family: Family) -> [Int] {
        var starts: [Int] = []
        starts.reserveCapacity(line.count)
        var i = line.startIndex
        let end = line.endIndex
        while i < end {
            starts.append(i)
            let b = line[i]
            var len = 1
            switch family {
            case .singleByte, .stateful:
                len = 1
            case .doubleByte:
                len = (b >= 0x81 && b <= 0xFE) ? 2 : 1
            case .gb18030:
                if b >= 0x81 && b <= 0xFE {
                    if i + 1 < end, line[i + 1] >= 0x30, line[i + 1] <= 0x39 { len = 4 } else { len = 2 }
                }
            case .shiftJIS:
                len = ((0x81...0x9F).contains(b) || (0xE0...0xFC).contains(b)) ? 2 : 1
            case .eucJP:
                if b == 0x8F { len = 3 } else if b == 0x8E || (0xA1...0xFE).contains(b) { len = 2 }
            }
            i = min(i + len, end)
        }
        return starts
    }

    /// ISO-2022 style line recovery: add a missing return-to-ASCII escape, drop a truncated tail,
    /// and as a last resort strip escapes and keep the ASCII.
    static func decodeStatefulLine(_ line: ArraySlice<UInt8>, encoding: String.Encoding) -> String? {
        var bytes = Array(line)
        var trailing: [UInt8] = []
        while let last = bytes.last, last == ASCII.lf || last == ASCII.cr { trailing.insert(last, at: 0); bytes.removeLast() }
        let reset: [UInt8] = [0x1B, 0x28, 0x42]
        for drop in 0...2 where drop <= bytes.count {
            let candidate = Array(bytes.dropLast(drop)) + reset + trailing
            if let s = String(data: Data(candidate), encoding: encoding) { return s }
        }
        var scalars = String.UnicodeScalarView()
        var i = 0
        while i < line.count {
            let b = line[line.startIndex + i]
            if b == 0x1B { i += 3; continue }
            scalars.append(b < 0x80 ? Unicode.Scalar(b) : "\u{FFFD}")
            i += 1
        }
        return String(scalars)
    }
}

/// High halves (0x80–0xFF) of the single-byte charsets, built in so every platform decodes them
/// the same way (Foundation on Linux lacks or mangles several of them).
enum SingleByteTables {
    private static let isoTables: [Int: [UInt16]] = isoUpper.mapValues { upper in
        // 0x80–0x9F are the C1 controls in every ISO-8859 part.
        (0x80..<0xA0).map { UInt16($0) } + upper.unicodeScalars.map { UInt16(truncatingIfNeeded: $0.value) }
    }

    private static let namedTables: [String: [UInt16]] = highHalves.mapValues { half in
        half.unicodeScalars.map { UInt16(truncatingIfNeeded: $0.value) }
    }

    /// ISO-8859-`n` (2…16 except 12; 1 and 15 have their own tables).
    static func iso(_ n: Int) -> [UInt16]? {
        guard let table = isoTables[n], table.count == 128 else { return nil }
        return table
    }

    /// "windows-1250"…"windows-1258", "windows-874", "koi8-r", "koi8-u", "ibm866".
    static func named(_ name: String) -> [UInt16]? {
        guard let table = namedTables[name], table.count == 128 else { return nil }
        return table
    }

    /// Windows-1252. The five undefined bytes map to the C1 controls, as browsers do.
    static let windows1252High: [UInt16] = {
        var t = (0x80...0xFF).map { UInt16($0) }
        let c1: [UInt16] = [
            0x20AC, 0x0081, 0x201A, 0x0192, 0x201E, 0x2026, 0x2020, 0x2021, 0x02C6, 0x2030, 0x0160, 0x2039, 0x0152, 0x008D, 0x017D, 0x008F,
            0x0090, 0x2018, 0x2019, 0x201C, 0x201D, 0x2022, 0x2013, 0x2014, 0x02DC, 0x2122, 0x0161, 0x203A, 0x0153, 0x009D, 0x017E, 0x0178,
        ]
        for (i, v) in c1.enumerated() { t[i] = v }
        return t
    }()

    /// Mac OS Roman (Foundation on Linux decodes it incorrectly, so it is spelled out here).
    static let macRomanHigh: [UInt16] = [
        0x00C4, 0x00C5, 0x00C7, 0x00C9, 0x00D1, 0x00D6, 0x00DC, 0x00E1, 0x00E0, 0x00E2, 0x00E4, 0x00E3, 0x00E5, 0x00E7, 0x00E9, 0x00E8,
        0x00EA, 0x00EB, 0x00ED, 0x00EC, 0x00EE, 0x00EF, 0x00F1, 0x00F3, 0x00F2, 0x00F4, 0x00F6, 0x00F5, 0x00FA, 0x00F9, 0x00FB, 0x00FC,
        0x2020, 0x00B0, 0x00A2, 0x00A3, 0x00A7, 0x2022, 0x00B6, 0x00DF, 0x00AE, 0x00A9, 0x2122, 0x00B4, 0x00A8, 0x2260, 0x00C6, 0x00D8,
        0x221E, 0x00B1, 0x2264, 0x2265, 0x00A5, 0x00B5, 0x2202, 0x2211, 0x220F, 0x03C0, 0x222B, 0x00AA, 0x00BA, 0x03A9, 0x00E6, 0x00F8,
        0x00BF, 0x00A1, 0x00AC, 0x221A, 0x0192, 0x2248, 0x2206, 0x00AB, 0x00BB, 0x2026, 0x00A0, 0x00C0, 0x00C3, 0x00D5, 0x0152, 0x0153,
        0x2013, 0x2014, 0x201C, 0x201D, 0x2018, 0x2019, 0x00F7, 0x25CA, 0x00FF, 0x0178, 0x2044, 0x20AC, 0x2039, 0x203A, 0xFB01, 0xFB02,
        0x2021, 0x00B7, 0x201A, 0x201E, 0x2030, 0x00C2, 0x00CA, 0x00C1, 0x00CB, 0x00C8, 0x00CD, 0x00CE, 0x00CF, 0x00CC, 0x00D3, 0x00D4,
        0xF8FF, 0x00D2, 0x00DA, 0x00DB, 0x00D9, 0x0131, 0x02C6, 0x02DC, 0x00AF, 0x02D8, 0x02D9, 0x02DA, 0x00B8, 0x02DD, 0x02DB, 0x02C7,
    ]

    /// ISO-8859-15 (Latin-9): Latin-1 with the euro sign and seven letters replaced.
    static let latin9High: [UInt16] = {
        var t = (0x80...0xFF).map { UInt16($0) }
        let changes: [(Int, UInt16)] = [(0xA4, 0x20AC), (0xA6, 0x0160), (0xA8, 0x0161), (0xB4, 0x017D), (0xB8, 0x017E), (0xBC, 0x0152), (0xBD, 0x0153), (0xBE, 0x0178)]
        for (byte, v) in changes { t[byte - 0x80] = v }
        return t
    }()
}
