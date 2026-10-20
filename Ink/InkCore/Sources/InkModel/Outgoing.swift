import Foundation

public enum ReplyMode: String, Codable, Sendable, CaseIterable {
    case reply, replyAll, forward
}

public struct OutgoingAttachment: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var filename: String
    public var mimeType: String
    public var data: Data

    public init(id: UUID = UUID(), filename: String, mimeType: String, data: Data) {
        self.id = id
        self.filename = filename
        self.mimeType = mimeType
        self.data = data
    }
}

/// A message being written or waiting to send. Also used as the draft model by Compose.
public struct OutgoingMessage: Identifiable, Hashable, Codable, Sendable {
    public var id: UUID
    public var accountID: String
    public var from: EmailAddress
    public var to: [EmailAddress]
    public var cc: [EmailAddress]
    public var bcc: [EmailAddress]
    public var subject: String
    /// What the user typed, plain text.
    public var body: String
    /// Quoted original for replies/forwards, plain text, appended below `body` when sending.
    public var quotedText: String?
    /// Quoted original as HTML (sanitised), used for the HTML alternative when present.
    public var quotedHTML: String?
    public var attachments: [OutgoingAttachment]
    /// Message-ID (no angle brackets) this replies to.
    public var inReplyTo: String?
    public var references: [String]
    public var replyMode: ReplyMode?
    public var createdAt: Date

    public init(
        id: UUID = UUID(),
        accountID: String,
        from: EmailAddress,
        to: [EmailAddress] = [],
        cc: [EmailAddress] = [],
        bcc: [EmailAddress] = [],
        subject: String = "",
        body: String = "",
        quotedText: String? = nil,
        quotedHTML: String? = nil,
        attachments: [OutgoingAttachment] = [],
        inReplyTo: String? = nil,
        references: [String] = [],
        replyMode: ReplyMode? = nil,
        createdAt: Date = Date()
    ) {
        self.id = id
        self.accountID = accountID
        self.from = from
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.subject = subject
        self.body = body
        self.quotedText = quotedText
        self.quotedHTML = quotedHTML
        self.attachments = attachments
        self.inReplyTo = inReplyTo
        self.references = references
        self.replyMode = replyMode
        self.createdAt = createdAt
    }

    public var allRecipients: [EmailAddress] { (to + cc + bcc).uniqued() }
    public var hasRecipients: Bool { !allRecipients.isEmpty }
    public var isEmpty: Bool {
        to.isEmpty && cc.isEmpty && bcc.isEmpty && subject.isEmpty
            && body.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && attachments.isEmpty
    }

    /// Plain-text body as sent: what the user typed, then the quoted original.
    public var fullPlainText: String {
        guard let quotedText, !quotedText.isEmpty else { return body }
        return body + "\n\n" + quotedText
    }
}
