import Foundation

/// IMAP system flags plus the common `$Forwarded` keyword.
public struct MessageFlags: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }

    public static let seen = MessageFlags(rawValue: 1 << 0)
    public static let answered = MessageFlags(rawValue: 1 << 1)
    public static let flagged = MessageFlags(rawValue: 1 << 2)
    public static let deleted = MessageFlags(rawValue: 1 << 3)
    public static let draft = MessageFlags(rawValue: 1 << 4)
    public static let forwarded = MessageFlags(rawValue: 1 << 5)
    public static let junk = MessageFlags(rawValue: 1 << 6)

    private static let mapping: [(MessageFlags, String)] = [
        (.seen, "\\Seen"), (.answered, "\\Answered"), (.flagged, "\\Flagged"),
        (.deleted, "\\Deleted"), (.draft, "\\Draft"), (.forwarded, "$Forwarded"), (.junk, "$Junk"),
    ]

    /// Builds flags from IMAP flag atoms (case-insensitive); unknown keywords are ignored.
    public init(imapFlags: [String]) {
        var flags: MessageFlags = []
        for raw in imapFlags {
            for (flag, name) in Self.mapping where raw.caseInsensitiveCompare(name) == .orderedSame {
                flags.insert(flag)
            }
        }
        self = flags
    }

    /// IMAP flag atoms for the flags in this set.
    public var imapFlags: [String] {
        Self.mapping.filter { contains($0.0) }.map(\.1)
    }
}

/// Header-level facts about one message in one mailbox: everything the list and thread
/// views need without downloading the body.
public struct MessageSummary: Identifiable, Hashable, Codable, Sendable {
    public var accountID: String
    /// Decoded path of the mailbox this copy lives in.
    public var mailboxPath: String
    public var uid: UInt32
    public var uidValidity: UInt32

    /// `Message-ID` header without angle brackets.
    public var messageID: String?
    public var inReplyTo: [String]
    public var references: [String]
    /// Gmail's X-GM-THRID / X-GM-MSGID, when the server is Gmail.
    public var gmailThreadID: UInt64?
    public var gmailMessageID: UInt64?
    public var gmailLabels: [String]

    public var subject: String
    public var from: [EmailAddress]
    public var replyTo: [EmailAddress]
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    /// The `Date` header (falls back to the received date when missing or unparseable).
    public var date: Date
    /// When the server received it (IMAP INTERNALDATE).
    public var receivedDate: Date
    /// One or two lines of preview text, whitespace-collapsed.
    public var snippet: String
    public var flags: MessageFlags
    /// RFC822.SIZE in bytes.
    public var size: Int
    public var hasAttachments: Bool
    /// Newsletter, notification or other automated mail (List-Unsubscribe, List-Id,
    /// Precedence: bulk, noreply senders). Drives the Focus / Other split.
    public var isBulk: Bool
    /// Raw `List-Unsubscribe` header, e.g. `<mailto:...>, <https://...>`.
    public var listUnsubscribe: String?
    /// Raw `List-Unsubscribe-Post` header (`List-Unsubscribe=One-Click` enables RFC 8058).
    public var listUnsubscribePost: String?
    /// Conversation key assigned by threading. Nil until threaded.
    public var threadKey: String?

    public init(
        accountID: String,
        mailboxPath: String,
        uid: UInt32,
        uidValidity: UInt32,
        messageID: String? = nil,
        inReplyTo: [String] = [],
        references: [String] = [],
        gmailThreadID: UInt64? = nil,
        gmailMessageID: UInt64? = nil,
        gmailLabels: [String] = [],
        subject: String,
        from: [EmailAddress],
        replyTo: [EmailAddress] = [],
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        date: Date,
        receivedDate: Date? = nil,
        snippet: String = "",
        flags: MessageFlags = [],
        size: Int = 0,
        hasAttachments: Bool = false,
        isBulk: Bool = false,
        listUnsubscribe: String? = nil,
        listUnsubscribePost: String? = nil,
        threadKey: String? = nil
    ) {
        self.accountID = accountID
        self.mailboxPath = mailboxPath
        self.uid = uid
        self.uidValidity = uidValidity
        self.messageID = messageID
        self.inReplyTo = inReplyTo
        self.references = references
        self.gmailThreadID = gmailThreadID
        self.gmailMessageID = gmailMessageID
        self.gmailLabels = gmailLabels
        self.subject = subject
        self.from = from
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.date = date
        self.receivedDate = receivedDate ?? date
        self.snippet = snippet
        self.flags = flags
        self.size = size
        self.hasAttachments = hasAttachments
        self.isBulk = isBulk
        self.listUnsubscribe = listUnsubscribe
        self.listUnsubscribePost = listUnsubscribePost
        self.threadKey = threadKey
    }

    /// Stable identity of this copy: account, mailbox, UIDVALIDITY and UID.
    public var id: String { "\(accountID)|\(mailboxPath)|\(uidValidity)|\(uid)" }

