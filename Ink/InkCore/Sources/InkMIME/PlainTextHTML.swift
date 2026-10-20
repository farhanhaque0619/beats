import Foundation

/// Plain text → HTML fragments: escaping, links, and `>` quotes as nested blockquotes.
public enum PlainTextHTML {
    /// Escapes `text` and turns URLs (`http(s)://`, `www.`, `mailto:`) and email addresses into links.
    /// Line breaks are kept as `\n` (render inside `white-space: pre-wrap`).
    public static func render(_ text: String) -> String {
        linkify(text.normalizedNewlines)
    }

    /// Renders plain text with `>`-quoted runs as nested `<blockquote>`s and a `-- ` signature in a
    /// muted block. Lines are separated by `\n` for `white-space: pre-wrap` containers; no newline is
    /// placed next to a block tag, so no blank lines appear around quotes.
    public static func renderQuoted(_ text: String) -> String {
        let lines = text.normalizedNewlines.components(separatedBy: "\n")
        var out = ""
        out.reserveCapacity(text.utf8.count + text.utf8.count / 4)
        var depth = 0
        var firstInBlock = true
        var inSignature = false
        for line in lines {
            let (lineDepth, content) = quoteDepth(line)
            if lineDepth == 0 && !inSignature && (line == "-- " || line == "--") && depth == 0 {
                out += "<div class=\"ink-signature\">"
                inSignature = true
                firstInBlock = true
            }
            if lineDepth != depth {
                if lineDepth > depth {
                    out += String(repeating: "<blockquote>", count: lineDepth - depth)
                } else {
                    out += String(repeating: "</blockquote>", count: depth - lineDepth)
                }
                depth = lineDepth
                firstInBlock = true
            }
            if !firstInBlock { out += "\n" }
            out += linkify(content)
            firstInBlock = false
        }
        out += String(repeating: "</blockquote>", count: depth)
        if inSignature { out += "</div>" }
        return out
    }

    /// Counts leading `>` markers (allowing `> > ` and `>>`), returning the depth and the rest.
    static func quoteDepth(_ line: String) -> (Int, String) {
        guard line.hasPrefix(">") else { return (0, line) }
        var depth = 0
        var rest = Substring(line)
        while let first = rest.first {
            if first == ">" { depth += 1; rest = rest.dropFirst() } else if first == " " && rest.dropFirst().first == ">" { rest = rest.dropFirst() } else { break }
        }
        if rest.first == " " { rest = rest.dropFirst() }
        return (depth, String(rest))
    }

    /// Escapes and links one piece of text.
    static func linkify(_ text: String) -> String {
        let b = Array(text.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count + 32)
        var i = 0
        var plainStart = 0
        func flushPlain(_ end: Int) {
            if end > plainStart { appendEscaped(b[plainStart..<end], to: &out) }
        }
        while i < b.count {
            let c = b[i]
            let boundary = i == 0 || !isWordByte(b[i - 1])
            if boundary, (c == 0x68 || c == 0x48 || c == 0x77 || c == 0x57 || c == 0x6D || c == 0x4D), let (end, href) = urlAt(b, i) {
                flushPlain(i)
                appendLink(href: href, text: b[i..<end], to: &out)
                i = end
                plainStart = i
                continue
            }
            if c == ASCII.at, let (start, end) = emailAround(b, i, minStart: plainStart) {
                flushPlain(start)
                let address = String(decoding: b[start..<end], as: UTF8.self)
                appendLink(href: "mailto:" + address, text: b[start..<end], to: &out)
                i = end
                plainStart = i
                continue
            }
            i += 1
        }
        flushPlain(b.count)
        return String(decoding: out, as: UTF8.self)
    }

    static func isWordByte(_ c: UInt8) -> Bool {
        isASCIILetter(c) || isASCIIDigit(c) || c == ASCII.underscore || c >= 0x80
    }

