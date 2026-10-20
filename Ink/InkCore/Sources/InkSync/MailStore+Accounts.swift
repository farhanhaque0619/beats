import Foundation
import InkModel

// Loading from disk, persistence, previews, and adding / removing accounts.
extension MailStore {
    // MARK: Files

    var accountsURL: URL { environment.storageDirectory.appendingPathComponent("accounts.json") }
    var snoozesURL: URL { environment.storageDirectory.appendingPathComponent("snoozes.json") }
    var stateURL: URL { environment.storageDirectory.appendingPathComponent("state.json") }
    var outboxURL: URL { environment.storageDirectory.appendingPathComponent("outbox.json") }
    var journalURL: URL { environment.storageDirectory.appendingPathComponent("pending-actions.json") }

    func persistAccounts() { cache?.scheduleJSON(accounts, to: accountsURL) }
    func persistSnoozes() {
        cache?.scheduleJSON(snoozes.merging(wakingSnoozes) { current, _ in current }, to: snoozesURL)
    }
    func persistState() {
        persisted.recentSearches = recentSearches
        cache?.scheduleJSON(persisted, to: stateURL)
    }
    func persistOutbox() { cache?.scheduleJSON(outbox, to: outboxURL) }

    /// Remembers triage until the server confirms it (see `JournalEntry`).
    func addToJournal(_ id: UUID, _ operations: [ServerOperation], verb: String) {
        guard cache != nil, !operations.isEmpty else { return }
        journal.removeAll { $0.id == id }
        journal.append(JournalEntry(id: id, operations: operations, verb: verb))
        cache?.scheduleJSON(journal, to: journalURL)
    }

    /// The action was committed (or failed, or was undone): nothing left to replay.
    func forgetJournal(_ id: UUID) {
        guard journal.contains(where: { $0.id == id }) else { return }
        journal.removeAll { $0.id == id }
        cache?.scheduleJSON(journal, to: journalURL)
    }

    func persistMailbox(key: String) {
        guard let cache, let box = mailboxData[key] else { return }
        cache.saveMailbox(box)
    }

    // MARK: Services

    /// Demo accounts get the in-memory sample service; everything else talks IMAP/SMTP when the
    /// environment can open connections, or fails politely when it can't.
    static func defaultServiceFactory(environment: MailStoreEnvironment) -> MailServiceFactory {
        let now = environment.now
        let transportFactory = environment.transportFactory
        return { account, credentials in
            if account.isDemo { return DemoMailService(account: account, now: now) }
            guard let transportFactory else { return OfflineMailService(account: account) }
            return IMAPMailService(account: account, credentials: credentials, transportFactory: transportFactory)
        }
    }

    func makeService(for account: AccountConfig) -> MailService {
        serviceFactory(account, environment.credentials)
    }

    // MARK: Load

    func performLoad() async {
        defer { isLoaded = true }
        guard let cache else { return }
        let storedAccounts = await cache.loadJSON([AccountConfig].self, from: accountsURL) ?? []
        let storedSnoozes = await cache.loadJSON([String: SnoozeRecord].self, from: snoozesURL) ?? [:]
        let storedState = await cache.loadJSON(PersistedState.self, from: stateURL) ?? PersistedState()
        let storedOutbox = await cache.loadJSON([OutgoingMessage].self, from: outboxURL) ?? []
        let storedJournal = await cache.loadJSON([JournalEntry].self, from: journalURL) ?? []

        var seen = Set<String>()
        let unique = storedAccounts.filter { seen.insert($0.id).inserted }
        var loadedBoxes: [String: CachedMailbox] = [:]
        var loadedLists: [String: [MailboxInfo]] = [:]
        for account in unique {
            let cached = await cache.loadAccount(account.id)
            if let list = cached.mailboxes { loadedLists[account.id] = list }
            for box in cached.mailboxContents { loadedBoxes[boxKey(account.id, box.path)] = box }
        }

        // Anything added while the disk was being read (an account added before load finished)
        // wins over what was on disk.
        let addedMeanwhile = accounts
        accounts = unique.filter { stored in !addedMeanwhile.contains { $0.id == stored.id } } + addedMeanwhile
        for account in accounts where services[account.id] == nil { services[account.id] = makeService(for: account) }
        for (key, box) in loadedBoxes where mailboxData[key] == nil { mailboxData[key] = box }
        for (accountID, list) in loadedLists where mailboxesByAccount[accountID] == nil { applyMailboxList(list, for: accountID, persist: false) }
        let accountIDs = Set(accounts.map(\.id))
        for (id, record) in storedSnoozes where snoozes[id] == nil && accountIDs.contains(record.accountID) { snoozes[id] = record }
        persisted = storedState
        recentSearches = storedState.recentSearches
        let known = Set(outbox.map(\.id))
        let restored = storedOutbox.filter { !known.contains($0.id) && accountIDs.contains($0.accountID) }
        outbox += restored
        // Anything left over from the last run didn't go out; show it as failed so it can be retried.
        failedSendIDs.formUnion(restored.map(\.id))
        if !addedMeanwhile.isEmpty { persistAccounts() }

        isLoaded = true
        let limit = bodyCacheLimit
        for account in accounts {
            let id = account.id
            track { await cache.pruneBodies(accountID: id, maxBytes: limit) }
        }
        replayJournal(storedJournal)
        markChanged()
        startWakeTimer()
        guard !accounts.isEmpty else { return }
        let scopeToRefresh = scope
        beginSync()
        track {
            await self.refresh(scope: scopeToRefresh, onlyIfStale: false)
            self.endSync(succeeded: false, error: nil)
        }
    }

