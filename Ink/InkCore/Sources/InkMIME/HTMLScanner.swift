import Foundation

/// A tag found by `HTMLScanner`. Ranges index into the scanner's UTF-8 bytes.
struct HTMLTag {
    /// Whole tag, from "<" to just past ">".
    var range: Range<Int>
    /// Lowercased element name.
    var name: String
    var isEnd: Bool
    var selfClosing: Bool
    /// Bytes between the name and the closing ">" (attributes).
    var attributeRange: Range<Int>
}

struct HTMLAttribute {
    /// Lowercased attribute name.
    var name: String
    /// Entity-decoded value ("" for a bare attribute).
    var value: String
    /// Range of the raw value bytes (without quotes), when there is a value.
    var valueRange: Range<Int>?
    /// Range of the whole `name="value"` text.
    var range: Range<Int>
}

enum HTMLToken {
    case text(Range<Int>)
    case tag(HTMLTag)
    case comment(Range<Int>)
    /// Contents of script/style/title/textarea/xmp/iframe/noembed/noframes elements.
    case rawText(Range<Int>, element: String)
    /// Doctype, CDATA, processing instructions, bogus comments, a truncated tag at the end.
    case other(Range<Int>)
}

/// A forgiving, allocation-light HTML tokenizer over UTF-8 bytes. It never fails: anything that
/// isn't a well-formed tag is returned as text, and a tag cut off at the end of the input
/// (partial fetches) is swallowed rather than shown.
struct HTMLScanner {
    let b: [UInt8]
    private(set) var pos: Int
    private var rawTextElement: String?

    static let rawTextElements: Set<String> = ["script", "style", "title", "textarea", "xmp", "iframe", "noembed", "noframes", "plaintext"]

    init(_ bytes: [UInt8]) {
        b = bytes
        pos = 0
    }

    init(_ html: String) {
        self.init(Array(html.utf8))
    }

    mutating func next() -> HTMLToken? {
        let n = b.count
        if let element = rawTextElement {
            rawTextElement = nil
            let close = Array(("</" + element).utf8)
            let start = pos
            var end = n
            var search = pos
            while let found = b.firstRangeCaseInsensitive(of: close, from: search, to: n) {
                let after = found + close.count
                if after >= n || b[after] == ASCII.gt || isASCIIWhitespace(b[after]) || b[after] == ASCII.slash {
                    end = found
                    break
                }
                search = found + 1
            }
            pos = end
            if end > start { return .rawText(start..<end, element: element) }
        }
        guard pos < n else { return nil }
        if b[pos] == ASCII.lt, let token = scanMarkup() {
            return token
        }
        // Text up to the next "<" that starts markup.
        let start = pos
        var i = pos + 1
        while i < n {
            if b[i] == ASCII.lt, i + 1 < n {
                let c = b[i + 1]
                if isASCIILetter(c) || c == ASCII.slash || c == ASCII.bang || c == ASCII.question { break }
            }
            i += 1
        }
        pos = i
        return .text(start..<i)
    }

    private mutating func scanMarkup() -> HTMLToken? {
        let n = b.count
        let start = pos
        guard start + 1 < n else { return nil }
        let c = b[start + 1]
        if c == ASCII.bang {
            if b.hasBytes([ASCII.lt, ASCII.bang, ASCII.dash, ASCII.dash], at: start) {
                var end = n
                if let close = b.firstRange(of: [ASCII.dash, ASCII.dash, ASCII.gt], from: start + 4, to: n) {
                    end = close + 3
                } else if b.hasBytes([ASCII.gt], at: start + 4) {
                    end = start + 5   // "<!-->"
                }
                pos = end
                return .comment(start..<end)
            }
            if b.hasBytesCaseInsensitive(Array("<![cdata[".utf8), at: start) {
                let close = b.firstRange(of: [0x5D, 0x5D, ASCII.gt], from: start + 9, to: n).map { $0 + 3 } ?? n
                pos = close
                return .other(start..<close)
            }
            let close = b.firstIndex(of: ASCII.gt, from: start + 2, to: n).map { $0 + 1 } ?? n
            pos = close
            return .other(start..<close)
        }
        if c == ASCII.question {
            let close = b.firstIndex(of: ASCII.gt, from: start + 2, to: n).map { $0 + 1 } ?? n
            pos = close
            return .other(start..<close)
        }
        var i = start + 1
        var isEnd = false
        if c == ASCII.slash {
            isEnd = true
            i += 1
            guard i < n, isASCIILetter(b[i]) else {
                // "</>" or "</ 3": bogus comment up to ">".
                let close = b.firstIndex(of: ASCII.gt, from: i, to: n).map { $0 + 1 } ?? n
                pos = close
                return .other(start..<close)
            }
        } else if !isASCIILetter(c) {
            return nil
        }
        let nameStart = i
        while i < n {
            let ch = b[i]
            if isASCIILetter(ch) || isASCIIDigit(ch) || ch == ASCII.dash || ch == ASCII.colon || ch == ASCII.underscore || ch == ASCII.dot { i += 1 } else { break }
        }
        let nameEnd = i
        // Find the closing ">" while respecting quoted attribute values.
        var quote: UInt8 = 0
        var close: Int?
        var lastSignificant: UInt8 = 0
        while i < n {
            let ch = b[i]
            if quote != 0 {
                if ch == quote { quote = 0 }
            } else if ch == ASCII.quote || ch == ASCII.apostrophe {
                // Only quotes that start an attribute value count; a stray quote in a name doesn't.
                if lastSignificant == ASCII.equals { quote = ch }
            } else if ch == ASCII.gt {
                close = i
                break
            }
            if !isASCIIWhitespace(ch) { lastSignificant = ch }
            i += 1
        }
        guard let gt = close else {
            // Unterminated tag: if a quote swallowed everything, retry ignoring quotes.
            if let plainGT = b.firstIndex(of: ASCII.gt, from: nameEnd, to: n), quote != 0,
               b.firstIndex(of: ASCII.lt, from: nameEnd, to: plainGT) == nil {
                return finishTag(start: start, nameStart: nameStart, nameEnd: nameEnd, gt: plainGT, isEnd: isEnd)
            }
            pos = n
            return .other(start..<n)
        }
        return finishTag(start: start, nameStart: nameStart, nameEnd: nameEnd, gt: gt, isEnd: isEnd)
    }