    static func appendEscaped(_ s: ArraySlice<UInt8>, to out: inout [UInt8]) {
        for c in s {
            switch c {
            case ASCII.amp: out.append(contentsOf: [ASCII.amp, 0x61, 0x6D, 0x70, ASCII.semicolon])
            case ASCII.lt: out.append(contentsOf: [ASCII.amp, 0x6C, 0x74, ASCII.semicolon])
            case ASCII.gt: out.append(contentsOf: [ASCII.amp, 0x67, 0x74, ASCII.semicolon])
            case ASCII.quote: out.append(contentsOf: [ASCII.amp, 0x71, 0x75, 0x6F, 0x74, ASCII.semicolon])
            default: out.append(c)
            }
        }
    }

    static func appendLink(href: String, text: ArraySlice<UInt8>, to out: inout [UInt8]) {
        out.append(contentsOf: Array("<a href=\"".utf8))
        appendEscaped(Array(href.utf8)[...], to: &out)
        out.append(contentsOf: Array("\">".utf8))
        appendEscaped(text, to: &out)
        out.append(contentsOf: Array("</a>".utf8))
    }

    static let schemes: [(prefix: [UInt8], addHTTP: Bool)] = [
        (Array("https://".utf8), false), (Array("http://".utf8), false), (Array("mailto:".utf8), false), (Array("www.".utf8), true),
    ]

    /// A URL starting at `i`: returns its end and the href.
    static func urlAt(_ b: [UInt8], _ i: Int) -> (Int, String)? {
        for scheme in schemes where b.hasBytesCaseInsensitive(scheme.prefix, at: i) {
            var j = i + scheme.prefix.count
            var parens = 0
            while j < b.count {
                let c = b[j]
                if c <= 0x20 || c == ASCII.lt || c == ASCII.gt || c == ASCII.quote || c == 0x7F { break }
                if c == ASCII.lparen { parens += 1 }
                if c == ASCII.rparen {
                    if parens == 0 { break }
                    parens -= 1
                }
                j += 1
            }
            // Trailing punctuation belongs to the sentence, not the URL.
            while j > i + scheme.prefix.count, let last = Optional(b[j - 1]),
                  last == ASCII.dot || last == ASCII.comma || last == ASCII.semicolon || last == ASCII.colon || last == ASCII.bang || last == ASCII.question || last == ASCII.apostrophe || last == 0x2A {
                j -= 1
            }
            guard j > i + scheme.prefix.count else { return nil }
            // "www." must be followed by a host, "mailto:" by an address.
            let rest = b[(i + scheme.prefix.count)..<j]
            if scheme.addHTTP && !rest.contains(ASCII.dot) { return nil }
            let text = String(decoding: b[i..<j], as: UTF8.self)
            return (j, scheme.addHTTP ? "http://" + text : text)
        }
        return nil
    }

    static func isEmailLocalByte(_ c: UInt8) -> Bool {
        isASCIILetter(c) || isASCIIDigit(c) || c == ASCII.dot || c == ASCII.dash || c == ASCII.underscore || c == 0x2B || c == ASCII.percent || c == ASCII.apostrophe
    }

    static func isEmailDomainByte(_ c: UInt8) -> Bool {
        isASCIILetter(c) || isASCIIDigit(c) || c == ASCII.dot || c == ASCII.dash
    }

    /// An email address around the `@` at `at` (not reaching back before `minStart`).
    static func emailAround(_ b: [UInt8], _ at: Int, minStart: Int) -> (Int, Int)? {
        var s = at
        while s > minStart && isEmailLocalByte(b[s - 1]) { s -= 1 }
        while s < at && (b[s] == ASCII.dot || b[s] == ASCII.apostrophe) { s += 1 }
        guard s < at else { return nil }
        var e = at + 1
        while e < b.count && isEmailDomainByte(b[e]) { e += 1 }
        while e > at + 1 && (b[e - 1] == ASCII.dot || b[e - 1] == ASCII.dash) { e -= 1 }
        let domain = b[(at + 1)..<e]
        guard domain.count >= 3, let dot = domain.lastIndex(of: ASCII.dot), dot > at + 1, dot < e - 1 else { return nil }
        return (s, e)
    }
}