    /// Sends triage the last run took but didn't get to the server (see `JournalEntry`). The
    /// change is applied locally again first, in case the cache write didn't make it either, and
    /// kept on screen while the commit runs; a failure puts things back with an error toast.
    func replayJournal(_ entries: [JournalEntry]) {
        for entry in entries {
            let operations = entry.operations.filter { services[$0.accountID] != nil && !$0.isEmpty }
            guard !operations.isEmpty, !journal.contains(where: { $0.id == entry.id }) else { continue }
            var change = LocalChange()
            var protection = Protection()
            for operation in operations {
                switch operation.action {
                case .markRead: applyFlagEdit(FlagEdit(insert: .seen), to: operation.messages, change: &change, protection: &protection)
                case .markUnread: applyFlagEdit(FlagEdit(remove: .seen), to: operation.messages, change: &change, protection: &protection)
                case .flag: applyFlagEdit(FlagEdit(insert: .flagged), to: operation.messages, change: &change, protection: &protection)
                case .unflag: applyFlagEdit(FlagEdit(remove: .flagged), to: operation.messages, change: &change, protection: &protection)
                case .archive, .trash, .markSpam, .moveToInbox, .move, .deletePermanently:
                    removeLocally(operation.messages, change: &change, protection: &protection)
                }
            }
            if !protection.isEmpty { protections.append(protection) }
            addToJournal(entry.id, operations, verb: entry.verb)
            let protectionID = protection.id
            enqueueCommit {
                if let failure = await self.run(operations) {
                    self.revert(change)
                    self.protections.removeAll { $0.id == protectionID }
                    self.markChanged()
                    self.showError("Couldn't \(entry.verb).", failure)
                } else {
                    self.finishProtection(protectionID)
                }
                self.forgetJournal(entry.id)
            }
        }
    }

    // MARK: Preview

    /// Fills the store with the demo inbox synchronously: no disk, no network, no timers.
    func installPreviewDemo() {
        let now = environment.now()
        let account = AccountConfig.demo
        let snapshot = DemoContent.snapshot(account: account, now: now, uidValidity: DemoMailService.uidValidity(for: now))
        let service = DemoMailService(account: account, now: environment.now, snapshot: snapshot)
        accounts = [account]
        services[account.id] = service
        applyMailboxList(snapshot.mailboxes, for: account.id, persist: false)
        for (path, messages) in snapshot.messages {
            let state = MailboxSyncState(uidValidity: snapshot.uidValidity, uidNext: (messages.last?.uid ?? 100) + 1,
                                         knownUIDs: messages.map(\.uid), lastSync: now)
            let key = boxKey(account.id, path)
            mailboxData[key] = CachedMailbox(accountID: account.id, path: path, state: state, messages: messages, savedAt: now)
            lastSyncAt[key] = now
            exhaustedMailboxes.insert(key)
            for message in messages {
                guard let id = message.messageID?.lowercased(), var body = snapshot.bodies[id] else { continue }
                body.messageID = message.id
                bodyMemory[message.dedupeKey] = body
            }
        }
        persisted.highWaterMarks[account.id] = HighWaterMark.covering(inboxMessages(accountID: account.id))
        isLoaded = true
        lastSyncedAt = now
        markChanged()
    }

