import Foundation

/// Separates what the sender wrote from the quoted conversation below it.
public enum QuoteSplitter {
    /// Splits a plain-text body into what the sender wrote and the quoted tail.
    ///
    /// The tail starts at the earliest of: an attribution line ("On … wrote:" and its German,
    /// French, Spanish, Italian, Dutch, Portuguese and Swedish forms, also when wrapped over two or
    /// three lines), an "-----Original Message-----" separator (localized), an Outlook
    /// "From: / Sent: / To: / Subject:" header block (localized, with the `____` rule above it), the
    /// `-- ` signature separator, or a run of `>` lines that ends the message. Nothing is split when
    /// the sender's part would be empty (bottom-posted replies) or when there is no marker.
    public static func split(_ text: String) -> (body: String, quoted: String?) {
        let lines = text.normalizedNewlines.components(separatedBy: "\n")
        guard let start = quoteStart(lines) else { return (text, nil) }
        let body = trimTrailing(lines[..<start].joined(separator: "\n"))
        guard !body.trimmedWhitespace.isEmpty else { return (text, nil) }
        let quoted = lines[start...].joined(separator: "\n").trimmingCharacters(in: .newlines)
        return (body, quoted.trimmedWhitespace.isEmpty ? nil : quoted)
    }

    /// Removes the quoted conversation from an HTML body: Gmail `div.gmail_quote`, Apple Mail and
    /// Thunderbird `blockquote[type=cite]` (with the attribution line before it), Outlook
    /// `#divRplyFwdMsg` / `#appendonsend` / header-rule blocks (everything after them), Yahoo
    /// `.yahoo_quoted`, Proton `.protonmail_quote`, new Outlook's reference-message container.
    /// Only a quote that ends the message is removed; interleaved replies are left alone.
    public static func stripQuotedHTML(_ html: String) -> (html: String, hadQuote: Bool) {
        let bytes = Array(html.utf8)
        guard let range = HTMLQuoteFinder.quoteRange(bytes) else { return (html, false) }
        var out = Array(bytes[..<range.lowerBound])
        out.append(contentsOf: bytes[range.upperBound...])
        return (String(decoding: out, as: UTF8.self), true)
    }

    // MARK: Plain text

    static func trimTrailing(_ s: String) -> String {
        var scalars = Substring(s)
        while let last = scalars.last, last.isWhitespace { scalars = scalars.dropLast() }
        return String(scalars)
    }

    static func quoteStart(_ lines: [String]) -> Int? {
        var marker: Int?
        for i in lines.indices {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || trimmed.isEmpty { continue }
            if line == "-- " || line == "--" || line == "-- \t" {
                marker = i
                break
            }
            if isOriginalMessageSeparator(trimmed) {
                marker = i
                break
            }
            if isOutlookHeader(lines, at: i) {
                marker = ruleAbove(lines, i) ?? i
                break
            }
            if let attribution = attributionStart(lines, at: i) {
                marker = attribution
                break
            }
        }
        if let run = trailingQuoteRun(lines) {
            // An attribution right above the run belongs to it.
            var start = run
            var k = run - 1
            while k >= 0 && lines[k].trimmedWhitespace.isEmpty { k -= 1 }
            if k >= 0, isAttribution(lines[k]) { start = k }
            return min(marker ?? start, start)
        }
        return marker
    }

    /// Index of the first line of a run of `>` lines (blank lines allowed inside) that ends the text.
    static func trailingQuoteRun(_ lines: [String]) -> Int? {
        var i = lines.count - 1
        while i >= 0 && lines[i].trimmedWhitespace.isEmpty { i -= 1 }
        guard i >= 0, lines[i].trimmingCharacters(in: .whitespaces).hasPrefix(">") else { return nil }
        var start = i
        while i >= 0 {
            let t = lines[i].trimmingCharacters(in: .whitespaces)
            if t.hasPrefix(">") { start = i } else if !t.isEmpty { break }
            i -= 1
        }
        return start
    }

