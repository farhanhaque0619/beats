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
        "noscript", "portal", "xml", "o:p",
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
            }
        }
        return SanitizedHTML(styles: styles, body: String(decoding: out, as: UTF8.self), bodyStyle: bodyStyle)
    }

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

    static func isDangerousURL(_ value: String) -> Bool {
        let compact = String(value.unicodeScalars.filter { $0.value > 0x20 && $0.value != 0x7F }).lowercased()
        return compact.hasPrefix("javascript:") || compact.hasPrefix("vbscript:") || compact.hasPrefix("livescript:")
            || compact.hasPrefix("data:text/html") || compact.hasPrefix("data:application") || compact.hasPrefix("data:image/svg")
            || compact.contains(",javascript:") || compact.contains(" javascript:")
    }

    static func isDangerousCSS(_ value: String) -> Bool {
        let compact = value.lowercased().filter { !$0.isWhitespace && $0 != "\\" }
        return compact.contains("expression(") || compact.contains("javascript:") || compact.contains("behavior:")
            || compact.contains("-moz-binding") || compact.contains("vbscript:")
    }

    /// Neutralises the dangerous parts of a style sheet (expressions, bindings, `@import`).
    static func sanitizeCSS(_ css: String) -> String {
        var s = css
        for needle in ["@import", "expression(", "behavior:", "-moz-binding", "javascript:", "vbscript:", "</"] where s.lowercased().contains(needle) {
            s = replaceCaseInsensitive(s, needle, with: needle == "</" ? "<\\/" : "/*x*/")
        }
        return s
    }

    static func replaceCaseInsensitive(_ s: String, _ needle: String, with replacement: String) -> String {
        var out = ""
        var rest = Substring(s)
        while let r = rest.range(of: needle, options: .caseInsensitive) {
            out += rest[..<r.lowerBound]
            out += replacement
            rest = rest[r.upperBound...]
        }
        out += rest
        return out
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
                if !isDangerousURL(value), !value.contains(where: { "'\"()\\\n\r".contains($0) }) {
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
