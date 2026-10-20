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
            let text = filtered(plain)
            if !text.isEmpty { return truncate(text, maxLength: maxLength) }
            fallback = plain
        }
        // No plain text, or a plain part that is only boilerplate (common in newsletters).
        if let html, !html.isEmpty {
            let converted = HTMLText.toPlainText(QuoteSplitter.stripQuotedHTML(html).html)
            let text = filtered(converted)
            if !text.isEmpty { return truncate(text, maxLength: maxLength) }
            if fallback.isEmpty { fallback = converted }
        }
        return truncate(stripLinkTargets(fallback).collapsingWhitespace, maxLength: maxLength)
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
