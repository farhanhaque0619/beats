import Foundation
import InkModel
import InkIMAP
import InkMIME

// Incremental sync, paging, and turning FETCH responses into `MessageSummary`s.
extension IMAPMailService {
    /// Brings `mailbox` up to date.
    ///
    /// - No previous state, or UIDVALIDITY changed: the newest `limit` messages by sequence
    ///   number (`didReset`).
    /// - Otherwise only changes: with CONDSTORE, flags changed since the last HIGHESTMODSEQ plus
    ///   a `UID SEARCH` of the known window to find removals and new mail; without it, one
    ///   `UID FETCH <oldest known>:* (UID FLAGS)`. New messages get full summaries; known ones
    ///   whose flags changed are re-sent with the new flags. More than `limit` new messages
    ///   resets the window instead.
    ///
    /// Summaries never download whole bodies: snippets come from the first couple of KB of the
    /// preferred text part, fetched in batches grouped by part.
    ///
    /// Servers with a MESSAGELIMIT (Yahoo: 1,000) cut longer replies short, SEARCH silently
    /// (RESEARCH §3.4). There the known window is checked with `UID FETCH` in UID spans holding at
    /// most half the limit of known messages, never with SEARCH; a reply that reaches the limit
    /// counts as cut short and reloads the newest `limit` messages by sequence number instead.
    public func sync(mailbox: MailboxInfo, previous: MailboxSyncState?, limit: Int) async throws -> MailboxSyncResult {
        try await exclusive {
            try await self.withClient { client in
                try await self.performSync(mailbox: mailbox, previous: previous, limit: max(1, limit), client: client)
            }
        }
    }

    /// The `limit` messages just older than `olderThanUID`, newest first.
    public func fetchOlder(mailbox: MailboxInfo, olderThanUID: UInt32, limit: Int) async throws -> [MessageSummary] {
        guard olderThanUID > 1, limit > 0 else { return [] }
        return try await exclusive {
            try await self.withClient { client in
                try await self.performFetchOlder(mailbox: mailbox, olderThanUID: olderThanUID, limit: limit, client: client)
            }
        }
    }

    // MARK: Sync

