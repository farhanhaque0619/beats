import Foundation
import InkModel

// Optimistic triage: local changes now, server calls after the undo window.
extension MailStore {
    // MARK: Moves (archive, trash, spam, folders)

    func performMove(_ action: MailAction, _ conversations: [Conversation], destination: MailboxInfo? = nil) {
        let list = Self.unique(conversations)
        guard !list.isEmpty else { return }
        var change = LocalChange()
        var protection = Protection()
        var operations: [ServerOperation] = []
        var followUps: [FollowUp] = []
        var count = 0

        for conversation in list {
            let accountID = conversation.accountID
            if let destination, destination.accountID != accountID { continue }
            guard account(id: accountID) != nil else { continue }

            if let record = snoozes[conversation.id] {
                // Snoozed mail is already archived on the server: cancel the snooze, and act on the
                // archived copies we know about.
                snoozes[conversation.id] = nil
                change.snoozesRemoved.append((conversation.id, record))
                count += 1
                if action != .archive {
                    let keys = Set(record.messages.map(\.dedupeKey))
                    let copies = cachedCopies(accountID: accountID, keys: keys, excludingRoles: [.inbox, .sent, .drafts, .trash, .junk])
                    if !copies.isEmpty {
                        removeLocally(copies, change: &change, protection: &protection)
                        operations.append(ServerOperation(accountID: accountID, action: action, messages: copies))
                    }
                }
                continue
            }

            let targets = moveTargets(for: action, in: conversation, destination: destination)
            guard !targets.isEmpty else { continue }
            count += 1
            var hidden = targets
            if action == .trash || action == .markSpam {
                // Gmail drops every label when mail goes to Trash or Spam, so All Mail loses it too.
                let gmailKeys = Set(targets.filter { $0.gmailMessageID != nil }.map(\.dedupeKey))
                if !gmailKeys.isEmpty {
                    let known = Set(targets.map(\.id))
                    hidden += cachedCopies(accountID: accountID, keys: gmailKeys, excludingRoles: [.trash, .junk]).filter { !known.contains($0.id) }
                }
            }
            removeLocally(hidden, change: &change, protection: &protection)
            operations.append(ServerOperation(accountID: accountID, action: action, messages: targets))
            if let path = destinationPath(for: action, accountID: accountID, explicit: destination) {
                followUps.append(.markStale(accountID: accountID, path: path))
            }
        }
        guard count > 0 else { return }
        if !change.snoozesRemoved.isEmpty { persistSnoozes() }

        let (verb, text, image): (String, String, String)
        switch action {
        case .archive:
            (verb, text, image) = ("archive", count == 1 ? "Archived" : "Archived \(count) conversations", "archivebox")
        case .trash:
            (verb, text, image) = ("move to Trash", count == 1 ? "Moved to Trash" : "Moved \(count) conversations to Trash", "trash")
        case .markSpam:
            (verb, text, image) = ("mark as spam", count == 1 ? "Marked as Spam" : "Marked \(count) conversations as Spam", "xmark.octagon")
        default:
            let name = destination?.displayName ?? "folder"
            (verb, text, image) = ("move to \(name)", count == 1 ? "Moved to \(name)" : "Moved \(count) conversations to \(name)", "folder")
        }
        beginUndoable(operations: operations, change: change, protection: protection, verb: verb, followUps: followUps,
                      toast: text, systemImage: image)
    }

    /// The copies a move acts on: what the current list shows of the conversation, else every copy
    /// the action makes sense for.
    private func moveTargets(for action: MailAction, in conversation: Conversation, destination: MailboxInfo?) -> [MessageSummary] {
        let accountID = conversation.accountID
        func eligible(_ message: MessageSummary) -> Bool {
            let role = self.role(ofPath: message.mailboxPath, accountID: accountID)
            switch action {
            case .archive: return ![.archive, .all, .sent, .drafts].contains(role)
            case .trash: return role != .trash
            case .markSpam: return ![.junk, .sent, .drafts].contains(role)
            case .move(let path): return message.mailboxPath != path && role != .drafts
            case .moveToInbox: return ![.inbox, .sent, .drafts].contains(role)
            default: return true
            }
        }
        let plan = plan(for: scope, accountID: accountID)
        let primary = plan?.primaryPaths ?? []
        // Your own sent copies only move when you're looking at Sent.
        let keepSent = plan?.role != .sent
        let shown = conversation.messages.filter { message in
            guard primary.contains(message.mailboxPath), eligible(message) else { return false }
            return !(keepSent && self.role(ofPath: message.mailboxPath, accountID: accountID) == .sent)
        }
        if !shown.isEmpty { return shown }
        return conversation.messages.filter { message in
            let role = self.role(ofPath: message.mailboxPath, accountID: accountID)
            return eligible(message) && role != .sent && role != .drafts
        }
    }