    private mutating func finishTag(start: Int, nameStart: Int, nameEnd: Int, gt: Int, isEnd: Bool) -> HTMLToken {
        let name = String(decoding: b[nameStart..<nameEnd].map(asciiLower), as: UTF8.self)
        var selfClosing = false
        var k = gt - 1
        while k > nameEnd && isASCIIWhitespace(b[k]) { k -= 1 }
        if k >= nameEnd && b[k] == ASCII.slash { selfClosing = true }
        pos = gt + 1
        if !isEnd && !selfClosing && HTMLScanner.rawTextElements.contains(name) {
            rawTextElement = name
        }
        return .tag(HTMLTag(range: start..<(gt + 1), name: name, isEnd: isEnd, selfClosing: selfClosing, attributeRange: nameEnd..<gt))
    }

    // MARK: Attributes

    func attributes(of tag: HTMLTag) -> [HTMLAttribute] {
        HTMLScanner.attributes(b, in: tag.attributeRange)
    }

    func attribute(_ name: String, of tag: HTMLTag) -> String? {
        let lower = name.asciiLowercased
        return attributes(of: tag).first { $0.name == lower }?.value
    }

    static func attributes(_ b: [UInt8], in range: Range<Int>) -> [HTMLAttribute] {
        var result: [HTMLAttribute] = []
        var i = range.lowerBound
        let end = range.upperBound
        while i < end {
            while i < end && (isASCIIWhitespace(b[i]) || b[i] == ASCII.slash) { i += 1 }
            guard i < end else { break }
            let attrStart = i
            while i < end && !isASCIIWhitespace(b[i]) && b[i] != ASCII.equals && b[i] != ASCII.slash { i += 1 }
            if i == attrStart { i += 1; continue }
            let name = String(decoding: b[attrStart..<i].map(asciiLower), as: UTF8.self)
            var j = i
            while j < end && isASCIIWhitespace(b[j]) { j += 1 }
            guard j < end, b[j] == ASCII.equals else {
                result.append(HTMLAttribute(name: name, value: "", valueRange: nil, range: attrStart..<i))
                continue
            }
            j += 1
            while j < end && isASCIIWhitespace(b[j]) { j += 1 }
            var valueRange: Range<Int>
            var after: Int
            if j < end && (b[j] == ASCII.quote || b[j] == ASCII.apostrophe) {
                let q = b[j]
                let vs = j + 1
                let ve = b.firstIndex(of: q, from: vs, to: end) ?? end
                valueRange = vs..<ve
                after = min(ve + 1, end)
            } else {
                let vs = j
                var ve = j
                while ve < end && !isASCIIWhitespace(b[ve]) { ve += 1 }
                valueRange = vs..<ve
                after = ve
            }
            let value = HTMLText.decodeEntities(b, range: valueRange, inAttribute: true)
            result.append(HTMLAttribute(name: name, value: value, valueRange: valueRange, range: attrStart..<after))
            i = after
        }
        return result
    }
}

extension HTMLAttribute {
    /// Whitespace-separated class names, lowercased.
    var classNames: [String] {
        value.asciiLowercased.split(whereSeparator: { $0 == " " || $0 == "\t" || $0 == "\n" || $0 == "\r" }).map(String.init)
    }
}

/// Elements that never have content (so they never need a matching end tag).
let htmlVoidElements: Set<String> = ["area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "param", "source", "track", "wbr", "keygen", "basefont", "frame"]
