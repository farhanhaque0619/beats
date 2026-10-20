import Foundation

/// One-line message previews for the message list.
public enum Snippet {
    /// A single line of preview text, at most `maxLength` characters (an ellipsis marks a cut).
    ///
    /// Uses the plain text when it has content, else the HTML converted to text. Drops the quoted
    /// conversation and signature, `>` lines, lines that are only a URL, Gmail's `[image: …]`
    /// placeholders, separator rules, "View in browser" boilerplate and "Sent from my iPhone"
    /// footers; removes `<https://…>` link targets; collapses whitespace. Falls back to the unfiltered
    /// text if filtering leaves nothing.
    public static func make(plain: String?, html: String?, maxLength: Int = 200) -> String {
        var fallback = ""
        if let plain, !plain.trimmedWhitespace.isEmpty {
            let clean = removingFillers(plain)
            let text = filtered(clean)
            if !text.isEmpty { return truncate(text, maxLength: maxLength) }
            fallback = clean
        }
        // No plain text, or a plain part that is only boilerplate (common in newsletters).
        if let html, !html.isEmpty {
            let converted = removingFillers(HTMLText.toPlainText(QuoteSplitter.stripQuotedHTML(html).html))
            let text = filtered(converted)
            if !text.isEmpty { return truncate(text, maxLength: maxLength) }
            if fallback.isEmpty { fallback = converted }
        }
        return truncate(stripLinkTargets(fallback).collapsingWhitespace, maxLength: maxLength)
    }

    /// Drops the invisible padding newsletters put after their preheader (U+034F, zero-width
    /// spaces and joiners, word joiner, BOM, soft hyphen; RESEARCH §4.6) so it can't show up as
    /// garbage in the preview. ZWNJ / ZWJ between two visible characters (Persian words, emoji
    /// sequences) are kept. Works on scalars: U+034F is a combining mark, so it hides inside the
    /// `Character` before it.
    static func removingFillers(_ s: String) -> String {
        guard s.unicodeScalars.contains(where: { isFiller($0) || isJoiner($0) }) else { return s }
        let scalars = Array(s.unicodeScalars)
        var out = String.UnicodeScalarView()
        for (i, scalar) in scalars.enumerated() {
            if isFiller(scalar) { continue }
            if isJoiner(scalar) {
                guard let previous = out.last, isVisible(previous),
                      i + 1 < scalars.count, isVisible(scalars[i + 1]) else { continue }
            }
            out.append(scalar)
        }
        return String(out)
    }

    static func isFiller(_ scalar: Unicode.Scalar) -> Bool {
        switch scalar.value {
        case 0x034F, 0x00AD, 0x180E, 0x200B, 0x2060...0x2064, 0xFEFF: return true
        default: return false
        }
    }

    static func isJoiner(_ scalar: Unicode.Scalar) -> Bool {
        scalar.value == 0x200C || scalar.value == 0x200D
    }

    static func isVisible(_ scalar: Unicode.Scalar) -> Bool {
        !isFiller(scalar) && !isJoiner(scalar) && !scalar.properties.isWhitespace && scalar.value != 0x00A0 && scalar.value >= 0x20
    }

    /// The sender's own words from `source`, one line, or "" when nothing survives the filters.
    static func filtered(_ source: String) -> String {
        let body = QuoteSplitter.split(source).body
        var kept: [String] = []
        for rawLine in body.normalizedNewlines.split(separator: "\n", omittingEmptySubsequences: true) {
            let line = stripLinkTargets(String(rawLine)).trimmedWhitespace
            if line.isEmpty || isNoise(line) { continue }
            kept.append(line)
        }
        return kept.joined(separator: " ").collapsingWhitespace
    }

    static let boilerplate = [
        "view this email in your browser", "view in browser", "view in your browser", "view online", "view this email online",
        "view it in your browser", "having trouble viewing this email", "can't see this email", "trouble viewing",
        "click here to view", "web version", "open in browser", "if you are having trouble viewing", "view as a web page",
        "e-mail im browser ansehen", "im browser anzeigen", "afficher dans le navigateur", "ver en el navegador",
    ]

    static let mobileFooters = [
        "sent from my iphone", "sent from my ipad", "sent from my android", "sent from my samsung", "sent from my mobile",
        "sent from mail for windows", "sent from yahoo mail", "sent from outlook", "get outlook for ios", "get outlook for android",
        "sent with proton mail", "sent from proton mail", "von meinem iphone gesendet", "envoyé de mon iphone", "enviado desde mi iphone",
        "inviato da iphone", "verstuurd vanaf mijn iphone", "enviado do meu iphone", "skickat från min iphone",
    ]

    static func isNoise(_ line: String) -> Bool {
        if line.hasPrefix(">") { return true }
        let lower = line.lowercased()
        if (lower.hasPrefix("http://") || lower.hasPrefix("https://") || lower.hasPrefix("www.") || lower.hasPrefix("<http")) && !lower.contains(" ") {
            return true
        }
        if (lower.hasPrefix("[image:") || lower.hasPrefix("[cid:") || lower.hasPrefix("[http")) && lower.hasSuffix("]") { return true }
        if line.allSatisfy({ "-_=*~#.•·|".contains($0) || $0.isWhitespace }) { return true }
        if line.count <= 90 {
            if boilerplate.contains(where: { lower.contains($0) }) { return true }
            if mobileFooters.contains(where: { lower.hasPrefix($0) }) { return true }
        }
        return false
    }

    /// Removes `<https://…>` / `<mailto:…>` link targets that plain-text renderings put after link text.
    static func stripLinkTargets(_ s: String) -> String {
        guard s.contains("<") else { return s }
        var out = ""
        out.reserveCapacity(s.count)
        var rest = Substring(s)
        while let open = rest.firstIndex(of: "<") {
            let after = rest[rest.index(after: open)...]
            let lower = after.prefix(8).lowercased()
            if lower.hasPrefix("http") || lower.hasPrefix("mailto:") || lower.hasPrefix("www."), let close = after.firstIndex(of: ">") {
                out += rest[..<open]
                rest = after[after.index(after: close)...]
            } else {
                out += rest[...open]
                rest = after
            }
        }
        out += rest
        return out
    }

    static func truncate(_ text: String, maxLength: Int) -> String {
        guard maxLength > 0 else { return "" }
        guard text.count > maxLength else { return text }
        var cut = text.prefix(maxLength - 1)
        if let space = cut.lastIndex(of: " "), cut.distance(from: space, to: cut.endIndex) <= 24 {
            cut = cut[..<space]
        }
        while let last = cut.last, last.isWhitespace || ",;:-".contains(last) { cut = cut.dropLast() }
        return String(cut) + "…"
    }
}