    private func destinationPath(for action: MailAction, accountID: String, explicit: MailboxInfo?) -> String? {
        switch action {
        case .archive: return (mailbox(accountID: accountID, role: .archive) ?? mailbox(accountID: accountID, role: .all))?.path
        case .trash: return mailbox(accountID: accountID, role: .trash)?.path
        case .markSpam: return mailbox(accountID: accountID, role: .junk)?.path
        case .move(let path): return explicit?.path ?? path
        default: return nil
        }
    }

    /// Cached copies of messages (by dedupe key) in an account's folders, skipping some roles.
    func cachedCopies(accountID: String, keys: Set<String>, excludingRoles: Set<MailboxRole>) -> [MessageSummary] {
        guard !keys.isEmpty else { return [] }
        let prefix = boxKey(accountID, "")
        var result: [MessageSummary] = []
        for (key, box) in mailboxData where key.hasPrefix(prefix) {
            if excludingRoles.contains(role(ofPath: box.path, accountID: accountID)) { continue }
            result += box.messages.filter { keys.contains($0.dedupeKey) }
        }
        return result
    }

    // MARK: Inbox, snooze

    func performMoveToInbox(_ conversations: [Conversation]) {
        let list = Self.unique(conversations)
        guard !list.isEmpty else { return }
        var change = LocalChange()
        var protection = Protection()
        var operations: [ServerOperation] = []
        var followUps: [FollowUp] = []
        var count = 0
        for conversation in list {
            let accountID = conversation.accountID
            guard account(id: accountID) != nil else { continue }
            if let record = snoozes[conversation.id] {
                snoozes[conversation.id] = nil
                change.snoozesRemoved.append((conversation.id, record))
                operations.append(ServerOperation(accountID: accountID, action: .moveToInbox, messages: wakeTargets(record)))
                followUps.append(.syncInbox(accountID: accountID))
                count += 1
                continue
            }
            let targets = moveTargets(for: .moveToInbox, in: conversation, destination: nil)
            guard !targets.isEmpty else { continue }
            removeLocally(targets, change: &change, protection: &protection)
            operations.append(ServerOperation(accountID: accountID, action: .moveToInbox, messages: targets))
            followUps.append(.syncInbox(accountID: accountID))
            count += 1
        }
        guard count > 0 else { return }
        if !change.snoozesRemoved.isEmpty { persistSnoozes() }
        beginUndoable(operations: operations, change: change, protection: protection, verb: "move to Inbox", followUps: followUps,
                      toast: count == 1 ? "Moved to Inbox" : "Moved \(count) conversations to Inbox", systemImage: "tray")
    }

    func performSnooze(_ conversations: [Conversation], until date: Date) {
        let list = Self.unique(conversations)
        guard !list.isEmpty, date.timeIntervalSinceReferenceDate.isFinite else { return }
        let now = environment.now()
        var change = LocalChange()
        var protection = Protection()
        var operations: [ServerOperation] = []
        var count = 0
        for conversation in list {
            let accountID = conversation.accountID
            guard account(id: accountID) != nil, !conversation.messages.isEmpty else { continue }
            count += 1
            if var record = snoozes[conversation.id] {
                // Already snoozed: just a new time.
                change.snoozesRemoved.append((conversation.id, record))
                change.snoozesAdded.append(conversation.id)
                record.until = date
                snoozes[conversation.id] = record
                continue
            }
            let inboxCopies = conversation.messages.filter { role(ofPath: $0.mailboxPath, accountID: accountID) == .inbox }
            snoozes[conversation.id] = SnoozeRecord(until: date, messages: conversation.messages, snoozedAt: now)
            change.snoozesAdded.append(conversation.id)
            removeLocally(inboxCopies, change: &change, protection: &protection)
            operations.append(ServerOperation(accountID: accountID, action: .archive, messages: inboxCopies))
        }
        guard count > 0 else { return }
        persistSnoozes()
        let label = Self.snoozeLabel(date)
        beginUndoable(operations: operations, change: change, protection: protection, verb: "snooze", followUps: [],
                      toast: count == 1 ? "Snoozed until \(label)" : "Snoozed \(count) conversations until \(label)", systemImage: "clock")
    }

