import Foundation

/// What a mailbox is for, independent of what the server calls it.
public enum MailboxRole: String, Codable, Sendable, CaseIterable, Identifiable {
    case inbox, flagged, snoozed, drafts, sent, archive, all, junk, trash, custom
    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .inbox: return "Inbox"
        case .flagged: return "Starred"
        case .snoozed: return "Snoozed"
        case .drafts: return "Drafts"
        case .sent: return "Sent"
        case .archive: return "Archive"
        case .all: return "All Mail"
        case .junk: return "Spam"
        case .trash: return "Trash"
        case .custom: return "Folder"
        }
    }

    /// SF Symbol name.
    public var systemImage: String {
        switch self {
        case .inbox: return "tray"
        case .flagged: return "star"
        case .snoozed: return "clock"
        case .drafts: return "doc"
        case .sent: return "paperplane"
        case .archive: return "archivebox"
        case .all: return "tray.2"
        case .junk: return "xmark.bin"
        case .trash: return "trash"
        case .custom: return "folder"
        }
    }

    /// Roles shown as smart mailboxes in the unified sidebar, in order.
    public static let unifiedRoles: [MailboxRole] = [.inbox, .flagged, .snoozed, .sent, .drafts, .archive, .junk, .trash]
}

/// A folder (or Gmail label) on the server.
public struct MailboxInfo: Identifiable, Hashable, Codable, Sendable {
    public var accountID: String
    /// Full path decoded to Unicode, e.g. `[Gmail]/All Mail` or `Projects/Ink`.
    public var path: String
    /// Path exactly as the server sent it (modified UTF-7), used on the wire.
    public var rawPath: String
    public var delimiter: String?
    public var role: MailboxRole
    /// Raw LIST attributes such as `\HasNoChildren`, `\Noselect`, `\Sent`.
    public var attributes: [String]

    public init(accountID: String, path: String, rawPath: String? = nil, delimiter: String? = "/", role: MailboxRole, attributes: [String] = []) {
        self.accountID = accountID
        self.path = path
        self.rawPath = rawPath ?? path
        self.delimiter = delimiter
        self.role = role
        self.attributes = attributes
    }

    public var id: String { "\(accountID)|\(path)" }

    /// Last path component ("All Mail"), or the role title for well-known roles.
    public var displayName: String {
        if role != .custom { return role.title }
        if let delimiter, !delimiter.isEmpty, let last = path.components(separatedBy: delimiter).last, !last.isEmpty {
            return last
        }
        return path
    }

    public var isSelectable: Bool {
        !attributes.contains { $0.caseInsensitiveCompare("\\Noselect") == .orderedSame || $0.caseInsensitiveCompare("\\NonExistent") == .orderedSame }
    }

    /// Nesting depth, for indenting folders in the sidebar.
    public var depth: Int {
        guard let delimiter, !delimiter.isEmpty else { return 0 }
        return max(0, path.components(separatedBy: delimiter).count - 1)
    }
}

/// What the message list is showing.
public enum MailScope: Hashable, Codable, Sendable {
    /// A role across every account ("All Inboxes").
    case unified(MailboxRole)
    /// A role in one account.
    case account(accountID: String, role: MailboxRole)
    /// A specific folder or label in one account.
    case mailbox(accountID: String, path: String)

    public static let allInboxes = MailScope.unified(.inbox)

    public var role: MailboxRole? {
        switch self {
        case .unified(let role), .account(_, let role): return role
        case .mailbox: return nil
        }
    }

    public var accountID: String? {
        switch self {
        case .unified: return nil
        case .account(let id, _), .mailbox(let id, _): return id
        }
    }
}

/// Inbox split: real people first, newsletters and notifications in Other.
public enum InboxFilter: String, Codable, Sendable, CaseIterable, Identifiable {
    case focused, other, everything
    public var id: String { rawValue }
    public var title: String {
        switch self {
        case .focused: return "Focus"
        case .other: return "Other"
        case .everything: return "All"
        }
    }
}
