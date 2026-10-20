import Foundation

/// The parts of an email's HTML that are safe to place inside Ink's own document.
struct SanitizedHTML {
    /// Contents of the email's `<style>` elements (sanitised), in order.
    var styles: [String]
    /// Body content without `<html>`, `<head>`, `<body>` tags.
    var body: String
    /// The `<body>` element's presentational attributes as CSS (`background-color: …; color: …`).
    var bodyStyle: String
}

/// A tolerant, single-pass HTML cleaner for displaying and quoting mail.
///
/// Removes scripts, `<head>` content, `<meta>`/`<link>`/`<base>`, frames, objects, embeds and form
/// controls, comments, event-handler attributes, `javascript:`-style URLs, and CSS expressions.
/// The result still goes into a document with a strict CSP; this is defence in depth and a way to
/// lift the email's body out of its own `<html>` wrapper.
enum HTMLSanitizer {
    static let droppedTags: Set<String> = [
        "html", "head", "body", "meta", "link", "base", "title", "script", "style", "iframe", "frame", "frameset", "object",
        "embed", "applet", "param", "form", "input", "button", "select", "option", "optgroup", "textarea", "isindex", "keygen",
        "noscript", "portal", "xml", "o:p", "plaintext",
    ]

    static let urlAttributes: Set<String> = [
        "href", "src", "background", "lowsrc", "dynsrc", "xlink:href", "poster", "data", "codebase", "cite", "srcset", "action",
        "formaction", "longdesc", "usemap", "profile", "manifest",
    ]

    static func sanitize(_ html: String, dropCIDImages: Bool = false) -> SanitizedHTML {
        let b = Array(html.utf8)
        var scanner = HTMLScanner(b)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var styles: [String] = []
        var bodyStyle = ""
        var inHead = false
        var sawBody = false
        var sawContent = false
        // Elements the email has opened and not closed, so an end tag with nothing to close
        // (a stray `</div>`) is dropped instead of closing Ink's wrapper (or a reply's quote) early.
        var open: [String] = []

        while let token = scanner.next() {
            switch token {
            case .text(let r):
                if inHead {
                    if !HTMLQuoteFinder.containsVisibleText(b, r) { continue }
                    inHead = false   // text inside an unclosed <head>: the body has started
                }
                sawContent = true
                out.append(contentsOf: b[r])
            case .rawText(let r, let element):
                if element == "style" {
                    let css = sanitizeCSS(String(decoding: b[r], as: UTF8.self))
                    if !css.trimmedWhitespace.isEmpty { styles.append(css) }
                } else if element == "xmp" || element == "plaintext" {
                    out.append(contentsOf: Array(HTMLText.escape(String(decoding: b[r], as: UTF8.self)).utf8))
                }
            case .comment, .other:
                continue
            case .tag(let tag):
                let name = tag.name
                switch name {
                case "head":
                    if !tag.isEnd && !sawBody && !sawContent { inHead = true } else if tag.isEnd { inHead = false }
                    continue
                case "body":
                    if !tag.isEnd && !sawBody {
                        sawBody = true
                        bodyStyle = bodyAttributesCSS(scanner.attributes(of: tag))
                    }
                    inHead = false
                    continue
                default:
                    break
                }
                if inHead {
                    if tag.isEnd || ["meta", "link", "base", "title", "script", "style", "noscript", "object"].contains(name) { continue }
                    inHead = false
                }
                if droppedTags.contains(name) { continue }
                if tag.isEnd {
                    // `</br>` is a line break and a stray `</p>` an empty paragraph to a browser;
                    // neither can close anything outside the email.
                    if let index = open.lastIndex(of: name) {
                        open.removeSubrange(index...)
                    } else if name != "br" && name != "p" {
                        continue
                    }
                    out.append(contentsOf: Array("</\(name)>".utf8))
                    continue
                }
                let attributes = scanner.attributes(of: tag)
                if dropCIDImages, name == "img",
                   let src = attributes.first(where: { $0.name == "src" })?.value.trimmedWhitespace.lowercased(), src.hasPrefix("cid:") {
                    continue
                }
                sawContent = true
                out.append(ASCII.lt)
                out.append(contentsOf: Array(name.utf8))
                for attribute in attributes where isSafe(attribute, element: name) {
                    // Rebuilt from the decoded value, so a broken quote can't swallow the markup after it.
                    out.append(ASCII.space)
                    out.append(contentsOf: Array(attribute.name.utf8))
                    if attribute.valueRange != nil {
                        out.append(contentsOf: [ASCII.equals, ASCII.quote])
                        out.append(contentsOf: Array(HTMLText.escape(attribute.value).utf8))
                        out.append(ASCII.quote)
                    }
                }
                if tag.selfClosing { out.append(contentsOf: [ASCII.space, ASCII.slash]) }
                out.append(ASCII.gt)
                if name == "li" || name == "dd" || name == "dt" {
                    closeImplicitly(by: name, &open)
                }
                if !htmlVoidElements.contains(name) { open.append(name) }
            }
        }
        return SanitizedHTML(styles: styles, body: String(decoding: out, as: UTF8.self), bodyStyle: bodyStyle)
    }

    /// A new `<li>` closes the open list item even through `div`s inside it (`<dd>`/`<dt>` likewise),
    /// as the HTML parser does, so a later `</div>` isn't taken to match one of those `div`s.
    static func closeImplicitly(by name: String, _ open: inout [String]) {
        let closes: Set<String> = name == "li" ? ["li"] : ["dd", "dt"]
        var index = open.count - 1
        while index >= 0 {
            let element = open[index]
            if closes.contains(element) {
                open.removeSubrange(index...)
                return
            }
            if element != "div" && element != "p" && element != "address" && specialElements.contains(element) { return }
            index -= 1
        }
    }