    func performUnsnooze(_ conversations: [Conversation]) {
        let snoozed = Self.unique(conversations).filter { snoozes[$0.id] != nil }
        guard !snoozed.isEmpty else { return }
        performMoveToInbox(snoozed)
    }

    /// "Tue 8:00 AM" in the user's locale.
    static func snoozeLabel(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.locale = .current
        formatter.setLocalizedDateFormatFromTemplate("EEE j:mm")
        return formatter.string(from: date)
    }

    /// The messages a wake-up moves back to the inbox: not your own sent copies.
    func wakeTargets(_ record: SnoozeRecord) -> [MessageSummary] {
        record.messages.filter { message in
            let role = self.role(ofPath: message.mailboxPath, accountID: message.accountID)
            return role != .sent && role != .drafts
        }
    }

    func performWakeDueSnoozes() async {
        guard !isWaking else { return }
        let now = environment.now()
        let due = snoozes.filter { $0.value.until <= now }
        guard !due.isEmpty else { return }
        isWaking = true
        defer { isWaking = false }

        // The archive that hid them has to reach the server before they come back.
        if let pending = pendingAction, pending.change.snoozesAdded.contains(where: { due[$0] != nil }) { commit(pending) }
        for (id, record) in due {
            snoozes[id] = nil
            for message in record.messages { persisted.resurfaced[message.dedupeKey] = now }
        }
        let monthAgo = now.addingTimeInterval(-30 * 86_400)
        persisted.resurfaced = persisted.resurfaced.filter { $0.value > monthAgo }
        persistSnoozes()
        persistState()
        markChanged()

        var byAccount: [String: [(String, SnoozeRecord)]] = [:]
        for (id, record) in due { byAccount[record.accountID, default: []].append((id, record)) }
        let task = enqueueCommit {
            for (accountID, records) in byAccount.sorted(by: { $0.key < $1.key }) {
                await self.wake(records, accountID: accountID)
            }
        }
        await task.value
    }

    /// Moves woken mail back to the inbox, syncs it, and marks the returned copies unread.
    private func wake(_ records: [(String, SnoozeRecord)], accountID: String) async {
        guard let service = services[accountID] else { return }
        let targets = records.flatMap { wakeTargets($0.1) }
        do {
            if !targets.isEmpty { try await service.perform(.moveToInbox, on: targets) }
            guard let inbox = mailbox(accountID: accountID, role: .inbox) else { return }
            try await syncMailbox(inbox, fresh: true)
            let keys = Set(targets.map(\.dedupeKey))
            let returned = inboxMessages(accountID: accountID).filter { keys.contains($0.dedupeKey) && !$0.isUnread }
            guard !returned.isEmpty else { return }
            var change = LocalChange()
            var protection = Protection()
            applyFlagEdit(FlagEdit(remove: .seen), to: returned, change: &change, protection: &protection)
            protections.append(protection)
            markChanged()
            do {
                try await service.perform(.markUnread, on: returned)
                finishProtection(protection.id)
            } catch {
                protections.removeAll { $0.id == protection.id }
            }
        } catch {
            guard services[accountID] === service, (error as? MailError) != .messageNotFound else { return }
            // Couldn't reach the server: snooze them again until the next check retries.
            for (id, record) in records where snoozes[id] == nil { snoozes[id] = record }
            persistSnoozes()
            markChanged()
        }
    }

