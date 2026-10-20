import Foundation
import InkModel

/// RFC 5322 address lists as they appear in real mail.
///
/// Handles quoted names with escapes, comments (`addr (Name)`), groups (`Team: a@x, b@y;`,
/// `undisclosed-recipients:;`), RFC 2047 names (also inside quotes), unquoted `Last, First <addr>`,
/// names without angle brackets (`Ada Lovelace ada@example.com`), `<mailto:addr>`, missing closing
/// brackets, junk after the address, and whole `Name <addr>` strings sent as one encoded word.
public enum AddressParser {
    /// Parses every mailbox in an address-list header value. Never fails; entries without a usable
    /// address are skipped.
    public static func parseList(_ s: String) -> [EmailAddress] {
        let trimmed = s.trimmedWhitespace
        guard !trimmed.isEmpty else { return [] }
        var result = parse(tokens: tokenize(Array(trimmed.utf8)))
        if result.isEmpty, trimmed.contains("=?") {
            let decoded = EncodedWord.decode(trimmed)
            if decoded != trimmed { result = parse(tokens: tokenize(Array(decoded.utf8))) }
        }
        return result
    }

    /// The first mailbox in `s`.
    public static func parse(_ s: String) -> EmailAddress? {
        parseList(s).first
    }

    // MARK: Tokens

    enum Token: Equatable {
        case word(String, quoted: Bool)
        case comment(String)
        case angle(String)
        case comma, colon, semicolon
    }

    static func isSpecial(_ c: UInt8) -> Bool {
        switch c {
        case ASCII.space, ASCII.tab, ASCII.cr, ASCII.lf, ASCII.quote, ASCII.lparen, ASCII.rparen, ASCII.lt, ASCII.gt,
             ASCII.comma, ASCII.semicolon, ASCII.colon, ASCII.backslash:
            return true
        default:
            return false
        }
    }

