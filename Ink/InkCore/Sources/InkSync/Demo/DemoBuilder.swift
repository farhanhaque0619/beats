import Foundation
import InkModel

/// Everything in the demo account at one moment: folders, summaries (UID order) and bodies.
struct DemoSnapshot: Sendable {
    var mailboxes: [MailboxInfo]
    /// Summaries per decoded mailbox path, UID ascending.
    var messages: [String: [MessageSummary]]
    /// Bodies keyed by lowercased Message-ID (their `messageID` field is filled in on request).
    var bodies: [String: MessageBody]
    var uidValidity: UInt32
}

/// Collects demo messages with relative dates and threading headers, then lays them out as a
/// mailbox snapshot with UIDs.
struct DemoBuilder {
    struct Entry {
        var folder: String
        var summary: MessageSummary
        var body: MessageBody
        /// What the sender wrote, without the quoted parent (used when quoting this message).
        var freshText: String
    }

    let account: AccountConfig
    let now: Date
    let calendar: Calendar
    private(set) var entries: [Entry] = []
    private var indexByKey: [String: Int] = [:]
    /// Largest "minutes ago" used for today's mail, so early-morning launches can compress them.
    let todaySpanMinutes: Double = 260

    init(account: AccountConfig, now: Date, calendar: Calendar) {
        self.account = account
        self.now = now
        self.calendar = calendar
    }

    var me: EmailAddress { account.address }

    // MARK: Dates

    /// `minutes` before now, but always today: when the day is younger than today's span, every
    /// "today" offset shrinks by the same factor so order is kept and nothing slips into yesterday.
    func today(_ minutes: Double) -> Date {
        let startOfDay = calendar.startOfDay(for: now)
        let elapsed = now.timeIntervalSince(startOfDay)
        let span = todaySpanMinutes * 60
        let scale = elapsed > span + 120 ? 1 : max(elapsed * 0.9, 0.001) / span
        return now.addingTimeInterval(-minutes * 60 * scale)
    }

