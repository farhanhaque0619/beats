import Foundation

/// A parsed `Content-Type` header.
public struct ContentType: Hashable, Sendable {
    /// Lowercased top-level type ("text").
    public var type: String
    /// Lowercased subtype ("plain").
    public var subtype: String
    /// Parameters with lowercased names. RFC 2231 continuations are joined and charset-decoded;
    /// RFC 2047 encoded words in values are decoded.
    public var parameters: [String: String]

    public init(type: String, subtype: String, parameters: [String: String] = [:]) {
        self.type = type.asciiLowercased
        self.subtype = subtype.asciiLowercased
        self.parameters = parameters
    }

    /// `type/subtype`, lowercased.
    public var mimeType: String { "\(type)/\(subtype)" }

    public var charset: String? { parameters["charset"] }
    public var boundary: String? { parameters["boundary"] }
    public var isMultipart: Bool { type == "multipart" }
    public var isText: Bool { type == "text" }

    /// RFC 2045's default: `text/plain; charset=us-ascii`.
    public static let defaultPlain = ContentType(type: "text", subtype: "plain", parameters: ["charset": "us-ascii"])

    /// Parses a Content-Type value. Anything unusable becomes `text/plain` (keeping parameters
    /// such as charset that could be read).
    public static func parse(_ value: String) -> ContentType {
        let (main, params) = HeaderParameters.split(value)
        var token = main
        var extra: [String: String] = [:]
        // "text/plain charset=utf-8" (missing semicolon)
        if let space = token.firstIndex(where: { $0 == " " || $0 == "\t" }) {
            let rest = String(token[space...])
            token = String(token[..<space])
            if rest.contains("=") { extra = HeaderParameters.split(";" + rest).parameters }
        }
        var parameters = extra.merging(params) { _, new in new }
        token = token.trimmingCharacters(in: CharacterSet(charactersIn: " \t\"'")).asciiLowercased
        let pieces = token.split(separator: "/", maxSplits: 1, omittingEmptySubsequences: false)
        var type = pieces.first.map(String.init)?.trimmingCharacters(in: .whitespaces) ?? ""
        var subtype = pieces.count > 1 ? String(pieces[1]).trimmingCharacters(in: .whitespaces) : ""
        if pieces.count == 1 {
            switch type {
            case "text": subtype = "plain"
            case "html": type = "text"; subtype = "html"
            default: break
            }
        }
        if !isToken(type) || !isToken(subtype) || type.isEmpty || subtype.isEmpty {
            type = "text"
            subtype = "plain"
            if parameters["charset"] == nil { parameters["charset"] = "us-ascii" }
        }
        return ContentType(type: type, subtype: subtype, parameters: parameters)
    }

    static func isToken(_ s: String) -> Bool {
        for b in s.utf8 {
            if b <= 32 || b >= 127 { return false }
            switch b {
            case ASCII.lparen, ASCII.rparen, ASCII.lt, ASCII.gt, ASCII.at, ASCII.comma, ASCII.semicolon, ASCII.colon,
                 ASCII.backslash, ASCII.quote, ASCII.slash, 0x5B, 0x5D, ASCII.question, ASCII.equals:
                return false
            default: continue
            }
        }
        return true
    }
}

extension ContentType: CustomStringConvertible {
    public var description: String {
        var s = mimeType
        for key in parameters.keys.sorted() {
            if let value = parameters[key] { s += "; \(key)=\"\(value)\"" }
        }
        return s
    }
}

/// A parsed `Content-Disposition` header.
public struct ContentDisposition: Hashable, Sendable {
    /// Lowercased disposition type: "inline", "attachment", or whatever the sender wrote.
    public var type: String
    /// Parameters with lowercased names, decoded like `ContentType.parameters`.
    public var parameters: [String: String]
    /// The `filename` parameter, decoded and stripped of any directory components.
    public var filename: String?

    public init(type: String, parameters: [String: String] = [:]) {
        self.type = type.asciiLowercased
        self.parameters = parameters
        self.filename = parameters["filename"].flatMap(HeaderParameters.sanitizeFilename)
    }

    public var isAttachment: Bool { type == "attachment" }
    public var isInline: Bool { type == "inline" }

