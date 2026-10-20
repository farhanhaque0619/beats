import Foundation

/// Builds the HTML document Ink shows a message in (WKWebView).
public enum EmailHTMLDocument {
    /// How to present the message.
    public struct Options: Hashable, Sendable {
        /// The app is in dark mode.
        public var dark: Bool
        /// Load remote images (otherwise the CSP blocks them, which also stops tracking pixels).
        public var allowRemoteContent: Bool
        /// Link colour for simple messages, `#RRGGBB`.
        public var accentHex: String
        /// `-apple-system` (SF) or `ui-serif` (New York).
        public var fontFamily: String
        /// Base text size in CSS pixels.
        public var fontSizePx: Int
        /// Fold the quoted conversation behind a "•••" toggle.
        public var collapseQuotes: Bool

        public init(
            dark: Bool = false,
            allowRemoteContent: Bool = false,
            accentHex: String = "#0A84FF",
            fontFamily: String = "-apple-system",
            fontSizePx: Int = 17,
            collapseQuotes: Bool = true
        ) {
            self.dark = dark
            self.allowRemoteContent = allowRemoteContent
            self.accentHex = accentHex
            self.fontFamily = fontFamily
            self.fontSizePx = fontSizePx
            self.collapseQuotes = collapseQuotes
        }
    }

    /// Wraps an email's HTML (or plain text when there is no HTML) in a complete document: viewport,
    /// a strict Content-Security-Policy, base typography, and dark-mode handling. "Simple" HTML
    /// (no background colours or images of its own) and plain text are recoloured for dark mode;
    /// "designed" newsletters keep their colours on a light card. Plain text is escaped, links are
    /// made clickable, and `>` quotes become blockquotes.
    public static func build(html: String?, plainText: String?, options: Options) -> String {
        var bodyContent = ""
        var emailStyles: [String] = []
        var wrapperStyle = ""
        var designed = false
        var kind = "ink-plain-doc"

        if let html, !html.trimmedWhitespace.isEmpty {
            kind = "ink-html"
            designed = isDesigned(html)
            var source = html
            if options.collapseQuotes {
                let bytes = Array(html.utf8)
                if let range = HTMLQuoteFinder.quoteRange(bytes) {
                    var wrapped = Array(bytes[..<range.lowerBound])
                    wrapped += Array(quoteToggleOpen.utf8)
                    wrapped += bytes[range]
                    wrapped += Array("</details>".utf8)
                    wrapped += bytes[range.upperBound...]
                    source = String(decoding: wrapped, as: UTF8.self)
                }
            }
            let sanitized = HTMLSanitizer.sanitize(source)
            bodyContent = sanitized.body
            emailStyles = sanitized.styles
            wrapperStyle = sanitized.bodyStyle
        } else {
            let text = plainText ?? ""
            if options.collapseQuotes {
                let (body, quoted) = QuoteSplitter.split(text)
                bodyContent = "<div class=\"ink-plain\">" + PlainTextHTML.renderQuoted(body)
                if let quoted {
                    bodyContent += quoteToggleOpen + "<div class=\"ink-plain\">" + PlainTextHTML.renderQuoted(quoted) + "</div></details>"
                }
                bodyContent += "</div>"
            } else {
                bodyContent = "<div class=\"ink-plain\">" + PlainTextHTML.renderQuoted(text) + "</div>"
            }
        }

        let classes = ["ink", options.dark ? "ink-dark" : "ink-light", designed ? "ink-designed" : "ink-simple",
                       options.fontFamily.lowercased().contains("serif") && !options.fontFamily.lowercased().contains("sans") ? "ink-serif" : "ink-sans"]
        var doc = "<!DOCTYPE html>\n<html><head>\n<meta charset=\"utf-8\">\n"
        doc += "<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">\n"
        doc += "<meta http-equiv=\"Content-Security-Policy\" content=\"\(contentSecurityPolicy(allowRemoteContent: options.allowRemoteContent))\">\n"
        doc += "<meta name=\"color-scheme\" content=\"\(options.dark ? "dark" : "light")\">\n"
        doc += "<style>\n\(baseCSS(options))</style>\n"
        for style in emailStyles {
            doc += "<style>\n\(style)\n</style>\n"
        }
        if options.dark {
            doc += "<style>\n\(darkOverrideCSS)</style>\n"
        }
        doc += "</head>\n<body class=\"\(classes.joined(separator: " "))\">\n"
        doc += "<div id=\"ink-content\" class=\"\(kind)\""
        if !wrapperStyle.isEmpty { doc += " style=\"\(HTMLText.escape(wrapperStyle))\"" }
        doc += ">\n" + bodyContent + "\n</div>\n</body></html>\n"
        return doc
    }

