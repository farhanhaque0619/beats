import Foundation
import InkModel
import InkIMAP
import InkMIME

// Reading a message, server-side triage, search and sending.
extension IMAPMailService {
    // MARK: - Body

    /// Downloads the whole message (`UID FETCH uid BODY.PEEK[]`, so it isn't marked read) and
    /// decodes it. A summary from an older UIDVALIDITY is found again by Message-ID.
    /// Throws `.messageNotFound` when the message is no longer there.
    public func body(for message: MessageSummary) async throws -> MessageBody {
        try await exclusive {
            try await self.withClient { client in
                let raw = try await self.rawPath(for: message.mailboxPath, client: client)
                let info = try await self.ensureSelected(raw, client: client)
                var uid = message.uid
                if info.uidValidity != 0, message.uidValidity != 0, info.uidValidity != message.uidValidity {
                    let isGmail = await client.isGmail
                    guard let found = try await self.locateInSelected([message], isGmail: isGmail, client: client).first?.uid else {
                        throw MailError.messageNotFound
                    }
                    uid = found
                }
                let responses = try await client.fetch(IMAPSequenceSet(uid), byUID: true, items: [.bodyPeek(section: "", partial: nil)])
                guard let data = responses.first(where: { $0.uid == uid })?.section(""), !data.isEmpty else {
                    throw MailError.messageNotFound
                }
                return MIMEParser.parse(data).body(messageID: message.id)
            }
        }
    }

    // MARK: - Actions

    /// Runs `action` on the server, one batch per mailbox.
    ///
    /// - read / unread / flag / unflag: `UID STORE ±FLAGS.SILENT`.
    /// - archive: Gmail drops the Inbox label (UID MOVE from INBOX to All Mail, or removing the
    ///   `\Inbox` label elsewhere); other servers MOVE to the Archive folder, creating it if needed.
    /// - trash / markSpam: MOVE to Trash / Junk (created on servers that have none, except Gmail).
    /// - moveToInbox: checks where the summary says the message is, then finds it by X-GM-MSGID
    ///   (Gmail) or Message-ID in All Mail / Archive, Trash and Spam, and moves it back (Gmail
    ///   copies from All Mail and labels, which adds the Inbox label and keeps the others).
    /// - move: MOVE to the folder with that path.
    /// - deletePermanently: `\Deleted` + `UID EXPUNGE` of just those messages (Gmail moves them
    ///   to Trash first, since expunging elsewhere only removes a label).
    public func perform(_ action: MailAction, on messages: [MessageSummary]) async throws {
        var seen = Set<String>()
        let unique = messages.filter { seen.insert($0.id).inserted }
        guard !unique.isEmpty else { return }
        try await exclusive {
            try await self.withClient { client in
                try await self.performAction(action, on: unique, client: client)
            }
        }
    }

    private func performAction(_ action: MailAction, on messages: [MessageSummary], client: IMAPClient) async throws {
        switch action {
        case .markRead: try await store(["\\Seen"], mode: .add, on: messages, client: client)
        case .markUnread: try await store(["\\Seen"], mode: .remove, on: messages, client: client)
        case .flag: try await store(["\\Flagged"], mode: .add, on: messages, client: client)
        case .unflag: try await store(["\\Flagged"], mode: .remove, on: messages, client: client)
        case .archive: try await archive(messages, client: client)
        case .trash: try await moveToSystemFolder(.trash, name: "Trash", messages, client: client)
        case .markSpam: try await moveToSystemFolder(.junk, name: "Junk", messages, client: client)
        case .moveToInbox: try await moveToInbox(messages, client: client)
        case .move(let path):
            guard let destination = try await mailbox(path: path, client: client), destination.isSelectable else {
                throw MailError.mailboxNotFound(path)
            }
            try await move(messages, to: destination, client: client)
        case .deletePermanently: try await deletePermanently(messages, client: client)
        }
    }

    /// Messages of one mailbox, selected, with their current UIDs.
    struct ResolvedGroup {
        var path: String
        var rawPath: String
        var role: MailboxRole
        /// (summary id, UID) for each message found.
        var pairs: [(id: String, uid: UInt32)]
        var uids: [UInt32] { pairs.map(\.uid) }
        var set: IMAPSequenceSet { IMAPSequenceSet(uids) }
    }