    /// The HTML parser's "special" elements (the ones that stop the implied-close walk above).
    static let specialElements: Set<String> = [
        "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br", "button",
        "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset", "figcaption",
        "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr",
        "html", "iframe", "img", "input", "keygen", "li", "link", "listing", "main", "marquee", "menu", "meta", "nav",
        "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext", "pre", "script", "search", "section",
        "select", "source", "style", "summary", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead",
        "title", "tr", "track", "ul", "wbr", "xmp",
    ]

    static func isSafe(_ attribute: HTMLAttribute, element: String = "") -> Bool {
        let name = attribute.name
        // Images may be data: URIs (the app inlines cid: parts that way); SVG in <img> can't run script.
        if name == "src", element == "img" || element == "image" {
            let lower = attribute.value.trimmedWhitespace.lowercased()
            if lower.hasPrefix("data:image/") { return true }
        }
        if name.hasPrefix("on") || name == "srcdoc" || name == "ping" || name == "formaction" || name == "action" || name.isEmpty {
            return false
        }
        if !name.utf8.allSatisfy({ isASCIILetter($0) || isASCIIDigit($0) || $0 == ASCII.dash || $0 == ASCII.colon || $0 == ASCII.underscore || $0 == ASCII.dot }) {
            return false
        }
        if urlAttributes.contains(name) && isDangerousURL(attribute.value) { return false }
        if name == "style" && isDangerousCSS(attribute.value) { return false }
        return true
    }

    /// Checked on bytes and scalars, not `Character`s: a combining mark after the scheme's colon
    /// would hide the prefix from `hasPrefix` (and `contains` behaves differently on Apple and Linux).
    static func isDangerousURL(_ value: String) -> Bool {
        let compact = String(String.UnicodeScalarView(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F })).asciiLowercased
        for prefix in ["javascript:", "vbscript:", "livescript:", "data:text/html", "data:application", "data:image/svg"] where compact.hasASCIIPrefix(prefix) {
            return true
        }
        return compact.containsASCII(",javascript:")
    }

    static func isDangerousCSS(_ value: String) -> Bool {
        let compact = String(String.UnicodeScalarView(value.unicodeScalars.filter { !$0.properties.isWhitespace && $0 != "\\" }))
        return ["expression(", "javascript:", "behavior:", "-moz-binding", "vbscript:"].contains { compact.containsASCIICaseInsensitive($0) }
    }

    static let dangerousCSS = ["@import", "expression(", "behavior:", "-moz-binding", "javascript:", "vbscript:", "</"]

    /// Neutralises the dangerous parts of a style sheet (expressions, bindings, `@import`).
    static func sanitizeCSS(_ css: String) -> String {
        var s = css
        for needle in dangerousCSS where s.containsASCIICaseInsensitive(needle) {
            s = replaceCaseInsensitive(s, needle, with: needle == "</" ? "<\\/" : "/*x*/")
        }
        return s
    }

    /// Replaces every ASCII-case-insensitive occurrence of the ASCII `needle`, working on UTF-8
    /// bytes so the result is the same on every platform.
    static func replaceCaseInsensitive(_ s: String, _ needle: String, with replacement: String) -> String {
        let b = Array(s.utf8)
        let n = Array(needle.asciiLowercased.utf8)
        var out: [UInt8] = []
        out.reserveCapacity(b.count)
        var from = 0
        while let i = b.firstRangeCaseInsensitive(of: n, from: from, to: b.count) {
            out.append(contentsOf: b[from..<i])
            out.append(contentsOf: Array(replacement.utf8))
            from = i + n.count
        }
        out.append(contentsOf: b[from...])
        return String(decoding: out, as: UTF8.self)
    }

    /// `<body bgcolor text background style>` as CSS for the wrapper element.
    static func bodyAttributesCSS(_ attributes: [HTMLAttribute]) -> String {
        var css: [String] = []
        for attribute in attributes {
            let value = attribute.value.trimmedWhitespace
            guard !value.isEmpty else { continue }
            switch attribute.name {
            case "bgcolor":
                if let c = cssColor(value) { css.append("background-color: \(c)") }
            case "text":
                if let c = cssColor(value) { css.append("color: \(c)") }
            case "background":
                // Scalars, not Characters: "\r\n" is one Character and would slip past a "\n" check.
                if !isDangerousURL(value), !value.unicodeScalars.contains(where: { "'\"()\\\n\r".unicodeScalars.contains($0) }) {
                    css.append("background-image: url('\(value)')")
                }
            case "style":
                if !isDangerousCSS(value) {
                    css.append(value.replacingOccurrences(of: "\"", with: "'").trimmingCharacters(in: CharacterSet(charactersIn: "; ")))
                }
            default:
                continue
            }
        }
        return css.joined(separator: "; ")
    }

    /// A colour attribute value made safe for CSS ("#fff", "white", "ffffff" → "#ffffff").
    static func cssColor(_ value: String) -> String? {
        let v = value.trimmedWhitespace
        guard !v.isEmpty, v.count <= 40, v.allSatisfy({ $0.isLetter || $0.isNumber || "#(),. %".contains($0) }) else { return nil }
        if v.count == 6 || v.count == 3, v.allSatisfy({ $0.isHexDigit }), v.contains(where: { $0.isNumber }) { return "#" + v }
        return v
    }
}
