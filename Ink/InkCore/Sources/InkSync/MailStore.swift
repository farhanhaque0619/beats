import Foundation
import Observation
import InkModel

/// What the store needs from the outside world.
public struct MailStoreEnvironment: Sendable {
    /// Where accounts.json, the message cache and snoozes live (Application Support/Ink).
    public var storageDirectory: URL
    public var credentials: CredentialStore
    /// Makes a fresh connection to a mail server. Nil means demo-only (previews, tests).
    public var transportFactory: MailTransportFactory?
    /// Clock, injectable for tests.
    public var now: @Sendable () -> Date

    public init(storageDirectory: URL, credentials: CredentialStore, transportFactory: MailTransportFactory?, now: @escaping @Sendable () -> Date = { Date() }) {
        self.storageDirectory = storageDirectory
        self.credentials = credentials
        self.transportFactory = transportFactory
        self.now = now
    }
}

/// A short message at the bottom of the screen, optionally with Undo.
public struct Toast: Identifiable, Equatable, Sendable {
    public enum Style: Sendable, Equatable { case info, success, error }

    public var id: UUID
    public var message: String
    public var systemImage: String?
    public var style: Style
    /// Shows an Undo button that calls `MailStore.undo()`.
    public var undoable: Bool

    public init(id: UUID = UUID(), message: String, systemImage: String? = nil, style: Style = .info, undoable: Bool = false) {
        self.id = id
        self.message = message
        self.systemImage = systemImage
        self.style = style
        self.undoable = undoable
    }
}

public enum SyncStatus: Equatable, Sendable {
    case idle
    case syncing
    case failed(String)
}

/// The app's single source of truth: accounts, the conversations on screen, and every action.
///
/// Triage actions (archive, trash, snooze, read, star) update the UI immediately. The server
/// call is held back for `undoWindow` seconds, so Undo just puts things back locally — no
/// reverse operation is ever sent. Starting another undoable action, `flushPendingActions()`
/// (the app calls it when going to the background) or the window elapsing commits it.
///
/// Sending works the same way with `undoSendDelay`.
@MainActor
@Observable
public final class MailStore {
    // MARK: Lifecycle

    public init(environment: MailStoreEnvironment) {
        self.environment = environment
    }

    /// A store already filled with the demo inbox, synchronously. For previews and screenshots.
    public static func preview() -> MailStore {
        fatalError("TODO: implemented by InkSync")
    }

    /// Loads accounts, cached mail and snoozes from disk (fast, shows cached mail instantly),
    /// then refreshes from the servers in the background.
    public func load() async {}

    public let environment: MailStoreEnvironment

    // MARK: Accounts

    public private(set) var accounts: [AccountConfig] = []
    public var hasAccounts: Bool { !accounts.isEmpty }
    public var isDemoActive: Bool { accounts.contains(where: \.isDemo) }

    public func account(id: String) -> AccountConfig? { accounts.first { $0.id == id } }

    /// Connects and signs in to IMAP and SMTP with these details without saving anything.
    public func verify(_ account: AccountConfig, credential: Credential, progress: @escaping @Sendable (VerificationStep) -> Void) async throws {}

    /// Saves the credential, persists the account, loads its folders and syncs the inbox.
    /// Removes the demo account if it was the only one.
    public func addAccount(_ account: AccountConfig, credential: Credential) async throws {}

    /// Adds the built-in sample inbox (no network).
    public func addDemoAccount() async {}

    /// Removes the account, its credential and its cached mail.
    public func removeAccount(id: String) async {}

    /// Saves edits to an account's name, signature or colour.
    public func updateAccount(_ account: AccountConfig) {}

    /// Accounts you can send from, demo excluded when real accounts exist.
    public var sendingAccounts: [AccountConfig] { accounts }

    // MARK: Scope and lists

    /// What the list shows. Changing it rebuilds `conversations` from the cache immediately and
    /// syncs the new scope if it is stale.
    public var scope: MailScope = .allInboxes

    /// Focus / Other split for inbox scopes. Ignored elsewhere.
    public var inboxFilter: InboxFilter = .focused

    /// Whether the Focus / Other split is on at all (a setting). When off, inboxes show everything.
    public var focusedInboxEnabled: Bool = true

    /// Conversations for `scope` (and `inboxFilter`), newest first.
    public private(set) var conversations: [Conversation] = []

    /// Unread conversations in Other, for the "Other" pill.
    public private(set) var otherUnreadCount: Int = 0
    /// Total conversations in Other.
    public private(set) var otherCount: Int = 0

    public private(set) var syncStatus: SyncStatus = .idle
    public private(set) var lastSyncedAt: Date?
    public private(set) var isLoadingMore: Bool = false
    /// False once the server has no older messages for the scope.
    public private(set) var canLoadMore: Bool = true

    /// Folders per account (from the last sync), sorted with well-known roles first.
    public private(set) var mailboxesByAccount: [String: [MailboxInfo]] = [:]