    /// Groups messages by mailbox, keeping the order in which mailboxes first appear.
    static func grouped(_ messages: [MessageSummary]) -> [(path: String, messages: [MessageSummary])] {
        var order: [String] = []
        var groups: [String: [MessageSummary]] = [:]
        for message in messages {
            if groups[message.mailboxPath] == nil { order.append(message.mailboxPath) }
            groups[message.mailboxPath, default: []].append(message)
        }
        return order.map { ($0, groups[$0] ?? []) }
    }

    /// Selects the group's mailbox and works out its UIDs. Summaries from an older UIDVALIDITY
    /// are looked up by Message-ID. Nil when the mailbox no longer exists.
    func resolve(_ messages: [MessageSummary], path: String, client: IMAPClient) async throws -> ResolvedGroup? {
        let raw = try await rawPath(for: path, client: client)
        let role = try await role(ofPath: path, client: client)
        let info: IMAPSelectInfo
        do {
            info = try await ensureSelected(raw, client: client)
        } catch MailError.mailboxNotFound {
            log("“\(path)” is gone; skipping \(messages.count) message(s).")
            return nil
        }
        var pairs: [(id: String, uid: UInt32)] = []
        var stale: [MessageSummary] = []
        for message in messages {
            if info.uidValidity == 0 || message.uidValidity == 0 || message.uidValidity == info.uidValidity {
                pairs.append((message.id, message.uid))
            } else {
                stale.append(message)
            }
        }
        if !stale.isEmpty {
            let isGmail = await client.isGmail
            pairs += try await locateInSelected(stale, isGmail: isGmail, client: client)
        }
        return ResolvedGroup(path: path, rawPath: raw, role: role, pairs: pairs)
    }

    private func store(_ flags: [String], mode: IMAPStoreMode, on messages: [MessageSummary], client: IMAPClient) async throws {
        let change = MessageFlags(imapFlags: flags)
        for (path, group) in Self.grouped(messages) {
            guard let resolved = try await resolve(group, path: path, client: client), !resolved.pairs.isEmpty else { continue }
            try await client.uidStore(resolved.set, flags: flags, mode: mode)
            if var memo = memos[path] {
                for uid in resolved.uids {
                    guard var summary = memo.byUID[uid] else { continue }
                    if mode == .remove { summary.flags.subtract(change) } else { summary.flags.formUnion(change) }
                    memo.byUID[uid] = summary
                }
                memos[path] = memo
            }
        }
    }

    private func archive(_ messages: [MessageSummary], client: IMAPClient) async throws {
        if await client.isGmail {
            let allMail = try await mailbox(role: .all, client: client)
            for (path, group) in Self.grouped(messages) {
                guard let resolved = try await resolve(group, path: path, client: client), !resolved.pairs.isEmpty else { continue }
                switch resolved.role {
                case .inbox, .trash, .junk:
                    if let allMail {
                        _ = try await client.uidMove(resolved.set, to: allMail.rawPath)
                        forget(resolved)
                    } else if resolved.role == .inbox {
                        // All Mail hidden from IMAP (RESEARCH §3.4): removing the label still archives.
                        try await client.gmailStoreLabels(resolved.set, labels: ["\\Inbox"], mode: .remove)
                        forget(resolved)
                    } else {
                        // Out of Trash or Spam there's nowhere to go without All Mail.
                        throw MailError.notSupported("archiving from \(resolved.role.title) until “All Mail” is shown in IMAP (Gmail settings › Labels)")
                    }
                default:
                    // In All Mail or another label, archiving means losing the Inbox label only.
                    try await client.gmailStoreLabels(resolved.set, labels: ["\\Inbox"], mode: .remove)
                }
            }
            return
        }
        let archive = try await mailbox(role: .archive, creatingAs: "Archive", client: client)
        try await move(messages, to: archive, client: client)
    }

    private func moveToSystemFolder(_ role: MailboxRole, name: String, _ messages: [MessageSummary], client: IMAPClient) async throws {
        let destination: MailboxInfo
        if await client.isGmail {
            guard let found = try await mailbox(role: role, client: client) else {
                throw MailError.notSupported("moving to \(role.title) until “\(role.title)” is shown in IMAP (Gmail settings › Labels)")
            }
            destination = found
        } else {
            destination = try await mailbox(role: role, creatingAs: name, client: client)
        }
        try await move(messages, to: destination, client: client)
    }

    private func move(_ messages: [MessageSummary], to destination: MailboxInfo, client: IMAPClient) async throws {
        for (path, group) in Self.grouped(messages) where path != destination.path {
            guard let resolved = try await resolve(group, path: path, client: client), !resolved.pairs.isEmpty else { continue }
            _ = try await client.uidMove(resolved.set, to: destination.rawPath)
            forget(resolved)
        }
    }

