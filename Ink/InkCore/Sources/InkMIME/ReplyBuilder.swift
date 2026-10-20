import Foundation
import InkModel

/// Drafts replies and forwards.
public enum ReplyBuilder {
    /// A reply, reply-all or forward of `message`, ready for Compose.
    ///
    /// - Recipients: reply goes to Reply-To, else From. Reply-all adds the original To and Cc, minus
    ///   `myAddresses` (and the account's own address), without duplicates. Replying to a message
    ///   you sent goes to its original recipients instead. Forwards start with no recipients.
    /// - Subject: "Re: " / "Fwd: " added once; existing reply prefixes in any language Ink knows
    ///   ("Re:", "AW:", "SV:", "Antw:", "RE[2]:" …) are not stacked, and a `[list]` tag stays.
    /// - Threading: In-Reply-To is the message's Message-ID; References are its References (or its
    ///   In-Reply-To) plus its Message-ID, keeping the last 20. Set for forwards too, so they thread.
    /// - Quote: "On <date>, <name> wrote:" and the original text with "> " (forwards: a
    ///   "Forwarded message" header block and the original text); `quotedHTML` is the original HTML
    ///   (sanitised) when there is one. Forwards carry the original's attachments, and inline
    ///   images big enough to be content rather than decoration (the quoted HTML drops `cid:` images).
    /// - `body` is left empty; the caller adds the signature.
    public static func draft(
        replyingTo message: MessageSummary,
        body: MessageBody?,
        mode: ReplyMode,
        from account: AccountConfig,
        myAddresses: Set<String>,
        now: Date = Date()
    ) -> OutgoingMessage {
        var mine = Set(myAddresses.map { $0.trimmedWhitespace.lowercased() })
        mine.insert(account.emailAddress.trimmedWhitespace.lowercased())
        let (to, cc) = recipients(for: message, mode: mode, myAddresses: mine)

        var references = message.references.isEmpty ? message.inReplyTo : message.references
        if let id = message.messageID, !id.isEmpty { references.append(id) }
        var seen = Set<String>()
        references = references.filter { !$0.isEmpty && seen.insert($0).inserted }
        if references.count > 20 { references = Array(references.suffix(20)) }

        let original = originalText(body)
        var quotedText: String?
        var attachments: [OutgoingAttachment] = []
        switch mode {
        case .reply, .replyAll:
            if let original {
                quotedText = attribution(for: message) + "\n" + quote(original)
            }
        case .forward:
            var block = forwardHeader(for: message)
            if let original { block += "\n\n" + original }
            quotedText = block
            attachments = (body?.attachments ?? []).filter(isForwarded).compactMap { attachment in
                attachment.data.map { OutgoingAttachment(filename: attachment.filename, mimeType: attachment.mimeType, data: $0) }
            }
        }
        var quotedHTML: String?
        if let html = body?.html, !html.trimmedWhitespace.isEmpty {
            let sanitized = HTMLSanitizer.sanitize(html, dropCIDImages: true).body.trimmedWhitespace
            if !sanitized.isEmpty { quotedHTML = sanitized }
        }

        return OutgoingMessage(
            accountID: account.id,
            from: account.address,
            to: to,
            cc: cc,
            subject: mode == .forward ? forwardSubject(message.subject) : replySubject(message.subject),
            body: "",
            quotedText: quotedText,
            quotedHTML: quotedHTML,
            attachments: attachments,
            inReplyTo: message.messageID,
            references: references,
            replyMode: mode,
            createdAt: now
        )
    }

    /// Smallest inline image a forward carries along. The quoted HTML can't show `cid:` images,
    /// so a photo pasted into the original (iPhone Mail sends them inline) would otherwise be lost;
    /// icons, spacers and small signature logos stay behind.
    static let minimumForwardedInlineBytes = 8 * 1024

    static func isForwarded(_ attachment: Attachment) -> Bool {
        guard attachment.isInline else { return true }
        return attachment.mimeType.lowercased().hasPrefix("image/") && (attachment.data?.count ?? 0) >= minimumForwardedInlineBytes
    }

    // MARK: Recipients

    /// To and Cc for a reply (see `draft`). `myAddresses` must be lowercased.
    static func recipients(for message: MessageSummary, mode: ReplyMode, myAddresses: Set<String>) -> (to: [EmailAddress], cc: [EmailAddress]) {
        guard mode != .forward else { return ([], []) }
        func isMine(_ a: EmailAddress) -> Bool { myAddresses.contains(a.normalized) }
        let fromMe = !message.from.isEmpty && message.from.allSatisfy(isMine)
        let primary: [EmailAddress]
        if fromMe {
            // Replying to something I sent: continue the conversation with its recipients (its Cc
            // when it had no To).
            primary = !message.to.isEmpty ? message.to : (!message.cc.isEmpty ? message.cc : message.from)
        } else {
            primary = message.replyTo.isEmpty ? message.from : message.replyTo
        }
        if mode == .reply {
            return (primary.uniqued(), [])
        }
        var to = (primary + (fromMe ? [] : message.to)).uniqued().filter { !isMine($0) }
        if to.isEmpty { to = primary.uniqued() }
        let toSet = Set(to.map(\.normalized))
        let cc = message.cc.uniqued().filter { !isMine($0) && !toSet.contains($0.normalized) }
        return (to, cc)
    }

    // MARK: Subjects