    // MARK: Read, star

    func performSetRead(_ read: Bool, _ conversations: [Conversation]) {
        let list = Self.unique(conversations)
        var targets: [MessageSummary] = []
        var count = 0
        for conversation in list {
            if read {
                let unread = conversation.messages.filter(\.isUnread)
                if !unread.isEmpty { count += 1 }
                targets += unread
            } else if !conversation.isUnread, let latest = latestIncoming(conversation) {
                targets.append(latest)
                count += 1
            }
        }
        guard !targets.isEmpty else { return }
        var change = LocalChange()
        var protection = Protection()
        applyFlagEdit(read ? FlagEdit(insert: .seen) : FlagEdit(remove: .seen), to: targets, change: &change, protection: &protection)
        let operations = Self.group(targets, action: read ? .markRead : .markUnread)
        let what = read ? "Read" : "Unread"
        beginUndoable(operations: operations, change: change, protection: protection, verb: read ? "mark as read" : "mark as unread",
                      followUps: [], toast: count == 1 ? "Marked as \(what)" : "Marked \(count) conversations as \(what)",
                      systemImage: read ? "envelope.open" : "envelope.badge")
    }

    func performSetFlagged(_ flagged: Bool, _ conversations: [Conversation]) {
        let list = Self.unique(conversations)
        var targets: [MessageSummary] = []
        var count = 0
        for conversation in list {
            if flagged {
                guard !conversation.isFlagged, let latest = latestIncoming(conversation) ?? conversation.latest else { continue }
                targets.append(latest)
            } else {
                let starred = conversation.messages.filter(\.isFlagged)
                guard !starred.isEmpty else { continue }
                targets += starred
            }
            count += 1
        }
        guard !targets.isEmpty else { return }
        var change = LocalChange()
        var protection = Protection()
        applyFlagEdit(flagged ? FlagEdit(insert: .flagged) : FlagEdit(remove: .flagged), to: targets, change: &change, protection: &protection)
        let operations = Self.group(targets, action: flagged ? .flag : .unflag)
        let text = flagged ? (count == 1 ? "Starred" : "Starred \(count) conversations") : (count == 1 ? "Unstarred" : "Unstarred \(count) conversations")
        beginUndoable(operations: operations, change: change, protection: protection, verb: flagged ? "star" : "unstar",
                      followUps: [], toast: text, systemImage: flagged ? "star.fill" : "star.slash")
    }

    func performMarkOpened(_ conversation: Conversation) {
        let unread = conversation.messages.filter(\.isUnread)
        guard !unread.isEmpty else { return }
        var change = LocalChange()
        var protection = Protection()
        applyFlagEdit(FlagEdit(insert: .seen), to: unread, change: &change, protection: &protection)
        protections.append(protection)
        markChanged()
        let operations = Self.group(unread, action: .markRead)
        let protectionID = protection.id
        enqueueCommit {
            if await self.run(operations) == nil {
                self.finishProtection(protectionID)
            } else {
                // Stay read on screen; the next sync shows what the server kept.
                self.protections.removeAll { $0.id == protectionID }
            }
        }
    }

    /// The newest message someone else sent, else the newest message.
    func latestIncoming(_ conversation: Conversation) -> MessageSummary? {
        let mine = myAddresses
        return conversation.messages.last { message in !message.from.contains { mine.contains($0.normalized) } } ?? conversation.latest
    }

    // MARK: Local changes

    /// Removes copies from their cached folders and keeps them from coming back until the server agrees.
    func removeLocally(_ messages: [MessageSummary], change: inout LocalChange, protection: inout Protection) {
        var touched = Set<String>()
        for message in messages {
            protection.hiddenIDs.insert(message.id)
            let key = boxKey(message.accountID, message.mailboxPath)
            guard var box = mailboxData[key], let index = box.messages.firstIndex(where: { $0.id == message.id }) else { continue }
            change.removed.append((key, box.messages[index]))
            box.messages.remove(at: index)
            mailboxData[key] = box
            touched.insert(key)
        }
        for key in touched { persistMailbox(key: key) }
    }