    private func deletePermanently(_ messages: [MessageSummary], client: IMAPClient) async throws {
        let isGmail = await client.isGmail
        for (path, group) in Self.grouped(messages) {
            guard let resolved = try await resolve(group, path: path, client: client), !resolved.pairs.isEmpty else { continue }
            if !isGmail || resolved.role == .trash || resolved.role == .junk {
                try await client.uidStore(resolved.set, flags: ["\\Deleted"], mode: .add)
                try await expunge(resolved.set, client: client)
                forget(resolved)
                continue
            }
            // Gmail: expunging outside Trash/Spam only removes a label, so go through Trash.
            guard let trash = try await mailbox(role: .trash, client: client) else {
                throw MailError.notSupported("deleting for good until “Trash” is shown in IMAP (Gmail settings › Labels)")
            }
            let mapping = try await client.uidMove(resolved.set, to: trash.rawPath)
            forget(resolved)
            _ = try await ensureSelected(trash.rawPath, client: client)
            var targets = Array(mapping.values)
            if targets.isEmpty {
                targets = try await locateInSelected(group, isGmail: true, client: client).map(\.uid)
            }
            guard !targets.isEmpty else { continue }
            let set = IMAPSequenceSet(targets)
            try await client.uidStore(set, flags: ["\\Deleted"], mode: .add)
            try await expunge(set, client: client)
        }
    }

    /// Expunges exactly `set` (already marked `\Deleted`). Without UIDPLUS, other messages
    /// marked `\Deleted` are unmarked around a plain EXPUNGE so they survive it.
    private func expunge(_ set: IMAPSequenceSet, client: IMAPClient) async throws {
        if await client.supports("UIDPLUS") {
            try await client.uidExpunge(set)
            return
        }
        let others = try await client.uidSearch(.and([.deleted, .not(.uid(set))]))
        let otherSet = IMAPSequenceSet(others)
        if !otherSet.isEmpty { try await client.uidStore(otherSet, flags: ["\\Deleted"], mode: .remove) }
        try await client.expunge()
        if !otherSet.isEmpty { try await client.uidStore(otherSet, flags: ["\\Deleted"], mode: .add) }
    }

    /// Drops moved messages from the memo of their old mailbox.
    private func forget(_ group: ResolvedGroup) {
        guard var memo = memos[group.path] else { return }
        for uid in group.uids { memo.byUID[uid] = nil }
        memo.exists = nil
        memos[group.path] = memo
    }

    // MARK: Move to inbox

    private func moveToInbox(_ messages: [MessageSummary], client: IMAPClient) async throws {
        let isGmail = await client.isGmail
        let inbox = try await mailbox(role: .inbox, client: client)
            ?? MailboxInfo(accountID: account.id, path: "INBOX", rawPath: "INBOX", role: .inbox)
        var remaining = messages
        var located = 0
        var searched = Set<String>()

        // 1. Where the summaries say the messages are.
        for (path, group) in Self.grouped(messages) {
            guard let resolved = try await resolve(group, path: path, client: client), !resolved.pairs.isEmpty else { continue }
            let present = Set(try await client.uidSearch(.and([.uid(resolved.set), .undeleted])))
            let here = resolved.pairs.filter { present.contains($0.uid) }
            guard !here.isEmpty else { continue }
            let set = IMAPSequenceSet(here.map(\.uid))
            if resolved.role != .inbox {
                if Self.copiesToInbox(isGmail: isGmail, from: resolved.role) {
                    _ = try await client.uidCopy(set, to: inbox.rawPath)
                } else {
                    _ = try await client.uidMove(set, to: inbox.rawPath)
                    forget(ResolvedGroup(path: path, rawPath: resolved.rawPath, role: resolved.role, pairs: here))
                }
            }
            let done = Set(here.map(\.id))
            located += done.count
            remaining.removeAll { done.contains($0.id) }
            if resolved.role != .inbox { searched.insert(path) }
        }

        // 2. Search by identity: INBOX first (already back?), then where archived or deleted mail goes.
        let candidateRoles: [MailboxRole] = isGmail ? [.all, .trash, .junk] : [.archive, .trash, .junk]
        var candidates: [MailboxInfo] = [inbox]
        for role in candidateRoles {
            if let box = try await mailbox(role: role, client: client), !candidates.contains(where: { $0.path == box.path }) {
                candidates.append(box)
            }
        }
        for box in candidates {
            let searchable = remaining.filter { ($0.messageID?.isEmpty == false) || (isGmail && $0.gmailMessageID != nil) }
            guard !searchable.isEmpty else { break }
            if box.role != .inbox, searched.contains(box.path) { continue }
            do {
                _ = try await ensureSelected(box.rawPath, client: client)
            } catch MailError.mailboxNotFound {
                continue
            }
            let found = try await locateInSelected(searchable, isGmail: isGmail, client: client)
            guard !found.isEmpty else { continue }
            let set = IMAPSequenceSet(found.map(\.uid))
            if box.role != .inbox {
                if Self.copiesToInbox(isGmail: isGmail, from: box.role) {
                    _ = try await client.uidCopy(set, to: inbox.rawPath)
                } else {
                    _ = try await client.uidMove(set, to: inbox.rawPath)
                    forget(ResolvedGroup(path: box.path, rawPath: box.rawPath, role: box.role, pairs: found))
                }
            }
            let done = Set(found.map(\.id))
            located += done.count
            remaining.removeAll { done.contains($0.id) }
        }
        if located == 0 { throw MailError.messageNotFound }
        if !remaining.isEmpty { log("Couldn't find \(remaining.count) message(s) to move back to the inbox.") }
    }