    private func performSync(mailbox: MailboxInfo, previous: MailboxSyncState?, limit: Int, client: IMAPClient) async throws -> MailboxSyncResult {
        let condstore = await client.supports("CONDSTORE")
        let messageLimit = Self.messageLimit(await client.capabilities)
        // Always a fresh SELECT: it reports the current UIDNEXT and HIGHESTMODSEQ.
        let info = try await client.select(mailbox.rawPath, condstore: condstore)
        let modSeq = (condstore && !info.noModSeq) ? info.highestModSeq : nil

        guard let previous, previous.uidValidity == info.uidValidity else {
            return try await resetSync(mailbox: mailbox, info: info, modSeq: modSeq, previous: previous, limit: limit, client: client)
        }

        let path = mailbox.path
        let validity = info.uidValidity
        let known = Set(previous.knownUIDs)
        let windowStart = max(1, previous.knownUIDs.min() ?? previous.uidNext)
        var memo = memos[path].flatMap { $0.uidValidity == validity ? $0 : nil } ?? IMAPMailServiceMemo(uidValidity: validity)
        // The memory describes what the caller has only if it hands back the state this service
        // last returned; otherwise (an older state, another device's cache) report conservatively.
        let trusted = memo.produced(previous)

        // Nothing at all happened since the last sync of this session.
        if trusted, let modSeq, memo.highestModSeq == modSeq, memo.exists == info.exists, memo.uidNext == info.uidNext, info.uidNext != nil {
            let state = MailboxSyncState(uidValidity: validity, uidNext: previous.uidNext, highestModSeq: modSeq,
                                         knownUIDs: previous.knownUIDs, lastSync: Date())
            return MailboxSyncResult(state: state, upserted: [], removedIDs: [], didReset: false)
        }

        var existing = Set<UInt32>()
        var currentFlags: [UInt32: [String]] = [:]
        // The mod-sequence the returned state may claim: not past changes this sync missed.
        var syncedModSeq = modSeq
        if info.exists == 0 {
            // Empty: everything known is gone (and `n:*` would be invalid on some servers).
        } else if let modSeq, let previousModSeq = previous.highestModSeq, messageLimit == nil {
            if modSeq != previousModSeq {
                let changed = try await client.fetchReportingCompleteness(.from(windowStart), byUID: true, items: [.uid, .flags],
                                                                          changedSince: previousModSeq)
                for response in changed.responses {
                    if let uid = response.uid, uid >= windowStart, let flags = response.flags { currentFlags[uid] = flags }
                }
                if !changed.isComplete {
                    // Changes the server didn't send would never be asked for again.
                    log("The server sent only some of the flag changes in \(path); asking again next time.")
                    syncedModSeq = previousModSeq
                }
            }
            let found = try await client.uidSearch(.and([.uid(.from(windowStart)), .undeleted]))
            existing = Set(found.filter { $0 >= windowStart })
        } else {
            let spans = Self.uidSpans(known: previous.knownUIDs, from: windowStart, perSpan: messageLimit.map { max(1, $0 / 2) })
            var cutShort = false
            var incomplete = false
            var listed = Set<UInt32>()
            for span in spans {
                let outcome = try await client.fetchReportingCompleteness(span, byUID: true, items: [.uid, .flags])
                let all = outcome.responses
                if !outcome.isComplete { incomplete = true }
                if let messageLimit, all.count >= messageLimit { cutShort = true }
                for response in all {
                    guard let uid = response.uid, uid >= windowStart else { continue }
                    listed.insert(uid)
                    let flags = response.flags ?? []
                    if MessageFlags(imapFlags: flags).contains(.deleted) { continue }
                    existing.insert(uid)
                    currentFlags[uid] = flags
                }
            }
            if cutShort {
                log("A reply in \(path) reached the server's message limit and may be incomplete; loading the newest \(limit) instead.")
                return try await resetSync(mailbox: mailbox, info: info, modSeq: modSeq, previous: previous, limit: limit, client: client)
            }
            if incomplete {
                // The server answered NO part-way through: a known message it left out may well
                // still be there, so only what it showed as gone (or \Deleted) counts as removed.
                log("The server listed only part of \(path); keeping the messages it left out.")
                existing.formUnion(known.subtracting(listed))
            }
        }
        // A message flagged \Deleted is on its way out (e.g. moved by a server without MOVE).
        for (uid, flags) in currentFlags where MessageFlags(imapFlags: flags).contains(.deleted) {
            existing.remove(uid)
        }

        let removed = known.subtracting(existing)
        let newUIDs = existing.subtracting(known).sorted()
        if newUIDs.count > limit {
            log("\(newUIDs.count) new messages in \(path); loading the newest \(limit) instead.")
            return try await resetSync(mailbox: mailbox, info: info, modSeq: modSeq, previous: previous, limit: limit, client: client)
        }

        var upserted: [MessageSummary] = []
        var fetchedNew: [UInt32] = []
        if !newUIDs.isEmpty {
            let summaries = try await fetchSummaries(uids: newUIDs, path: path, uidValidity: validity, client: client)
            upserted.append(contentsOf: summaries)
            fetchedNew = summaries.map(\.uid)
        }

        // Known messages whose flags we learned: compare with what this session last reported.
        var needFull: [UInt32] = []
        for uid in known.intersection(existing).sorted() {
            guard let flags = currentFlags[uid] else { continue }
            let messageFlags = MessageFlags(imapFlags: flags)
            if var cached = memo.byUID[uid] {
                if !trusted || cached.flags != messageFlags {
                    cached.flags = messageFlags
                    memo.byUID[uid] = cached
                    upserted.append(cached)
                }
            } else {
                needFull.append(uid)
            }
        }
        if !needFull.isEmpty {
            // Not seen in this session (e.g. after a relaunch): send complete summaries.
            let summaries = try await fetchSummaries(uids: needFull, path: path, uidValidity: validity, client: client)
            upserted.append(contentsOf: summaries)
        }

        let knownNow = known.intersection(existing).union(fetchedNew).sorted()
        let highestSeen = (existing.max() ?? 0) &+ 1
        let uidNext = info.uidNext.map { max($0, highestSeen) } ?? max(previous.uidNext, highestSeen)
        let state = MailboxSyncState(uidValidity: validity, uidNext: uidNext, highestModSeq: syncedModSeq, knownUIDs: knownNow, lastSync: Date())

        for uid in removed { memo.byUID[uid] = nil }
        memo.store(upserted)
        memo.exists = info.exists
        memo.uidNext = info.uidNext
        memo.highestModSeq = syncedModSeq
        memo.lastState = state
        memos[path] = memo

        let removedIDs = Set(removed.map { summaryID(path: path, uidValidity: validity, uid: $0) })
        return MailboxSyncResult(state: state, upserted: Self.newestFirst(upserted), removedIDs: removedIDs, didReset: false)
    }