    /// Identity of the message regardless of which mailbox holds it (Gmail shows one
    /// message in INBOX and All Mail at once). Used to de-duplicate.
    public var dedupeKey: String {
        if let gmailMessageID { return "\(accountID)|gm:\(gmailMessageID)" }
        if let messageID, !messageID.isEmpty { return "\(accountID)|mid:\(messageID.lowercased())" }
        return id
    }

    public var isUnread: Bool { !flags.contains(.seen) }
    public var isFlagged: Bool { flags.contains(.flagged) }
    public var sender: EmailAddress? { from.first }

    /// Subject with reply/forward prefixes removed ("Re: Fwd: Hi" -> "Hi").
    public var normalizedSubject: String { SubjectNormalizer.normalize(subject) }
}

public enum SubjectNormalizer {
    private static let prefixes = ["re", "fw", "fwd", "aw", "wg", "sv", "vs", "antw", "réf", "rif", "tr", "odp", "res", "enc"]

    public static func normalize(_ subject: String) -> String {
        var s = subject.trimmingCharacters(in: .whitespacesAndNewlines)
        var changed = true
        while changed {
            changed = false
            // "[list-name] " tags
            if s.hasPrefix("["), let close = s.firstIndex(of: "]"), s.distance(from: s.startIndex, to: close) < 40 {
                let rest = s[s.index(after: close)...].trimmingCharacters(in: .whitespaces)
                if !rest.isEmpty { s = rest; changed = true; continue }
            }
            guard let colon = s.firstIndex(where: { $0 == ":" || $0 == "：" }) else { break }
            var head = s[..<colon].lowercased().trimmingCharacters(in: .whitespaces)
            // "Re[2]" / "Re(2)"
            if let bracket = head.firstIndex(where: { $0 == "[" || $0 == "(" }) { head = String(head[..<bracket]) }
            if prefixes.contains(head) {
                s = s[s.index(after: colon)...].trimmingCharacters(in: .whitespaces)
                changed = true
            }
        }
        return s
    }
}

/// A downloaded, decoded message body.
public struct MessageBody: Hashable, Codable, Sendable {
    /// `MessageSummary.id` this body belongs to.
    public var messageID: String
    public var plainText: String?
    public var html: String?
    public var attachments: [Attachment]
    public var fetchedAt: Date

    public init(messageID: String, plainText: String? = nil, html: String? = nil, attachments: [Attachment] = [], fetchedAt: Date = Date()) {
        self.messageID = messageID
        self.plainText = plainText
        self.html = html
        self.attachments = attachments
        self.fetchedAt = fetchedAt
    }

    /// Attachments the user should see as files (not inline images referenced by the HTML).
    public var visibleAttachments: [Attachment] { attachments.filter { !$0.isInline } }
}

public struct Attachment: Identifiable, Hashable, Codable, Sendable {
    /// MIME part path, e.g. "2" or "1.3".
    public var id: String
    public var filename: String
    public var mimeType: String
    public var size: Int
    /// Content-ID without angle brackets, for `cid:` references from HTML.
    public var contentID: String?
    public var isInline: Bool
    public var data: Data?

    public init(id: String, filename: String, mimeType: String, size: Int, contentID: String? = nil, isInline: Bool = false, data: Data? = nil) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.size = size
        self.contentID = contentID
        self.isInline = isInline
        self.data = data
    }

    public var isImage: Bool { mimeType.lowercased().hasPrefix("image/") }
}

/// Messages that belong together, newest last.
public struct Conversation: Identifiable, Hashable, Sendable {
    public var id: String
    /// Oldest first. Includes copies from Sent so your replies show in the thread.
    public var messages: [MessageSummary]

    public init(id: String, messages: [MessageSummary]) {
        self.id = id
        self.messages = messages.sorted { $0.date < $1.date }
    }

    public var latest: MessageSummary? { messages.last }
    public var accountID: String { messages.last?.accountID ?? "" }
    public var date: Date { messages.last?.date ?? .distantPast }
    public var count: Int { messages.count }
    public var isUnread: Bool { messages.contains { $0.isUnread } }
    public var unreadCount: Int { messages.filter(\.isUnread).count }
    public var isFlagged: Bool { messages.contains { $0.isFlagged } }
    public var hasAttachments: Bool { messages.contains { $0.hasAttachments } }
    public var isBulk: Bool { messages.last?.isBulk ?? false }

    public var subject: String {
        let subject = messages.first(where: { !$0.subject.isEmpty })?.normalizedSubject ?? ""
        return subject.isEmpty ? "(no subject)" : subject
    }

    public var snippet: String { messages.last?.snippet ?? "" }

    /// Distinct senders in order of first appearance.
    public var senders: [EmailAddress] { messages.compactMap(\.sender).uniqued() }

    /// Everyone on the thread.
    public var participants: [EmailAddress] {
        messages.flatMap { $0.from + $0.to + $0.cc }.uniqued()
    }

    /// Copies of the messages that are in `path`.
    public func messages(inMailbox path: String) -> [MessageSummary] {
        messages.filter { $0.mailboxPath == path }
    }
}