    public func mailboxes(for accountID: String) -> [MailboxInfo] { mailboxesByAccount[accountID] ?? [] }

    /// Unread conversation count for a scope (inbox counts respect nothing but unread).
    public func unreadCount(for scope: MailScope) -> Int { 0 }

    /// "All Inboxes", "Inbox", "Gmail · Receipts", ...
    public func title(for scope: MailScope) -> String { "" }

    /// Pulls new mail for the current scope (all accounts for unified scopes).
    public func refresh() async {}

    /// Syncs every account's inbox. Returns messages that arrived since the previous sync
    /// (for background-refresh notifications).
    @discardableResult
    public func refreshAllInboxes() async -> [MessageSummary] { [] }

    /// Pages in older messages for the current scope.
    public func loadMore() async {}

    /// Keeps an IMAP IDLE connection per inbox while the app is in the foreground.
    public func startLiveUpdates() {}
    public func stopLiveUpdates() {}

    // MARK: Reading

    public func conversation(id: String) -> Conversation? { nil }

    /// The full message, from cache or the server.
    public func body(for message: MessageSummary) async throws -> MessageBody {
        throw MailError.messageNotFound
    }

    public func cachedBody(for message: MessageSummary) -> MessageBody? { nil }

    /// Marks the conversation's unread messages read (no toast, committed right away).
    public func markOpened(_ conversation: Conversation) {}

    // MARK: Triage

    /// Seconds an undoable action waits before it is sent to the server.
    public var undoWindow: TimeInterval = 4

    /// The current toast, if any. The UI shows it and calls `dismissToast()` when it times out.
    public private(set) var toast: Toast?

    /// Runs a swipe/shortcut action. `.snooze` needs a date, so the UI calls `snooze(_:until:)`
    /// for that instead; passing `.snooze` here is ignored.
    public func perform(_ action: SwipeAction, on conversations: [Conversation]) {}

    public func archive(_ conversations: [Conversation]) {}
    public func trash(_ conversations: [Conversation]) {}
    public func markSpam(_ conversations: [Conversation]) {}
    public func setRead(_ read: Bool, _ conversations: [Conversation]) {}
    public func toggleRead(_ conversations: [Conversation]) {}
    public func setFlagged(_ flagged: Bool, _ conversations: [Conversation]) {}
    public func toggleFlag(_ conversations: [Conversation]) {}
    /// Hides the conversations until `date` (archived on the server meanwhile), then brings them
    /// back to the top of the inbox, unread.
    public func snooze(_ conversations: [Conversation], until date: Date) {}
    public func unsnooze(_ conversations: [Conversation]) {}
    /// Back to the inbox (from Archive, Trash, Spam or Snoozed).
    public func moveToInbox(_ conversations: [Conversation]) {}
    public func move(_ conversations: [Conversation], to mailbox: MailboxInfo) {}

    /// When a conversation is snoozed until.
    public func snoozeDate(for conversation: Conversation) -> Date? { nil }

    /// Reverts the most recent undoable action (or cancels the pending send).
    public func undo() {}
    public func dismissToast() {}
    /// Shows an informational toast (used by the UI for things like "Copied").
    public func showToast(_ toast: Toast) {}

    /// Commits every pending action and send now (app going to background).
    public func flushPendingActions() async {}

    // MARK: Compose and send

    /// Seconds a sent message waits (with an Undo toast) before it actually goes out.
    public var undoSendDelay: TimeInterval = 5

    /// A blank message from `accountID` (or the default sending account), with signature.
    public func newDraft(accountID: String? = nil) -> OutgoingMessage {
        let account = accounts.first ?? .demo
        return OutgoingMessage(accountID: account.id, from: account.address)
    }

    /// Reply / reply-all / forward, with recipients, "Re:"/"Fwd:" subject, threading headers and
    /// the quoted original filled in. Pass the body if it is loaded so the quote is complete.
    public func draft(replyingTo message: MessageSummary, mode: ReplyMode, body: MessageBody?) -> OutgoingMessage {
        newDraft(accountID: message.accountID)
    }

    /// Queues the message. It is sent after `undoSendDelay` unless `undo()` is called.
    public func send(_ message: OutgoingMessage) {}

    /// Messages waiting to send or that failed.
    public private(set) var outbox: [OutgoingMessage] = []

    // MARK: Search

    /// Instant search over cached mail (subject, people, snippet), newest first.
    public func searchLocal(_ query: String) -> [Conversation] { [] }

    /// Server-side search across accounts' inboxes / All Mail, merged with local results.
    public func searchServer(_ query: String) async throws -> [Conversation] { [] }

    public private(set) var recentSearches: [String] = []
    public func recordSearch(_ query: String) {}

    // MARK: People

    /// Addresses you've exchanged mail with, best matches first.
    public func contactSuggestions(matching prefix: String, limit: Int = 6) -> [EmailAddress] { [] }

    /// True when the address is one of your accounts.
    public func isMe(_ address: EmailAddress) -> Bool { accounts.contains { $0.emailAddress.lowercased() == address.normalized } }
}