    /// On Gmail, putting a message back in the inbox means adding the Inbox label (COPY), which
    /// keeps its other labels; only Trash and Spam need a real MOVE. Elsewhere it's always a MOVE.
    static func copiesToInbox(isGmail: Bool, from role: MailboxRole) -> Bool {
        isGmail && role != .trash && role != .junk
    }

    // MARK: Finding messages by identity

    /// Finds `messages` in the selected mailbox by X-GM-MSGID (Gmail) or Message-ID, returning
    /// (summary id, UID) pairs. Several messages share one SEARCH; a follow-up FETCH tells which
    /// UID belongs to which.
    ///
    /// `SEARCH HEADER Message-ID x` is a substring match (RFC 3501 §6.4.4), so it also finds
    /// `<1x>`; every hit is checked against the exact Message-ID before anyone acts on it. Only
    /// a lone X-GM-MSGID search is exact enough to trust as is.
    func locateInSelected(_ messages: [MessageSummary], isGmail: Bool, client: IMAPClient) async throws -> [(id: String, uid: UInt32)] {
        var results: [(id: String, uid: UInt32)] = []
        let searchable = messages.filter { (isGmail && $0.gmailMessageID != nil) || ($0.messageID.map { !$0.isEmpty } ?? false) }
        var index = 0
        while index < searchable.count {
            let chunk = Array(searchable[index..<min(index + 20, searchable.count)])
            index += chunk.count
            let criteria = chunk.compactMap { Self.identityCriterion($0, isGmail: isGmail) }
            guard !criteria.isEmpty else { continue }
            let uids = try await client.uidSearch(.and([.anyOf(criteria), .undeleted]))
            guard !uids.isEmpty else { continue }
            if chunk.count == 1, isGmail, chunk[0].gmailMessageID != nil {
                results += uids.map { (chunk[0].id, $0) }
                continue
            }
            let idItem = IMAPFetchItem.headerFields(["MESSAGE-ID"])
            let fetched = try await client.fetch(IMAPSequenceSet(uids), byUID: true, items: [.uid, .gmailMessageID, idItem])
            for response in fetched {
                guard let uid = response.uid else { continue }
                if let gmailID = response.gmailMessageID, let match = chunk.first(where: { $0.gmailMessageID == gmailID }) {
                    results.append((match.id, uid))
                    continue
                }
                guard let data = response.section(idItem.sectionKey ?? ""),
                      let header = MIMEHeaders.parse(data)["Message-ID"],
                      let id = MessageIDParser.parseList(header).first?.lowercased(),
                      let match = chunk.first(where: { $0.messageID?.lowercased() == id }) else { continue }
                results.append((match.id, uid))
            }
        }
        return results
    }

    static func identityCriterion(_ message: MessageSummary, isGmail: Bool) -> IMAPSearchCriteria? {
        if isGmail, let gmailID = message.gmailMessageID { return .gmailMessageID(gmailID) }
        guard let id = message.messageID?.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t")), !id.isEmpty else { return nil }
        return isGmail ? .gmailRaw("rfc822msgid:\(id)") : .header("Message-ID", id)
    }