    func daysAgo(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: -days, to: start) ?? start.addingTimeInterval(Double(-days) * 86_400)
        let date = calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day.addingTimeInterval(Double(hour * 3600 + minute * 60))
        // Never in the future, whatever the clock says.
        return min(date, now.addingTimeInterval(-60))
    }

    func yesterday(_ hour: Int, _ minute: Int) -> Date { daysAgo(1, hour, minute) }

    func daysAhead(_ days: Int, _ hour: Int, _ minute: Int) -> Date {
        let start = calendar.startOfDay(for: now)
        let day = calendar.date(byAdding: .day, value: days, to: start) ?? start.addingTimeInterval(Double(days) * 86_400)
        return calendar.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    /// The next `weekday` (1 = Sunday) at least one day after today, at `hour`:00.
    func next(weekday: Int, hour: Int) -> Date {
        let todayWeekday = calendar.component(.weekday, from: now)
        var delta = (weekday - todayWeekday + 7) % 7
        if delta == 0 { delta = 7 }
        return daysAhead(delta, hour, 0)
    }

    // MARK: Calendar words

    /// The month `offset` months after the month of `date`, e.g. "November".
    func month(_ offset: Int, from date: Date) -> String {
        format(firstOfMonth(offset, from: date), "MMMM")
    }

    /// Midnight on the first day of the month `offset` months after `date`'s month.
    func firstOfMonth(_ offset: Int, from date: Date) -> Date {
        let start = calendar.date(from: calendar.dateComponents([.year, .month], from: date)) ?? date
        return calendar.date(byAdding: .month, value: offset, to: start) ?? start
    }

    /// "Q4" for the quarter `date` is in.
    func quarter(of date: Date) -> String {
        "Q\((calendar.component(.month, from: date) - 1) / 3 + 1)"
    }

    /// "spring", "summer", "autumn" or "winter" (northern hemisphere, by month).
    func season(of date: Date) -> String {
        switch calendar.component(.month, from: date) {
        case 3...5: return "spring"
        case 6...8: return "summer"
        case 9...11: return "autumn"
        default: return "winter"
        }
    }

    /// The `number`-th `weekday` (1 = Sunday) of the month `offset` months after `date`'s month.
    func weekday(_ weekday: Int, number: Int, monthsAfter offset: Int, from date: Date) -> Date {
        let first = firstOfMonth(offset, from: date)
        let delta = (weekday - calendar.component(.weekday, from: first) + 7) % 7
        return calendar.date(byAdding: .day, value: delta + 7 * (number - 1), to: first) ?? first
    }

    /// The first `weekday` (1 = Sunday) at least `days` days after `date`'s day.
    func weekday(_ weekday: Int, atLeast days: Int, after date: Date) -> Date {
        let start = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
        let delta = (weekday - calendar.component(.weekday, from: start) + 7) % 7
        return calendar.date(byAdding: .day, value: delta, to: start) ?? start
    }

    /// The first Monday-to-Friday day at least `days` days after `date`'s day.
    func workday(atLeast days: Int, after date: Date) -> Date {
        var day = calendar.date(byAdding: .day, value: days, to: calendar.startOfDay(for: date)) ?? date
        // Weekday numbers are the same in every locale (1 = Sunday, 7 = Saturday); isDateInWeekend isn't.
        while [1, 7].contains(calendar.component(.weekday, from: day)) { day = calendar.date(byAdding: .day, value: 1, to: day) ?? day }
        return day
    }

    /// The 30th of the month after `date`'s, or that month's last day when it's shorter.
    func thirtieth(monthAfter date: Date) -> Date {
        let first = firstOfMonth(1, from: date)
        let length = calendar.range(of: .day, in: .month, for: first)?.count ?? 30
        return calendar.date(byAdding: .day, value: min(30, length) - 1, to: first) ?? first
    }

    /// "1st", "2nd", "3rd", "15th", "21st" … for the day of the month of `date`.
    func dayOrdinal(_ date: Date) -> String {
        let day = calendar.component(.day, from: date)
        let suffix: String
        switch (day % 10, day % 100) {
        case (_, 11...13): suffix = "th"
        case (1, _): suffix = "st"
        case (2, _): suffix = "nd"
        case (3, _): suffix = "rd"
        default: suffix = "th"
        }
        return "\(day)\(suffix)"
    }

    func format(_ date: Date, _ pattern: String) -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.calendar = calendar
        formatter.timeZone = calendar.timeZone
        formatter.dateFormat = pattern
        return formatter.string(from: date)
    }

    // MARK: Messages

    /// Adds one message. `key` becomes the Message-ID's left part; `parent` (another key) makes
    /// it a reply with In-Reply-To/References and a quoted copy of the parent below the text.
    mutating func add(
        _ key: String,
        folder: String = "INBOX",
        from: EmailAddress,
        to: [EmailAddress],
        cc: [EmailAddress] = [],
        replyTo: [EmailAddress] = [],
        subject: String,
        date: Date,
        text: String,
        html: String? = nil,
        snippet: String? = nil,
        unread: Bool = false,
        flagged: Bool = false,
        answered: Bool = false,
        bulk: Bool = false,
        unsubscribe: String? = nil,
        attachments: [Attachment] = [],
        parent: String? = nil,
        externalReferences: [String] = [],
        draft: Bool = false
    ) {
        let domain = from.domain.isEmpty ? "ink.example" : from.domain
        let messageID = "\(key)@\(domain)"
        var inReplyTo: [String] = []
        var references: [String] = externalReferences
        var fullText = text
        if let parent, let parentIndex = indexByKey[parent] {
            let parentEntry = entries[parentIndex]
            if let parentID = parentEntry.summary.messageID {
                inReplyTo = [parentID]
                references = parentEntry.summary.references + [parentID]
            }
            fullText += "\n\n" + quote(parentEntry)
        } else if let last = externalReferences.last {
            inReplyTo = [last]
        }

        var flags: MessageFlags = []
        if !unread { flags.insert(.seen) }
        if flagged { flags.insert(.flagged) }
        if answered { flags.insert(.answered) }
        if draft { flags.insert(.draft) }

        let attachmentBytes = attachments.reduce(0) { $0 + $1.size * 4 / 3 }
        let size = 2_400 + fullText.utf8.count + (html?.utf8.count ?? 0) + attachmentBytes
        let summary = MessageSummary(
            accountID: account.id,
            mailboxPath: folder,
            uid: 0,
            uidValidity: 0,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            subject: subject,
            from: [from],
            replyTo: replyTo,
            to: to,
            cc: cc,
            date: date,
            receivedDate: date.addingTimeInterval(4),
            snippet: snippet ?? Self.snippet(from: text),
            flags: flags,
            size: size,
            hasAttachments: attachments.contains { !$0.isInline },
            isBulk: bulk,
            listUnsubscribe: unsubscribe.map { "<mailto:unsubscribe@\(domain)?subject=unsubscribe>, <\($0)>" },
            listUnsubscribePost: unsubscribe == nil ? nil : "List-Unsubscribe=One-Click"
        )
        let body = MessageBody(messageID: "", plainText: fullText, html: html, attachments: attachments, fetchedAt: now)
        indexByKey[key] = entries.count
        entries.append(Entry(folder: folder, summary: summary, body: body, freshText: text))
    }

    /// "On Mon, Oct 19, 2026 at 5:42 PM Priya Natarajan <priya@…> wrote:" and the text with "> ".
    private func quote(_ entry: Entry) -> String {
        let sender = entry.summary.from.first
        let who = sender.map { "\($0.displayName) <\($0.address)>" } ?? "someone"
        let attribution = "On \(format(entry.summary.date, "EEE, MMM d, yyyy 'at' h:mm a")) \(who) wrote:"
        let quoted = entry.body.plainText ?? entry.freshText
        let lines = quoted.split(separator: "\n", omittingEmptySubsequences: false).map { $0.isEmpty ? ">" : "> \($0)" }
        return attribution + "\n" + lines.joined(separator: "\n")
    }

    /// One line of preview text: what the sender wrote, whitespace collapsed, at most 200 characters.
    static func snippet(from text: String) -> String {
        var words: [Substring] = []
        var length = 0
        // `isNewline` also matches "\r\n", a single Character in Swift.
        for line in text.split(whereSeparator: \.isNewline) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix(">") || trimmed == "--" { continue }
            if trimmed.hasPrefix("http://") || trimmed.hasPrefix("https://") { continue }
            for word in line.split(whereSeparator: { $0 == " " || $0 == "\t" }) {
                words.append(word)
                length += word.count + 1
                if length > 200 { break }
            }
            if length > 200 { break }
        }
        let joined = words.joined(separator: " ")
        return joined.count > 200 ? String(joined.prefix(200)) : joined
    }

    // MARK: Attachments

    static func attachment(_ part: Int, _ filename: String, _ mimeType: String, _ data: Data, inline: Bool = false, contentID: String? = nil) -> Attachment {
        Attachment(id: "\(part)", filename: filename, mimeType: mimeType, size: data.count, contentID: contentID, isInline: inline, data: data)
    }

    // MARK: Snapshot

    func snapshot(uidValidity: UInt32) -> DemoSnapshot {
        var byFolder: [String: [Entry]] = [:]
        for entry in entries { byFolder[entry.folder, default: []].append(entry) }
        var messages: [String: [MessageSummary]] = [:]
        var bodies: [String: MessageBody] = [:]
        for (folder, folderEntries) in byFolder {
            let sorted = folderEntries.sorted { $0.summary.date < $1.summary.date }
            var uid: UInt32 = 101
            var summaries: [MessageSummary] = []
            for (index, entry) in sorted.enumerated() {
                var summary = entry.summary
                summary.uid = uid
                summary.uidValidity = uidValidity
                summaries.append(summary)
                if let id = summary.messageID { bodies[id.lowercased()] = entry.body }
                // Gaps like a real server's, where some mail was deleted along the way.
                uid += index % 3 == 2 ? 3 : 1
            }
            messages[folder] = summaries
        }
        let mailboxes = DemoContent.mailboxes(accountID: account.id)
        for mailbox in mailboxes where messages[mailbox.path] == nil { messages[mailbox.path] = [] }
        return DemoSnapshot(mailboxes: mailboxes, messages: messages, bodies: bodies, uidValidity: uidValidity)
    }
}