    /// Loads the newest `limit` messages from scratch.
    private func resetSync(mailbox: MailboxInfo, info: IMAPSelectInfo, modSeq: UInt64?, previous: MailboxSyncState?, limit: Int,
                           client: IMAPClient) async throws -> MailboxSyncResult {
        let path = mailbox.path
        let validity = info.uidValidity
        var summaries: [MessageSummary] = []
        if info.exists > 0 {
            let count = UInt32(clamping: limit)
            let start = info.exists > count ? info.exists - count + 1 : 1
            summaries = try await fetchSummaries(sequence: start...info.exists, path: path, uidValidity: validity, client: client)
        }
        let uids = summaries.map(\.uid).sorted()
        let uidNext = max(info.uidNext ?? 0, (uids.last ?? 0) &+ 1)
        let state = MailboxSyncState(uidValidity: validity, uidNext: max(uidNext, 1), highestModSeq: modSeq, knownUIDs: uids, lastSync: Date())

        var memo = IMAPMailServiceMemo(uidValidity: validity)
        memo.store(summaries)
        memo.exists = info.exists
        memo.uidNext = info.uidNext
        memo.highestModSeq = modSeq
        memo.lastState = state
        memos[path] = memo

        var removed = Set<String>()
        if let previous {
            for uid in previous.knownUIDs { removed.insert(summaryID(path: path, uidValidity: previous.uidValidity, uid: uid)) }
            if previous.uidValidity == validity { removed.subtract(summaries.map(\.id)) }
        }
        return MailboxSyncResult(state: state, upserted: Self.newestFirst(summaries), removedIDs: removed, didReset: true)
    }

    // MARK: Older

    private func performFetchOlder(mailbox: MailboxInfo, olderThanUID: UInt32, limit: Int, client: IMAPClient) async throws -> [MessageSummary] {
        let info = try await ensureSelected(mailbox.rawPath, client: client)
        let path = mailbox.path
        let validity = info.uidValidity
        // The anchor's sequence number turns "the `limit` before it" into one range.
        let anchor = try await client.fetch(IMAPSequenceSet(olderThanUID), byUID: true, items: [.uid])
        var summaries: [MessageSummary]
        if let seq = anchor.first(where: { $0.uid == olderThanUID })?.seq {
            guard seq > 1 else { return [] }
            let count = UInt32(clamping: limit)
            let start = seq > count ? seq - count : 1
            summaries = try await fetchSummaries(sequence: start...(seq - 1), path: path, uidValidity: validity, client: client)
            summaries = summaries.filter { $0.uid < olderThanUID }
        } else if let messageLimit = Self.messageLimit(await client.capabilities) {
            // The anchor is gone, and SEARCH may be cut at the message limit: walk down in UID spans.
            let chosen = try await olderUIDsByFetch(below: olderThanUID, limit: limit, spanWidth: messageLimit, client: client)
            guard !chosen.isEmpty else { return [] }
            summaries = try await fetchSummaries(uids: chosen, path: path, uidValidity: validity, client: client)
        } else {
            // The anchor is gone: find the older UIDs directly.
            let older = try await client.uidSearch(.and([.uid(IMAPSequenceSet(1...(olderThanUID - 1))), .undeleted]))
            let chosen = Array(older.filter { $0 < olderThanUID }.suffix(limit))
            guard !chosen.isEmpty else { return [] }
            summaries = try await fetchSummaries(uids: chosen, path: path, uidValidity: validity, client: client)
        }
        if var memo = memos[path], memo.uidValidity == validity {
            memo.store(summaries)
            // Callers add paged-in messages to their known window; keep the memory in step.
            if var last = memo.lastState {
                last.knownUIDs = Array(Set(last.knownUIDs).union(summaries.map(\.uid))).sorted()
                memo.lastState = last
            }
            memos[path] = memo
        } else {
            var memo = IMAPMailServiceMemo(uidValidity: validity)
            memo.store(summaries)
            memos[path] = memo
        }
        return Self.newestFirst(summaries)
    }

