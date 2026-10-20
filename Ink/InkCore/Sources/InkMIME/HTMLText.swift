import Foundation

/// HTML → readable plain text, entity decoding and escaping.
public enum HTMLText {
    /// Converts an HTML email to plain text in one pass, without regular expressions.
    ///
    /// Drops `<head>`, `<style>`, `<script>`, `<title>`, comments (incl. Outlook conditional
    /// comments) and invisible padding characters; keeps hidden preheader text. Block elements
    /// become line breaks (paragraphs a blank line, Outlook's `MsoNormal` paragraphs a single one),
    /// list items get a bullet, table cells are separated by spaces, `<pre>` keeps its whitespace,
    /// entities are decoded and everything else has its whitespace collapsed. At most one blank
    /// line in a row; leading/trailing whitespace trimmed. A tag cut off at the end is ignored.
    public static func toPlainText(_ html: String) -> String {
        let bytes = Array(html.utf8)
        var scanner = HTMLScanner(bytes)
        var out = PlainTextWriter()
        var inHead = false
        var preDepth = 0
        var listStack: [(ordered: Bool, counter: Int)] = []
        var sawBody = false
        var msoParagraph = false

        while let token = scanner.next() {
            switch token {
            case .text(let r):
                if inHead {
                    // Visible text inside an unclosed <head> means the body has started.
                    guard HTMLQuoteFinder.containsVisibleText(bytes, r) else { continue }
                    inHead = false
                }
                out.appendText(bytes, r, preformatted: preDepth > 0)
            case .rawText, .comment, .other:
                continue
            case .tag(let tag):
                let name = tag.name
                if name == "head" {
                    if tag.isEnd { inHead = false } else if !sawBody { inHead = true }
                    continue
                }
                if name == "body" { inHead = false; sawBody = true; continue }
                if inHead {
                    // Any non-head start tag inside an unclosed <head> means the body has started.
                    if !tag.isEnd && !headOnlyElements.contains(name) { inHead = false } else { continue }
                }
                switch name {
                case "br":
                    out.hardBreak()
                case "pre", "listing":
                    out.blockBreak(1)
                    preDepth = max(0, preDepth + (tag.isEnd ? -1 : (tag.selfClosing ? 0 : 1)))
                case "li":
                    out.blockBreak(1)
                    if !tag.isEnd {
                        if let last = listStack.last, last.ordered {
                            listStack[listStack.count - 1].counter += 1
                            out.appendMarker("\(last.counter + 1). ")
                        } else {
                            out.appendMarker("• ")
                        }
                    }
                case "ul", "ol", "menu", "dir":
                    out.blockBreak(listStack.isEmpty ? 2 : 1)
                    if tag.isEnd {
                        if !listStack.isEmpty { listStack.removeLast() }
                    } else if !tag.selfClosing {
                        listStack.append((ordered: name == "ol", counter: 0))
                    }
                case "td", "th":
                    if !tag.isEnd { out.cellBreak() }
                case "p":
                    // Outlook writes one <p class=MsoNormal> per line with no margins.
                    if !tag.isEnd {
                        msoParagraph = scanner.attribute("class", of: tag)?.asciiLowercased.contains("msonormal") ?? false
                    }
                    out.blockBreak(msoParagraph ? 1 : 2)
                case "img":
                    continue
                default:
                    if let n = blockBreaks[name] { out.blockBreak(n) }
                }
            }
        }
        return out.finish()
    }

    /// Elements that belong in `<head>`; anything else there starts the body.
    static let headOnlyElements: Set<String> = ["meta", "link", "title", "style", "script", "base", "noscript", "template", "xml", "o:officedocumentsettings"]