    static func tokenize(_ b: [UInt8]) -> [Token] {
        var tokens: [Token] = []
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            switch c {
            case ASCII.space, ASCII.tab, ASCII.cr, ASCII.lf, ASCII.gt, ASCII.backslash, ASCII.rparen:
                i += 1
            case ASCII.comma:
                tokens.append(.comma); i += 1
            case ASCII.semicolon:
                tokens.append(.semicolon); i += 1
            case ASCII.colon:
                tokens.append(.colon); i += 1
            case ASCII.quote:
                var out: [UInt8] = []
                i += 1
                while i < n && b[i] != ASCII.quote {
                    if b[i] == ASCII.backslash && i + 1 < n { out.append(b[i + 1]); i += 2; continue }
                    out.append(b[i])
                    i += 1
                }
                i += 1
                tokens.append(.word(String(decoding: out, as: UTF8.self), quoted: true))
            case ASCII.lparen:
                var depth = 1
                var out: [UInt8] = []
                i += 1
                while i < n {
                    let d = b[i]
                    if d == ASCII.backslash && i + 1 < n { out.append(b[i + 1]); i += 2; continue }
                    if d == ASCII.lparen { depth += 1 }
                    if d == ASCII.rparen {
                        depth -= 1
                        if depth == 0 { i += 1; break }
                    }
                    out.append(d)
                    i += 1
                }
                tokens.append(.comment(String(decoding: out, as: UTF8.self)))
            case ASCII.lt:
                var out: [UInt8] = []
                i += 1
                while i < n {
                    let d = b[i]
                    if d == ASCII.gt { i += 1; break }
                    if d == ASCII.quote {
                        // Quoted local part inside the brackets.
                        out.append(d)
                        i += 1
                        while i < n && b[i] != ASCII.quote {
                            if b[i] == ASCII.backslash && i + 1 < n { out.append(b[i]); out.append(b[i + 1]); i += 2; continue }
                            out.append(b[i])
                            i += 1
                        }
                        if i < n { out.append(b[i]); i += 1 }
                        continue
                    }
                    // A missing ">" ends at the next separator or the next "<".
                    if d == ASCII.lt || d == ASCII.comma || d == ASCII.semicolon { break }
                    out.append(d)
                    i += 1
                }
                tokens.append(.angle(String(decoding: out, as: UTF8.self)))
            default:
                let start = i
                while i < n {
                    let d = b[i]
                    if d == 0x5B {
                        // Domain literal: "[...]" may contain colons.
                        i += 1
                        while i < n && b[i] != 0x5D && b[i] != ASCII.gt && b[i] != ASCII.comma { i += 1 }
                        if i < n && b[i] == 0x5D { i += 1 }
                        continue
                    }
                    if isSpecial(d) { break }
                    i += 1
                }
                if i == start { i += 1; continue }
                tokens.append(.word(String(decoding: b[start..<i], as: UTF8.self), quoted: false))
            }
        }
        return tokens
    }

    // MARK: Entries

    struct Mailbox {
        var name: String?
        var address: String?
        /// The entry was only words with no "@" (a candidate for "Last, First <addr>").
        var phraseOnly: Bool
        var hasAngle: Bool
    }

    static func parse(tokens: [Token]) -> [EmailAddress] {
        var entries: [[Token]] = []
        var current: [Token] = []
        for token in tokens {
            switch token {
            case .comma, .semicolon:
                entries.append(current)
                current = []
            case .colon:
                let looksLikeGroupName = !current.contains { token in
                    if case .angle = token { return true }
                    if case .word(let w, false) = token, w.contains("@") { return true }
                    return false
                }
                if looksLikeGroupName {
                    current = []   // group display name; its members follow
                }
            default:
                current.append(token)
            }
        }
        entries.append(current)

        let mailboxes = entries.filter { !$0.isEmpty }.map(mailbox)
        var result: [EmailAddress] = []
        var index = 0
        while index < mailboxes.count {
            let box = mailboxes[index]
            // "Doe, John <john@example.com>": an unquoted comma inside a display name.
            if box.phraseOnly, index + 1 < mailboxes.count, mailboxes[index + 1].hasAngle, let address = mailboxes[index + 1].address {
                let first = box.name ?? ""
                let second = mailboxes[index + 1].name ?? ""
                let name = second.isEmpty ? first : first + ", " + second
                result.append(make(name: name, address: address))
                index += 2
                continue
            }
            if let address = box.address {
                result.append(make(name: box.name, address: address))
            }
            index += 1
        }
        return result
    }

    static func make(name: String?, address: String) -> EmailAddress {
        var name = name
        if let n = name {
            let bare = n.trimmingCharacters(in: CharacterSet(charactersIn: "<>'\" "))
            if bare.caseInsensitiveCompare(address) == .orderedSame { name = nil }
        }
        return EmailAddress(name: name, address: address)
    }

    static func mailbox(_ tokens: [Token]) -> Mailbox {
        var phrase: [String] = []
        var afterAngle: [String] = []
        var comments: [String] = []
        var angle: String?
        var words: [(String, Bool)] = []
        for token in tokens {
            switch token {
            case .word(let w, let quoted):
                if angle == nil { phrase.append(w); words.append((w, quoted)) } else { afterAngle.append(w) }
            case .comment(let c):
                comments.append(c)
            case .angle(let a):
                if angle == nil { angle = a }
            default:
                break
            }
        }

        if let angle {
            var address = cleanAddress(angle)
            var name = displayName(phrase)
            if address.isEmpty, let i = words.firstIndex(where: { $0.0.contains("@") }) {
                // "ada@example.com <>": the address is in the phrase.
                address = cleanAddress(words[i].0)
                var rest = words.map(\.0)
                rest.remove(at: i)
                name = displayName(rest)
            }
            if name == nil { name = displayName(comments) }
            if name == nil, !afterAngle.isEmpty, !afterAngle.contains(where: { $0.contains("@") }) { name = displayName(afterAngle) }
            return Mailbox(name: name, address: isPlausible(address) ? address : nil, phraseOnly: false, hasAngle: true)
        }

        // No angle brackets: an addr-spec, possibly with a name around it.
        var merged = words
        // "ada @ example.com" (obsolete CFWS around "@").
        var k = 0
        while k < merged.count {
            let w = merged[k].0
            if !merged[k].1, w == "@" || w.hasSuffix("@"), k + 1 < merged.count, !merged[k + 1].1 {
                var joined = w + merged[k + 1].0
                if w == "@", k > 0, !merged[k - 1].1 {
                    joined = merged[k - 1].0 + joined
                    merged.replaceSubrange((k - 1)...(k + 1), with: [(joined, false)])
                    k -= 1
                } else {
                    merged.replaceSubrange(k...(k + 1), with: [(joined, false)])
                }
                continue
            }
            if !merged[k].1, w.hasPrefix("@"), w.count > 1, k > 0, !merged[k - 1].1, !merged[k - 1].0.contains("@") {
                merged.replaceSubrange((k - 1)...k, with: [(merged[k - 1].0 + w, false)])
                k -= 1
                continue
            }
            k += 1
        }

        let addressIndex = merged.lastIndex { !$0.1 && $0.0.contains("@") && !isEncodedWord($0.0) }
            ?? merged.lastIndex { $0.0.contains("@") && !$0.0.contains(" ") }
        if let addressIndex {
            let address = cleanAddress(merged[addressIndex].0)
            var rest = merged.map(\.0)
            rest.remove(at: addressIndex)
            let name = displayName(rest) ?? displayName(comments)
            return Mailbox(name: name, address: isPlausible(address) ? address : nil, phraseOnly: false, hasAngle: false)
        }
        let name = displayName(merged.map(\.0))
        if merged.count == 1, !merged[0].1, !isEncodedWord(merged[0].0) {
            // A bare local name ("MAILER-DAEMON", "root"): an address without a domain.
            let local = cleanAddress(merged[0].0)
            return Mailbox(name: displayName(comments) ?? name, address: isPlausible(local) ? local : nil, phraseOnly: true, hasAngle: false)
        }
        return Mailbox(name: name, address: nil, phraseOnly: !merged.isEmpty, hasAngle: false)
    }

    static func isEncodedWord(_ s: String) -> Bool {
        s.hasPrefix("=?") && s.hasSuffix("?=")
    }

    static func isPlausible(_ address: String) -> Bool {
        guard !address.isEmpty, address.utf8.count <= 512 else { return false }
        // Spaces are only allowed inside a quoted local part ("john smith"@example.com).
        var inQuote = false
        for ch in address {
            if ch == "\"" { inQuote.toggle(); continue }
            if ch == "<" || ch == ">" { return false }
            if ch == " " && !inQuote { return false }
        }
        return !inQuote
    }

    /// Joins phrase words, decodes encoded words, drops surrounding quotes and tidies whitespace.
    static func displayName(_ words: [String]) -> String? {
        guard !words.isEmpty else { return nil }
        var name = words.joined(separator: " ")
        if name.contains("=?") { name = EncodedWord.decode(name) }
        name = name.collapsingWhitespace
        while name.count >= 2, let first = name.first, let last = name.last,
              (first == "'" && last == "'") || (first == "\"" && last == "\"") {
            name = String(name.dropFirst().dropLast()).trimmedWhitespace
        }
        return name.isEmpty ? nil : name
    }

    /// Removes comments, whitespace, `mailto:`, source routes and stray quotes from an addr-spec.
    static func cleanAddress(_ raw: String) -> String {
        var s = raw
        if s.contains("(") {
            var out = ""
            var depth = 0
            for ch in s {
                if ch == "(" { depth += 1; continue }
                if ch == ")" { depth = max(0, depth - 1); continue }
                if depth == 0 { out.append(ch) }
            }
            s = out
        }
        // Whitespace is only meaningful inside a quoted local part.
        if !s.contains("\"") {
            s = s.filter { !$0.isWhitespace }
        } else {
            s = s.trimmedWhitespace
        }
        if s.lowercased().hasPrefix("mailto:") { s = String(s.dropFirst(7)) }
        if let q = s.firstIndex(of: "?"), s.contains("@"), s[..<q].contains("@") { s = String(s[..<q]) }
        // Obsolete source route "@relay1,@relay2:user@host".
        if s.hasPrefix("@"), let colon = s.lastIndex(of: ":") { s = String(s[s.index(after: colon)...]) }
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: "'<>,;"))
        if s.count >= 2, s.first == "\"", s.last == "\"", s.dropFirst().dropLast().contains("@") {
            s = String(s.dropFirst().dropLast())
        }
        return s
    }
}