    /// The newest `limit` UIDs below `anchor`, found with `UID FETCH` over UID spans `spanWidth`
    /// wide (so no reply can exceed the server's message limit), walking down from the anchor.
    private func olderUIDsByFetch(below anchor: UInt32, limit: Int, spanWidth: Int, client: IMAPClient) async throws -> [UInt32] {
        guard anchor > 1 else { return [] }
        let width = UInt32(clamping: max(1, spanWidth))
        var found = Set<UInt32>()
        var upper = anchor - 1
        // Bounded, so a mailbox with huge UID gaps can't keep this going for long.
        for _ in 0..<64 {
            let lower = upper >= width ? upper - width + 1 : 1
            let responses = try await client.fetch(IMAPSequenceSet(lower...upper), byUID: true, items: [.uid, .flags])
            for response in responses {
                guard let uid = response.uid, uid >= lower, uid <= upper,
                      !MessageFlags(imapFlags: response.flags ?? []).contains(.deleted) else { continue }
                found.insert(uid)
            }
            if found.count >= limit || lower <= 1 { break }
            upper = lower - 1
        }
        return Array(found.sorted().suffix(limit))
    }

    // MARK: Message limits

    /// The server's MESSAGELIMIT (RFC 9738; Yahoo advertises 1000): the most messages one command
    /// handles or returns. Nil when the server announces none.
    static func messageLimit(_ capabilities: Set<String>) -> Int? {
        let prefix = "MESSAGELIMIT="
        let limits = capabilities.compactMap { capability -> Int? in
            guard capability.uppercased().hasPrefix(prefix) else { return nil }
            return Int(capability.dropFirst(prefix.count)).flatMap { $0 > 0 ? $0 : nil }
        }
        return limits.min()
    }

    /// UID sets covering `windowStart` and everything above it, split so that each closed range
    /// holds at most `perSpan` of the `known` UIDs; the last set is open (`n:*`) and also catches
    /// new mail. Without `perSpan`, one open set.
    static func uidSpans(known: [UInt32], from windowStart: UInt32, perSpan: Int?) -> [IMAPSequenceSet] {
        guard let perSpan, perSpan > 0 else { return [.from(windowStart)] }
        let sorted = Set(known.filter { $0 >= windowStart }).sorted()
        var spans: [IMAPSequenceSet] = []
        var lower = windowStart
        var index = 0
        while sorted.count - index > perSpan {
            let upper = sorted[index + perSpan - 1]
            spans.append(IMAPSequenceSet(lower...upper))
            guard upper < UInt32.max else { return spans }
            lower = upper + 1
            index += perSpan
        }
        spans.append(.from(lower))
        return spans
    }

    /// Messages per FETCH: `Options.fetchBatchSize`, but never more than the server's message limit.
    func batchSize(_ client: IMAPClient) async -> Int {
        let limit = Self.messageLimit(await client.capabilities) ?? Int.max
        return max(1, min(options.fetchBatchSize, limit))
    }

