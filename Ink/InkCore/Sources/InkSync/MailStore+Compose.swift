import Foundation
import InkModel

// The outbox: undo send, delivery, retries.
extension MailStore {
    func performSend(_ message: OutgoingMessage) {
        guard account(id: message.accountID) != nil else {
            showError("Couldn't send.", MailError.sendFailed("That account is no longer set up."))
            return
        }
        guard message.hasRecipients else {
            present("Add at least one recipient.", systemImage: "exclamationmark.triangle", style: .error)
            return
        }
        if let invalid = message.allRecipients.first(where: { !$0.isValid }) {
            present("“\(invalid.address)” doesn't look like an email address.", systemImage: "exclamationmark.triangle", style: .error)
            return
        }
        let id = message.id
        pendingSendTimers[id]?.cancel()
        outbox.removeAll { $0.id == id }
        outbox.append(message)
        failedSendIDs.remove(id)
        persistOutbox()

        let delay = Self.nanoseconds(undoSendDelay)
        pendingSendTimers[id] = Task { @MainActor [weak self] in
            try? await Task.sleep(nanoseconds: delay)
            guard !Task.isCancelled, let self, self.pendingSendTimers[id] != nil else { return }
            self.pendingSendTimers[id] = nil
            self.startSendNow(id)
        }
        undoStack.append(.send(id))
        present("Sending…", systemImage: "paperplane", entry: .send(id))
    }

    /// Hands the message to the service now (the undo delay is over).
    func startSendNow(_ id: UUID) {
        undoStack.removeAll { $0 == .send(id) }
        retireToast(for: .send(id))
        guard sendTasks[id] == nil else { return }
        sendTasks[id] = track {
            await self.deliver(id)
            self.sendTasks[id] = nil
        }
    }

    private func deliver(_ id: UUID) async {
        guard let message = outbox.first(where: { $0.id == id }), !inFlightSends.contains(id) else { return }
        guard let service = services[message.accountID] else {
            failedSendIDs.insert(id)
            showError("Couldn't send.", MailError.sendFailed("That account is no longer set up."))
            return
        }
        inFlightSends.insert(id)
        defer { inFlightSends.remove(id) }
        do {
            try await service.send(message)
        } catch {
            guard outbox.contains(where: { $0.id == id }) else { return }
            failedSendIDs.insert(id)
            persistOutbox()
            if case MailError.sendFailed = error {
                present(error.userMessage, systemImage: "exclamationmark.triangle", style: .error)
            } else {
                showError("Couldn't send.", error)
            }
            return
        }
        outbox.removeAll { $0.id == id }
        failedSendIDs.remove(id)
        persistOutbox()
        present("Sent", systemImage: "checkmark", style: .success)
        markAnsweredLocally(message)

        // Pull the sent copy so the reply shows in its thread (and the inbox when you wrote to yourself).
        let accountID = message.accountID
        let toSelf = message.allRecipients.contains { isMe($0) }
        if mailbox(accountID: accountID, role: .sent) == nil, !(mailboxesByAccount[accountID] ?? []).isEmpty {
            // The service created Sent for this copy (servers that start without one).
            try? await ensureMailboxes(accountID: accountID, force: true)
        }
        if let sent = mailbox(accountID: accountID, role: .sent) {
            try? await syncMailbox(sent, fresh: true)
        }
        if toSelf, let inbox = mailbox(accountID: accountID, role: .inbox) {
            try? await syncMailbox(inbox, fresh: true)
        }
    }

    /// Shows the answered / forwarded mark on the message a reply went to, before the next sync.
    private func markAnsweredLocally(_ message: OutgoingMessage) {
        guard let parent = message.inReplyTo?.lowercased(), !parent.isEmpty else { return }
        let flag: MessageFlags = message.replyMode == .forward ? .forwarded : .answered
        let prefix = boxKey(message.accountID, "")
        var changed = false
        for key in Array(mailboxData.keys) where key.hasPrefix(prefix) {
            guard var box = mailboxData[key] else { continue }
            var touched = false
            for index in box.messages.indices where box.messages[index].messageID?.lowercased() == parent {
                if !box.messages[index].flags.contains(flag) {
                    box.messages[index].flags.insert(flag)
                    touched = true
                }
            }
            if touched {
                mailboxData[key] = box
                persistMailbox(key: key)
                changed = true
            }
        }
        if changed { markChanged() }
    }

    func performRetrySend(id: UUID) {
        guard outbox.contains(where: { $0.id == id }), pendingSendTimers[id] == nil, !inFlightSends.contains(id) else { return }
        failedSendIDs.remove(id)
        present("Sending…", systemImage: "paperplane")
        startSendNow(id)
    }

    func performDiscardOutbox(id: UUID) {
        guard !inFlightSends.contains(id) else { return }
        pendingSendTimers[id]?.cancel()
        pendingSendTimers[id] = nil
        undoStack.removeAll { $0 == .send(id) }
        if toastEntry == .send(id) {
            toast = nil
            toastEntry = nil
        }
        outbox.removeAll { $0.id == id }
        failedSendIDs.remove(id)
        persistOutbox()
    }
}