    static let attributionEndings = [
        "wrote:", "writes:", "wrote :", "schrieb:", "schrieb :", "a écrit :", "a écrit:", "a ecrit :", "a ecrit:",
        "escribió:", "escribio:", "escribió :", "ha scritto:", "ha scritto :", "schreef:", "schreef :", "het volgende geschreven:",
        "escreveu:", "escreveu :", "skrev:", "skrev :", "skrev följande:", "kirjoitti:", "napisał:", "napsal:", "написал:", "написал(а):",
    ]

    static let attributionStarters = ["on ", "am ", "le ", "el ", "il ", "op ", "em ", "den ", "på ", "w dniu ", "dne ", "in ", "at "]

    /// Verbs that come before the name in German, Dutch, Swedish… attributions
    /// ("Am 20.10.2026 um 09:15 schrieb Ada <ada@example.com>:").
    static let attributionVerbs = [" schrieb ", " schreef ", " skrev ", " kirjoitti ", " napisał ", " wrote ", " escribió ", " a écrit "]

    /// True when the line (trimmed) ends like an attribution.
    static func isAttribution(_ line: String) -> Bool {
        let t = line.trimmedWhitespace.lowercased()
        guard t.count <= 400, t.hasSuffix(":") else { return false }
        if attributionEndings.contains(where: { t.hasSuffix($0) }) { return true }
        return attributionVerbs.contains { t.contains($0) }
    }

    /// The first line of an attribution starting at `i` (one line, or wrapped over up to three).
    static func attributionStart(_ lines: [String], at i: Int) -> Int? {
        var joined = ""
        var end = i
        var found = false
        while end < lines.count && end < i + 3 {
            let t = lines[end].trimmedWhitespace
            if t.isEmpty || t.hasPrefix(">") { break }
            joined = joined.isEmpty ? t : joined + " " + t
            if isAttribution(joined) { found = true; break }
            end += 1
        }
        guard found else { return nil }
        // A wrapped match that really starts on a later line ("Thanks.\nOn Tue, … wrote:").
        if end > i {
            let next = lines[i + 1].trimmedWhitespace.lowercased()
            if attributionStarters.contains(where: { next.hasPrefix($0) }), attributionStart(lines, at: i + 1) != nil { return nil }
        }
        let first = lines[i].trimmedWhitespace.lowercased()
        let hasStarter = attributionStarters.contains { first.hasPrefix($0) }
        let lower = joined.lowercased()
        let looksLikeDate = lower.contains(where: { $0.isNumber }) || lower.contains("@")
        var next = end + 1
        while next < lines.count && lines[next].trimmedWhitespace.isEmpty { next += 1 }
        let quotedFollows = next < lines.count && lines[next].trimmingCharacters(in: .whitespaces).hasPrefix(">")
        if end == i {
            return quotedFollows || (hasStarter && looksLikeDate) ? i : nil
        }
        let firstLooksRight = hasStarter || first.contains(where: { $0.isNumber })
        return firstLooksRight && (quotedFollows || looksLikeDate) ? i : nil
    }

    static let originalMessagePhrases: Set<String> = [
        "original message", "ursprüngliche nachricht", "originalnachricht", "message d'origine", "message d’origine", "mensaje original",
        "messaggio originale", "oorspronkelijk bericht", "origineel bericht", "mensagem original", "ursprungligt meddelande",
        "originalmeddelande", "oprindelig meddelelse", "opprinnelig melding", "alkuperäinen viesti", "wiadomość oryginalna",
        "původní zpráva", "исходное сообщение",
    ]

    static func isOriginalMessageSeparator(_ trimmed: String) -> Bool {
        guard trimmed.hasPrefix("--") || trimmed.hasPrefix("__") else { return false }
        let core = trimmed.trimmingCharacters(in: CharacterSet(charactersIn: "-_ \t")).lowercased()
        return originalMessagePhrases.contains(core)
    }