    /// Parses a Content-Disposition value. Tolerates a missing type ("filename=x.pdf" alone) and
    /// a missing semicolon ("attachment filename=x.pdf").
    public static func parse(_ value: String) -> ContentDisposition {
        let (main, params) = HeaderParameters.split(value)
        var parameters = params
        let text = main.trimmingCharacters(in: .whitespaces)
        let firstWord = text.prefix(while: { !$0.isWhitespace && $0 != "=" })
        var type = String(firstWord).trimmingCharacters(in: CharacterSet(charactersIn: "\"'")).asciiLowercased
        if text.contains("=") {
            let rest: Substring
            if firstWord.endIndex < text.endIndex, text[firstWord.endIndex].isWhitespace {
                rest = text[firstWord.endIndex...]
            } else {
                type = "attachment"
                rest = Substring(text)
            }
            let extra = HeaderParameters.split(";" + rest).parameters
            parameters = extra.merging(params) { _, new in new }
        }
        if type.isEmpty { type = "attachment" }
        return ContentDisposition(type: type, parameters: parameters)
    }
}

/// Header parameter parsing shared by Content-Type and Content-Disposition (RFC 2045, RFC 2231).
enum HeaderParameters {
    struct RawParameter {
        var name: String
        var value: String
    }

    /// Splits `main; a=b; c="d"` into the main value and decoded parameters.
    static func split(_ value: String) -> (main: String, parameters: [String: String]) {
        let s = Array(value.unicodeScalars)
        var i = 0
        var main = String.UnicodeScalarView()
        var depth = 0
        var inQuote = false
        while i < s.count {
            let c = s[i]
            if inQuote {
                if c == "\\", i + 1 < s.count { main.append(c); main.append(s[i + 1]); i += 2; continue }
                if c == "\"" { inQuote = false }
                main.append(c)
                i += 1
                continue
            }
            if c == "\"" { inQuote = true; main.append(c); i += 1; continue }
            if c == "(" { depth += 1; i += 1; continue }
            if c == ")" { depth = max(0, depth - 1); i += 1; continue }
            if depth > 0 { i += 1; continue }
            if c == ";" { break }
            main.append(c)
            i += 1
        }
        let raws = parseRaw(s, from: i)
        return (String(main).trimmedWhitespace, assemble(raws))
    }

    /// Reads `; name=value` pairs starting at `start` (which points at a ";" or the end).
    static func parseRaw(_ s: [Unicode.Scalar], from start: Int) -> [RawParameter] {
        var result: [RawParameter] = []
        var i = start
        let n = s.count
        while i < n {
            // Skip separators and whitespace.
            while i < n && (s[i] == ";" || s[i] == " " || s[i] == "\t" || s[i] == "\r" || s[i] == "\n") { i += 1 }
            if i >= n { break }
            // Name.
            var name = String.UnicodeScalarView()
            while i < n && s[i] != "=" && s[i] != ";" {
                name.append(s[i])
                i += 1
            }
            guard i < n, s[i] == "=" else { continue }   // flag without value: ignore
            i += 1
            while i < n && (s[i] == " " || s[i] == "\t") { i += 1 }
            var value = String.UnicodeScalarView()
            if i < n && s[i] == "\"" {
                i += 1
                while i < n {
                    let c = s[i]
                    if c == "\\" && i + 1 < n {
                        // Keep backslashes that don't escape a quote or backslash (Windows paths).
                        let next = s[i + 1]
                        if next == "\"" || next == "\\" { value.append(next); i += 2; continue }
                        value.append(c)
                        i += 1
                        continue
                    }
                    if c == "\"" { i += 1; break }
                    value.append(c)
                    i += 1
                }
                // Junk between the closing quote and the next ";" is ignored.
                while i < n && s[i] != ";" { i += 1 }
            } else {
                while i < n && s[i] != ";" {
                    value.append(s[i])
                    i += 1
                }
            }
            let key = String(name).trimmingCharacters(in: CharacterSet(charactersIn: " \t\r\n\"")).asciiLowercased
            guard !key.isEmpty else { continue }
            var v = String(value)
            if !v.isEmpty, v.first == " " || v.last == " " || v.last == "\t" { v = v.trimmingCharacters(in: .whitespaces) }
            result.append(RawParameter(name: key, value: v))
        }
        return result
    }