    static let quoteToggleOpen = "<details class=\"ink-quote\"><summary class=\"ink-quote-toggle\" aria-label=\"Show quoted text\">•••</summary>"

    /// The policy placed in the document: nothing loads except inline styles, `cid:`/`data:`
    /// images, embedded fonts and (when allowed) remote images.
    public static func contentSecurityPolicy(allowRemoteContent: Bool) -> String {
        let images = allowRemoteContent ? "cid: data: https: http:" : "cid: data:"
        return "default-src 'none'; img-src \(images); style-src 'unsafe-inline'; font-src data:"
    }

    // MARK: Styles

    static func fontStack(_ family: String) -> String {
        let lower = family.lowercased()
        if lower.contains("serif") && !lower.contains("sans") {
            return "ui-serif, \"New York\", \"Iowan Old Style\", Georgia, \"Times New Roman\", serif"
        }
        if lower.contains("mono") {
            return "ui-monospace, \"SF Mono\", SFMono-Regular, Menlo, Consolas, monospace"
        }
        if lower == "-apple-system" || lower.contains("system") || lower.isEmpty {
            return "-apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Helvetica, Arial, sans-serif"
        }
        let safe = family.filter { $0.isLetter || $0.isNumber || $0 == " " || $0 == "-" || $0 == "_" }
        return "\"\(safe)\", -apple-system, BlinkMacSystemFont, \"Helvetica Neue\", Helvetica, Arial, sans-serif"
    }

    static func sanitizedAccent(_ hex: String) -> String {
        var h = hex.trimmedWhitespace
        if h.hasPrefix("#") { h.removeFirst() }
        guard [3, 4, 6, 8].contains(h.count), h.allSatisfy({ $0.isHexDigit }) else { return "#0A84FF" }
        return "#" + h
    }

    static func baseCSS(_ options: Options) -> String {
        let size = min(max(options.fontSizePx, 10), 40)
        let accent = sanitizedAccent(options.accentHex)
        return """
        :root { color-scheme: \(options.dark ? "dark" : "light"); --ink-accent: \(accent);
          --ink-bg: #FFFFFF; --ink-text: #1D1D1F; --ink-secondary: #6E6E73; --ink-rule: #D2D2D7; --ink-fill: #F2F2F7; }
        body.ink-dark { --ink-bg: #1C1C1E; --ink-text: #F2F2F7; --ink-secondary: #AEAEB2; --ink-rule: #48484A; --ink-fill: #2C2C2E; }
        html { -webkit-text-size-adjust: 100%; text-size-adjust: 100%; }
        html, body { margin: 0; padding: 0; background-color: var(--ink-bg); }
        body { color: var(--ink-text); font-family: \(fontStack(options.fontFamily)); font-size: \(size)px; line-height: 1.5;
          overflow-wrap: break-word; word-wrap: break-word; -webkit-font-smoothing: antialiased; }
        #ink-content { box-sizing: border-box; max-width: 100%; overflow-x: auto; }
        body.ink-simple #ink-content { padding: 16px; }
        body.ink-designed #ink-content { padding: 0; }
        img { max-width: 100% !important; height: auto; }
        video { max-width: 100%; height: auto; }
        table { max-width: 100% !important; }
        a { word-break: break-word; }
        body.ink-simple a { color: var(--ink-accent); }
        pre, code, tt, kbd, samp { font-family: ui-monospace, "SF Mono", SFMono-Regular, Menlo, Consolas, monospace; font-size: 0.88em; }
        pre { white-space: pre-wrap; word-wrap: break-word; }
        .ink-plain { white-space: pre-wrap; word-wrap: break-word; overflow-wrap: anywhere; }
        .ink-plain-part { white-space: pre-wrap; }
        body.ink-simple blockquote, .ink-plain blockquote { margin: 0.4em 0; padding: 0 0 0 0.85em; border-left: 2px solid var(--ink-rule); color: var(--ink-secondary); }
        .ink-plain blockquote { white-space: pre-wrap; }
        .ink-signature { color: var(--ink-secondary); }
        .ink-forwarded-header { color: var(--ink-secondary); font-size: 0.9em; margin: 1em 0 0.5em; }
        hr { border: none; border-top: 1px solid var(--ink-rule); }
        details.ink-quote { margin-top: 0.75em; }
        details.ink-quote > summary { list-style: none; display: inline-block; cursor: pointer; padding: 0 0.7em; border-radius: 0.6em;
          background-color: var(--ink-fill); color: var(--ink-secondary); font-size: 0.8em; line-height: 1.7; letter-spacing: 0.1em;
          -webkit-user-select: none; user-select: none; }
        details.ink-quote > summary::-webkit-details-marker { display: none; }
        details.ink-quote[open] > summary { margin-bottom: 0.5em; }

        """
    }