    static let fromLabels = ["from:", "von:", "de:", "de :", "da:", "van:", "från:", "fra:", "od:", "lähettäjä:", "от:"]
    static let sentLabels = [
        "sent:", "date:", "gesendet:", "datum:", "envoyé :", "envoyé:", "date :", "enviado:", "enviado el:", "fecha:", "inviato:",
        "data:", "verzonden:", "skickat:", "sendt:", "wysłano:", "wysłane:", "lähetetty:", "отправлено:", "odesláno:",
    ]
    static let toOrSubjectLabels = [
        "to:", "subject:", "cc:", "an:", "betreff:", "à :", "à:", "objet :", "objet:", "para:", "asunto:", "a:", "oggetto:", "aan:",
        "onderwerp:", "till:", "ämne:", "assunto:", "til:", "emne:", "do:", "temat:", "vastaanottaja:", "aihe:", "кому:", "тема:",
    ]

    static func labelled(_ line: String, _ labels: [String]) -> Bool {
        var t = line.trimmingCharacters(in: .whitespaces).lowercased()
        while t.hasPrefix("*") { t.removeFirst() }
        t = t.replacingOccurrences(of: "*", with: "")
        return labels.contains { t.hasPrefix($0) }
    }

    /// "From: …" followed within a few lines by "Sent:"/"Date:" and "To:"/"Subject:" (Outlook, localized).
    static func isOutlookHeader(_ lines: [String], at i: Int) -> Bool {
        guard labelled(lines[i], fromLabels) else { return false }
        var sawSent = false
        var sawTo = false
        var k = i + 1
        while k < lines.count && k <= i + 6 {
            let line = lines[k]
            if labelled(line, sentLabels) { sawSent = true }
            if labelled(line, toOrSubjectLabels) { sawTo = true }
            k += 1
        }
        return sawSent && sawTo
    }

    /// A `_____` or `-----` rule (optionally followed by a blank line) just above line `i`.
    static func ruleAbove(_ lines: [String], _ i: Int) -> Int? {
        var k = i - 1
        while k >= 0 && lines[k].trimmedWhitespace.isEmpty && k >= i - 2 { k -= 1 }
        guard k >= 0 else { return nil }
        let t = lines[k].trimmedWhitespace
        if t.count >= 8, t.allSatisfy({ $0 == "_" || $0 == "-" || $0 == "—" }) { return k }
        return nil
    }
}

/// Finds the trailing quoted conversation in an HTML body.
enum HTMLQuoteFinder {
    private struct Open {
        var name: String
        var start: Int
        var contentStart: Int
    }

    private enum PendingKind {
        /// The element itself is the quote.
        case element(stackIndex: Int)
        /// Everything from the marker to the end of the element at `parentIndex` (or the document).
        case toParentEnd(parentIndex: Int)
    }

    static func quoteRange(_ b: [UInt8]) -> Range<Int>? {
        let candidates = findCandidates(b)
        guard let last = candidates.last else { return nil }
        // Walk back from the end: the quote starts at the earliest candidate after which only
        // other candidates and invisible markup follow. Each gap is scanned once.
        var first: Int?
        var index = candidates.count - 1
        while index >= 0 {
            let gapStart = candidates[index].upperBound
            let gapEnd = index + 1 < candidates.count ? candidates[index + 1].lowerBound : b.count
            if hasVisibleContent(b, gapStart..<max(gapStart, gapEnd)) { break }
            first = index
            index -= 1
        }
        guard let first else { return nil }
        return candidates[first].lowerBound..<last.upperBound
    }