    /// Line breaks requested around block elements (1 = new line, 2 = blank line).
    static let blockBreaks: [String: Int] = [
        "div": 1, "tr": 1, "dt": 1, "dd": 1, "section": 1, "article": 1, "header": 1, "footer": 1, "nav": 1, "aside": 1,
        "main": 1, "figure": 1, "figcaption": 1, "address": 1, "center": 1, "form": 1, "fieldset": 1, "legend": 1,
        "caption": 1, "details": 1, "summary": 1, "option": 1, "table": 1, "tbody": 1, "thead": 1, "tfoot": 1,
        "h1": 2, "h2": 2, "h3": 2, "h4": 2, "h5": 2, "h6": 2, "blockquote": 2, "hr": 2, "dl": 1, "body": 1, "html": 1,
    ]

    /// Decodes named (HTML 4 + common HTML5) and numeric character references. Unknown names are
    /// left as they are; `&#0;`, surrogates and out-of-range numbers become U+FFFD, and
    /// `&#128;`–`&#159;` map through Windows-1252 as browsers do.
    public static func decodeEntities(_ s: String) -> String {
        guard s.contains("&") else { return s }
        let bytes = Array(s.utf8)
        return decodeEntities(bytes, range: 0..<bytes.count, inAttribute: false)
    }

    static func decodeEntities(_ b: [UInt8], range: Range<Int>, inAttribute: Bool) -> String {
        guard b.firstIndex(of: ASCII.amp, from: range.lowerBound, to: range.upperBound) != nil else {
            return String(decoding: b[range], as: UTF8.self)
        }
        var out: [UInt8] = []
        out.reserveCapacity(range.count)
        var i = range.lowerBound
        while i < range.upperBound {
            if b[i] == ASCII.amp, let (scalar, next) = HTMLEntities.decode(b, at: i, end: range.upperBound, inAttribute: inAttribute) {
                appendUTF8(scalar, to: &out)
                i = next
            } else {
                out.append(b[i])
                i += 1
            }
        }
        return String(decoding: out, as: UTF8.self)
    }

    /// Escapes `& < > " '` for use in HTML text or attribute values.
    public static func escape(_ s: String) -> String {
        var needs = false
        for b in s.utf8 where b == ASCII.amp || b == ASCII.lt || b == ASCII.gt || b == ASCII.quote || b == ASCII.apostrophe {
            needs = true
            break
        }
        guard needs else { return s }
        var out: [UInt8] = []
        out.reserveCapacity(s.utf8.count + 16)
        for b in s.utf8 {
            switch b {
            case ASCII.amp: out.append(contentsOf: Array("&amp;".utf8))
            case ASCII.lt: out.append(contentsOf: Array("&lt;".utf8))
            case ASCII.gt: out.append(contentsOf: Array("&gt;".utf8))
            case ASCII.quote: out.append(contentsOf: Array("&quot;".utf8))
            case ASCII.apostrophe: out.append(contentsOf: Array("&#39;".utf8))
            default: out.append(b)
            }
        }
        return String(decoding: out, as: UTF8.self)
    }
}

@inline(__always)
func appendUTF8(_ scalar: Unicode.Scalar, to out: inout [UInt8]) {
    let v = scalar.value
    switch v {
    case 0..<0x80:
        out.append(UInt8(v))
    case 0x80..<0x800:
        out.append(UInt8(0xC0 | (v >> 6)))
        out.append(UInt8(0x80 | (v & 0x3F)))
    case 0x800..<0x10000:
        out.append(UInt8(0xE0 | (v >> 12)))
        out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (v & 0x3F)))
    default:
        out.append(UInt8(0xF0 | (v >> 18)))
        out.append(UInt8(0x80 | ((v >> 12) & 0x3F)))
        out.append(UInt8(0x80 | ((v >> 6) & 0x3F)))
        out.append(UInt8(0x80 | (v & 0x3F)))
    }
}

/// Accumulates plain text with collapsed whitespace and bounded blank lines.
struct PlainTextWriter {
    private(set) var out: [UInt8] = []
    private var pendingSpace = false
    private var pendingBreaks = 0

    init() { out.reserveCapacity(4096) }

