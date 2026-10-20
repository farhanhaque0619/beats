import Foundation
import XCTest
import InkModel
@testable import InkSync

/// A clock tests can move forward.
final class TestClock: @unchecked Sendable {
    private let lock = NSLock()
    private var current: Date

    init(_ date: Date) { current = date }

    var now: Date { lock.withLock { current } }

    func advance(_ seconds: TimeInterval) { lock.withLock { current = current.addingTimeInterval(seconds) } }

    /// `@Sendable` closure for `MailStoreEnvironment.now`.
    var function: @Sendable () -> Date { { [self] in self.now } }
}

/// Tuesday 20 October 2026, 15:30 UTC: a weekday afternoon, so "today" has room for several messages.
let referenceDate: Date = {
    var components = DateComponents()
    components.year = 2026
    components.month = 10
    components.day = 20
    components.hour = 15
    components.minute = 30
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC") ?? .current
    return calendar.date(from: components) ?? Date(timeIntervalSince1970: 1_792_510_200)
}()

func makeTemporaryDirectory(_ name: String = #function) throws -> URL {
    let safe = name.filter { $0.isLetter || $0.isNumber }
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("InkSyncTests-\(safe)-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

/// Polls `condition` on the main actor until it holds or `timeout` passes.
@MainActor
func waitFor(_ timeout: TimeInterval = 3, _ condition: @MainActor () async -> Bool) async -> Bool {
    let deadline = Date().addingTimeInterval(timeout)
    while Date() < deadline {
        if await condition() { return true }
        try? await Task.sleep(nanoseconds: 20_000_000)
    }
    return await condition()
}

func address(_ name: String, _ email: String) -> EmailAddress { EmailAddress(name: name, address: email) }

/// A summary with sensible defaults for threading and cache tests.
func summary(
    account: String = "acct",
    mailbox: String = "INBOX",
    uid: UInt32,
    validity: UInt32 = 1,
    messageID: String?,
    inReplyTo: [String] = [],
    references: [String] = [],
    gmailThread: UInt64? = nil,
    gmailMessage: UInt64? = nil,
    subject: String,
    from: EmailAddress,
    to: [EmailAddress] = [address("Alex Rivera", "alex@ink.example")],
    cc: [EmailAddress] = [],
    date: Date,
    flags: MessageFlags = [.seen],
    bulk: Bool = false,
    snippet: String = ""
) -> MessageSummary {
    MessageSummary(
        accountID: account, mailboxPath: mailbox, uid: uid, uidValidity: validity,
        messageID: messageID, inReplyTo: inReplyTo, references: references,
        gmailThreadID: gmailThread, gmailMessageID: gmailMessage,
        subject: subject, from: [from], to: to, cc: cc, date: date,
        snippet: snippet, flags: flags, size: 4_096, isBulk: bulk)
}

/// A small IMAP-like server in memory: folders with UIDs, incremental sync, scripted failures and
/// a log of every call, for store tests that need to see (or break) the server side.
actor FakeMailService: MailService {
    nonisolated let account: AccountConfig
    private var folders: [MailboxInfo]
    private var contents: [String: [MessageSummary]]
    private var nextUID: [String: UInt32] = [:]
    let uidValidity: UInt32

    private(set) var performed: [(action: MailAction, ids: [String])] = []
    private(set) var sent: [OutgoingMessage] = []
    private(set) var syncCount = 0
    private(set) var searchQueries: [String] = []
    private var syncDelay: UInt64 = 0
    private var performDelay: UInt64 = 0
    private var performFailure: MailError?
    private var syncFailure: MailError?
    private var sendFailure: MailError?
    private var continuations: [AsyncStream<MailboxChange>.Continuation] = []
    /// Like IMAPMailService on a server that starts bare: Archive / Trash / Junk / Sent are
    /// created on first use, and `send` files a copy in Sent.
    private var createsMissingFolders = false
    private(set) var mailboxListCount = 0

    init(account: AccountConfig, folders: [MailboxInfo], contents: [String: [MessageSummary]], uidValidity: UInt32 = 7) {
        self.account = account
        self.folders = folders
        self.uidValidity = uidValidity
        var normalized: [String: [MessageSummary]] = [:]
        for folder in folders { normalized[folder.path] = [] }
        for (path, messages) in contents {
            normalized[path] = messages.map { message in
                var copy = message
                copy.accountID = account.id
                copy.mailboxPath = path
                copy.uidValidity = uidValidity
                return copy
            }.sorted { $0.uid < $1.uid }
        }
        self.contents = normalized
        for (path, messages) in normalized { nextUID[path] = (messages.map(\.uid).max() ?? 0) + 1 }
    }

    func failPerform(_ error: MailError?) { performFailure = error }
    func createMissingFolders() { createsMissingFolders = true }
    /// A folder made elsewhere (another app, the webmail).
    func addFolder(_ info: MailboxInfo, messages: [MessageSummary] = []) {
        folders.append(info)
        contents[info.path] = contents[info.path] ?? []
        nextUID[info.path] = nextUID[info.path] ?? 1
        for message in messages { deliver(message, to: info.path) }
    }
    func folderList() -> [MailboxInfo] { folders }

    /// The folder for `role`, created (as a real server would) when allowed and missing.
    private func folder(_ role: MailboxRole, createAs name: String) -> String? {
        if let existing = folders.first(where: { $0.role == role })?.path { return existing }
        guard createsMissingFolders else { return nil }
        folders.append(MailboxInfo(accountID: account.id, path: name, role: role))
        contents[name] = contents[name] ?? []
        nextUID[name] = nextUID[name] ?? 1
        return name
    }
    /// Makes `sync` answer with what the server had when it started, `seconds` later.
    func delaySync(_ seconds: Double) { syncDelay = UInt64(seconds * 1_000_000_000) }
    func failSync(_ error: MailError?) { syncFailure = error }
    /// Makes every `perform` take `seconds` before it changes anything.
    func delayPerform(_ seconds: Double) { performDelay = UInt64(seconds * 1_000_000_000) }
    func failSend(_ error: MailError?) { sendFailure = error }
    func messages(in path: String) -> [MessageSummary] { contents[path] ?? [] }

    /// Adds a message to a folder as new mail and pings watchers.
    @discardableResult
    func deliver(_ message: MessageSummary, to path: String = "INBOX") -> MessageSummary {
        var copy = message
        copy.accountID = account.id
        copy.mailboxPath = path
        copy.uidValidity = uidValidity
        copy.uid = nextUID[path] ?? 1
        nextUID[path] = copy.uid + 1
        contents[path, default: []].append(copy)
        for continuation in continuations { continuation.yield(.changed) }
        return copy
    }

    func verify(progress: @escaping @Sendable (VerificationStep) -> Void) async throws {
        for step in VerificationStep.allCases { progress(step) }
    }

    func mailboxes() async throws -> [MailboxInfo] {
        mailboxListCount += 1
        if let syncFailure { throw syncFailure }
        return folders
    }

    func sync(mailbox: MailboxInfo, previous: MailboxSyncState?, limit: Int) async throws -> MailboxSyncResult {
        syncCount += 1
        if let syncFailure { throw syncFailure }
        guard let messages = contents[mailbox.path] else { throw MailError.mailboxNotFound(mailbox.path) }
        let uidNext = nextUID[mailbox.path] ?? 1
        if syncDelay > 0 { try? await Task.sleep(nanoseconds: syncDelay) }
        if let previous, previous.uidValidity == uidValidity {
            let present = Dictionary(uniqueKeysWithValues: messages.map { ($0.uid, $0) })
            var upserted: [MessageSummary] = []
            var removed = Set<String>()
            var known: [UInt32] = []
            for uid in previous.knownUIDs {
                if let message = present[uid] {
                    upserted.append(message)
                    known.append(uid)
                } else {
                    removed.insert("\(account.id)|\(mailbox.path)|\(uidValidity)|\(uid)")
                }
            }
            let knownSet = Set(previous.knownUIDs)
            for message in messages where message.uid >= previous.uidNext && !knownSet.contains(message.uid) {
                upserted.append(message)
                known.append(message.uid)
            }
            return MailboxSyncResult(state: MailboxSyncState(uidValidity: uidValidity, uidNext: uidNext, knownUIDs: known.sorted()),
                                     upserted: upserted, removedIDs: removed)
        }
        let window = Array(messages.suffix(limit))
        return MailboxSyncResult(state: MailboxSyncState(uidValidity: uidValidity, uidNext: uidNext, knownUIDs: window.map(\.uid)),
                                 upserted: window, didReset: true)
    }

    func fetchOlder(mailbox: MailboxInfo, olderThanUID: UInt32, limit: Int) async throws -> [MessageSummary] {
        Array((contents[mailbox.path] ?? []).filter { $0.uid < olderThanUID }.suffix(limit))
    }

    func body(for message: MessageSummary) async throws -> MessageBody {
        guard contents[message.mailboxPath]?.contains(where: { $0.uid == message.uid }) == true else { throw MailError.messageNotFound }
        return MessageBody(messageID: message.id, plainText: "Body of \(message.subject)", html: nil)
    }

    func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        performed.append((action, messages.map(\.id)))
        if performDelay > 0 { try? await Task.sleep(nanoseconds: performDelay) }
        if let performFailure { throw performFailure }
        let destination: String?
        switch action {
        case .archive: destination = folders.first { $0.role == .all }?.path ?? folder(.archive, createAs: "Archive")
        case .trash: destination = folder(.trash, createAs: "Trash")
        case .markSpam: destination = folder(.junk, createAs: "Junk")
        case .moveToInbox: destination = "INBOX"
        case .move(let path): destination = path
        default: destination = nil
        }
        for original in messages {
            var message = original
            if action == .moveToInbox, contents[message.mailboxPath]?.contains(where: { $0.uid == message.uid }) != true {
                // Like a real server: find the message by Message-ID wherever it is now.
                guard let id = message.messageID,
                      let found = contents.first(where: { $0.key != "INBOX" && $0.value.contains { $0.messageID == id } }),
                      let copy = found.value.first(where: { $0.messageID == id }) else { continue }
                message = copy
            }
            guard var list = contents[message.mailboxPath], let index = list.firstIndex(where: { $0.uid == message.uid }) else { continue }
            switch action {
            case .markRead: list[index].flags.insert(.seen)
            case .markUnread: list[index].flags.remove(.seen)
            case .flag: list[index].flags.insert(.flagged)
            case .unflag: list[index].flags.remove(.flagged)
            case .deletePermanently: list.remove(at: index)
            default:
                guard let destination, destination != message.mailboxPath else { break }
                let moved = list.remove(at: index)
                contents[message.mailboxPath] = list
                // Gmail-style: archiving keeps the All Mail copy, so only add when it's not already there.
                let target = contents[destination] ?? []
                if moved.gmailMessageID == nil || !target.contains(where: { $0.gmailMessageID == moved.gmailMessageID }) {
                    var copy = moved
                    copy.uid = nextUID[destination] ?? 1
                    nextUID[destination] = copy.uid + 1
                    copy.mailboxPath = destination
                    contents[destination, default: []].append(copy)
                }
                continue
            }
            contents[message.mailboxPath] = list
        }
    }

    func send(_ message: OutgoingMessage) async throws {
        if let sendFailure { throw sendFailure }
        sent.append(message)
        if createsMissingFolders, let path = folder(.sent, createAs: "Sent") {
            deliver(MessageSummary(accountID: account.id, mailboxPath: path, uid: 0, uidValidity: uidValidity,
                                   messageID: "\(message.id.uuidString.lowercased())@ink.test",
                                   inReplyTo: message.inReplyTo.map { [$0] } ?? [], references: message.references,
                                   subject: message.subject, from: [message.from], to: message.to, cc: message.cc,
                                   date: message.createdAt, snippet: message.body, flags: [.seen]), to: path)
        }
    }

    func search(_ query: String, in mailbox: MailboxInfo, limit: Int) async throws -> [MessageSummary] {
        searchQueries.append(query)
        if let syncFailure { throw syncFailure }
        let needle = query.lowercased()
        return Array((contents[mailbox.path] ?? []).filter { $0.subject.lowercased().contains(needle) }.suffix(limit))
    }

    nonisolated func watch(mailbox: MailboxInfo) -> AsyncStream<MailboxChange> {
        let (stream, continuation) = AsyncStream<MailboxChange>.makeStream()
        Task { await self.addContinuation(continuation) }
        return stream
    }

    private func addContinuation(_ continuation: AsyncStream<MailboxChange>.Continuation) { continuations.append(continuation) }

    func disconnect() async {}
}

/// A Gmail-flavoured account and folder list.
func gmailFixture(accountID: String = "gmail-1") -> (AccountConfig, [MailboxInfo]) {
    let account = AccountConfig(
        id: accountID, provider: .gmail, displayName: "Alex Rivera", emailAddress: "alex.rivera@gmail.example",
        imap: ServerConfig(host: "imap.gmail.com", port: 993, security: .tls, username: "alex.rivera@gmail.example"),
        smtp: ServerConfig(host: "smtp.gmail.com", port: 465, security: .tls, username: "alex.rivera@gmail.example"),
        savesSentAutomatically: true, colorIndex: 2, createdAt: referenceDate)
    let folders = [
        MailboxInfo(accountID: accountID, path: "INBOX", role: .inbox, attributes: ["\\HasNoChildren"]),
        MailboxInfo(accountID: accountID, path: "[Gmail]/All Mail", role: .all, attributes: ["\\All", "\\HasNoChildren"]),
        MailboxInfo(accountID: accountID, path: "[Gmail]/Sent Mail", role: .sent, attributes: ["\\Sent", "\\HasNoChildren"]),
        MailboxInfo(accountID: accountID, path: "[Gmail]/Spam", role: .junk, attributes: ["\\Junk", "\\HasNoChildren"]),
        MailboxInfo(accountID: accountID, path: "[Gmail]/Trash", role: .trash, attributes: ["\\Trash", "\\HasNoChildren"]),
        MailboxInfo(accountID: accountID, path: "Receipts", role: .custom, attributes: ["\\HasNoChildren"]),
    ]
    return (account, folders)
}

/// A credential store whose writes fail (a locked keychain).
final class FailingCredentialStore: CredentialStore, @unchecked Sendable {
    func credential(for account: AccountConfig) async throws -> Credential { throw MailError.authenticationFailed("Keychain locked.") }
    func save(_ credential: Credential, for accountID: String) async throws { throw MailError.serverError("The keychain is locked.") }
    func delete(accountID: String) async throws {}
}