/// Message-ID lists (`Message-ID`, `In-Reply-To`, `References`).
public enum MessageIDParser {
    /// `"<a@b> <c@d>"` → `["a@b", "c@d"]`. Tolerates commas, comments, folding inside IDs, missing
    /// brackets (bare `id@host` tokens) and old-style text such as `<a@b> from Ada's message of …`.
    /// Duplicates are removed, keeping the first occurrence.
    public static func parseList(_ s: String) -> [String] {
        let b = Array(s.utf8)
        var ids: [String] = []
        var seen = Set<String>()
        func add(_ bytes: ArraySlice<UInt8>) {
            var cleaned = bytes.filter { !isASCIIWhitespace($0) }
            while let first = cleaned.first, first == ASCII.lt || first == ASCII.quote || first == ASCII.apostrophe { cleaned.removeFirst() }
            while let last = cleaned.last, last == ASCII.gt || last == ASCII.comma || last == ASCII.semicolon || last == ASCII.quote || last == ASCII.apostrophe {
                cleaned.removeLast()
            }
            guard !cleaned.isEmpty, cleaned.count <= 998 else { return }
            let id = String(decoding: cleaned, as: UTF8.self)
            if seen.insert(id).inserted { ids.append(id) }
        }

        let hasAngles = b.contains(ASCII.lt)
        var bare: [ArraySlice<UInt8>] = []
        var i = 0
        let n = b.count
        while i < n {
            let c = b[i]
            if c == ASCII.lparen {
                var depth = 1
                i += 1
                while i < n && depth > 0 {
                    if b[i] == ASCII.lparen { depth += 1 } else if b[i] == ASCII.rparen { depth -= 1 }
                    i += 1
                }
                continue
            }
            if c == ASCII.lt {
                let start = i + 1
                var j = start
                while j < n && b[j] != ASCII.gt && b[j] != ASCII.lt { j += 1 }
                add(b[start..<j])
                i = j < n && b[j] == ASCII.gt ? j + 1 : j
                continue
            }
            if isASCIIWhitespace(c) || c == ASCII.comma || c == ASCII.semicolon {
                i += 1
                continue
            }
            let start = i
            while i < n, !isASCIIWhitespace(b[i]), b[i] != ASCII.comma, b[i] != ASCII.lt, b[i] != ASCII.lparen { i += 1 }
            bare.append(b[start..<i])
        }
        let bareWithAt = bare.filter { $0.contains(ASCII.at) }
        if hasAngles {
            // Only take bare tokens that clearly are IDs; the rest is prose.
            for token in bareWithAt where !token.contains(ASCII.quote) { add(token) }
        } else if !bareWithAt.isEmpty {
            for token in bareWithAt { add(token) }
        } else if bare.count == 1 {
            add(bare[0])
        }
        if hasAngles && !bareWithAt.isEmpty {
            // Keep document order: re-sort by position of first occurrence in the source.
            let text = s
            ids.sort { a, b in
                (text.range(of: a)?.lowerBound ?? text.endIndex) < (text.range(of: b)?.lowerBound ?? text.endIndex)
            }
        }
        return ids
    }
}