    /// Outermost quote elements in document order.
    static func findCandidates(_ b: [UInt8]) -> [Range<Int>] {
        var scanner = HTMLScanner(b)
        var stack: [Open] = []
        var result: [Range<Int>] = []
        var pending: (start: Int, kind: PendingKind)?
        var lastClosed: (start: Int, end: Int, depth: Int)?
        var visibleSinceClose = false
        var lastHR: (start: Int, depth: Int)?
        var tokensSinceHR = 0

        func documentEnd(from start: Int) -> Int {
            let end = b.count
            for needle in ["</body", "</html"] {
                if let i = b.firstRangeCaseInsensitive(of: Array(needle.utf8), from: start, to: end) { return i }
            }
            return end
        }

        while let token = scanner.next() {
            switch token {
            case .text(let r):
                if pending == nil, containsVisibleText(b, r) { visibleSinceClose = true; tokensSinceHR += 1 }
            case .tag(let tag):
                if tag.isEnd {
                    guard let index = stack.lastIndex(where: { $0.name == tag.name }) else { continue }
                    let element = stack[index]
                    if let p = pending {
                        switch p.kind {
                        case .element(let stackIndex) where stackIndex >= index:
                            // Its own end tag is part of it; an ancestor's end tag closing it implicitly isn't.
                            result.append(p.start..<(stackIndex == index ? tag.range.upperBound : tag.range.lowerBound))
                            pending = nil
                        case .toParentEnd(let parentIndex) where parentIndex >= index:
                            result.append(p.start..<tag.range.lowerBound)
                            pending = nil
                        default:
                            break
                        }
                    }
                    stack.removeSubrange(index...)
                    lastClosed = (element.start, tag.range.upperBound, stack.count)
                    visibleSinceClose = false
                    continue
                }
                let depth = stack.count
                if tag.name == "img" { visibleSinceClose = true }
                if tag.name == "hr" {
                    lastHR = (tag.range.lowerBound, depth)
                    tokensSinceHR = 0
                } else if tag.name != "br" {
                    tokensSinceHR += 1
                }
                if pending == nil, let kind = classify(scanner, tag) {
                    switch kind {
                    case .element:
                        var start = tag.range.lowerBound
                        if tag.name == "blockquote", let closed = lastClosed, closed.depth == depth, !visibleSinceClose,
                           endsWithAttribution(b, closed.start..<closed.end) {
                            start = closed.start
                        }
                        if htmlVoidElements.contains(tag.name) || tag.selfClosing {
                            result.append(start..<tag.range.upperBound)
                        } else {
                            pending = (start, .element(stackIndex: depth))
                        }
                    case .toParentEnd:
                        var start = tag.range.lowerBound
                        var level = depth
                        while level > 0 {
                            let parent = stack[level - 1]
                            guard parent.name == "div", onlyWhitespace(b, parent.contentStart..<start) else { break }
                            start = parent.start
                            level -= 1
                        }
                        if let hr = lastHR, hr.depth == level, tokensSinceHR <= 1, onlyWhitespace(b, hrEnd(b, hr.start)..<start) {
                            start = hr.start
                        }
                        if level == 0 {
                            result.append(start..<documentEnd(from: start))
                            return merge(result)
                        }
                        pending = (start, .toParentEnd(parentIndex: level - 1))
                    }
                }
                if !htmlVoidElements.contains(tag.name) && !tag.selfClosing {
                    stack.append(Open(name: tag.name, start: tag.range.lowerBound, contentStart: tag.range.upperBound))
                }
            default:
                continue
            }
        }
        if let p = pending {
            // Never closed: the quote runs to the end of the document.
            result.append(p.start..<documentEnd(from: p.start))
        }
        return merge(result)
    }

    private enum Kind { case element, toParentEnd }

    private static func classify(_ scanner: HTMLScanner, _ tag: HTMLTag) -> Kind? {
        let attributes = scanner.attributes(of: tag)
        var classes: [String] = []
        var id = ""
        var type = ""
        var style = ""
        for attribute in attributes {
            switch attribute.name {
            case "class": classes = attribute.classNames
            case "id": id = attribute.value.asciiLowercased
            case "type": type = attribute.value.asciiLowercased
            case "style": style = attribute.value.asciiLowercased.filter { !$0.isWhitespace }
            default: break
            }
        }
        if id.hasSuffix("divrplyfwdmsg") || id.hasSuffix("appendonsend") { return .toParentEnd }
        if tag.name == "div", style.contains("border-top:solid"),
           style.contains("padding:3.0pt0in0in0in") || style.contains("padding:3.0pt0cm0cm0cm") || style.contains("padding:3pt0in0in0in") || style.contains("padding:3pt0cm0cm0cm") {
            return .toParentEnd
        }
        if tag.name == "blockquote" && type == "cite" { return .element }
        for cls in classes {
            if cls == "gmail_quote" || cls == "gmail_quote_container" || cls == "yahoo_quoted" || cls == "protonmail_quote"
                || cls == "moz-cite-prefix" || cls == "zmail_extra" || cls == "x_gmail_quote" {
                return .element
            }
        }
        if id.hasPrefix("yahoo_quoted") || id == "mail-editor-reference-message-container" { return .element }
        return nil
    }