    // MARK: Verify

    func performVerify(_ account: AccountConfig, credential: Credential, progress: @escaping @Sendable (VerificationStep) -> Void) async throws {
        let credentials = InMemoryCredentialStore([account.id: credential])
        let service = serviceFactory(account, credentials)
        do {
            try await service.verify(progress: progress)
        } catch {
            await service.disconnect()
            throw error
        }
        await service.disconnect()
    }

    // MARK: Add / remove

    func performAddAccount(_ account: AccountConfig, credential: Credential) async throws {
        await load()
        try await environment.credentials.save(credential, for: account.id)

        // Signing in again with the same address replaces the old account.
        let duplicates = accounts.filter {
            $0.id != account.id && !$0.isDemo && $0.emailAddress.lowercased() == account.emailAddress.lowercased()
        }
        for duplicate in duplicates { await performRemoveAccount(id: duplicate.id, deleteCredential: true) }
        if accounts.count == 1, let only = accounts.first, only.isDemo, only.id != account.id {
            await performRemoveAccount(id: only.id, deleteCredential: false)
        }

        if let index = accounts.firstIndex(where: { $0.id == account.id }) {
            let old = accounts[index]
            accounts[index] = account
            if let service = services[account.id], needsNewService(old: old, new: account) {
                liveTasks[account.id]?.cancel()
                liveTasks[account.id] = nil
                await service.disconnect()
                services[account.id] = makeService(for: account)
            }
        } else {
            accounts.append(account)
            services[account.id] = makeService(for: account)
        }
        persistAccounts()
        markChanged()
        startWakeTimer()
        await syncNewAccount(account.id)
    }

    func performAddDemoAccount() async {
        await load()
        guard !accounts.contains(where: \.isDemo) else { return }
        let account = AccountConfig.demo
        accounts.append(account)
        services[account.id] = makeService(for: account)
        persistAccounts()
        markChanged()
        startWakeTimer()
        await syncNewAccount(account.id)
    }

    /// Folders, then the inbox and Sent, for an account that was just added.
    func syncNewAccount(_ accountID: String) async {
        beginSync()
        var failure: String?
        do {
            try await ensureMailboxes(accountID: accountID, force: true)
            for mailbox in syncTargets(for: .account(accountID: accountID, role: .inbox), accountID: accountID, onlyIfStale: false) {
                try await syncMailbox(mailbox)
            }
        } catch {
            failure = error.userMessage
            if let address = account(id: accountID)?.emailAddress {
                showError("Couldn't load mail for \(address).", error)
            }
        }
        endSync(succeeded: failure == nil, error: failure)
        if liveUpdatesWanted { startWatching(accountID: accountID) }
    }

    func performRemoveAccount(id: String) async {
        await performRemoveAccount(id: id, deleteCredential: true)
    }

    func performRemoveAccount(id: String, deleteCredential: Bool) async {
        guard let index = accounts.firstIndex(where: { $0.id == id }) else { return }
        accounts.remove(at: index)
        liveTasks[id]?.cancel()
        liveTasks[id] = nil
        let service = services.removeValue(forKey: id)

        let prefix = boxKey(id, "")
        for key in mailboxData.keys where key.hasPrefix(prefix) {
            mailboxData[key] = nil
            lastSyncAt[key] = nil
            exhaustedMailboxes.remove(key)
        }
        mailboxesByAccount[id] = nil
        mailboxIndex[id] = nil
        lastMailboxListFetch[id] = nil
        let snoozedHere = snoozes.filter { $0.value.accountID == id }.map(\.key)
        for key in snoozedHere { snoozes[key] = nil }
        wakingSnoozes = wakingSnoozes.filter { $0.value.accountID != id }
        persisted.highWaterMarks[id] = nil
        for key in bodyMemory.keys where key.hasPrefix(id + "|") { bodyMemory[key] = nil }
        bodyMemoryOrder.removeAll { $0.hasPrefix(id + "|") }
        for (key, message) in serverSearchResults where message.accountID == id { serverSearchResults[key] = nil }
        serverSearchOrder.removeAll { serverSearchResults[$0] == nil }
        if var pending = pendingAction {
            pending.operations.removeAll { $0.accountID == id }
            pending.change.snoozesRemoved.removeAll { $0.record.accountID == id }
            pendingAction = pending
        }
        if journal.contains(where: { entry in entry.operations.contains { $0.accountID == id } }) {
            journal = journal.compactMap { entry in
                var entry = entry
                entry.operations.removeAll { $0.accountID == id }
                return entry.operations.isEmpty ? nil : entry
            }
            cache?.scheduleJSON(journal, to: journalURL)
        }
        let doomed = outbox.filter { $0.accountID == id }.map(\.id)
        for messageID in doomed {
            pendingSendTimers[messageID]?.cancel()
            pendingSendTimers[messageID] = nil
            undoStack.removeAll { $0 == .send(messageID) }
            failedSendIDs.remove(messageID)
            // Its "Sending…" toast would otherwise offer an Undo that reverts something else.
            if toastEntry == .send(messageID) {
                toast = nil
                toastEntry = nil
            }
        }
        outbox.removeAll { $0.accountID == id }

        cache?.removeAccount(id)
        persistAccounts()
        persistSnoozes()
        persistState()
        persistOutbox()
        if scope.accountID == id { scope = .allInboxes }
        markChanged()

        if deleteCredential { try? await environment.credentials.delete(accountID: id) }
        await service?.disconnect()
    }

