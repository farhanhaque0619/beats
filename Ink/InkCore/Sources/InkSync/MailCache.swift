import Foundation
import InkModel
import InkProviders

/// One mailbox as the cache keeps it: the sync state plus the summaries in the synced window.
public struct CachedMailbox: Codable, Sendable, Equatable {
    public var accountID: String
    /// Decoded mailbox path ("INBOX", "[Gmail]/All Mail").
    public var path: String
    public var state: MailboxSyncState?
    public var messages: [MessageSummary]
    public var savedAt: Date

    public init(accountID: String, path: String, state: MailboxSyncState?, messages: [MessageSummary], savedAt: Date = Date()) {
        self.accountID = accountID
        self.path = path
        self.state = state
        self.messages = messages
        self.savedAt = savedAt
    }
}

/// Everything cached for one account, as read back at launch.
public struct CachedAccount: Sendable {
    public var mailboxes: [MailboxInfo]?
    public var mailboxContents: [CachedMailbox]
}

/// The on-disk message cache: JSON files under `<storageDirectory>/cache/<accountID>/`.
///
/// - `mailboxes.json`: the account's folder list.
/// - `mailbox-<sha256(path)>.json`: a `CachedMailbox` (sync state + summaries).
/// - `bodies/<sha256(key)>.json`: a `MessageBody`. Attachments larger than
///   `maxStoredAttachmentBytes` are stored without their data.
///
/// Writes are coalesced: scheduling a write only records it, and a serial background queue
/// encodes and writes everything pending once `debounceInterval` has passed (a later write to
/// the same file replaces an earlier one that hasn't gone out yet). Every write is atomic
/// (temporary file + rename), so a crash never leaves a half-written file. Unreadable or corrupt
/// files are ignored. The class is thread-safe; nothing here blocks the main thread except the
/// small synchronous body read used by `MailStore.cachedBody(for:)`.
public final class MailCache: @unchecked Sendable {
    /// `<storageDirectory>/cache`.
    public let directory: URL
    /// How long writes are held back so bursts of changes become one write per file.
    public let debounceInterval: TimeInterval
    /// Attachments above this size are cached without data (re-downloaded when opened).
    public static let maxStoredAttachmentBytes = 5 * 1024 * 1024

    private struct PendingWrite {
        var sequence: UInt64
        /// Returns the bytes to write, or nil to delete the file.
        var produce: @Sendable () throws -> Data?
    }

    private let lock = NSLock()
    private let queue = DispatchQueue(label: "ink.mailcache.io", qos: .utility)
    private var pending: [URL: PendingWrite] = [:]
    private var flushScheduled = false
    private var sequence: UInt64 = 0
    private let fileManager = FileManager()

    /// - Parameter storageDirectory: the store's storage directory; the cache lives in its `cache` subfolder.
    public init(storageDirectory: URL, debounceInterval: TimeInterval = 0.5) {
        self.directory = storageDirectory.appendingPathComponent("cache", isDirectory: true)
        self.debounceInterval = max(0, debounceInterval)
    }

    // MARK: Paths

    /// A filesystem-safe folder name for an account ID.
    static func safeComponent(_ raw: String) -> String {
        let allowed = Set("abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789-_.")
        if !raw.isEmpty, raw.count <= 80, raw.first != ".", raw.allSatisfy({ allowed.contains($0) }) { return raw }
        return "a-" + String(InkSHA256.hexDigest(Array(raw.utf8)).prefix(32))
    }

    func accountDirectory(_ accountID: String) -> URL {
        directory.appendingPathComponent(Self.safeComponent(accountID), isDirectory: true)
    }

    func mailboxesURL(accountID: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("mailboxes.json")
    }

    func mailboxURL(accountID: String, path: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("mailbox-\(InkSHA256.hexDigest(Array(path.utf8)).prefix(40)).json")
    }

    func bodyURL(accountID: String, key: String) -> URL {
        accountDirectory(accountID).appendingPathComponent("bodies", isDirectory: true)
            .appendingPathComponent("\(InkSHA256.hexDigest(Array(key.utf8)).prefix(40)).json")
    }