    private static func hrEnd(_ b: [UInt8], _ start: Int) -> Int {
        (b.firstIndex(of: ASCII.gt, from: start, to: b.count) ?? start) + 1
    }

    private static func onlyWhitespace(_ b: [UInt8], _ r: Range<Int>) -> Bool {
        guard r.lowerBound <= r.upperBound else { return false }
        var i = r.lowerBound
        while i < r.upperBound {
            if !isASCIIWhitespace(b[i]) { return false }
            i += 1
        }
        return true
    }

    private static func merge(_ ranges: [Range<Int>]) -> [Range<Int>] {
        var out: [Range<Int>] = []
        for r in ranges.sorted(by: { $0.lowerBound < $1.lowerBound }) {
            if let last = out.last, r.lowerBound < last.upperBound {
                out[out.count - 1] = last.lowerBound..<max(last.upperBound, r.upperBound)
            } else {
                out.append(r)
            }
        }
        return out
    }

    private static func endsWithAttribution(_ b: [UInt8], _ r: Range<Int>) -> Bool {
        guard r.count < 4000 else { return false }
        let text = HTMLText.toPlainText(String(decoding: b[r], as: UTF8.self))
        let lastLine = text.split(separator: "\n").last.map(String.init) ?? ""
        return QuoteSplitter.isAttribution(lastLine) || QuoteSplitter.isAttribution(text.collapsingWhitespace)
    }

    /// True when the text contains something other than whitespace, `&nbsp;` and zero-width characters.
    static func containsVisibleText(_ b: [UInt8], _ r: Range<Int>) -> Bool {
        var i = r.lowerBound
        while i < r.upperBound {
            let c = b[i]
            if isASCIIWhitespace(c) { i += 1; continue }
            if c == ASCII.amp {
                // Only whitespace-like entities are invisible.
                let rest = b[i..<min(r.upperBound, i + 10)]
                let text = String(decoding: rest, as: UTF8.self).lowercased()
                if text.hasPrefix("&nbsp;") { i += 6; continue }
                if text.hasPrefix("&#160;") { i += 6; continue }
                if text.hasPrefix("&zwnj;") { i += 6; continue }
                if text.hasPrefix("&#8203;") { i += 7; continue }
                return true
            }
            if c == 0xC2, i + 1 < r.upperBound, b[i + 1] == 0xA0 { i += 2; continue }
            if c == 0xE2, i + 2 < r.upperBound, b[i + 1] == 0x80, b[i + 2] == 0x8B || b[i + 2] == 0x8C || b[i + 2] == 0x8D { i += 3; continue }
            if c == 0xEF, i + 2 < r.upperBound, b[i + 1] == 0xBB, b[i + 2] == 0xBF { i += 3; continue }
            return true
        }
        return false
    }

    /// True when `range` holds visible text or an image (tags, comments and whitespace aren't).
    static func hasVisibleContent(_ b: [UInt8], _ range: Range<Int>) -> Bool {
        guard range.lowerBound < range.upperBound, range.upperBound <= b.count else { return false }
        var scanner = HTMLScanner(Array(b[range]))
        while let token = scanner.next() {
            switch token {
            case .text(let r):
                if containsVisibleText(scanner.b, r) { return true }
            case .tag(let tag):
                if !tag.isEnd && (tag.name == "img" || tag.name == "video") { return true }
            default:
                continue
            }
        }
        return false
    }
}
