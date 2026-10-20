import Foundation

/// A server-side operation on messages.
public enum MailAction: Hashable, Codable, Sendable {
    /// Remove from the inbox, keep the message (Gmail: drop the Inbox label; others: move to Archive).
    case archive
    /// Move to Trash.
    case trash
    case markRead
    case markUnread
    case flag
    case unflag
    /// Move to Spam / Junk.
    case markSpam
    /// Put messages back in the inbox (undo archive, snooze wake-up, "not spam"). The summaries
    /// may still describe the old location; the service finds the message by Message-ID
    /// (or X-GM-MSGID) in Archive / All Mail / Trash / Spam.
    case moveToInbox
    /// Move into a specific folder (decoded path).
    case move(toPath: String)
    /// Expunge for good (only from Trash / Spam).
    case deletePermanently
}

/// What a mailbox looked like at the last sync, so the next one only fetches changes.
public struct MailboxSyncState: Hashable, Codable, Sendable {
    public var uidValidity: UInt32
    public var uidNext: UInt32
    public var highestModSeq: UInt64?
    /// UIDs inside the synced window (newest `limit` messages plus whatever was paged in).
    public var knownUIDs: [UInt32]
    public var lastSync: Date

    public init(uidValidity: UInt32, uidNext: UInt32, highestModSeq: UInt64? = nil, knownUIDs: [UInt32] = [], lastSync: Date = Date()) {
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
        self.knownUIDs = knownUIDs
        self.lastSync = lastSync
    }
}

public struct MailboxSyncResult: Sendable {
    public var state: MailboxSyncState
    /// New messages and messages whose flags changed.
    public var upserted: [MessageSummary]
    /// `MessageSummary.id`s that are gone from the mailbox.
    public var removedIDs: Set<String>
    /// UIDVALIDITY changed (or first sync): the caller should drop everything it cached for
    /// this mailbox and keep only `upserted`.
    public var didReset: Bool

    public init(state: MailboxSyncState, upserted: [MessageSummary], removedIDs: Set<String> = [], didReset: Bool = false) {
        self.state = state
        self.upserted = upserted
        self.removedIDs = removedIDs
        self.didReset = didReset
    }
}

/// Steps shown while connecting a new account.
public enum VerificationStep: String, Sendable, CaseIterable, Codable {
    case connectingIMAP, signingInIMAP, loadingMailboxes, connectingSMTP, signingInSMTP, done

    public var title: String {
        switch self {
        case .connectingIMAP: return "Reaching the mail server"
        case .signingInIMAP: return "Signing in"
        case .loadingMailboxes: return "Finding your folders"
        case .connectingSMTP: return "Reaching the sending server"
        case .signingInSMTP: return "Checking you can send"
        case .done: return "All set"
        }
    }
}

public enum MailboxChange: Sendable, Equatable {
    /// Something changed (new mail, flags, expunge). Re-sync the mailbox.
    case changed
    /// The live connection dropped; the caller may retry later.
    case connectionLost
}

/// One account's mail, behind a protocol so the UI and store don't care whether it's IMAP or the demo.
///
/// Implementations are actors. `account` and `watch` are `nonisolated`.
public protocol MailService: AnyObject, Sendable {
    var account: AccountConfig { get }

    /// Connects, signs in to IMAP and SMTP, lists folders, then disconnects. Reports each step.
    func verify(progress: @escaping @Sendable (VerificationStep) -> Void) async throws

    /// All folders, with roles detected from SPECIAL-USE attributes or well-known names.
    func mailboxes() async throws -> [MailboxInfo]

    /// Incremental sync of the newest `limit` messages (plus already-known ones) in `mailbox`.
    func sync(mailbox: MailboxInfo, previous: MailboxSyncState?, limit: Int) async throws -> MailboxSyncResult

    /// The next `limit` messages older than `olderThanUID` (for infinite scroll).
    func fetchOlder(mailbox: MailboxInfo, olderThanUID: UInt32, limit: Int) async throws -> [MessageSummary]

    /// Downloads and decodes the full message.
    func body(for message: MessageSummary) async throws -> MessageBody

    func perform(_ action: MailAction, on messages: [MessageSummary]) async throws

    /// Sends over SMTP, then files a copy in Sent unless the server does that itself.
    func send(_ message: OutgoingMessage) async throws

    /// Server-side search (Gmail: X-GM-RAW; others: SEARCH OR FROM/SUBJECT/BODY).
    func search(_ query: String, in mailbox: MailboxInfo, limit: Int) async throws -> [MessageSummary]

    /// Live updates for a mailbox (IMAP IDLE). Ends when the task is cancelled.
    func watch(mailbox: MailboxInfo) -> AsyncStream<MailboxChange>

    func disconnect() async
}

/// Errors with messages fit to show the user.
public enum MailError: Error, LocalizedError, Sendable, Equatable {
    case authenticationFailed(String)
    case connectionFailed(String)
    case tlsFailed(String)
    case timeout
    case protocolError(String)
    case serverError(String)
    case mailboxNotFound(String)
    case messageNotFound
    case notSupported(String)
    case cancelled
    case oauthNotConfigured(OAuthProviderID)
    case oauth(String)
    case sendFailed(String)

    public var errorDescription: String? {
        switch self {
        case .authenticationFailed(let detail):
            return detail.isEmpty ? "The server didn't accept that password." : "The server didn't accept that password: \(detail)"
        case .connectionFailed(let detail): return "Couldn't reach the server. \(detail)"
        case .tlsFailed(let detail): return "Couldn't set up a secure connection. \(detail)"
        case .timeout: return "The server took too long to answer."
        case .protocolError(let detail): return "The server sent something unexpected. \(detail)"
        case .serverError(let detail): return detail
        case .mailboxNotFound(let name): return "Couldn't find the folder “\(name)”."
        case .messageNotFound: return "That message is no longer on the server."
        case .notSupported(let what): return "This server doesn't support \(what)."
        case .cancelled: return "Cancelled."
        case .oauthNotConfigured(let provider):
            return "Sign in with \(provider == .google ? "Google" : "Microsoft") isn't set up in this build."
        case .oauth(let detail): return "Sign-in failed. \(detail)"
        case .sendFailed(let detail): return "Couldn't send. \(detail)"
        }
    }
}