    // MARK: Writing

    /// Schedules the folder list for an account to be written.
    public func saveMailboxes(_ mailboxes: [MailboxInfo], accountID: String) {
        scheduleJSON(mailboxes, to: mailboxesURL(accountID: accountID))
    }

    /// Schedules one mailbox's state and summaries to be written.
    public func saveMailbox(_ mailbox: CachedMailbox) {
        scheduleJSON(mailbox, to: mailboxURL(accountID: mailbox.accountID, path: mailbox.path))
    }

    /// Schedules a mailbox's file to be deleted.
    public func removeMailbox(accountID: String, path: String) {
        schedule(mailboxURL(accountID: accountID, path: path)) { nil }
    }

    /// Schedules a message body to be written under `key` (usually `MessageSummary.dedupeKey`).
    /// Large attachments are stored without their data.
    public func saveBody(_ body: MessageBody, key: String, accountID: String) {
        var trimmed = body
        trimmed.attachments = body.attachments.map { attachment in
            var copy = attachment
            if let data = copy.data, data.count > Self.maxStoredAttachmentBytes { copy.data = nil }
            return copy
        }
        scheduleJSON(trimmed, to: bodyURL(accountID: accountID, key: key))
    }

    /// Schedules any Codable value to be written to `url` (used for the store's own files:
    /// accounts.json, snoozes.json, state.json).
    public func scheduleJSON<T: Encodable & Sendable>(_ value: T, to url: URL) {
        schedule(url) {
            let encoder = JSONEncoder()
            encoder.dateEncodingStrategy = .secondsSince1970
            return try encoder.encode(value)
        }
    }

    /// Deletes everything cached for the account (pending writes for it are dropped).
    public func removeAccount(_ accountID: String) {
        let folder = accountDirectory(accountID)
        let prefix = folder.standardizedFileURL.path
        lock.withLock {
            pending = pending.filter { !$0.key.standardizedFileURL.path.hasPrefix(prefix) }
        }
        queue.async { [fileManager] in try? fileManager.removeItem(at: folder) }
    }