    // MARK: Fetching summaries

    /// Summaries (with snippets) for messages by UID, in batches.
    func fetchSummaries(uids: [UInt32], path: String, uidValidity: UInt32, client: IMAPClient) async throws -> [MessageSummary] {
        var responses: [IMAPFetchResponse] = []
        let batchSize = await batchSize(client)
        for chunk in Self.chunks(uids.sorted(), size: batchSize) {
            responses += try await fetchSummaryResponses(IMAPSequenceSet(chunk), byUID: true, client: client)
        }
        return try await summaries(from: responses, path: path, uidValidity: uidValidity, client: client)
    }

    /// Summaries (with snippets) for a range of sequence numbers, in batches.
    func fetchSummaries(sequence range: ClosedRange<UInt32>, path: String, uidValidity: UInt32, client: IMAPClient) async throws -> [MessageSummary] {
        var responses: [IMAPFetchResponse] = []
        let batch = UInt64(await batchSize(client))
        var lower = range.lowerBound
        while true {
            let upper = UInt32(min(UInt64(range.upperBound), UInt64(lower) + batch - 1))
            responses += try await fetchSummaryResponses(IMAPSequenceSet(lower...upper), byUID: false, client: client)
            if upper >= range.upperBound { break }
            lower = upper + 1
        }
        return try await summaries(from: responses, path: path, uidValidity: uidValidity, client: client)
    }

    /// One FETCH of the summary items. A server that chokes on BODYSTRUCTURE for a malformed
    /// message (Exchange, Yahoo) fails the whole command; then the batch is fetched without it.
    private func fetchSummaryResponses(_ set: IMAPSequenceSet, byUID: Bool, client: IMAPClient) async throws -> [IMAPFetchResponse] {
        do {
            return try await client.fetch(set, byUID: byUID, items: IMAPMailServiceSummaries.summaryItems)
        } catch let error as MailError {
            guard case .serverError = error else { throw error }
            log("FETCH failed (\(error.localizedDescription)); retrying without BODYSTRUCTURE.")
            return try await client.fetch(set, byUID: byUID, items: IMAPMailServiceSummaries.minimalItems)
        }
    }

    /// Builds summaries from FETCH responses and fills in snippets. Messages marked `\Deleted`
    /// are left out.
    func summaries(from responses: [IMAPFetchResponse], path: String, uidValidity: UInt32, client: IMAPClient) async throws -> [MessageSummary] {
        var summaries: [MessageSummary] = []
        var targets: [UInt32: IMAPMailServiceSummaries.SnippetTarget] = [:]
        var seen = Set<UInt32>()
        for response in responses {
            guard let summary = IMAPMailServiceSummaries.summary(from: response, accountID: account.id, mailboxPath: path, uidValidity: uidValidity),
                  !summary.flags.contains(.deleted), seen.insert(summary.uid).inserted else { continue }
            summaries.append(summary)
            if let target = IMAPMailServiceSummaries.snippetTarget(response.bodyStructure, options: options) {
                targets[summary.uid] = target
            }
        }
        let snippets = try await fetchSnippets(targets, client: client)
        for index in summaries.indices {
            if let snippet = snippets[summaries[index].uid] { summaries[index].snippet = snippet }
        }
        return summaries
    }