    static let forwardHeads: Set<String> = ["fw", "fwd", "wg", "tr", "enc", "rv", "fs", "doorst", "vb", "pd", "i"]

    /// The first "Prefix:" of a subject, when it is one SubjectNormalizer knows: (lowercased head, rest).
    static func leadingPrefix(_ s: Substring) -> (head: String, rest: Substring)? {
        guard let colon = s.prefix(14).firstIndex(where: { $0 == ":" || $0 == "：" }) else { return nil }
        let rawHead = s[..<colon].trimmingCharacters(in: .whitespaces)
        guard !rawHead.isEmpty, !rawHead.contains(" ") else { return nil }
        var head = rawHead.lowercased()
        if let bracket = head.firstIndex(where: { $0 == "[" || $0 == "(" }) { head = String(head[..<bracket]) }
        guard !head.isEmpty, SubjectNormalizer.normalize(head + ": x") == "x" else { return nil }
        let rest = s[s.index(after: colon)...].drop(while: { $0 == " " || $0 == "\t" })
        return (head, rest)
    }

    /// "Re: " + the subject without its reply prefixes ("RE: AW: Hi" → "Re: Hi",
    /// "[ink-dev] Re: Release" → "Re: [ink-dev] Release").
    public static func replySubject(_ subject: String) -> String {
        var rest = Substring(subject.trimmedWhitespace)
        var tag: Substring?
        while true {
            if let (head, after) = leadingPrefix(rest), !forwardHeads.contains(head) {
                rest = after
                continue
            }
            if tag == nil, rest.hasPrefix("["), let close = rest.firstIndex(of: "]"), rest.distance(from: rest.startIndex, to: close) < 40 {
                let after = rest[rest.index(after: close)...].drop(while: { $0 == " " })
                if let (head, afterPrefix) = leadingPrefix(after), !forwardHeads.contains(head) {
                    tag = rest[...close]
                    rest = afterPrefix
                    continue
                }
            }
            break
        }
        let core = (tag.map { String($0) + " " } ?? "") + rest
        return ("Re: " + core).trimmedWhitespace
    }

    /// "Fwd: " + the subject without its forward prefixes ("Fwd: Fwd: Hi" → "Fwd: Hi"; "Re: Hi" →
    /// "Fwd: Re: Hi").
    public static func forwardSubject(_ subject: String) -> String {
        var rest = Substring(subject.trimmedWhitespace)
        while let (head, after) = leadingPrefix(rest), forwardHeads.contains(head) {
            rest = after
        }
        return ("Fwd: " + rest).trimmedWhitespace
    }

    // MARK: Quoting

    static func originalText(_ body: MessageBody?) -> String? {
        guard let body else { return nil }
        var text: String?
        if let plain = body.plainText, !plain.trimmedWhitespace.isEmpty {
            text = plain
        } else if let html = body.html, !html.trimmedWhitespace.isEmpty {
            text = HTMLText.toPlainText(html)
        }
        guard let text else { return nil }
        let trimmed = QuoteSplitter.trimTrailing(text.normalizedNewlines).trimmingCharacters(in: .newlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    static func quote(_ text: String) -> String {
        text.components(separatedBy: "\n").map { $0.isEmpty ? ">" : "> " + $0 }.joined(separator: "\n")
    }

    /// "On Tue, Oct 20, 2026 at 9:15 AM, Ada Lovelace <ada@example.com> wrote:"
    public static func attribution(for message: MessageSummary, timeZone: TimeZone = .current) -> String {
        "On \(humanDate(message.date, timeZone: timeZone)), \(personDescription(message.from.first)) wrote:"
    }

    static func personDescription(_ address: EmailAddress?) -> String {
        guard let address else { return "Unknown sender" }
        if let name = address.name, !name.isEmpty { return "\(name) <\(address.address)>" }
        return address.address
    }

    static func forwardHeader(for message: MessageSummary, timeZone: TimeZone = .current) -> String {
        var lines = ["---------- Forwarded message ---------"]
        lines.append("From: " + (message.from.isEmpty ? "Unknown sender" : message.from.map(\.formatted).joined(separator: ", ")))
        lines.append("Date: " + humanDate(message.date, timeZone: timeZone))
        lines.append("Subject: " + message.subject)
        if !message.to.isEmpty { lines.append("To: " + message.to.map(\.formatted).joined(separator: ", ")) }
        if !message.cc.isEmpty { lines.append("Cc: " + message.cc.map(\.formatted).joined(separator: ", ")) }
        return lines.joined(separator: "\n")
    }

    /// "Tue, Oct 20, 2026 at 9:15 AM" — English and locale-independent, so quotes read the same everywhere.
    static func humanDate(_ date: Date, timeZone: TimeZone) -> String {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = timeZone
        let c = calendar.dateComponents([.year, .month, .day, .weekday, .hour, .minute], from: date)
        let weekdays = ["Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat"]
        let months = ["Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec"]
        let weekday = weekdays[((c.weekday ?? 1) - 1 + 7) % 7]
        let month = months[((c.month ?? 1) - 1 + 12) % 12]
        let hour24 = c.hour ?? 0
        let hour12 = hour24 % 12 == 0 ? 12 : hour24 % 12
        let minute = c.minute ?? 0
        let ampm = hour24 < 12 ? "AM" : "PM"
        return "\(weekday), \(month) \(c.day ?? 1), \(c.year ?? 1970) at \(hour12):\(minute < 10 ? "0" : "")\(minute) \(ampm)"
    }
}
