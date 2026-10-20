import Foundation
import InkModel

/// A snoozed conversation: when it comes back, and the messages it had when it was snoozed.
///
/// Persisted in `snoozes.json` as `[conversationID: SnoozeRecord]`. While snoozed, the inbox copies
/// are archived on the server; on wake-up they are moved back to the inbox and marked unread.
public struct SnoozeRecord: Codable, Sendable, Hashable {
    /// When the conversation comes back.
    public var until: Date
    /// The conversation's messages at snooze time (oldest first), as shown in Snoozed.
    public var messages: [MessageSummary]
    /// When it was snoozed.
    public var snoozedAt: Date

    public init(until: Date, messages: [MessageSummary], snoozedAt: Date = Date()) {
        self.until = until
        self.messages = messages
        self.snoozedAt = snoozedAt
    }

    /// The account the conversation belongs to.
    public var accountID: String { messages.last?.accountID ?? "" }
}

/// Creates the `MailService` behind an account. The store passes the credential store to use, which
/// is the environment's, or a temporary one holding the credential being verified.
public typealias MailServiceFactory = @MainActor (AccountConfig, CredentialStore) -> MailService

/// The newest inbox message `refreshAllInboxes()` has reported for an account.
struct HighWaterMark: Codable, Sendable, Hashable {
    var uidValidity: UInt32
    var uid: UInt32
    var receivedDate: Date

    /// True when `message` arrived after this mark: a higher UID in the same UIDVALIDITY, or a
    /// later received date after the mailbox was reset.
    func isBefore(_ message: MessageSummary) -> Bool {
        if message.uidValidity == uidValidity { return message.uid > uid }
        return message.receivedDate > receivedDate
    }

    /// The mark after also having seen `messages`.
    func advanced(past messages: [MessageSummary]) -> HighWaterMark {
        var mark = self
        for message in messages {
            if message.uidValidity == mark.uidValidity {
                mark.uid = max(mark.uid, message.uid)
            } else if message.receivedDate > mark.receivedDate {
                mark.uidValidity = message.uidValidity
                mark.uid = message.uid
            }
            mark.receivedDate = max(mark.receivedDate, message.receivedDate)
        }
        return mark
    }

    /// The mark for a mailbox seen for the first time: past everything below its UIDNEXT, and
    /// past every message in `messages`.
    static func start(state: MailboxSyncState, covering messages: [MessageSummary], now: Date) -> HighWaterMark {
        var mark = covering(messages) ?? HighWaterMark(uidValidity: state.uidValidity, uid: 0, receivedDate: now)
        if mark.uidValidity == state.uidValidity, state.uidNext > 0 { mark.uid = max(mark.uid, state.uidNext - 1) }
        return mark
    }

    static func covering(_ messages: [MessageSummary]) -> HighWaterMark? {
        guard let newest = messages.max(by: { ($0.receivedDate, $0.uid) < ($1.receivedDate, $1.uid) }) else { return nil }
        let start = HighWaterMark(uidValidity: newest.uidValidity, uid: newest.uid, receivedDate: newest.receivedDate)
        return start.advanced(past: messages)
    }
}

/// Small bits of store state kept in `state.json`.
struct PersistedState: Codable, Sendable {
    var recentSearches: [String] = []
    var highWaterMarks: [String: HighWaterMark] = [:]
    /// `MessageSummary.dedupeKey` → when it came back from a snooze, so woken conversations sort
    /// to the top of the inbox.
    var resurfaced: [String: Date] = [:]

    init() {}

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        recentSearches = (try? container.decode([String].self, forKey: .recentSearches)) ?? []
        highWaterMarks = (try? container.decode([String: HighWaterMark].self, forKey: .highWaterMarks)) ?? [:]
        resurfaced = (try? container.decode([String: Date].self, forKey: .resurfaced)) ?? [:]
    }
}

/// The service used for an account when the store can't reach servers (no transport factory:
/// previews and tests). Every call fails with a readable error.
actor OfflineMailService: MailService {
    nonisolated let account: AccountConfig

    init(account: AccountConfig) { self.account = account }

    private var offline: MailError { .connectionFailed("This build can't connect to mail servers.") }

    func verify(progress: @escaping @Sendable (VerificationStep) -> Void) async throws { throw offline }
    func mailboxes() async throws -> [MailboxInfo] { throw offline }
    func sync(mailbox: MailboxInfo, previous: MailboxSyncState?, limit: Int) async throws -> MailboxSyncResult { throw offline }
    func fetchOlder(mailbox: MailboxInfo, olderThanUID: UInt32, limit: Int) async throws -> [MessageSummary] { throw offline }
    func body(for message: MessageSummary) async throws -> MessageBody { throw offline }
    func perform(_ action: MailAction, on messages: [MessageSummary]) async throws { throw offline }
    func send(_ message: OutgoingMessage) async throws { throw offline }
    func search(_ query: String, in mailbox: MailboxInfo, limit: Int) async throws -> [MessageSummary] { throw offline }
    nonisolated func watch(mailbox: MailboxInfo) -> AsyncStream<MailboxChange> { AsyncStream { $0.finish() } }
    func disconnect() async {}
}

// MARK: Triage bookkeeping

/// Flags to add and remove, applied to every cached copy of a message.
struct FlagEdit: Sendable, Hashable {
    var insert: MessageFlags = []
    var remove: MessageFlags = []

    func applied(to flags: MessageFlags) -> MessageFlags { flags.union(insert).subtracting(remove) }

