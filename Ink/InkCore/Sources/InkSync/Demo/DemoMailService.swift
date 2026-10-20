import Foundation
import InkModel

/// The built-in sample account: a realistic, deterministic inbox that lives entirely in memory.
///
/// It behaves like a small IMAP server: every folder has a UIDVALIDITY and ascending UIDs,
/// `sync` is incremental (new UIDs, flag updates, expunged UIDs), moves give messages a new UID
/// in the destination folder, and `send` files a copy in Sent (and delivers it to the inbox when
/// you write to yourself). Nothing touches the network or the disk.
///
/// Each instance picks a fresh UIDVALIDITY, so a store that cached an earlier demo session
/// resets cleanly instead of mixing old and new sample mail.
public actor DemoMailService: MailService {
    public nonisolated let account: AccountConfig

    private let now: @Sendable () -> Date
    private let latency: TimeInterval
    private let uidValidity: UInt32
    private var mailboxList: [MailboxInfo]
    /// Folder path → summaries, UID ascending.
    private var folders: [String: [MessageSummary]]
    private var nextUID: [String: UInt32]
    /// Lowercased Message-ID → body.
    private var bodies: [String: MessageBody]
    private var watchers: [UUID: (path: String, continuation: AsyncStream<MailboxChange>.Continuation)] = [:]

    /// - Parameters:
    ///   - now: the clock the sample dates are relative to (and new messages are stamped with).
    ///   - latency: simulated round-trip time for every call, for exercising loading states.
    public init(account: AccountConfig = .demo, now: @escaping @Sendable () -> Date = { Date() }, latency: TimeInterval = 0) {
        let date = now()
        self.init(account: account, now: now, latency: latency,
                  snapshot: DemoContent.snapshot(account: account, now: date, uidValidity: Self.uidValidity(for: date)))
    }

    /// The UIDVALIDITY a demo session started at `date` uses: one per minute, never zero.
    static func uidValidity(for date: Date) -> UInt32 {
        let minutes = max(1, Int(date.timeIntervalSince1970.isFinite ? date.timeIntervalSince1970 : 60) / 60)
        let validity = UInt32(truncatingIfNeeded: minutes)
        return validity == 0 ? 1 : validity
    }

    init(account: AccountConfig, now: @escaping @Sendable () -> Date, latency: TimeInterval = 0, snapshot: DemoSnapshot) {
        self.account = account
        self.now = now
        self.latency = max(0, latency)
        self.uidValidity = snapshot.uidValidity
        self.mailboxList = snapshot.mailboxes
        self.folders = snapshot.messages
        self.bodies = snapshot.bodies
        var next: [String: UInt32] = [:]
        for (path, messages) in snapshot.messages { next[path] = (messages.last?.uid ?? 100) + 1 }
        self.nextUID = next
    }

    // MARK: Inspection (tests, previews)

    /// The messages currently in a folder, oldest first.
    public func messages(in path: String) -> [MessageSummary] { folders[canonicalPath(path)] ?? [] }

    /// A message's body by Message-ID, if the demo has one.
    public func storedBody(messageID: String) -> MessageBody? { bodies[messageID.lowercased()] }

    /// Puts a new message in the inbox as if it had just arrived, and wakes `watch` streams.
    /// The message gets the next inbox UID; its account and mailbox fields are overwritten.
    @discardableResult
    public func deliver(_ message: MessageSummary, body: MessageBody? = nil) -> MessageSummary {
        var copy = message
        copy.accountID = account.id
        if copy.messageID == nil { copy.messageID = "\(UUID().uuidString.lowercased())@demo.ink.example" }
        let stored = insert(copy, into: "INBOX")
        if let body, let id = stored.messageID { bodies[id.lowercased()] = body }
        notify(path: "INBOX")
        return stored
    }

    /// A plausible new message from one of the demo's people, delivered to the inbox.
    @discardableResult
    public func deliverSampleMessage() -> MessageSummary {
        let text = "Running about ten minutes late — save me a seat? I'll grab us coffees on the way.\n\nSam"
        let summary = MessageSummary(
            accountID: account.id, mailboxPath: "INBOX", uid: 0, uidValidity: uidValidity,
            messageID: "\(UUID().uuidString.lowercased())@mailbox.example",
            subject: "Running a little late", from: [DemoContent.sam], to: [account.address],
            date: now(), snippet: DemoBuilder.snippet(from: text), size: 2_600)
        return deliver(summary, body: MessageBody(messageID: "", plainText: text, fetchedAt: now()))
    }

    // MARK: MailService

    public func verify(progress: @escaping @Sendable (VerificationStep) -> Void) async throws {
        for step in VerificationStep.allCases {
            await pause()
            progress(step)
        }
    }

    public func mailboxes() async throws -> [MailboxInfo] {
        await pause()
        return mailboxList
    }

    public func sync(mailbox: MailboxInfo, previous: MailboxSyncState?, limit: Int) async throws -> MailboxSyncResult {
        await pause()
        let path = canonicalPath(mailbox.path)
        guard let messages = folders[path] else { throw MailError.mailboxNotFound(mailbox.path) }
        let uidNext = nextUID[path] ?? 1
        let stamp = now()
        if let previous, previous.uidValidity == uidValidity {
            let present = Dictionary(uniqueKeysWithValues: messages.map { ($0.uid, $0) })
            let known = Set(previous.knownUIDs)
            var upserted: [MessageSummary] = []
            var removed = Set<String>()
            var knownNow: [UInt32] = []
            for uid in previous.knownUIDs.sorted() {
                if let message = present[uid] {
                    upserted.append(message)
                    knownNow.append(uid)
                } else {
                    removed.insert("\(account.id)|\(path)|\(uidValidity)|\(uid)")
                }
            }
            for message in messages where message.uid >= previous.uidNext && !known.contains(message.uid) {
                upserted.append(message)
                knownNow.append(message.uid)
            }
            let state = MailboxSyncState(uidValidity: uidValidity, uidNext: uidNext, knownUIDs: knownNow.sorted(), lastSync: stamp)
            return MailboxSyncResult(state: state, upserted: upserted, removedIDs: removed, didReset: false)
        }
        let window = Array(messages.suffix(max(0, limit)))
        let state = MailboxSyncState(uidValidity: uidValidity, uidNext: uidNext, knownUIDs: window.map(\.uid), lastSync: stamp)
        return MailboxSyncResult(state: state, upserted: window, removedIDs: [], didReset: true)
    }

    public func fetchOlder(mailbox: MailboxInfo, olderThanUID: UInt32, limit: Int) async throws -> [MessageSummary] {
        await pause()
        let path = canonicalPath(mailbox.path)
        guard let messages = folders[path] else { throw MailError.mailboxNotFound(mailbox.path) }
        return Array(messages.filter { $0.uid < olderThanUID }.suffix(max(0, limit)))
    }

    public func body(for message: MessageSummary) async throws -> MessageBody {
        await pause()
        guard let located = locate(message), let id = located.messageID, var body = bodies[id.lowercased()] else {
            throw MailError.messageNotFound
        }
        body.messageID = message.id
        body.fetchedAt = now()
        return body
    }

    public func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        await pause()
        switch action {
        case .archive:
            for message in messages { move(message, to: "Archive") }
        case .trash:
            for message in messages { move(message, to: "Trash") }
        case .markSpam:
            for message in messages { move(message, to: "Junk") }
        case .markRead:
            for message in messages { updateFlags(message) { $0.insert(.seen) } }
        case .markUnread:
            for message in messages { updateFlags(message) { $0.remove(.seen) } }
        case .flag:
            for message in messages { updateFlags(message) { $0.insert(.flagged) } }
        case .unflag:
            for message in messages { updateFlags(message) { $0.remove(.flagged) } }
        case .moveToInbox:
            for message in messages {
                // Like the IMAP service: find the message by Message-ID wherever it is now.
                guard let id = message.messageID?.lowercased() else { continue }
                if folders["INBOX"]?.contains(where: { $0.messageID?.lowercased() == id }) == true { continue }
                if let current = locate(message, preferring: ["Archive", "Trash", "Junk"]) { move(current, to: "INBOX") }
            }
        case .move(let toPath):
            let target = canonicalPath(toPath)
            guard folders[target] != nil else { throw MailError.mailboxNotFound(toPath) }
            for message in messages { move(message, to: target) }
        case .deletePermanently:
            for message in messages {
                guard let current = locate(message) else { continue }
                folders[current.mailboxPath]?.removeAll { $0.uid == current.uid }
            }
        }
    }

    public func send(_ message: OutgoingMessage) async throws {
        await pause()
        let recipients = message.allRecipients
        guard !recipients.isEmpty else { throw MailError.sendFailed("Add at least one recipient.") }
        if let bad = recipients.first(where: { !$0.isValid }) {
            throw MailError.sendFailed("\(bad.address): that doesn't look like an email address.")
        }
        let date = now()
        let messageID = "\(message.id.uuidString.lowercased())@\(account.address.domain.isEmpty ? "ink.example" : account.address.domain)"
        var references = message.references
        if let parent = message.inReplyTo, !references.contains(parent) { references.append(parent) }
        let text = message.fullPlainText
        let attachments = message.attachments.enumerated().map { index, file in
            Attachment(id: "\(index + 2)", filename: file.filename, mimeType: file.mimeType, size: file.data.count, data: file.data)
        }
        let summary = MessageSummary(
            accountID: account.id, mailboxPath: "Sent", uid: 0, uidValidity: uidValidity,
            messageID: messageID, inReplyTo: message.inReplyTo.map { [$0] } ?? [], references: references,
            subject: message.subject, from: [message.from], to: message.to, cc: message.cc, bcc: message.bcc,
            date: date, snippet: DemoBuilder.snippet(from: message.body), flags: [.seen],
            size: 2_400 + text.utf8.count + attachments.reduce(0) { $0 + $1.size * 4 / 3 },
            hasAttachments: !attachments.isEmpty)
        let body = MessageBody(messageID: "", plainText: text, html: nil, attachments: attachments, fetchedAt: date)
        bodies[messageID] = body
        insert(summary, into: "Sent")
        notify(path: "Sent")

        if let parent = message.inReplyTo?.lowercased() {
            for (path, messages) in folders {
                for index in messages.indices where messages[index].messageID?.lowercased() == parent {
                    if message.replyMode == .forward {
                        folders[path]?[index].flags.insert(.forwarded)
                    } else {
                        folders[path]?[index].flags.insert(.answered)
                    }
                }
            }
        }
        if recipients.contains(where: { $0.normalized == account.emailAddress.lowercased() }) {
            var incoming = summary
            incoming.flags = []
            insert(incoming, into: "INBOX")
            notify(path: "INBOX")
        }
    }

    public func search(_ query: String, in mailbox: MailboxInfo, limit: Int) async throws -> [MessageSummary] {
        await pause()
        let terms = query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
        guard !terms.isEmpty else { return [] }
        let path = canonicalPath(mailbox.path)
        guard let messages = folders[path] else { throw MailError.mailboxNotFound(mailbox.path) }
        let hits = messages.filter { message in
            var haystack = message.subject + " " + message.snippet
            for address in message.from + message.to + message.cc { haystack += " \(address.name ?? "") \(address.address)" }
            if let id = message.messageID, let text = bodies[id.lowercased()]?.plainText { haystack += " " + text }
            let lowered = haystack.lowercased()
            return terms.allSatisfy { lowered.contains($0) }
        }
        return Array(hits.suffix(max(0, limit)))
    }

    public nonisolated func watch(mailbox: MailboxInfo) -> AsyncStream<MailboxChange> {
        let (stream, continuation) = AsyncStream<MailboxChange>.makeStream(bufferingPolicy: .bufferingNewest(8))
        let id = UUID()
        let path = mailbox.path
        continuation.onTermination = { [weak self] _ in
            guard let self else { return }
            Task { await self.removeWatcher(id) }
        }
        Task { await self.addWatcher(id, path: path, continuation: continuation) }
        return stream
    }

    public func disconnect() async {}

    // MARK: Internals

    private func pause() async {
        guard latency > 0 else { return }
        try? await Task.sleep(nanoseconds: UInt64(latency * 1_000_000_000))
    }

    private func addWatcher(_ id: UUID, path: String, continuation: AsyncStream<MailboxChange>.Continuation) {
        watchers[id] = (canonicalPath(path), continuation)
    }

    private func removeWatcher(_ id: UUID) { watchers[id] = nil }

    private func notify(path: String) {
        for (_, watcher) in watchers where watcher.path == path { watcher.continuation.yield(.changed) }
    }

    /// "inbox" → "INBOX"; other paths as stored.
    private func canonicalPath(_ path: String) -> String {
        path.caseInsensitiveCompare("INBOX") == .orderedSame ? "INBOX" : path
    }

    /// The message's current copy: same folder and UID when still valid, else by Message-ID
    /// (preferring `preferring` folders, then the original folder, then anywhere).
    private func locate(_ message: MessageSummary, preferring: [String] = []) -> MessageSummary? {
        let path = canonicalPath(message.mailboxPath)
        if message.uidValidity == uidValidity, let copy = folders[path]?.first(where: { $0.uid == message.uid }) {
            if message.messageID == nil || copy.messageID?.lowercased() == message.messageID?.lowercased() { return copy }
        }
        guard let id = message.messageID?.lowercased() else { return nil }
        let order = preferring + [path] + folders.keys.sorted()
        for folder in order {
            if let copy = folders[folder]?.first(where: { $0.messageID?.lowercased() == id }) { return copy }
        }
        return nil
    }

    @discardableResult
    private func insert(_ message: MessageSummary, into path: String) -> MessageSummary {
        let path = canonicalPath(path)
        var copy = message
        let uid = nextUID[path] ?? 101
        nextUID[path] = uid + 1
        copy.uid = uid
        copy.uidValidity = uidValidity
        copy.mailboxPath = path
        copy.threadKey = nil
        folders[path, default: []].append(copy)
        return copy
    }

    private func move(_ message: MessageSummary, to target: String) {
        let target = canonicalPath(target)
        guard let current = locate(message), current.mailboxPath != target else { return }
        folders[current.mailboxPath]?.removeAll { $0.uid == current.uid }
        insert(current, into: target)
    }

    private func updateFlags(_ message: MessageSummary, _ change: (inout MessageFlags) -> Void) {
        guard let current = locate(message), var list = folders[current.mailboxPath],
              let index = list.firstIndex(where: { $0.uid == current.uid }) else { return }
        change(&list[index].flags)
        folders[current.mailboxPath] = list
    }
}