    /// Dark mode: simple mail takes the palette; designed mail sits on a light card.
    static let darkOverrideCSS = """
    body.ink-dark.ink-simple #ink-content, body.ink-dark.ink-simple #ink-content * {
      color: var(--ink-text) !important; background-color: transparent !important; border-color: var(--ink-rule) !important; }
    body.ink-dark.ink-simple #ink-content a, body.ink-dark.ink-simple #ink-content a * { color: var(--ink-accent) !important; }
    body.ink-dark.ink-simple #ink-content blockquote, body.ink-dark.ink-simple #ink-content blockquote *,
    body.ink-dark.ink-simple #ink-content .ink-signature, body.ink-dark.ink-simple #ink-content .ink-signature * { color: var(--ink-secondary) !important; }
    body.ink-dark.ink-simple #ink-content details.ink-quote > summary { background-color: var(--ink-fill) !important; color: var(--ink-secondary) !important; }
    body.ink-dark.ink-simple #ink-content img { background-color: #F2F2F7 !important; border-radius: 3px; }
    body.ink-dark.ink-designed #ink-content { background-color: #FFFFFF; color: #1D1D1F; color-scheme: light; border-radius: 14px;
      margin: 8px; overflow: hidden; }

    """

    // MARK: Inspection

    /// True when the HTML brings its own look: background colours or images (`bgcolor`,
    /// `background`, CSS backgrounds other than white/transparent), or a fixed-width newsletter
    /// layout with several images.
    public static func isDesigned(_ html: String) -> Bool {
        let b = Array(html.utf8)
        var scanner = HTMLScanner(b)
        var wideTables = 0
        var images = 0
        while let token = scanner.next() {
            switch token {
            case .rawText(let r, let element) where element == "style":
                if cssHasBackground(String(decoding: b[r], as: UTF8.self)) { return true }
            case .tag(let tag) where !tag.isEnd:
                for attribute in scanner.attributes(of: tag) {
                    switch attribute.name {
                    case "bgcolor":
                        if !isPlainBackground(attribute.value) { return true }
                    case "background":
                        if !attribute.value.trimmedWhitespace.isEmpty { return true }
                    case "style":
                        if cssHasBackground(attribute.value) { return true }
                    case "width":
                        if tag.name == "table", let w = leadingNumber(attribute.value), w >= 480 { wideTables += 1 }
                    default:
                        continue
                    }
                }
                if tag.name == "img" { images += 1 }
            default:
                continue
            }
        }
        return wideTables > 0 && images >= 2
    }

    static let plainBackgrounds: Set<String> = [
        "", "transparent", "none", "inherit", "initial", "unset", "white", "#fff", "#ffffff", "#fefefe", "rgb(255,255,255)",
        "rgba(255,255,255,1)", "rgba(0,0,0,0)", "window", "currentcolor",
    ]

    static func isPlainBackground(_ value: String) -> Bool {
        var v = value.lowercased().filter { !$0.isWhitespace }
        if let bang = v.range(of: "!important") { v.removeSubrange(bang) }
        return plainBackgrounds.contains(v)
    }

    /// Looks for `background…: value` declarations whose value is a real colour or image.
    static func cssHasBackground(_ css: String) -> Bool {
        let lower = css.lowercased()
        var rest = Substring(lower)
        while let r = rest.range(of: "background") {
            var after = rest[r.upperBound...]
            // background, background-color, background-image (not background-position etc.)
            let property = after.prefix(while: { $0 != ":" && $0 != ";" && $0 != "{" && $0 != "}" })
            let name = property.trimmingCharacters(in: .whitespaces)
            after = after[property.endIndex...]
            rest = after
            guard name.isEmpty || name == "-color" || name == "-image", after.first == ":" else { continue }
            let value = after.dropFirst().prefix(while: { $0 != ";" && $0 != "}" && $0 != "\"" })
            if value.contains("url(") || value.contains("gradient(") { return true }
            if name == "-image" { if !isPlainBackground(String(value)) { return true } else { continue } }
            // Shorthand: any colour token that isn't white/transparent counts.
            let tokens = value.split(whereSeparator: { $0 == " " || $0 == "\t" })
            if tokens.isEmpty { continue }
            let joined = value.filter { !$0.isWhitespace }
            if isPlainBackground(joined) { continue }
            if tokens.allSatisfy({ isPlainBackground(String($0)) || $0 == "!important" || $0 == "no-repeat" }) { continue }
            return true
        }
        return false
    }