    /// Changes flags on every cached copy of the messages (all folders, snoozes, search results).
    func applyFlagEdit(_ edit: FlagEdit, to messages: [MessageSummary], change: inout LocalChange, protection: inout Protection) {
        let keys = Set(messages.map(\.dedupeKey))
        guard !keys.isEmpty else { return }
        for key in keys { protection.flagEdits[key] = (protection.flagEdits[key] ?? FlagEdit()).then(edit) }
        let accountIDs = Set(messages.map(\.accountID))

        for key in Array(mailboxData.keys) {
            guard var box = mailboxData[key], accountIDs.contains(box.accountID) else { continue }
            var touched = false
            for index in box.messages.indices where keys.contains(box.messages[index].dedupeKey) {
                let old = box.messages[index].flags
                let new = edit.applied(to: old)
                guard new != old else { continue }
                change.flagChanges.append(.init(location: .mailbox(key), id: box.messages[index].id, old: old))
                box.messages[index].flags = new
                touched = true
            }
            if touched {
                mailboxData[key] = box
                persistMailbox(key: key)
            }
        }

        var snoozesTouched = false
        for id in Array(snoozes.keys) {
            guard var record = snoozes[id], accountIDs.contains(record.accountID) else { continue }
            var touched = false
            for index in record.messages.indices where keys.contains(record.messages[index].dedupeKey) {
                let old = record.messages[index].flags
                let new = edit.applied(to: old)
                guard new != old else { continue }
                change.flagChanges.append(.init(location: .snooze(id), id: record.messages[index].id, old: old))
                record.messages[index].flags = new
                touched = true
            }
            if touched {
                snoozes[id] = record
                snoozesTouched = true
            }
        }
        if snoozesTouched { persistSnoozes() }

        for (id, message) in serverSearchResults where keys.contains(message.dedupeKey) {
            let new = edit.applied(to: message.flags)
            guard new != message.flags else { continue }
            change.flagChanges.append(.init(location: .search, id: id, old: message.flags))
            serverSearchResults[id]?.flags = new
        }
    }

    /// Puts back what an action changed locally.
    func revert(_ change: LocalChange) {
        var touched = Set<String>()
        for item in change.removed.reversed() {
            guard var box = mailboxData[item.key] else { continue }
            if let validity = box.state?.uidValidity, validity != item.message.uidValidity { continue }
            guard !box.messages.contains(where: { $0.id == item.message.id }) else { continue }
            box.messages.append(item.message)
            mailboxData[item.key] = box
            touched.insert(item.key)
        }
        var snoozesTouched = false
        for flagChange in change.flagChanges.reversed() {
            switch flagChange.location {
            case .mailbox(let key):
                guard var box = mailboxData[key], let index = box.messages.firstIndex(where: { $0.id == flagChange.id }) else { continue }
                box.messages[index].flags = flagChange.old
                mailboxData[key] = box
                touched.insert(key)
            case .snooze(let id):
                guard var record = snoozes[id], let index = record.messages.firstIndex(where: { $0.id == flagChange.id }) else { continue }
                record.messages[index].flags = flagChange.old
                snoozes[id] = record
                snoozesTouched = true
            case .search:
                serverSearchResults[flagChange.id]?.flags = flagChange.old
            }
        }
        for id in change.snoozesAdded {
            snoozes[id] = nil
            snoozesTouched = true
        }
        for item in change.snoozesRemoved {
            snoozes[item.id] = item.record
            snoozesTouched = true
        }
        if snoozesTouched { persistSnoozes() }
        for key in touched { persistMailbox(key: key) }
    }

    // MARK: Pending action, undo, commit

