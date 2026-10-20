import Foundation
import InkModel

/// A parsed search box query: free words plus a few Gmail-style operators
/// (`from:`, `to:`, `subject:`, `is:unread`, `is:read`, `is:starred`, `has:attachment`), with
/// "quoted phrases". Matching ignores case and accents; every part must match one message.
struct SearchQuery {
    var words: [String] = []
    var from: [String] = []
    var to: [String] = []
    var subject: [String] = []
    var unread: Bool?
    var starred: Bool?
    var hasAttachment: Bool?

    init(_ raw: String) {
        for token in Self.tokenize(raw) {
            let lower = token.lowercased()
            func value(after prefix: String) -> String? {
                guard lower.hasPrefix(prefix), token.count > prefix.count else { return nil }
                return Self.fold(String(token.dropFirst(prefix.count)))
            }
            if let value = value(after: "from:") {
                from.append(value)
            } else if let value = value(after: "to:") ?? value(after: "cc:") {
                to.append(value)
            } else if let value = value(after: "subject:") {
                subject.append(value)
            } else if lower == "is:unread" {
                unread = true
            } else if lower == "is:read" {
                unread = false
            } else if lower == "is:starred" || lower == "is:flagged" {
                starred = true
            } else if lower == "has:attachment" || lower == "has:attachments" {
                hasAttachment = true
            } else {
                let folded = Self.fold(token)
                if !folded.isEmpty { words.append(folded) }
            }
        }
    }

    var isEmpty: Bool {
        words.isEmpty && from.isEmpty && to.isEmpty && subject.isEmpty && unread == nil && starred == nil && hasAttachment == nil
    }

    /// `text` is the message's folded search text (`MailStore.searchText(for:)`).
    func matches(_ message: MessageSummary, text: String) -> Bool {
        if let unread, message.isUnread != unread { return false }
        if let starred, message.isFlagged != starred { return false }
        if let hasAttachment, message.hasAttachments != hasAttachment { return false }
        if !from.isEmpty {
            let people = Self.fold(message.from.map { "\($0.name ?? "") \($0.address)" }.joined(separator: " "))
            guard from.allSatisfy({ Self.containsWord(people, startingWith: $0) }) else { return false }
        }
        if !to.isEmpty {
            let people = Self.fold((message.to + message.cc).map { "\($0.name ?? "") \($0.address)" }.joined(separator: " "))
            guard to.allSatisfy({ Self.containsWord(people, startingWith: $0) }) else { return false }
        }
        if !subject.isEmpty {
            let folded = Self.fold(message.subject)
            guard subject.allSatisfy({ Self.containsWord(folded, startingWith: $0) }) else { return false }
        }
        return words.allSatisfy { Self.containsWord(text, startingWith: $0) }
    }

    /// True when `needle` occurs in `text` at the start of a word ("lease" finds "Lease renewal"
    /// but not "please"). Works on UTF-8 bytes; both strings are already folded.
    static func containsWord(_ text: String, startingWith needle: String) -> Bool {
        let hay = Array(text.utf8)
        let pin = Array(needle.utf8)
        guard !pin.isEmpty, pin.count <= hay.count else { return pin.isEmpty }
        let first = pin[0]
        var index = 0
        let last = hay.count - pin.count
        while index <= last {
            if hay[index] == first, index == 0 || !isWordByte(hay[index - 1]) || !isWordByte(first) {
                var matched = true
                var offset = 1
                while offset < pin.count {
                    if hay[index + offset] != pin[offset] {
                        matched = false
                        break
                    }
                    offset += 1
                }
                if matched { return true }
            }
            index += 1
        }
        return false
    }

    /// ASCII letters and digits, plus any non-ASCII byte (letters in other scripts).
    private static func isWordByte(_ byte: UInt8) -> Bool {
        (byte >= 0x30 && byte <= 0x39) || (byte >= 0x41 && byte <= 0x5A) || (byte >= 0x61 && byte <= 0x7A) || byte >= 0x80
    }

    /// Splits on whitespace, keeping "quoted phrases" (and `from:"Ada L"`) together.
    static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quoted = false
        for character in raw {
            if character == "\"" || character == "“" || character == "”" {
                quoted.toggle()
            } else if character.isWhitespace && !quoted {
                if !current.isEmpty { tokens.append(current) }
                current = ""
            } else {
                current.append(character)
            }
        }
        if !current.isEmpty { tokens.append(current) }
        return tokens
    }

    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}

// Bodies, search and people.
extension MailStore {
    static let bodyMemoryLimit = 200
    static let serverSearchLimit = 1_000
    /// Cached body files up to this size are read on the main thread by `cachedBody(for:)`;
    /// bigger ones (attachments) only off it, by `body(for:)`.
    static let mainThreadBodyFileLimit = 512 * 1024

    // MARK: Bodies

    func lookupCachedBody(for message: MessageSummary) -> MessageBody? {
        let key = message.dedupeKey
        if var body = bodyMemory[key] {
            body.messageID = message.id
            return body
        }
        guard let cache, var body = cache.loadBody(key: key, accountID: message.accountID, maxFileBytes: Self.mainThreadBodyFileLimit) else {
            return nil
        }
        rememberBody(body, key: key, accountID: message.accountID, persist: false)
        body.messageID = message.id
        return body
    }