    static func leadingNumber(_ s: String) -> Int? {
        let digits = s.trimmedWhitespace.prefix(while: { $0.isASCII && $0.isNumber })
        return digits.isEmpty ? nil : Int(digits.prefix(6))
    }

    /// Number of `<img>` elements that would load from the network (`http:`, `https:`, `//host`).
    public static func countRemoteImages(_ html: String) -> Int {
        imageSources(html).filter { isRemote($0.src) }.count
    }

    /// Number of images that look like tracking pixels: tiny (≤ 2px) or hidden images, or images
    /// served by known open-tracking services. Only remote images count.
    public static func countTrackingPixels(_ html: String) -> Int {
        imageSources(html).filter { image in
            guard isRemote(image.src) else { return false }
            return image.isTiny || image.isHidden || isTrackerURL(image.src)
        }.count
    }

    struct ImageInfo {
        var src: String
        var isTiny: Bool
        var isHidden: Bool
    }

    static func imageSources(_ html: String) -> [ImageInfo] {
        let b = Array(html.utf8)
        var scanner = HTMLScanner(b)
        var result: [ImageInfo] = []
        while let token = scanner.next() {
            guard case .tag(let tag) = token, !tag.isEnd, tag.name == "img" else { continue }
            var src = ""
            var width: Int?
            var height: Int?
            var style = ""
            for attribute in scanner.attributes(of: tag) {
                switch attribute.name {
                case "src": src = attribute.value.trimmedWhitespace
                case "width": width = leadingNumber(attribute.value)
                case "height": height = leadingNumber(attribute.value)
                case "style": style = attribute.value.lowercased().filter { !$0.isWhitespace }
                default: continue
                }
            }
            if width == nil, let w = cssPixels(style, "width:") { width = w }
            if height == nil, let h = cssPixels(style, "height:") { height = h }
            let tiny = (width.map { $0 <= 2 } ?? false) && (height.map { $0 <= 2 } ?? true)
                || (height.map { $0 <= 1 } ?? false) && (width.map { $0 <= 2 } ?? true)
            let hidden = style.contains("display:none") || style.contains("visibility:hidden") || style.contains("opacity:0;")
                || style.hasSuffix("opacity:0") || style.contains("max-height:0") || style.contains("max-width:0")
            result.append(ImageInfo(src: src, isTiny: tiny, isHidden: hidden))
        }
        return result
    }

    static func cssPixels(_ style: String, _ property: String) -> Int? {
        var search = Substring(style)
        while let r = search.range(of: property) {
            // Skip "max-width:" / "min-height:" when looking for "width:" / "height:".
            let before = search[..<r.lowerBound].last
            if before == nil || before == ";" || before == "\"" {
                return leadingNumber(String(search[r.upperBound...]))
            }
            search = search[r.upperBound...]
        }
        return nil
    }

    static func isRemote(_ src: String) -> Bool {
        let lower = src.lowercased()
        return lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("//")
    }

    static let trackerMarkers = [
        "mailtrack.io", "yesware.com", "mixmax.com", "track.hubspot", "hubspotlinks", "hs-analytics", "sidekickopen", "mailfoogae.appspot.com",
        "bananatag.com", "getnotify.com", "streak.com/", "superhuman.com", "/track/open", "/wf/open", "/open.php", "open.aspx",
        "emltrk.com", "list-manage.com/track", "mandrillapp.com/track", "sendgrid.net/wf", "pardot.com/r/", "convertkit-mail", "open.convertkit",
        "linkedin.com/emimp", "email_open_log_pic", "google-analytics.com/collect", "/e/o/", "/o.gif", "/pixel.gif", "/pixel.png", "/pixel?",
        "/pixel/", "://pixel.", "/beacon", "/trk?", "/trk/", "/tracking/", "/open?", "/open/", "awstrack.me", "mailgun.org/o", "mktoresp",
        "/imp?", "/impression", "trk.klclick", "klaviyomail", "/r/o/",
    ]

    static func isTrackerURL(_ src: String) -> Bool {
        let lower = src.lowercased()
        return trackerMarkers.contains { lower.contains($0) }
    }
}