    /// Fetches the start of each message's text part, one FETCH per part section and batch.
    /// A server refusing a snippet fetch only costs the snippets.
    func fetchSnippets(_ targets: [UInt32: IMAPMailServiceSummaries.SnippetTarget], client: IMAPClient) async throws -> [UInt32: String] {
        guard !targets.isEmpty else { return [:] }
        var groups: [String: [UInt32]] = [:]
        for (uid, target) in targets { groups[target.groupKey, default: []].append(uid) }
        var snippets: [UInt32: String] = [:]
        let batchSize = await batchSize(client)
        for key in groups.keys.sorted() {
            guard let uids = groups[key], let sample = uids.first.flatMap({ targets[$0] }) else { continue }
            for chunk in Self.chunks(uids.sorted(), size: batchSize) {
                let set = IMAPSequenceSet(chunk)
                let usePartial = !partialFetchBroken
                let item = IMAPFetchItem.bodyPeek(section: sample.section, partial: usePartial ? (0, sample.length) : nil)
                var responses: [IMAPFetchResponse] = []
                do {
                    responses = try await client.fetch(set, byUID: true, items: [item])
                } catch let error as MailError {
                    if Self.isConnectionLoss(error) || error == .cancelled { throw error }
                    guard usePartial, case .protocolError = error else {
                        log("Couldn't fetch snippets: \(error.localizedDescription)")
                        continue
                    }
                    // Some servers garble `BODY[1]<0>` replies (GreenMail omits the space before the
                    // literal). From now on fetch whole text parts instead.
                    log("Partial fetch failed (\(error.localizedDescription)); fetching whole text parts for snippets.")
                    partialFetchBroken = true
                    if await client.state == .disconnected { throw IMAPMailServiceRetry.partialFetchFailed }
                    do {
                        responses = try await client.fetch(set, byUID: true, items: [.bodyPeek(section: sample.section, partial: nil)])
                    } catch let retryError as MailError where !Self.isConnectionLoss(retryError) && retryError != .cancelled {
                        log("Couldn't fetch snippets: \(retryError.localizedDescription)")
                        continue
                    }
                }
                if usePartial, !responses.isEmpty, responses.allSatisfy({ $0.section(sample.section) == nil }) {
                    // Answered, but no part data came through: the reply to the partial fetch was
                    // garbled (GreenMail writes `BODY[1]<0>{22}` with no space). Use whole parts.
                    log("The server's partial fetch replies are unusable; fetching whole text parts for snippets.")
                    partialFetchBroken = true
                    do {
                        responses = try await client.fetch(set, byUID: true, items: [.bodyPeek(section: sample.section, partial: nil)])
                    } catch let retryError as MailError where !Self.isConnectionLoss(retryError) && retryError != .cancelled {
                        log("Couldn't fetch snippets: \(retryError.localizedDescription)")
                        continue
                    }
                }
                for response in responses {
                    guard let uid = response.uid, let target = targets[uid], let data = response.section(target.section) else { continue }
                    // Whole parts (no partial fetch) are cut down before decoding.
                    let limited = data.count > target.length * 4 ? data.prefix(target.length * 4) : data
                    snippets[uid] = IMAPMailServiceSummaries.snippet(from: Data(limited), target: target)
                }
            }
        }
        return snippets
    }

    static func chunks(_ values: [UInt32], size: Int) -> [[UInt32]] {
        let size = max(1, size)
        return stride(from: 0, to: values.count, by: size).map { Array(values[$0..<min($0 + size, values.count)]) }
    }

    static func newestFirst(_ summaries: [MessageSummary]) -> [MessageSummary] {
        summaries.sorted { $0.uid > $1.uid }
    }
}

/// Turning IMAP FETCH data into `MessageSummary`s: ENVELOPE decoding (RFC 2047 words, address
/// groups, Dovecot/UW placeholder hosts), bulk-mail detection, and snippets.
enum IMAPMailServiceSummaries {
    /// Headers fetched alongside the ENVELOPE.
    static let headerFieldNames = ["REFERENCES", "IN-REPLY-TO", "LIST-UNSUBSCRIBE", "LIST-UNSUBSCRIBE-POST", "LIST-ID", "PRECEDENCE", "AUTO-SUBMITTED"]

    static let headerItem = IMAPFetchItem.headerFields(headerFieldNames)

    /// Everything a list row needs. Gmail items are dropped by the client on other servers.
    static let summaryItems: [IMAPFetchItem] = [
        .uid, .flags, .internalDate, .rfc822Size, .envelope, .bodyStructure, headerItem,
        .gmailThreadID, .gmailMessageID, .gmailLabels,
    ]