    /// Requests at least `n` line breaks before the next text (1 = new line, 2 = blank line).
    mutating func blockBreak(_ n: Int) {
        pendingBreaks = max(pendingBreaks, n)
    }

    /// `<br>`: each one adds a line break.
    mutating func hardBreak() {
        pendingBreaks = min(pendingBreaks + 1, 2)
        if pendingBreaks == 1 && lastIsNewline { pendingBreaks = 2 }
    }

    mutating func cellBreak() {
        pendingSpace = true
    }

    mutating func appendMarker(_ marker: String) {
        flush()
        out.append(contentsOf: Array(marker.utf8))
        pendingSpace = false
    }

    private var lastIsNewline: Bool { out.last == ASCII.lf }

    private var trailingNewlines: Int {
        var count = 0
        var i = out.count - 1
        while i >= 0 && out[i] == ASCII.lf { count += 1; i -= 1 }
        return count
    }

    private mutating func flush() {
        if out.isEmpty {
            pendingBreaks = 0
            pendingSpace = false
            return
        }
        if pendingBreaks > 0 {
            while let last = out.last, last == ASCII.space || last == ASCII.tab { out.removeLast() }
            let have = trailingNewlines
            let want = min(pendingBreaks, 2)
            if want > have { for _ in 0..<(want - have) { out.append(ASCII.lf) } }
        } else if pendingSpace, let last = out.last, last != ASCII.lf, last != ASCII.space {
            out.append(ASCII.space)
        }
        pendingBreaks = 0
        pendingSpace = false
    }

    /// Appends text bytes, decoding entities and collapsing whitespace (unless preformatted).
    mutating func appendText(_ b: [UInt8], _ range: Range<Int>, preformatted: Bool) {
        var i = range.lowerBound
        let end = range.upperBound
        var scratch: [UInt8] = []
        while i < end {
            let c = b[i]
            if c == ASCII.amp, let (scalar, next) = HTMLEntities.decode(b, at: i, end: end) {
                scratch.removeAll(keepingCapacity: true)
                appendUTF8(scalar, to: &scratch)
                appendScalarBytes(scratch, scalar: scalar.value, preformatted: preformatted, b: b, at: i, end: end)
                i = next
                continue
            }
            if c < 0x80 {
                if isASCIIWhitespace(c) {
                    if preformatted {
                        if c == ASCII.lf { flush(); out.append(ASCII.lf) } else if c != ASCII.cr { flush(); out.append(c) }
                    } else {
                        pendingSpace = true
                    }
                } else if c >= 0x20 {
                    flush()
                    out.append(c)
                }
                i += 1
                continue
            }
            // Multi-byte UTF-8: look at the scalar for invisible/space characters.
            let len = c >= 0xF0 ? 4 : (c >= 0xE0 ? 3 : (c >= 0xC0 ? 2 : 1))
            let stop = min(i + len, end)
            let scalar = decodeScalar(b, i, stop)
            appendScalarBytes(Array(b[i..<stop]), scalar: scalar, preformatted: preformatted, b: b, at: i, end: end)
            i = stop
        }
    }

    private func decodeScalar(_ b: [UInt8], _ start: Int, _ end: Int) -> UInt32 {
        let len = end - start
        let c = UInt32(b[start])
        switch len {
        case 2: return (c & 0x1F) << 6 | UInt32(b[start + 1] & 0x3F)
        case 3: return (c & 0x0F) << 12 | UInt32(b[start + 1] & 0x3F) << 6 | UInt32(b[start + 2] & 0x3F)
        case 4: return (c & 0x07) << 18 | UInt32(b[start + 1] & 0x3F) << 12 | UInt32(b[start + 2] & 0x3F) << 6 | UInt32(b[start + 3] & 0x3F)
        default: return c
        }
    }