    /// This edit followed by `later`.
    func then(_ later: FlagEdit) -> FlagEdit {
        FlagEdit(insert: insert.subtracting(later.remove).union(later.insert),
                 remove: remove.subtracting(later.insert).union(later.remove))
    }
}

/// Keeps an optimistic change visible while the server hasn't confirmed it: syncs that merge
/// during the undo window or the commit (or that started before the commit finished) must not
/// bring an archived message back or revert a flag.
struct Protection: Sendable {
    let id: UUID
    /// `MessageSummary.id`s that must not reappear in their mailbox.
    var hiddenIDs: Set<String> = []
    /// `MessageSummary.dedupeKey` → flags to force on every copy.
    var flagEdits: [String: FlagEdit] = [:]
    /// `syncSequence` when the server confirmed the change; nil while pending or in flight.
    var finishedAtSequence: Int?
    var finishedAt: Date?

    init(id: UUID = UUID()) { self.id = id }

    /// Whether a sync that started at `sequence` must still be corrected by this protection.
    func applies(toSyncStartedAt sequence: Int) -> Bool {
        guard let finished = finishedAtSequence else { return true }
        return sequence <= finished
    }

    var isEmpty: Bool { hiddenIDs.isEmpty && flagEdits.isEmpty }
}

/// What an optimistic action changed locally, so Undo (or a failed commit) can put it back.
struct LocalChange {
    enum Location: Hashable {
        case mailbox(String)
        case snooze(String)
        case search
    }

    struct FlagChange {
        var location: Location
        var id: String
        var old: MessageFlags
    }

    /// Copies removed from a mailbox (by mailbox key).
    var removed: [(key: String, message: MessageSummary)] = []
    /// Server search results removed with them (the copy they describe is moving away).
    var removedSearchResults: [MessageSummary] = []
    var flagChanges: [FlagChange] = []
    var snoozesAdded: [String] = []
    var snoozesRemoved: [(id: String, record: SnoozeRecord)] = []

    var isEmpty: Bool {
        removed.isEmpty && removedSearchResults.isEmpty && flagChanges.isEmpty && snoozesAdded.isEmpty && snoozesRemoved.isEmpty
    }
}

/// One server call a triage action needs.
struct ServerOperation: Codable, Sendable {
    var accountID: String
    var action: MailAction
    var messages: [MessageSummary]
    /// Snoozed messages (as they were in the inbox) whose archived copies weren't cached when the
    /// action was taken. The commit finds them on the server first (`MailStore.locateSnoozed`).
    var unlocated: [MessageSummary] = []

    init(accountID: String, action: MailAction, messages: [MessageSummary], unlocated: [MessageSummary] = []) {
        self.accountID = accountID
        self.action = action
        self.messages = messages
        self.unlocated = unlocated
    }

    var isEmpty: Bool { messages.isEmpty && unlocated.isEmpty }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        accountID = try container.decode(String.self, forKey: .accountID)
        action = try container.decode(MailAction.self, forKey: .action)
        messages = (try? container.decode([MessageSummary].self, forKey: .messages)) ?? []
        unlocated = (try? container.decode([MessageSummary].self, forKey: .unlocated)) ?? []
    }
}

/// Triage the server hasn't confirmed yet. Kept in pending-actions.json from the moment an action
/// is taken until its commit finishes (or it is undone), so an action the app didn't live to send
/// (quit or killed during the undo window or mid-commit) is sent by the next launch.
struct JournalEntry: Codable, Sendable {
    var id: UUID
    var operations: [ServerOperation]
    /// "archive", "move to Trash" … for the error toast if the replay fails.
    var verb: String
}

/// What to do once a committed action succeeded.
enum FollowUp: Hashable {
    /// Re-sync an account's inbox (messages were moved into it).
    case syncInbox(accountID: String)
    /// A mailbox received messages; sync it next time it is shown.
    case markStale(accountID: String, path: String)
}

/// An optimistic action waiting out its undo window.
struct PendingAction {
    let id: UUID
    var operations: [ServerOperation]
    var change: LocalChange
    var protectionID: UUID
    /// "archive", "move to Trash" … for "Couldn't archive." errors.
    var verb: String
    var followUps: [FollowUp]
    var timer: Task<Void, Never>?
}

/// Entries that `undo()` can revert, most recent last.
enum UndoEntry: Hashable {
    case action(UUID)
    case send(UUID)
}

extension Array where Element == ServerOperation {
    /// One operation per account and action, messages in order, without duplicates.
    func coalesced() -> [ServerOperation] {
        var result: [ServerOperation] = []
        for operation in self where !operation.isEmpty {
            if let index = result.firstIndex(where: { $0.accountID == operation.accountID && $0.action == operation.action }) {
                let known = Set(result[index].messages.map(\.id))
                result[index].messages += operation.messages.filter { !known.contains($0.id) }
                let knownUnlocated = Set(result[index].unlocated.map(\.id))
                result[index].unlocated += operation.unlocated.filter { !knownUnlocated.contains($0.id) }
            } else {
                var unique = operation
                var seen = Set<String>()
                unique.messages = operation.messages.filter { seen.insert($0.id).inserted }
                var seenUnlocated = Set<String>()
                unique.unlocated = operation.unlocated.filter { seenUnlocated.insert($0.id).inserted }
                result.append(unique)
            }
        }
        return result
    }
}

extension Error {
    /// The sentence to show for this error.
    var userMessage: String {
        if let mail = self as? MailError, let text = mail.errorDescription { return text }
        if let transport = self as? TransportError, let text = transport.errorDescription { return text }
        if let localized = self as? LocalizedError, let text = localized.errorDescription, !text.isEmpty { return text }
        return localizedDescription
    }
}