    private struct Segment {
        var index: Int
        var encoded: Bool
        var value: String
    }

    /// Joins RFC 2231 continuations (`name*0*=`, `name*1=`), decodes extended values
    /// (`charset'lang'%XX`) and RFC 2047 words. Extended values win over plain ones.
    static func assemble(_ raws: [RawParameter]) -> [String: String] {
        var plain: [String: String] = [:]
        var segments: [String: [Segment]] = [:]
        for raw in raws {
            if let star = raw.name.firstIndex(of: "*") {
                let base = String(raw.name[..<star])
                let rest = raw.name[raw.name.index(after: star)...]
                guard !base.isEmpty else { continue }
                if rest.isEmpty {
                    segments[base, default: []].append(Segment(index: -1, encoded: true, value: raw.value))
                } else {
                    let encoded = rest.hasSuffix("*")
                    let digits = encoded ? rest.dropLast() : rest
                    guard let index = Int(digits), index >= 0, index < 10_000 else { continue }
                    segments[base, default: []].append(Segment(index: index, encoded: encoded, value: raw.value))
                }
            } else if plain[raw.name] == nil {
                plain[raw.name] = raw.value
            }
        }
        var result: [String: String] = [:]
        for (name, value) in plain {
            result[name] = value.contains("=?") ? EncodedWord.decode(value) : value
        }
        for (name, segs) in segments {
            // A lone "name*" is the extended form of the whole value; otherwise sort the pieces.
            let ordered: [Segment]
            if let single = segs.first(where: { $0.index == -1 }) {
                ordered = [single]
            } else {
                var seen = Set<Int>()
                ordered = segs.sorted { $0.index < $1.index }.filter { seen.insert($0.index).inserted }
            }
            var bytes: [UInt8] = []
            var charset: String?
            for (position, seg) in ordered.enumerated() {
                if seg.encoded {
                    var v = Substring(seg.value)
                    if position == 0 {
                        let parts = v.split(separator: "'", maxSplits: 2, omittingEmptySubsequences: false)
                        if parts.count == 3 {
                            let cs = parts[0].trimmingCharacters(in: .whitespaces)
                            charset = cs.isEmpty ? nil : cs
                            v = parts[2]
                        }
                    }
                    bytes.append(contentsOf: percentDecode(v))
                } else {
                    bytes.append(contentsOf: Array(seg.value.utf8))
                }
            }
            var value = Charset.decode(Data(bytes), charset: charset)
            if value.contains("=?") { value = EncodedWord.decode(value) }
            result[name] = value
        }
        return result
    }

    static func percentDecode(_ s: Substring) -> [UInt8] {
        let b = Array(s.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var i = 0
        while i < b.count {
            if b[i] == ASCII.percent, i + 2 < b.count, let hi = hexValue(b[i + 1]), let lo = hexValue(b[i + 2]) {
                out.append(hi << 4 | lo)
                i += 3
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return out
    }

    /// Makes an attachment name safe to show and save: no directories, control characters,
    /// bidirectional overrides (`invoice\u{202E}fdp.exe` would read as "invoiceexe.pdf") or
    /// surrounding whitespace. Returns nil when nothing usable is left.
    static func sanitizeFilename(_ name: String) -> String? {
        var s = name
        if let sep = s.lastIndex(where: { $0 == "/" || $0 == "\\" }) {
            s = String(s[s.index(after: sep)...])
        }
        s = String(String.UnicodeScalarView(s.unicodeScalars.filter { scalar in
            let v = scalar.value
            return v >= 0x20 && v != 0x7F && !(0x80...0x9F).contains(v) && !isBidiControl(v)
        }))
        s = s.trimmingCharacters(in: .whitespacesAndNewlines)
        if s == "." || s == ".." { return nil }
        return s.isEmpty ? nil : s
    }

    /// Bidirectional formatting characters (embeddings, overrides, isolates, marks).
    static func isBidiControl(_ v: UInt32) -> Bool {
        (0x202A...0x202E).contains(v) || (0x2066...0x2069).contains(v) || v == 0x200E || v == 0x200F || v == 0x061C
    }
}