    private mutating func appendScalarBytes(_ bytes: [UInt8], scalar: UInt32, preformatted: Bool, b: [UInt8], at: Int, end: Int) {
        switch scalar {
        case 0x00A0, 0x2000...0x200A, 0x202F, 0x205F, 0x3000, 0x1680:
            // Non-breaking and typographic spaces read as plain spaces, but a block holding only
            // `&nbsp;` (Outlook's empty paragraph) must still make a blank line: keep a no-break
            // space marker here and let `finish()` turn it into ordinary whitespace.
            if preformatted { flush(); out.append(ASCII.space) } else { flush(); out.append(contentsOf: [0xC2, 0xA0]) }
        case 0x09, 0x0A, 0x0D, 0x20:
            if preformatted { flush(); out.append(scalar == 0x0A ? ASCII.lf : ASCII.space) } else { pendingSpace = true }
        case 0x200B, 0x200C, 0x2060, 0xFEFF, 0x00AD, 0x034F, 0x180E, 0x2061...0x2064, 0x200E, 0x200F:
            // Zero-width padding used by preheaders. ZWNJ between letters (Persian) is kept.
            if scalar == 0x200C, let last = out.last, last != ASCII.space, last != ASCII.lf, !pendingSpace, nextIsLetter(b, at: at, end: end) {
                flush()
                out.append(contentsOf: bytes)
            }
        case 0..<0x20:
            break
        default:
            flush()
            out.append(contentsOf: bytes)
        }
    }

    private func nextIsLetter(_ b: [UInt8], at: Int, end: Int) -> Bool {
        // Skip the ZWNJ itself (3 bytes raw, or an entity), then check the next byte.
        var i = at
        if b[i] == ASCII.amp {
            while i < end && b[i] != ASCII.semicolon { i += 1 }
            i += 1
        } else {
            i += 3
        }
        guard i < end else { return false }
        let c = b[i]
        return c >= 0x80 || isASCIILetter(c)
    }

    mutating func finish() -> String {
        var result: [UInt8] = []
        result.reserveCapacity(out.count)
        var blank = 0
        var start = 0
        let n = out.count
        while start <= n {
            let lf = out.firstIndex(of: ASCII.lf, from: start, to: n) ?? n
            let line = Self.cleanLine(out, start, lf)
            if line.isEmpty {
                blank += 1
            } else {
                if !result.isEmpty {
                    result.append(ASCII.lf)
                    if blank > 0 { result.append(ASCII.lf) }
                }
                blank = 0
                result.append(contentsOf: line)
            }
            start = lf + 1
        }
        return String(decoding: result, as: UTF8.self)
    }

    /// One output line without trailing whitespace. Runs of whitespace that contain a no-break
    /// space become a single space (none at the start of the line); plain runs are kept as they are
    /// (indentation in `<pre>`).
    static func cleanLine(_ b: [UInt8], _ start: Int, _ end: Int) -> [UInt8] {
        var hasNBSP = false
        var k = start
        while k + 1 < end {
            if b[k] == 0xC2 && b[k + 1] == 0xA0 { hasNBSP = true; break }
            k += 1
        }
        var line: [UInt8]
        if !hasNBSP {
            line = Array(b[start..<end])
        } else {
            line = []
            line.reserveCapacity(end - start)
            var i = start
            while i < end {
                let c = b[i]
                let isNB = c == 0xC2 && i + 1 < end && b[i + 1] == 0xA0
                guard isNB || c == ASCII.space || c == ASCII.tab else {
                    line.append(c)
                    i += 1
                    continue
                }
                var j = i
                var runHasNB = false
                while j < end {
                    if b[j] == 0xC2 && j + 1 < end && b[j + 1] == 0xA0 {
                        runHasNB = true
                        j += 2
                    } else if b[j] == ASCII.space || b[j] == ASCII.tab {
                        j += 1
                    } else {
                        break
                    }
                }
                if runHasNB {
                    if !line.isEmpty && j < end { line.append(ASCII.space) }
                } else {
                    line.append(contentsOf: b[i..<j])
                }
                i = j
            }
        }
        while let last = line.last, last == ASCII.space || last == ASCII.tab { line.removeLast() }
        return line
    }
}