    /// The fallback when a server can't produce BODYSTRUCTURE for some message.
    static let minimalItems: [IMAPFetchItem] = [
        .uid, .flags, .internalDate, .rfc822Size, .envelope, headerItem, .gmailThreadID, .gmailMessageID, .gmailLabels,
    ]

    /// Host names servers put in addresses that had none.
    static let placeholderHosts: Set<String> = ["missing_domain", ".missing-host-name.", "missing-host-name", "unknown", "unspecified-domain"]

    /// Builds a summary; nil without a UID.
    static func summary(from response: IMAPFetchResponse, accountID: String, mailboxPath: String, uidValidity: UInt32,
                        now: Date = Date()) -> MessageSummary? {
        guard let uid = response.uid, uid > 0 else { return nil }
        let envelope = response.envelope ?? IMAPEnvelope()
        let headers = response.section(headerItem.sectionKey ?? "").map(MIMEHeaders.parse) ?? MIMEHeaders.parse(Data())

        var from = addresses(envelope.from)
        if from.isEmpty { from = addresses(envelope.sender) }
        // Servers fill an absent Reply-To with From; only a different one is worth keeping.
        let listedReplyTo = addresses(envelope.replyTo)
        let replyTo = Set(listedReplyTo) == Set(from) ? [] : listedReplyTo
        let received = response.internalDate
        let parsedDate = envelope.date.flatMap { RFC5322Date.parse($0) }
        let date = sanitizedDate(parsedDate, received: received, now: now)

        var inReplyTo = headers.values("In-Reply-To").flatMap(MessageIDParser.parseList)
        if inReplyTo.isEmpty, let raw = envelope.inReplyTo { inReplyTo = MessageIDParser.parseList(raw) }
        let references = MessageIDParser.parseList(headers.values("References").joined(separator: " "))
        let messageID = envelope.messageID.flatMap { MessageIDParser.parseList($0).first ?? cleanID($0) }

        let listUnsubscribe = headers["List-Unsubscribe"].map(collapse).flatMap { $0.isEmpty ? nil : $0 }
        let listUnsubscribePost = headers["List-Unsubscribe-Post"].map(collapse).flatMap { $0.isEmpty ? nil : $0 }

        return MessageSummary(
            accountID: accountID,
            mailboxPath: mailboxPath,
            uid: uid,
            uidValidity: uidValidity,
            messageID: messageID,
            inReplyTo: inReplyTo,
            references: references,
            gmailThreadID: response.gmailThreadID,
            gmailMessageID: response.gmailMessageID,
            gmailLabels: response.decodedGmailLabels,
            subject: decodeText(envelope.subject),
            from: from,
            replyTo: replyTo,
            to: addresses(envelope.to),
            cc: addresses(envelope.cc),
            bcc: addresses(envelope.bcc),
            date: date,
            receivedDate: received ?? date,
            snippet: "",
            flags: response.messageFlags,
            size: max(0, response.size ?? 0),
            hasAttachments: response.bodyStructure?.hasAttachments ?? false,
            isBulk: isBulk(headers: headers, from: from),
            listUnsubscribe: listUnsubscribe,
            listUnsubscribePost: listUnsubscribePost
        )
    }

    /// The Date header unless it's missing, before 1980, or more than two days after the
    /// server received the message (spam dated into the future would sit atop the list).
    static func sanitizedDate(_ header: Date?, received: Date?, now: Date) -> Date {
        let fallback = received ?? header ?? now
        guard let header else { return fallback }
        if header.timeIntervalSince1970 < 315_532_800 { return fallback }
        let reference = received ?? now
        if header.timeIntervalSince(reference) > 2 * 86_400 { return fallback }
        return header
    }

