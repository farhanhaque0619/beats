import Foundation
import InkModel

// Talking to the services: folder lists, incremental sync, paging, live updates.
extension MailStore {
    /// Newest messages kept in sync for an inbox, and for other folders.
    static let inboxWindow = 100
    static let folderWindow = 50
    /// Older messages fetched per `loadMore()`.
    static let pageSize = 50
    /// A mailbox synced more recently than this isn't re-synced when its scope is shown again.
    static let staleInterval: TimeInterval = 60
    /// Sent is synced alongside the inbox (for your replies in threads) at most this often.
    static let contextStaleInterval: TimeInterval = 5 * 60
    /// The folder list is re-read at most this often.
    static let mailboxListInterval: TimeInterval = 15 * 60

    // MARK: Keys and lookups

    /// Key for `mailboxData` and friends. The separator can't appear in an account ID or path.
    func boxKey(_ accountID: String, _ path: String) -> String { accountID + "\u{1F}" + path }

    func mailbox(accountID: String, role: MailboxRole) -> MailboxInfo? {
        mailboxesByAccount[accountID]?.first { $0.role == role }
    }

    func mailbox(accountID: String, path: String) -> MailboxInfo? {
        if let exact = mailboxIndex[accountID]?[path] { return exact }
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return mailbox(accountID: accountID, role: .inbox) }
        return nil
    }

    /// The role of the folder a message copy is in (custom when unknown).
    func role(ofPath path: String, accountID: String) -> MailboxRole {
        if let info = mailboxIndex[accountID]?[path] { return info.role }
        if path.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        return .custom
    }

    func messages(accountID: String, path: String) -> [MessageSummary] {
        mailboxData[boxKey(accountID, path)]?.messages ?? []
    }

    func inboxMessages(accountID: String) -> [MessageSummary] {
        guard let inbox = mailbox(accountID: accountID, role: .inbox) else { return messages(accountID: accountID, path: "INBOX") }
        return messages(accountID: accountID, path: inbox.path)
    }

    // MARK: Folder lists

    static func sortMailboxes(_ list: [MailboxInfo]) -> [MailboxInfo] {
        let order: [MailboxRole: Int] = [.inbox: 0, .flagged: 1, .snoozed: 2, .drafts: 3, .sent: 4, .archive: 5, .all: 6, .junk: 7, .trash: 8, .custom: 9]
        return list.enumerated().sorted { lhs, rhs in
            let l = order[lhs.element.role] ?? 9, r = order[rhs.element.role] ?? 9
            if l != r { return l < r }
            if lhs.element.role == .custom {
                let comparison = lhs.element.path.localizedStandardCompare(rhs.element.path)
                if comparison != .orderedSame { return comparison == .orderedAscending }
            }
            return lhs.offset < rhs.offset
        }.map(\.element)
    }

    func applyMailboxList(_ list: [MailboxInfo], for accountID: String, persist: Bool) {
        var seen = Set<String>()
        let unique = list.filter { $0.accountID == accountID && seen.insert($0.path).inserted }
        let sorted = Self.sortMailboxes(unique)
        if mailboxesByAccount[accountID] != sorted { mailboxesByAccount[accountID] = sorted }
        mailboxIndex[accountID] = Dictionary(sorted.map { ($0.path, $0) }, uniquingKeysWith: { first, _ in first })
        if persist, !sorted.isEmpty {
            // Folders that are gone take their cached mail with them.
            let prefix = boxKey(accountID, "")
            let paths = Set(sorted.map(\.path))
            for key in mailboxData.keys where key.hasPrefix(prefix) {
                let path = String(key.dropFirst(prefix.count))
                guard !paths.contains(path) else { continue }
                mailboxData[key] = nil
                lastSyncAt[key] = nil
                cache?.removeMailbox(accountID: accountID, path: path)
            }
            cache?.saveMailboxes(sorted, accountID: accountID)
        }
        markChanged()
    }

    /// Reads the folder list when there is none yet, when it wasn't read this session, or when it
    /// is older than `mailboxListInterval` (always with `force`).
    func ensureMailboxes(accountID: String, force: Bool = false) async throws {
        let now = environment.now()
        let haveList = !(mailboxesByAccount[accountID] ?? []).isEmpty
        if !force, haveList, let last = lastMailboxListFetch[accountID], now.timeIntervalSince(last) < Self.mailboxListInterval { return }
        if let running = mailboxListTasks[accountID] {
            try await running.value
            return
        }
        guard let service = services[accountID] else { throw MailError.connectionFailed("That account is no longer set up.") }
        let task = Task<Void, Error> { @MainActor in
            let list = try await service.mailboxes()
            guard self.services[accountID] === service else { return }
            self.lastMailboxListFetch[accountID] = self.environment.now()
            self.applyMailboxList(list, for: accountID, persist: true)
            if self.liveUpdatesWanted { self.startWatching(accountID: accountID) }
        }
        mailboxListTasks[accountID] = task
        defer { if mailboxListTasks[accountID] == task { mailboxListTasks[accountID] = nil } }
        do {
            try await task.value
        } catch {
            // Without a fresh list, the cached one still works.
            if haveList { return }
            throw error
        }
    }

    // MARK: Sync

    /// Which folders a scope shows for one account and should be synced to show it.
    func syncTargets(for scope: MailScope, accountID: String, onlyIfStale: Bool) -> [MailboxInfo] {
        var targets: [MailboxInfo] = []
        if let plan = plan(for: scope, accountID: accountID) {
            for path in plan.syncPaths {
                if let info = mailbox(accountID: accountID, path: path), info.isSelectable { targets.append(info) }
            }
        }
        let now = environment.now()
        func isStale(_ info: MailboxInfo, _ interval: TimeInterval) -> Bool {
            guard let last = lastSyncAt[boxKey(accountID, info.path)] else { return true }
            return now.timeIntervalSince(last) >= interval
        }
        if onlyIfStale { targets = targets.filter { isStale($0, Self.staleInterval) } }
        // Your replies, so threads in the inbox show both sides.
        if scope.role == .inbox || (scope.role == nil && plan(for: scope, accountID: accountID)?.role == .inbox),
           let sent = mailbox(accountID: accountID, role: .sent), sent.isSelectable,
           !targets.contains(where: { $0.path == sent.path }), isStale(sent, Self.contextStaleInterval) {
            targets.append(sent)
        }
        return targets
    }

    /// Syncs one mailbox. Concurrent calls share one sync; with `fresh`, a sync already running is
    /// waited for and then another one starts (its result may predate a change just made).
    func syncMailbox(_ mailbox: MailboxInfo, fresh: Bool = false) async throws {
        let key = boxKey(mailbox.accountID, mailbox.path)
        if let running = syncTasks[key] {
            if !fresh {
                try await running.value
                return
            }
            _ = try? await running.value
            if let again = syncTasks[key] {
                try await again.value
                return
            }
        }
        let task = Task<Void, Error> { @MainActor in try await self.performSync(mailbox) }
        syncTasks[key] = task
        defer { if syncTasks[key] == task { syncTasks[key] = nil } }
        try await task.value
    }

    private func performSync(_ mailbox: MailboxInfo) async throws {
        guard let service = services[mailbox.accountID] else { throw MailError.connectionFailed("That account is no longer set up.") }
        syncSequence += 1
        let sequence = syncSequence
        let key = boxKey(mailbox.accountID, mailbox.path)
        let previous = mailboxData[key]?.state
        let limit = mailbox.role == .inbox ? Self.inboxWindow : Self.folderWindow
        let result = try await service.sync(mailbox: mailbox, previous: previous, limit: limit)
        guard services[mailbox.accountID] === service else { return }
        merge(result, into: mailbox, limit: limit, startedAt: sequence)
        if mailbox.role == .inbox, persisted.highWaterMarks[mailbox.accountID] == nil,
           let mark = HighWaterMark.covering(messages(accountID: mailbox.accountID, path: mailbox.path)) {
            persisted.highWaterMarks[mailbox.accountID] = mark
            persistState()
        }
    }

    /// Folds a sync result into the cache, re-applying optimistic changes the server hasn't seen yet.
    func merge(_ result: MailboxSyncResult, into mailbox: MailboxInfo, limit: Int, startedAt sequence: Int) {
        let key = boxKey(mailbox.accountID, mailbox.path)
        var box = mailboxData[key] ?? CachedMailbox(accountID: mailbox.accountID, path: mailbox.path, state: nil, messages: [])
        var incoming = result.upserted.filter { $0.accountID == mailbox.accountID }
        for index in incoming.indices where incoming[index].mailboxPath != mailbox.path { incoming[index].mailboxPath = mailbox.path }

        if result.didReset || box.state?.uidValidity != result.state.uidValidity {
            var seen = Set<String>()
            box.messages = incoming.filter { seen.insert($0.id).inserted }
            if result.didReset, incoming.count < limit { exhaustedMailboxes.insert(key) } else { exhaustedMailboxes.remove(key) }
        } else {
            if !result.removedIDs.isEmpty { box.messages.removeAll { result.removedIDs.contains($0.id) } }
            var position: [String: Int] = [:]
            position.reserveCapacity(box.messages.count)
            for (index, message) in box.messages.enumerated() where position[message.id] == nil { position[message.id] = index }
            for message in incoming {
                if let index = position[message.id] {
                    box.messages[index] = message
                } else {
                    position[message.id] = box.messages.count
                    box.messages.append(message)
                }
            }
        }
        box.messages.removeAll { $0.uidValidity != result.state.uidValidity }
        box.state = result.state
        box.savedAt = environment.now()

        pruneProtections()
        for protection in protections where protection.applies(toSyncStartedAt: sequence) {
            if !protection.hiddenIDs.isEmpty { box.messages.removeAll { protection.hiddenIDs.contains($0.id) } }
            if !protection.flagEdits.isEmpty {
                for index in box.messages.indices {
                    if let edit = protection.flagEdits[box.messages[index].dedupeKey] {
                        box.messages[index].flags = edit.applied(to: box.messages[index].flags)
                    }
                }
            }
        }

        mailboxData[key] = box
        lastSyncAt[key] = environment.now()
        persistMailbox(key: key)
        markChanged()
    }

    /// Drops protections the server confirmed a while ago: no sync started that long ago is still running.
    func pruneProtections() {
        let now = environment.now()
        protections.removeAll { protection in
            guard let finished = protection.finishedAt else { return false }
            return now.timeIntervalSince(finished) > 120 || finished > now.addingTimeInterval(3600)
        }
    }

    // MARK: Status

    func beginSync() {
        activeSyncs += 1
        if syncStatus != .syncing { syncStatus = .syncing }
    }

    func endSync(succeeded: Bool, error: String?) {
        if succeeded { lastSyncedAt = environment.now() }
        if let error { roundErrors.append(error) }
        activeSyncs = max(0, activeSyncs - 1)
        guard activeSyncs == 0 else { return }
        let status: SyncStatus = roundErrors.first.map { .failed($0) } ?? .idle
        if syncStatus != status { syncStatus = status }
        roundErrors.removeAll()
    }

    // MARK: Refresh

    /// Syncs what `scope` shows, for every account it covers.
    func refresh(scope: MailScope, onlyIfStale: Bool) async {
        let accountIDs = self.accountIDs(for: scope)
        guard !accountIDs.isEmpty else {
            await performWakeDueSnoozes()
            return
        }
        beginSync()
        var failures: [(String, Error)] = []
        var anySuccess = false
        await withTaskGroup(of: (String, Error?).self) { group in
            for accountID in accountIDs {
                group.addTask { @MainActor in
                    do {
                        try await self.ensureMailboxes(accountID: accountID)
                        for mailbox in self.syncTargets(for: scope, accountID: accountID, onlyIfStale: onlyIfStale) {
                            try await self.syncMailbox(mailbox)
                        }
                        return (accountID, nil)
                    } catch {
                        return (accountID, error)
                    }
                }
            }
            for await (accountID, error) in group {
                if let error { failures.append((accountID, error)) } else { anySuccess = true }
            }
        }
        await performWakeDueSnoozes()
        let message = failures.first.map { $0.1.userMessage }
        if let (accountID, error) = failures.first, !(error is CancellationError), (error as? MailError) != .cancelled {
            if accounts.count > 1, let address = account(id: accountID)?.emailAddress {
                showError("Couldn't refresh \(address).", error)
            } else {
                showError("Couldn't refresh.", error)
            }
        }
        endSync(succeeded: anySuccess, error: message)
    }

    func scopeDidChange() {
        rebuildConversations()
        guard isLoaded, !accounts.isEmpty else { return }
        let target = scope
        let needsSync = accountIDs(for: target).contains { !syncTargets(for: target, accountID: $0, onlyIfStale: true).isEmpty }
            || accountIDs(for: target).contains { (mailboxesByAccount[$0] ?? []).isEmpty }
        guard needsSync else { return }
        track { await self.refresh(scope: target, onlyIfStale: true) }
    }

    func performRefreshAllInboxes() async -> [MessageSummary] {
        await load()
        guard !accounts.isEmpty else { return [] }
        beginSync()
        var anySuccess = false
        var failure: String?
        for account in accounts {
            do {
                try await ensureMailboxes(accountID: account.id)
                guard let inbox = mailbox(accountID: account.id, role: .inbox) else { continue }
                try await syncMailbox(inbox, fresh: true)
                anySuccess = true
            } catch {
                failure = failure ?? error.userMessage
            }
        }
        await performWakeDueSnoozes()
        endSync(succeeded: anySuccess, error: failure)

        var arrived: [MessageSummary] = []
        for account in accounts {
            let inbox = Threader.dedupe(inboxMessages(accountID: account.id))
            guard !inbox.isEmpty else { continue }
            if let mark = persisted.highWaterMarks[account.id] {
                arrived += inbox.filter { mark.isBefore($0) && $0.isUnread && !$0.isBulk && !isFromMe($0) }
                persisted.highWaterMarks[account.id] = mark.advanced(past: inbox)
            } else {
                persisted.highWaterMarks[account.id] = HighWaterMark.covering(inbox)
            }
        }
        persistState()
        return arrived.sorted { $0.date > $1.date }
    }

    func isFromMe(_ message: MessageSummary) -> Bool {
        let mine = myAddresses
        return message.from.contains { mine.contains($0.normalized) }
    }

    // MARK: Paging

    func performLoadMore() async {
        guard !isLoadingMore, canLoadMore else { return }
        let targets = accountIDs(for: scope).flatMap { accountID in
            (plan(for: scope, accountID: accountID)?.pagingPaths ?? []).compactMap { mailbox(accountID: accountID, path: $0) }
        }
        guard !targets.isEmpty else {
            canLoadMore = false
            return
        }
        isLoadingMore = true
        defer {
            isLoadingMore = false
            rebuildConversations()
        }
        for mailbox in targets {
            let key = boxKey(mailbox.accountID, mailbox.path)
            guard !exhaustedMailboxes.contains(key), let service = services[mailbox.accountID] else { continue }
            let box = mailboxData[key]
            let validity = box?.state?.uidValidity
            guard let oldest = box?.messages.filter({ validity == nil || $0.uidValidity == validity }).map(\.uid).min(), oldest > 1 else {
                exhaustedMailboxes.insert(key)
                continue
            }
            do {
                let older = try await service.fetchOlder(mailbox: mailbox, olderThanUID: oldest, limit: Self.pageSize)
                guard services[mailbox.accountID] === service, var current = mailboxData[key] else { continue }
                let fresh = older.filter { $0.accountID == mailbox.accountID && $0.uid < oldest && (validity == nil || $0.uidValidity == validity) }
                if fresh.isEmpty {
                    exhaustedMailboxes.insert(key)
                    continue
                }
                let known = Set(current.messages.map(\.id))
                var added = fresh.filter { !known.contains($0.id) }
                for index in added.indices where added[index].mailboxPath != mailbox.path { added[index].mailboxPath = mailbox.path }
                for protection in protections {
                    added.removeAll { protection.hiddenIDs.contains($0.id) }
                    for index in added.indices {
                        if let edit = protection.flagEdits[added[index].dedupeKey] { added[index].flags = edit.applied(to: added[index].flags) }
                    }
                }
                current.messages += added
                if var state = current.state {
                    state.knownUIDs = Array(Set(state.knownUIDs).union(fresh.map(\.uid))).sorted()
                    current.state = state
                }
                mailboxData[key] = current
                if fresh.count < Self.pageSize { exhaustedMailboxes.insert(key) }
                persistMailbox(key: key)
                markChanged()
            } catch {
                showError("Couldn't load older mail.", error)
                break
            }
        }
    }

    // MARK: Live updates

    func startWatching(accountID: String) {
        guard liveUpdatesWanted, liveTasks[accountID] == nil, let service = services[accountID],
              let inbox = mailbox(accountID: accountID, role: .inbox) else { return }
        liveTasks[accountID] = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                let stream = service.watch(mailbox: inbox)
                for await change in stream {
                    guard let self else { return }
                    if change == .changed { self.scheduleLiveSync(inbox) }
                }
                // The stream ended (connection gone for good): try again in a while.
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
                guard let self, self.liveUpdatesWanted, self.services[accountID] === service else { return }
            }
        }
    }

    /// Coalesces bursts of IDLE events into one sync.
    func scheduleLiveSync(_ mailbox: MailboxInfo) {
        let key = boxKey(mailbox.accountID, mailbox.path)
        guard liveSyncScheduled.insert(key).inserted else { return }
        track {
            try? await Task.sleep(nanoseconds: 300_000_000)
            self.liveSyncScheduled.remove(key)
            guard self.services[mailbox.accountID] != nil else { return }
            do {
                try await self.syncMailbox(mailbox, fresh: true)
            } catch {
                // Live updates are best-effort; the next refresh reports problems.
            }
        }
    }
}