    func performUpdateAccount(_ account: AccountConfig) {
        guard let index = accounts.firstIndex(where: { $0.id == account.id }) else { return }
        let old = accounts[index]
        guard old != account else { return }
        accounts[index] = account
        persistAccounts()
        if let service = services[account.id], needsNewService(old: old, new: account) {
            liveTasks[account.id]?.cancel()
            liveTasks[account.id] = nil
            services[account.id] = makeService(for: account)
            track { await service.disconnect() }
            if liveUpdatesWanted { startWatching(accountID: account.id) }
        }
        markChanged()
    }

    /// Server, sign-in or address changes need a fresh connection; name, signature and colour don't.
    /// The demo account keeps its in-memory mail.
    func needsNewService(old: AccountConfig, new: AccountConfig) -> Bool {
        guard !new.isDemo else { return false }
        return old.imap != new.imap || old.smtp != new.smtp || old.authMethod != new.authMethod
            || old.oauthProvider != new.oauthProvider || old.emailAddress != new.emailAddress
            || old.savesSentAutomatically != new.savesSentAutomatically || old.provider != new.provider
    }

    // MARK: Background work

    /// A delay as nanoseconds for `Task.sleep`, clamped to [0, one day] so odd values can't trap.
    static func nanoseconds(_ seconds: TimeInterval) -> UInt64 {
        guard seconds.isFinite, seconds > 0 else { return 0 }
        return UInt64(min(seconds, 86_400) * 1_000_000_000)
    }

    /// Runs `body` as tracked background work (awaited by `waitUntilIdle()`).
    @discardableResult
    func track(_ body: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let id = UUID()
        let task = Task { @MainActor in
            await body()
            self.inFlight[id] = nil
        }
        inFlight[id] = task
        return task
    }

    func startWakeTimer() {
        guard wakeTimer == nil, cache != nil else { return }
        wakeTimer = Task { @MainActor [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 60 * 1_000_000_000)
                guard let self, !Task.isCancelled else { return }
                await self.performWakeDueSnoozes()
            }
        }
    }

    // MARK: Toasts

    func present(_ message: String, systemImage: String?, style: Toast.Style = .info, entry: UndoEntry? = nil) {
        toast = Toast(message: message, systemImage: systemImage, style: style, undoable: entry != nil)
        toastEntry = entry
    }

    func showError(_ lead: String, _ error: Error) {
        let detail = error.userMessage
        let text = lead.isEmpty ? detail : (detail.isEmpty ? lead : "\(lead) \(detail)")
        toast = Toast(message: text, systemImage: "exclamationmark.triangle", style: .error)
        toastEntry = nil
    }

    /// When the undo window of the toast's action closes, the toast stays but loses its Undo button.
    func retireToast(for entry: UndoEntry) {
        guard toastEntry == entry, var current = toast else { return }
        current.undoable = false
        toast = current
        toastEntry = nil
    }

    // MARK: Identity

    var myAddresses: Set<String> { Set(accounts.map { $0.emailAddress.lowercased() }) }
}