    /// ENVELOPE addresses → `EmailAddress`es, skipping group markers and empty entries.
    static func addresses(_ list: [IMAPAddress]) -> [EmailAddress] {
        var result: [EmailAddress] = []
        for item in list where !item.isGroupStart && !item.isGroupEnd {
            guard var mailbox = item.mailbox?.trimmingCharacters(in: .whitespacesAndNewlines), !mailbox.isEmpty else { continue }
            if mailbox.contains("=?") { mailbox = EncodedWord.decode(mailbox) }
            var address = mailbox
            if let host = item.host?.trimmingCharacters(in: .whitespacesAndNewlines), !host.isEmpty,
               !placeholderHosts.contains(host.lowercased()) {
                address = mailbox.contains("@") ? mailbox : "\(mailbox)@\(host)"
            }
            if address.caseInsensitiveCompare("missing_mailbox") == .orderedSame { continue }
            var name = item.name.map(decodeText)
            if let current = name {
                name = stripQuotes(current)
                if name?.caseInsensitiveCompare(address) == .orderedSame { name = nil }
            }
            result.append(EmailAddress(name: name, address: address))
        }
        return result
    }

    /// RFC 2047-decoded, single line.
    static func decodeText(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "" }
        return collapse(raw.contains("=?") ? EncodedWord.decode(raw) : raw)
    }

    static func collapse(_ s: String) -> String {
        var output = ""
        output.reserveCapacity(s.count)
        var pendingSpace = false
        for character in s {
            if character.isWhitespace || character.isNewline {
                pendingSpace = !output.isEmpty
            } else {
                if pendingSpace { output.append(" ") }
                pendingSpace = false
                output.append(character)
            }
        }
        return output
    }

    /// `'Ada'` / `"Ada"` (Outlook quirks) → `Ada`.
    static func stripQuotes(_ s: String) -> String {
        var value = s.trimmingCharacters(in: .whitespaces)
        for quote in ["'", "\""] where value.count >= 2 && value.hasPrefix(quote) && value.hasSuffix(quote) {
            value = String(value.dropFirst().dropLast()).trimmingCharacters(in: .whitespaces)
        }
        return value
    }

    static func cleanID(_ raw: String) -> String? {
        var value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if value.hasPrefix("<") { value.removeFirst() }
        if value.hasSuffix(">") { value.removeLast() }
        return value.isEmpty ? nil : value
    }

    /// Newsletters, notifications and other automated mail.
    static func isBulk(headers: MIMEHeaders, from: [EmailAddress]) -> Bool {
        if headers["List-Unsubscribe"] != nil || headers["List-Id"] != nil { return true }
        if let precedence = headers["Precedence"]?.trimmingCharacters(in: .whitespaces).lowercased(),
           ["bulk", "list", "junk", "auto_reply"].contains(precedence) {
            return true
        }
        if let auto = headers["Auto-Submitted"]?.trimmingCharacters(in: .whitespaces).lowercased(), !auto.isEmpty,
           !(auto == "no" || auto.hasPrefix("no;") || auto.hasPrefix("no ")) {
            return true
        }
        return from.first?.looksAutomated ?? false
    }

    // MARK: Snippets

    /// Which part to fetch for a snippet, and how to decode it.
    struct SnippetTarget: Sendable, Hashable {
        var section: String
        var length: Int
        var encoding: String
        var contentType: ContentType
        var isHTML: Bool

        /// Messages sharing a section and length are fetched together.
        var groupKey: String { "\(section)|\(length)" }
    }

    static func snippetTarget(_ structure: BodyStructure?, options: IMAPMailService.Options) -> SnippetTarget? {
        guard let structure, let (section, part) = structure.preferredTextPart(), !section.isEmpty else { return nil }
        let isHTML = part.subtype == "html"
        let length = max(64, isHTML ? options.htmlSnippetBytes : options.snippetBytes)
        let contentType = ContentType(type: part.type, subtype: part.subtype, parameters: part.parameters)
        return SnippetTarget(section: section, length: length, encoding: part.encoding, contentType: contentType, isHTML: isHTML)
    }

    /// Decodes a (possibly truncated) part and makes the one-line preview.
    static func snippet(from data: Data, target: SnippetTarget) -> String {
        let text = MIMEParser.decodeText(data, transferEncoding: target.encoding, contentType: target.contentType)
        return target.isHTML ? Snippet.make(plain: nil, html: text) : Snippet.make(plain: text, html: nil)
    }
}
