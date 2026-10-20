import Foundation
import Observation
import InkModel
import InkMIME

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

    public convenience init(environment: MailStoreEnvironment) {
        self.init(environment: environment,
                  serviceFactory: MailStore.defaultServiceFactory(environment: environment),
                  cache: MailCache(storageDirectory: environment.storageDirectory))
    }

    /// A store that creates each account's `MailService` with `serviceFactory` instead of the
    /// built-in choice (demo accounts → `DemoMailService`, others → `IMAPMailService`).
    public convenience init(environment: MailStoreEnvironment, serviceFactory: @escaping MailServiceFactory) {
        self.init(environment: environment, serviceFactory: serviceFactory,
                  cache: MailCache(storageDirectory: environment.storageDirectory))
    }

    init(environment: MailStoreEnvironment, serviceFactory: @escaping MailServiceFactory, cache: MailCache?) {
        self.environment = environment
        self.serviceFactory = serviceFactory
        self.cache = cache
    }

    /// A store already filled with the demo inbox, synchronously. For previews and screenshots.
    public static func preview() -> MailStore {
        let environment = MailStoreEnvironment(
            storageDirectory: FileManager.default.temporaryDirectory.appendingPathComponent("InkPreview", isDirectory: true),
            credentials: InMemoryCredentialStore(),
            transportFactory: nil)
        let store = MailStore(environment: environment, serviceFactory: MailStore.defaultServiceFactory(environment: environment), cache: nil)
        store.installPreviewDemo()
        return store
    }

    /// Loads accounts, cached mail and snoozes from disk (fast, shows cached mail instantly),
    /// then refreshes from the servers in the background.
    public func load() async {
        if isLoaded { return }
        if let loadTask {
            await loadTask.value
            return
        }
        let task = Task { @MainActor in await self.performLoad() }
        loadTask = task
        await task.value
    }

    public let environment: MailStoreEnvironment

    // MARK: Accounts

    public internal(set) var accounts: [AccountConfig] = []
    public var hasAccounts: Bool { !accounts.isEmpty }
    public var isDemoActive: Bool { accounts.contains(where: \.isDemo) }

    public func account(id: String) -> AccountConfig? { accounts.first { $0.id == id } }

    /// Connects and signs in to IMAP and SMTP with these details without saving anything.
    public func verify(_ account: AccountConfig, credential: Credential, progress: @escaping @Sendable (VerificationStep) -> Void) async throws {
        try await performVerify(account, credential: credential, progress: progress)
    }

    /// Saves the credential, persists the account, loads its folders and syncs the inbox.
    /// Removes the demo account if it was the only one.
    public func addAccount(_ account: AccountConfig, credential: Credential) async throws {
        try await performAddAccount(account, credential: credential)
    }

    /// Adds the built-in sample inbox (no network).
    public func addDemoAccount() async {
        await performAddDemoAccount()
    }

    /// Removes the account, its credential and its cached mail.
    public func removeAccount(id: String) async {
        await performRemoveAccount(id: id)
    }

    /// Saves edits to an account's name, signature or colour.
    public func updateAccount(_ account: AccountConfig) {
        performUpdateAccount(account)
    }

    /// Accounts you can send from, demo excluded when real accounts exist.
    public var sendingAccounts: [AccountConfig] {
        let real = accounts.filter { !$0.isDemo }
        return real.isEmpty ? accounts : real
    }

    // MARK: Scope and lists

    /// What the list shows. Changing it rebuilds `conversations` from the cache immediately and
    /// syncs the new scope if it is stale.
    public var scope: MailScope = .allInboxes {
        didSet {
            guard scope != oldValue else { return }
            scopeDidChange()
        }
    }

    /// Focus / Other split for inbox scopes. Ignored elsewhere.
    public var inboxFilter: InboxFilter = .focused {
        didSet { if inboxFilter != oldValue { rebuildConversations() } }
    }

    /// Whether the Focus / Other split is on at all (a setting). When off, inboxes show everything.
    public var focusedInboxEnabled: Bool = true {
        didSet { if focusedInboxEnabled != oldValue { rebuildConversations() } }
    }

    /// Conversations for `scope` (and `inboxFilter`), newest first.
    public internal(set) var conversations: [Conversation] = []

    /// Unread conversations in Other, for the "Other" pill.
    public internal(set) var otherUnreadCount: Int = 0
    /// Total conversations in Other.
    public internal(set) var otherCount: Int = 0

    public internal(set) var syncStatus: SyncStatus = .idle
    public internal(set) var lastSyncedAt: Date?
    public internal(set) var isLoadingMore: Bool = false
    /// False once the server has no older messages for the scope.
    public internal(set) var canLoadMore: Bool = true

    /// Folders per account (from the last sync), sorted with well-known roles first.
    public internal(set) var mailboxesByAccount: [String: [MailboxInfo]] = [:]

    public func mailboxes(for accountID: String) -> [MailboxInfo] { mailboxesByAccount[accountID] ?? [] }

    /// Unread conversation count for a scope (inbox counts respect nothing but unread).
    public func unreadCount(for scope: MailScope) -> Int {
        allConversations(for: scope).reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
    }

    /// "All Inboxes", "Inbox", "Gmail · Receipts", ...
    public func title(for scope: MailScope) -> String { scopeTitle(scope) }

    /// Pulls new mail for the current scope (all accounts for unified scopes).
    public func refresh() async {
        if !isLoaded { await load() }
        await refresh(scope: scope, onlyIfStale: false)
    }

    /// Syncs every account's inbox. Returns messages that arrived since the previous sync
    /// (for background-refresh notifications).
    @discardableResult
    public func refreshAllInboxes() async -> [MessageSummary] {
        await performRefreshAllInboxes()
    }

    /// Pages in older messages for the current scope.
    public func loadMore() async {
        await performLoadMore()
    }

    /// Keeps an IMAP IDLE connection per inbox while the app is in the foreground.
    public func startLiveUpdates() {
        liveUpdatesWanted = true
        for account in accounts { startWatching(accountID: account.id) }
    }

    public func stopLiveUpdates() {
        liveUpdatesWanted = false
        for task in liveTasks.values { task.cancel() }
        liveTasks.removeAll()
    }

    // MARK: Reading

    public func conversation(id: String) -> Conversation? { findConversation(id: id) }

    /// The full message, from cache or the server.
    public func body(for message: MessageSummary) async throws -> MessageBody {
        try await loadBody(for: message)
    }

    public func cachedBody(for message: MessageSummary) -> MessageBody? {
        _ = dataVersion
        return lookupCachedBody(for: message)
    }

    /// Marks the conversation's unread messages read (no toast, committed right away).
    public func markOpened(_ conversation: Conversation) {
        performMarkOpened(conversation)
    }

    // MARK: Triage

    /// Seconds an undoable action waits before it is sent to the server.
    public var undoWindow: TimeInterval = 4

    /// The current toast, if any. The UI shows it and calls `dismissToast()` when it times out.
    public internal(set) var toast: Toast?

    /// Runs a swipe/shortcut action. `.snooze` needs a date, so the UI calls `snooze(_:until:)`
    /// for that instead; passing `.snooze` here is ignored.
    public func perform(_ action: SwipeAction, on conversations: [Conversation]) {
        switch action {
        case .none, .snooze: return
        case .archive: archive(conversations)
        case .trash: trash(conversations)
        case .toggleRead: toggleRead(conversations)
        case .flag: toggleFlag(conversations)
        case .markSpam: markSpam(conversations)
        }
    }

    public func archive(_ conversations: [Conversation]) { performMove(.archive, conversations) }
    public func trash(_ conversations: [Conversation]) { performMove(.trash, conversations) }
    public func markSpam(_ conversations: [Conversation]) { performMove(.markSpam, conversations) }
    public func setRead(_ read: Bool, _ conversations: [Conversation]) { performSetRead(read, conversations) }
    public func toggleRead(_ conversations: [Conversation]) {
        guard !conversations.isEmpty else { return }
        setRead(conversations.contains(where: \.isUnread), conversations)
    }
    public func setFlagged(_ flagged: Bool, _ conversations: [Conversation]) { performSetFlagged(flagged, conversations) }
    public func toggleFlag(_ conversations: [Conversation]) {
        guard !conversations.isEmpty else { return }
        setFlagged(!conversations.allSatisfy(\.isFlagged), conversations)
    }
    /// Hides the conversations until `date` (archived on the server meanwhile), then brings them
    /// back to the top of the inbox, unread.
    public func snooze(_ conversations: [Conversation], until date: Date) { performSnooze(conversations, until: date) }
    public func unsnooze(_ conversations: [Conversation]) { performUnsnooze(conversations) }
    /// Back to the inbox (from Archive, Trash, Spam or Snoozed).
    public func moveToInbox(_ conversations: [Conversation]) { performMoveToInbox(conversations) }
    public func move(_ conversations: [Conversation], to mailbox: MailboxInfo) { performMove(.move(toPath: mailbox.path), conversations, destination: mailbox) }

    /// When a conversation is snoozed until.
    public func snoozeDate(for conversation: Conversation) -> Date? { snoozes[conversation.id]?.until }

    /// Reverts the most recent undoable action (or cancels the pending send).
    public func undo() { performUndo() }
    public func dismissToast() {
        toast = nil
        toastEntry = nil
    }
    /// Shows an informational toast (used by the UI for things like "Copied").
    public func showToast(_ toast: Toast) {
        self.toast = toast
        toastEntry = nil
    }

    /// Commits every pending action and send now (app going to background).
    public func flushPendingActions() async { await performFlush() }

    // MARK: Compose and send

    /// Seconds a sent message waits (with an Undo toast) before it actually goes out.
    public var undoSendDelay: TimeInterval = 5

    /// A blank message from `accountID` (or the default sending account), with signature.
    public func newDraft(accountID: String? = nil) -> OutgoingMessage {
        let account = accountID.flatMap { self.account(id: $0) } ?? sendingAccounts.first ?? .demo
        return OutgoingMessage(accountID: account.id, from: account.address, body: signatureBlock(for: account), createdAt: environment.now())
    }

    /// Reply / reply-all / forward, with recipients, "Re:"/"Fwd:" subject, threading headers and
    /// the quoted original filled in. Pass the body if it is loaded so the quote is complete.
    public func draft(replyingTo message: MessageSummary, mode: ReplyMode, body: MessageBody?) -> OutgoingMessage {
        let account = self.account(id: message.accountID) ?? sendingAccounts.first ?? .demo
        var draft = ReplyBuilder.draft(replyingTo: message, body: body ?? cachedBody(for: message), mode: mode,
                                       from: account, myAddresses: myAddresses, now: environment.now())
        draft.body = signatureBlock(for: account)
        return draft
    }

    /// Queues the message. It is sent after `undoSendDelay` unless `undo()` is called.
    public func send(_ message: OutgoingMessage) { performSend(message) }

    /// Messages waiting to send or that failed.
    public internal(set) var outbox: [OutgoingMessage] = []

    // MARK: Search

    /// Instant search over cached mail (subject, people, snippet), newest first.
    public func searchLocal(_ query: String) -> [Conversation] { performSearchLocal(query) }

    /// Server-side search across accounts' inboxes / All Mail, merged with local results.
    public func searchServer(_ query: String) async throws -> [Conversation] { try await performSearchServer(query) }

    public internal(set) var recentSearches: [String] = []
    public func recordSearch(_ query: String) { performRecordSearch(query) }

    // MARK: People

    /// Addresses you've exchanged mail with, best matches first.
    public func contactSuggestions(matching prefix: String, limit: Int = 6) -> [EmailAddress] {
        contactIndex().suggestions(matching: prefix, limit: limit)
    }

    /// True when the address is one of your accounts.
    public func isMe(_ address: EmailAddress) -> Bool { accounts.contains { $0.emailAddress.lowercased() == address.normalized } }

    // MARK: Additions

    /// IDs in `outbox` whose last attempt failed (as opposed to waiting out the undo delay or sending).
    public internal(set) var failedSendIDs: Set<UUID> = []

    /// The message whose send was just undone, for Compose to reopen. Cleared by `takeRestoredDraft()`.
    public internal(set) var restoredDraft: OutgoingMessage?

    /// Returns `restoredDraft` and clears it.
    public func takeRestoredDraft() -> OutgoingMessage? {
        defer { restoredDraft = nil }
        return restoredDraft
    }

    /// Sends a failed outbox message again, right away.
    public func retrySend(id: UUID) { performRetrySend(id: id) }

    /// Drops a message from the outbox without sending it.
    public func discardOutboxMessage(id: UUID) { performDiscardOutbox(id: id) }

    /// The text new messages start with for `account`: two blank lines and the signature (after
    /// the standard "-- " separator), or "" when the account has none. Compose can compare a
    /// draft's body with this to tell whether anything was typed.
    public func signatureBlock(for account: AccountConfig) -> String {
        guard let signature = account.signature?.trimmingCharacters(in: .whitespacesAndNewlines), !signature.isEmpty else { return "" }
        if signature.hasPrefix("--") { return "\n\n" + signature }
        return "\n\n-- \n" + signature
    }

    /// Snoozed conversations across accounts, soonest to return first.
    public var snoozedConversations: [Conversation] { snoozedList(accountIDs: nil) }

    /// Brings back every snoozed conversation whose time has come (also runs on refresh and every minute).
    public func wakeDueSnoozes() async { await performWakeDueSnoozes() }

    /// Waits until no refresh, commit, send or wake-up is running. Undo windows that haven't
    /// elapsed yet are not waited for. For background tasks and tests.
    public func waitUntilIdle() async {
        while !inFlight.isEmpty {
            for task in Array(inFlight.values) { await task.value }
        }
    }

    // MARK: Internal state

    @ObservationIgnored let serviceFactory: MailServiceFactory
    @ObservationIgnored let cache: MailCache?
    @ObservationIgnored var services: [String: MailService] = [:]
    @ObservationIgnored var isLoaded = false
    @ObservationIgnored var loadTask: Task<Void, Never>?

    /// Cached mailboxes by `boxKey(accountID, path)`.
    @ObservationIgnored var mailboxData: [String: CachedMailbox] = [:]
    /// `[accountID: [path: MailboxInfo]]`, mirrors `mailboxesByAccount`.
    @ObservationIgnored var mailboxIndex: [String: [String: MailboxInfo]] = [:]
    /// When each mailbox was last synced in this session (by box key).
    @ObservationIgnored var lastSyncAt: [String: Date] = [:]
    @ObservationIgnored var lastMailboxListFetch: [String: Date] = [:]
    /// Mailboxes the server has no older messages for (by box key).
    @ObservationIgnored var exhaustedMailboxes: Set<String> = []

    /// Snoozed conversations by conversation ID. Observed so `snoozeDate(for:)` updates views.
    var snoozes: [String: SnoozeRecord] = [:]
    @ObservationIgnored var persisted = PersistedState()

    /// Bumped on every change to cached mail; invalidates the memoized lists below. Observed on
    /// purpose: views that call `unreadCount(for:)`, `conversation(id:)` or the search and contact
    /// helpers read it, so they update when mail changes.
    var dataVersion = 0
    @ObservationIgnored var scopeCache: [MailScope: (version: Int, conversations: [Conversation])] = [:]
    @ObservationIgnored var everythingCache: (version: Int, conversations: [Conversation], byID: [String: Int])?
    @ObservationIgnored var contactCache: (version: Int, index: ContactIndex)?
    @ObservationIgnored var searchTextCache: (version: Int, text: [String: String])?

    @ObservationIgnored var bodyMemory: [String: MessageBody] = [:]
    @ObservationIgnored var bodyMemoryOrder: [String] = []
    @ObservationIgnored var bodyTasks: [String: Task<MessageBody, Error>] = [:]
    /// Summaries returned by server search, by `MessageSummary.id`, so their threads can be opened.
    @ObservationIgnored var serverSearchResults: [String: MessageSummary] = [:]
    @ObservationIgnored var serverSearchOrder: [String] = []

    @ObservationIgnored var protections: [Protection] = []
    @ObservationIgnored var pendingAction: PendingAction?
    @ObservationIgnored var undoStack: [UndoEntry] = []
    /// Which undo entry the current toast belongs to.
    @ObservationIgnored var toastEntry: UndoEntry?
    @ObservationIgnored var commitChain: Task<Void, Never>?
    @ObservationIgnored var pendingSendTimers: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var inFlightSends: Set<UUID> = []
    @ObservationIgnored var sendTasks: [UUID: Task<Void, Never>] = [:]

    @ObservationIgnored var syncSequence = 0
    @ObservationIgnored var syncTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored var mailboxListTasks: [String: Task<Void, Error>] = [:]
    @ObservationIgnored var activeSyncs = 0
    @ObservationIgnored var roundErrors: [String] = []
    /// Tracked background work, awaited by `waitUntilIdle()`.
    @ObservationIgnored var inFlight: [UUID: Task<Void, Never>] = [:]
    @ObservationIgnored var wakeTimer: Task<Void, Never>?
    @ObservationIgnored var isWaking = false
    @ObservationIgnored var liveTasks: [String: Task<Void, Never>] = [:]
    @ObservationIgnored var liveSyncScheduled: Set<String> = []
    @ObservationIgnored var liveUpdatesWanted = false
}