    func loadBody(for message: MessageSummary) async throws -> MessageBody {
        if let cached = lookupCachedBody(for: message) { return cached }
        let key = message.dedupeKey
        if let cache, var body = await cache.loadBodyInBackground(key: key, accountID: message.accountID) {
            if bodyMemory[key] == nil, services[message.accountID] != nil {
                rememberBody(body, key: key, accountID: message.accountID, persist: false)
            }
            body.messageID = message.id
            return body
        }
        if let running = bodyTasks[key] {
            var body = try await running.value
            body.messageID = message.id
            return body
        }
        guard let service = services[message.accountID] else { throw MailError.messageNotFound }
        // Other cached copies of the same message, in case this one moved (snoozed, archived on
        // another device) and its UID is gone.
        let alternates = cachedCopies(accountID: message.accountID, keys: [key], excludingRoles: []).filter { $0.id != message.id }
        let task = Task<MessageBody, Error> {
            do {
                return try await service.body(for: message)
            } catch MailError.messageNotFound {
                for copy in alternates {
                    if let body = try? await service.body(for: copy) { return body }
                }
                throw MailError.messageNotFound
            }
        }
        bodyTasks[key] = task
        defer { bodyTasks[key] = nil }
        var body = try await task.value
        body.messageID = message.id
        if services[message.accountID] === service {
            rememberBody(body, key: key, accountID: message.accountID, persist: true)
        }
        return body
    }

    func rememberBody(_ body: MessageBody, key: String, accountID: String, persist: Bool) {
        if bodyMemory[key] == nil { bodyMemoryOrder.append(key) }
        bodyMemory[key] = body
        while bodyMemoryOrder.count > Self.bodyMemoryLimit {
            bodyMemory[bodyMemoryOrder.removeFirst()] = nil
        }
        if persist { cache?.saveBody(body, key: key, accountID: accountID) }
    }

    // MARK: Search

    /// Folded subject, people and snippet of a message, memoized per data version.
    func searchText(for message: MessageSummary) -> String {
        if searchTextCache?.version != dataVersion { searchTextCache = (dataVersion, [:]) }
        if let text = searchTextCache?.text[message.id] { return text }
        var parts = [message.subject, message.snippet]
        for address in message.from + message.to + message.cc {
            if let name = address.name { parts.append(name) }
            parts.append(address.address)
        }
        let text = SearchQuery.fold(parts.joined(separator: " "))
        searchTextCache?.text[message.id] = text
        return text
    }

    func performSearchLocal(_ query: String) -> [Conversation] {
        let parsed = SearchQuery(query)
        guard !parsed.isEmpty else { return [] }
        let hiddenRoles: Set<MailboxRole> = [.trash, .junk]
        return everything().conversations.filter { conversation in
            let visible = conversation.messages.filter { !hiddenRoles.contains(role(ofPath: $0.mailboxPath, accountID: $0.accountID)) }
            return visible.contains { parsed.matches($0, text: searchText(for: $0)) }
        }
    }

    func performSearchServer(_ query: String) async throws -> [Conversation] {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        var found: [MessageSummary] = []
        var firstError: Error?
        var anySucceeded = false
        for account in accounts {
            guard let service = services[account.id] else { continue }
            do {
                try await ensureMailboxes(accountID: account.id)
            } catch {
                firstError = firstError ?? error
                continue
            }
            let targets: [MailboxInfo]
            if let all = mailbox(accountID: account.id, role: .all) {
                targets = [all]
            } else {
                targets = [mailbox(accountID: account.id, role: .inbox), mailbox(accountID: account.id, role: .archive)].compactMap { $0 }
            }
            for mailbox in targets where mailbox.isSelectable {
                do {
                    let hits = try await service.search(trimmed, in: mailbox, limit: 50)
                    found += hits.filter { $0.accountID == account.id }
                    anySucceeded = true
                } catch {
                    firstError = firstError ?? error
                }
            }
        }
        let local = performSearchLocal(trimmed)
        if !anySucceeded, let firstError {
            if local.isEmpty { throw firstError }
            return local
        }
        rememberSearchResults(found)
        let keys = Set(found.map(\.dedupeKey))
        var merged: [String: Conversation] = [:]
        for conversation in local { merged[conversation.id] = conversation }
        for conversation in everything().conversations where merged[conversation.id] == nil {
            if conversation.messages.contains(where: { keys.contains($0.dedupeKey) }) { merged[conversation.id] = conversation }
        }
        return merged.values.sorted { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
    }

    private func rememberSearchResults(_ found: [MessageSummary]) {
        guard !found.isEmpty else { return }
        for var message in found where services[message.accountID] != nil {
            // Moved away by an action the server may not have seen yet (or just did).
            if protections.contains(where: { $0.hiddenIDs.contains(message.id) }) { continue }
            for protection in protections {
                if let edit = protection.flagEdits[message.dedupeKey] { message.flags = edit.applied(to: message.flags) }
            }
            if serverSearchResults[message.id] == nil { serverSearchOrder.append(message.id) }
            serverSearchResults[message.id] = message
        }
        while serverSearchOrder.count > Self.serverSearchLimit {
            serverSearchResults[serverSearchOrder.removeFirst()] = nil
        }
        markChanged()
    }

    func performRecordSearch(_ query: String) {
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var list = recentSearches.filter { $0.caseInsensitiveCompare(trimmed) != .orderedSame }
        list.insert(trimmed, at: 0)
        recentSearches = Array(list.prefix(10))
        persistState()
    }

    /// Forgets the recent searches.
    public func clearRecentSearches() {
        recentSearches = []
        persistState()
    }

    // MARK: People

    func contactIndex() -> ContactIndex {
        if let cached = contactCache, cached.version == dataVersion { return cached.index }
        var messages: [MessageSummary] = []
        for box in mailboxData.values where role(ofPath: box.path, accountID: box.accountID) != .junk {
            messages += box.messages
        }
        for record in snoozes.values { messages += record.messages }
        let index = ContactIndex(messages: messages, myAddresses: myAddresses, now: environment.now())
        contactCache = (dataVersion, index)
        return index
    }
}