    /// Writes everything pending now and waits for it.
    public func flush() async {
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.writePending()
                continuation.resume()
            }
        }
    }

    private func schedule(_ url: URL, produce: @escaping @Sendable () throws -> Data?) {
        let needsTimer: Bool = lock.withLock {
            sequence &+= 1
            pending[url] = PendingWrite(sequence: sequence, produce: produce)
            if flushScheduled { return false }
            flushScheduled = true
            return true
        }
        guard needsTimer else { return }
        queue.asyncAfter(deadline: .now() + debounceInterval) { self.writePending() }
    }

    /// Runs on `queue`. Each entry stays in `pending` (so readers still see it) until its file is
    /// written; an entry replaced meanwhile by a newer write is left for the next pass.
    private func writePending() {
        let batch: [(URL, PendingWrite)] = lock.withLock {
            flushScheduled = false
            return pending.sorted { $0.value.sequence < $1.value.sequence }
        }
        for (url, write) in batch {
            do {
                if let data = try write.produce() {
                    try fileManager.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
                    try data.write(to: url, options: .atomic)
                } else if fileManager.fileExists(atPath: url.path) {
                    try fileManager.removeItem(at: url)
                }
            } catch {
                // A failed cache write only costs a re-download later; never surface it.
            }
            lock.withLock {
                if pending[url]?.sequence == write.sequence { pending[url] = nil }
            }
        }
    }

    // MARK: Pruning

    /// Deletes an account's least recently written bodies until the rest take at most `maxBytes`
    /// on disk (they are downloaded again when opened). Runs off the calling thread; bodies with
    /// a write still pending are kept.
    public func pruneBodies(accountID: String, maxBytes: Int) async {
        let folder = accountDirectory(accountID).appendingPathComponent("bodies", isDirectory: true)
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            queue.async {
                self.prune(folder, maxBytes: max(0, maxBytes))
                continuation.resume()
            }
        }
    }

    private func prune(_ folder: URL, maxBytes: Int) {
        let keys: [URLResourceKey] = [.fileSizeKey, .contentModificationDateKey]
        guard let files = try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: keys) else { return }
        let pendingPaths: Set<String> = lock.withLock { Set(pending.keys.map(\.standardizedFileURL.path)) }
        var entries: [(url: URL, size: Int, date: Date)] = []
        for file in files where file.pathExtension == "json" {
            let values = try? file.resourceValues(forKeys: Set(keys))
            entries.append((file, values?.fileSize ?? 0, values?.contentModificationDate ?? .distantPast))
        }
        // Newest first; ties by name so the outcome doesn't depend on the directory order.
        entries.sort { $0.date != $1.date ? $0.date > $1.date : $0.url.lastPathComponent < $1.url.lastPathComponent }
        var total = 0
        for entry in entries {
            total += entry.size
            guard total > maxBytes, !pendingPaths.contains(entry.url.standardizedFileURL.path) else { continue }
            try? fileManager.removeItem(at: entry.url)
        }
    }

    // MARK: Reading

    /// Reads an account's folder list and every cached mailbox, off the calling thread.
    /// Pending writes are written first so the result is never older than what was saved.
    public func loadAccount(_ accountID: String) async -> CachedAccount {
        await withCheckedContinuation { (continuation: CheckedContinuation<CachedAccount, Never>) in
            queue.async {
                self.writePending()
                continuation.resume(returning: self.readAccount(accountID))
            }
        }
    }

    /// Reads a body written by `saveBody`, synchronously. With `maxFileBytes`, a body whose file is
    /// bigger (attachments) isn't read: use `loadBodyInBackground` for it.
    public func loadBody(key: String, accountID: String, maxFileBytes: Int? = nil) -> MessageBody? {
        let url = bodyURL(accountID: accountID, key: key)
        if let write = lock.withLock({ pending[url] }) {
            guard let data = try? write.produce() else { return nil }
            return Self.decode(MessageBody.self, from: data)
        }
        if let maxFileBytes {
            guard let size = (try? fileManager.attributesOfItem(atPath: url.path))?[.size] as? NSNumber,
                  size.intValue <= maxFileBytes else { return nil }
        }
        return readJSON(MessageBody.self, from: url)
    }

    /// Reads a body written by `saveBody` off the calling thread. Nil when missing or corrupt.
    public func loadBodyInBackground(key: String, accountID: String) async -> MessageBody? {
        await withCheckedContinuation { (continuation: CheckedContinuation<MessageBody?, Never>) in
            queue.async {
                continuation.resume(returning: self.loadBody(key: key, accountID: accountID))
            }
        }
    }

    /// Reads a JSON file written by `scheduleJSON`, off the calling thread. Nil when missing or corrupt.
    public func loadJSON<T: Decodable & Sendable>(_ type: T.Type, from url: URL) async -> T? {
        await withCheckedContinuation { (continuation: CheckedContinuation<T?, Never>) in
            queue.async {
                self.writePending()
                continuation.resume(returning: self.readJSON(type, from: url))
            }
        }
    }

    private func readAccount(_ accountID: String) -> CachedAccount {
        let folder = accountDirectory(accountID)
        let mailboxes = readJSON([MailboxInfo].self, from: mailboxesURL(accountID: accountID))
        var contents: [CachedMailbox] = []
        let files = (try? fileManager.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        for file in files where file.lastPathComponent.hasPrefix("mailbox-") && file.pathExtension == "json" {
            guard let mailbox = readJSON(CachedMailbox.self, from: file), mailbox.accountID == accountID else { continue }
            contents.append(mailbox)
        }
        contents.sort { $0.path < $1.path }
        return CachedAccount(mailboxes: mailboxes, mailboxContents: contents)
    }

    private func readJSON<T: Decodable>(_ type: T.Type, from url: URL) -> T? {
        guard let data = try? Data(contentsOf: url) else { return nil }
        return Self.decode(type, from: data)
    }

    private static func decode<T: Decodable>(_ type: T.Type, from data: Data) -> T? {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .secondsSince1970
        return try? decoder.decode(type, from: data)
    }
}