    func beginUndoable(operations: [ServerOperation], change: LocalChange, protection: Protection, verb: String,
                       followUps: [FollowUp], toast text: String, systemImage: String) {
        // Starting another undoable action commits the one before.
        if let previous = pendingAction { commit(previous) }
        let id = UUID()
        if !protection.isEmpty { protections.append(protection) }
        var action = PendingAction(id: id, operations: operations.coalesced(), change: change, protectionID: protection.id,
                                   verb: verb, followUps: followUps, timer: nil)
        let delay = Self.nanoseconds(undoWindow)
        action.timer = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, let pending = self.pendingAction, pending.id == id else { return }
            self.commit(pending)
        }
        pendingAction = action
        undoStack.append(.action(id))
        present(text, systemImage: systemImage, entry: .action(id))
        markChanged()
    }

    /// Sends a pending action to the server (after everything committed before it).
    func commit(_ action: PendingAction) {
        action.timer?.cancel()
        if pendingAction?.id == action.id { pendingAction = nil }
        undoStack.removeAll { $0 == .action(action.id) }
        retireToast(for: .action(action.id))
        enqueueCommit { await self.runCommit(action) }
    }

    /// Server work runs one piece at a time, in the order it was committed.
    @discardableResult
    func enqueueCommit(_ work: @escaping @MainActor () async -> Void) -> Task<Void, Never> {
        let previous = commitChain
        let task = track {
            await previous?.value
            await work()
        }
        commitChain = task
        return task
    }

    private func runCommit(_ action: PendingAction) async {
        if let failure = await run(action.operations) {
            revert(action.change)
            protections.removeAll { $0.id == action.protectionID }
            markChanged()
            showError("Couldn't \(action.verb).", failure)
            return
        }
        finishProtection(action.protectionID)
        for followUp in action.followUps {
            switch followUp {
            case .markStale(let accountID, let path):
                lastSyncAt[boxKey(accountID, path)] = nil
            case .syncInbox(let accountID):
                guard let inbox = mailbox(accountID: accountID, role: .inbox) else { continue }
                track {
                    do {
                        try await self.syncMailbox(inbox, fresh: true)
                    } catch {
                        // The next refresh picks it up.
                    }
                }
            }
        }
    }

    /// Runs the operations in order; returns the first error.
    func run(_ operations: [ServerOperation]) async -> Error? {
        for operation in operations where !operation.messages.isEmpty {
            guard let service = services[operation.accountID] else { continue }
            do {
                try await service.perform(operation.action, on: operation.messages)
            } catch {
                return error
            }
        }
        return nil
    }

    func finishProtection(_ id: UUID) {
        guard let index = protections.firstIndex(where: { $0.id == id }) else { return }
        protections[index].finishedAtSequence = syncSequence
        protections[index].finishedAt = environment.now()
    }

    func performUndo() {
        while let entry = undoStack.popLast() {
            switch entry {
            case .action(let id):
                guard let action = pendingAction, action.id == id else { continue }
                action.timer?.cancel()
                pendingAction = nil
                revert(action.change)
                protections.removeAll { $0.id == action.protectionID }
                toast = nil
                toastEntry = nil
                markChanged()
                return
            case .send(let id):
                guard let timer = pendingSendTimers[id] else { continue }
                timer.cancel()
                pendingSendTimers[id] = nil
                restoredDraft = outbox.first { $0.id == id }
                outbox.removeAll { $0.id == id }
                failedSendIDs.remove(id)
                persistOutbox()
                toast = nil
                toastEntry = nil
                return
            }
        }
    }

    func performFlush() async {
        if let pending = pendingAction { commit(pending) }
        for id in Array(pendingSendTimers.keys) {
            pendingSendTimers[id]?.cancel()
            pendingSendTimers[id] = nil
            startSendNow(id)
        }
        while let chain = commitChain {
            await chain.value
            if commitChain == chain { break }
        }
        for running in Array(sendTasks.values) { await running.value }
        await cache?.flush()
    }

    // MARK: Helpers

    static func unique(_ conversations: [Conversation]) -> [Conversation] {
        var seen = Set<String>()
        return conversations.filter { seen.insert($0.id).inserted && !$0.messages.isEmpty }
    }

    static func group(_ messages: [MessageSummary], action: MailAction) -> [ServerOperation] {
        var order: [String] = []
        var byAccount: [String: [MessageSummary]] = [:]
        for message in messages {
            if byAccount[message.accountID] == nil { order.append(message.accountID) }
            byAccount[message.accountID, default: []].append(message)
        }
        return order.map { ServerOperation(accountID: $0, action: action, messages: byAccount[$0] ?? []) }.coalesced()
    }
}