    // MARK: - Search

    /// Server-side search, newest `limit` matches first. Gmail: `X-GM-RAW` (Gmail's own search
    /// syntax) in All Mail. Others: every word must match the sender, recipients, subject or body.
    public func search(_ query: String, in mailbox: MailboxInfo, limit: Int) async throws -> [MessageSummary] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, limit > 0 else { return [] }
        return try await exclusive {
            try await self.withClient { client in
                let isGmail = await client.isGmail
                var target = mailbox
                let criteria: IMAPSearchCriteria
                if isGmail {
                    if let allMail = try await self.mailbox(role: .all, client: client) { target = allMail }
                    criteria = .gmailRaw(trimmed)
                } else {
                    let terms = Self.searchTerms(trimmed)
                    guard !terms.isEmpty else { return [] }
                    let useBody = self.options.searchBodies
                    criteria = .and(terms.map { term in
                        .anyOf([.from(term), .to(term), .subject(term), useBody ? .body(term) : .text(term)])
                    } + [.undeleted])
                }
                let info = try await self.ensureSelected(target.rawPath, client: client)
                let uids = try await client.uidSearch(criteria)
                if let messageLimit = Self.messageLimit(await client.capabilities), uids.count >= messageLimit {
                    // Yahoo answers at most MESSAGELIMIT matches, with a plain OK (RESEARCH §3.4).
                    self.log("The search may be incomplete: the server returns at most \(messageLimit) matches.")
                }
                let chosen = Array(uids.suffix(limit))
                guard !chosen.isEmpty else { return [] }
                let summaries = try await self.fetchSummaries(uids: chosen, path: target.path, uidValidity: info.uidValidity, client: client)
                return summaries.sorted { $0.date == $1.date ? $0.uid > $1.uid : $0.date > $1.date }
            }
        }
    }

    /// Splits a query into words, keeping "quoted phrases" together; at most eight terms.
    static func searchTerms(_ query: String) -> [String] {
        var terms: [String] = []
        var current = ""
        var quoted = false
        for character in query {
            if character == "\"" {
                quoted.toggle()
                if !quoted, !current.isEmpty { terms.append(current); current = "" }
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { terms.append(current); current = "" }
            } else {
                current.append(character)
            }
        }
        let last = current.trimmingCharacters(in: .whitespaces)
        if !last.isEmpty { terms.append(last) }
        var seen = Set<String>()
        return Array(terms.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty && seen.insert($0.lowercased()).inserted }.prefix(8))
    }

    // MARK: - Send

    /// Builds the message, sends it over SMTP (password or XOAUTH2), then makes sure Sent has a
    /// copy (RESEARCH §3.8):
    ///
    /// - Accounts whose server files the copy itself (`savesSentAutomatically`: Gmail, Outlook,
    ///   Yahoo, AOL, Zoho) get nothing more, and neither does Gmail's own SMTP whatever the
    ///   account says (a Gmail APPEND only wastes upload).
    /// - Everyone else (iCloud, Fastmail, any other server): Ink looks for the server's copy in
    ///   Sent by Message-ID at `Options.sentCopyPollDelays` (0, 1, 1, 2 s), and uploads its own,
    ///   `\Seen` and with a Bcc header so you can see who you blind-copied, only when none turns
    ///   up. Once this session has seen the server file a copy it waits longer
    ///   (`Options.sentCopyPatientPollDelays`), since such copies can arrive late.
    ///
    /// Once the server has accepted the message nothing more is thrown: a failure to file the
    /// Sent copy is logged, because reporting it would invite sending the message again.
    /// Recipients refused while others were accepted don't throw either (the message is out).
    public func send(_ message: OutgoingMessage) async throws {
        let recipients = message.allRecipients.map(\.address).filter { !$0.isEmpty }
        guard !recipients.isEmpty else { throw MailError.sendFailed("Add at least one recipient.") }
        let built = MessageBuilder.build(message)

        let smtp = try await connector.openSMTP()
        do {
            let result = try await smtp.send(from: message.from.address, recipients: recipients, message: built.data)
            if let summary = result.rejectionSummary { log(summary) }
        } catch {
            await smtp.quit()
            throw connector.advise(error, server: .smtp)
        }
        await smtp.quit()

        // A server Ink knows nothing about is checked even if the account claims it files copies.
        guard !account.savesSentAutomatically || account.provider == .other else { return }
        let copy = Self.sentCopy(built.data, bcc: message.bcc)
        do {
            try await fileSentCopy(copy, messageID: built.messageID)
        } catch {
            log("Sent, but couldn't file a copy in Sent: \(Self.mailError(error).localizedDescription)")
        }
    }

    /// What a look in Sent found.
    enum SentCopyLookup: Equatable {
        /// Gmail's SMTP files the copy; nothing to do.
        case serverFiles
        /// The server's copy is there.
        case found
        case notFound
        /// The account has no Sent folder yet (the upload creates one).
        case noSentFolder
    }

    /// Looks for the server's copy of a just-sent message, then uploads Ink's own if there's none.
    func fileSentCopy(_ copy: Data, messageID: String) async throws {
        let delays: [TimeInterval]
        switch serverSavesSentCopies {
        case true?: delays = options.sentCopyPatientPollDelays
        case false?: delays = Array(options.sentCopyPollDelays.prefix(1))
        case nil: delays = options.sentCopyPollDelays
        }
        poll: for delay in delays {
            if delay > 0 { try await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000)) }
            let lookup = try await exclusive {
                try await self.withClient { client in try await self.lookForSentCopy(messageID: messageID, client: client) }
            }
            switch lookup {
            case .serverFiles:
                return
            case .found:
                if serverSavesSentCopies != true { log("The server filed its own copy in Sent; not uploading one.") }
                serverSavesSentCopies = true
                return
            case .noSentFolder:
                break poll
            case .notFound:
                continue
            }
        }
        if !delays.isEmpty, serverSavesSentCopies == nil { serverSavesSentCopies = false }
        try await exclusive {
            try await self.withClient { client in
                let isGmail = await client.isGmail
                if isGmail, Self.isGoogleSMTP(self.account.smtp.host) { return }
                let sent: MailboxInfo
                if isGmail {
                    // Never invent a "Sent" label on Gmail; its Sent Mail may just be hidden from IMAP.
                    guard let found = try await self.mailbox(role: .sent, client: client) else {
                        self.log("Gmail's Sent Mail isn't shown in IMAP; not filing a copy.")
                        return
                    }
                    sent = found
                } else {
                    sent = try await self.mailbox(role: .sent, creatingAs: "Sent", client: client)
                }
                _ = try await client.append(to: sent.rawPath, message: copy, flags: ["\\Seen"], date: Date())
                if var memo = self.memos[sent.path] {
                    memo.exists = nil
                    self.memos[sent.path] = memo
                }
            }
        }
    }

    /// One look for the message in Sent, by Message-ID.
    private func lookForSentCopy(messageID: String, client: IMAPClient) async throws -> SentCopyLookup {
        if await client.isGmail, Self.isGoogleSMTP(account.smtp.host) { return .serverFiles }
        guard let sent = try await mailbox(role: .sent, client: client) else { return .noSentFolder }
        let id = messageID.trimmingCharacters(in: CharacterSet(charactersIn: "<> \t"))
        guard !id.isEmpty else { return .notFound }
        let wasSelected = await client.selectedMailbox?.mailbox == sent.rawPath
        _ = try await ensureSelected(sent.rawPath, client: client)
        // A mailbox selected earlier hears about new messages only in reply to a command.
        if wasSelected { _ = try await client.noop() }
        let found = try await client.uidSearch(.and([.header("Message-ID", id), .undeleted]))
        return found.isEmpty ? .notFound : .found
    }

    static func isGoogleSMTP(_ host: String) -> Bool {
        let lower = host.lowercased()
        return lower.hasSuffix("gmail.com") || lower.hasSuffix("googlemail.com") || lower.hasSuffix("google.com")
    }

    /// The Sent copy: the sent message with a `Bcc:` header added (never sent over SMTP).
    static func sentCopy(_ data: Data, bcc: [EmailAddress]) -> Data {
        let addresses = bcc.uniqued().filter { !$0.address.isEmpty }
        guard !addresses.isEmpty else { return data }
        let formatted = addresses.map { address -> String in
            guard let name = address.name, !name.isEmpty else { return address.address }
            if name.unicodeScalars.allSatisfy({ $0.isASCII }) { return address.formatted }
            return "\(EncodedWord.encode(name)) <\(address.address)>"
        }
        var header = Data("Bcc: ".utf8)
        header.append(Data(formatted.joined(separator: ",\r\n ").utf8))
        header.append(Data("\r\n".utf8))
        header.append(data)
        return header
    }
}
