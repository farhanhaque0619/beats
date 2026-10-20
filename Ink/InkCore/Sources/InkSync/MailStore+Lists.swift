import Foundation
import InkModel

/// Which cached folders make up a scope for one account.
struct ScopePlan {
    /// The role the scope behaves as (inbox scopes get Focus / Other).
    var role: MailboxRole
    /// A conversation is listed when it has a copy in one of these.
    var primaryPaths: Set<String>
    /// Folders threaded together so conversations are complete (e.g. Sent for your replies).
    var contextPaths: [String]
    /// Folders to sync to show the scope.
    var syncPaths: [String]
    /// Folders `loadMore()` pages.
    var pagingPaths: [String]
    /// Only conversations with a starred message (accounts without a Starred folder).
    var flaggedOnly = false
}

// Building the lists the UI shows from the cache.
extension MailStore {
    // MARK: Plans

    func accountIDs(for scope: MailScope) -> [String] {
        switch scope {
        case .unified: return accounts.map(\.id)
        case .account(let id, _), .mailbox(let id, _): return account(id: id) == nil ? [] : [id]
        }
    }

    func plan(for scope: MailScope, accountID: String) -> ScopePlan? {
        switch scope {
        case .unified(let role), .account(_, let role):
            return plan(role: role, accountID: accountID)
        case .mailbox(_, let path):
            let role = mailbox(accountID: accountID, path: path)?.role ?? .custom
            if role != .custom, let canonical = plan(role: role, accountID: accountID), canonical.primaryPaths == [path] {
                return canonical
            }
            let sent = mailbox(accountID: accountID, role: .sent)?.path
            var context = [path]
            if let sent, sent != path { context.append(sent) }
            return ScopePlan(role: role == .inbox ? .inbox : .custom, primaryPaths: [path], contextPaths: context,
                             syncPaths: [path], pagingPaths: [path])
        }
    }

    private func plan(role: MailboxRole, accountID: String) -> ScopePlan? {
        let hasList = !(mailboxesByAccount[accountID] ?? []).isEmpty
        func path(_ role: MailboxRole) -> String? {
            if let info = mailbox(accountID: accountID, role: role) { return info.path }
            if role == .inbox && !hasList { return "INBOX" }
            return nil
        }
        let inbox = path(.inbox)
        let sent = path(.sent)
        func context(_ primary: String, _ extra: String?...) -> [String] {
            var list = [primary]
            for item in extra { if let item, !list.contains(item) { list.append(item) } }
            return list
        }
        switch role {
        case .inbox:
            guard let inbox else { return nil }
            return ScopePlan(role: .inbox, primaryPaths: [inbox], contextPaths: context(inbox, sent), syncPaths: [inbox], pagingPaths: [inbox])
        case .sent:
            guard let sent else { return nil }
            return ScopePlan(role: .sent, primaryPaths: [sent], contextPaths: context(sent, inbox), syncPaths: [sent], pagingPaths: [sent])
        case .drafts, .junk, .trash:
            guard let box = path(role) else { return nil }
            return ScopePlan(role: role, primaryPaths: [box], contextPaths: [box], syncPaths: [box], pagingPaths: [box])
        case .archive:
            guard let box = path(.archive) ?? path(.all) else { return nil }
            return ScopePlan(role: .archive, primaryPaths: [box], contextPaths: context(box, inbox, sent), syncPaths: [box], pagingPaths: [box])
        case .all:
            if let all = path(.all) {
                return ScopePlan(role: .all, primaryPaths: [all], contextPaths: context(all, inbox, sent), syncPaths: [all], pagingPaths: [all])
            }
            let parts = [inbox, path(.archive), sent].compactMap { $0 }
            guard !parts.isEmpty else { return nil }
            return ScopePlan(role: .all, primaryPaths: Set(parts), contextPaths: parts, syncPaths: parts, pagingPaths: parts)
        case .flagged:
            if let starred = path(.flagged) {
                return ScopePlan(role: .flagged, primaryPaths: [starred], contextPaths: context(starred, inbox, sent),
                                 syncPaths: [starred], pagingPaths: [starred])
            }
            // No Starred folder: starred messages from every cached folder except Spam, Trash and Drafts.
            let excluded: Set<MailboxRole> = [.junk, .trash, .drafts]
            let prefix = boxKey(accountID, "")
            var paths = mailboxData.keys.filter { $0.hasPrefix(prefix) }.map { String($0.dropFirst(prefix.count)) }
            paths = paths.filter { !excluded.contains(self.role(ofPath: $0, accountID: accountID)) }.sorted()
            if let inbox, !paths.contains(inbox) { paths.insert(inbox, at: 0) }
            return ScopePlan(role: .flagged, primaryPaths: Set(paths), contextPaths: paths, syncPaths: inbox.map { [$0] } ?? [],
                             pagingPaths: [], flaggedOnly: true)
        case .snoozed, .custom:
            return nil
        }
    }

    /// The role a scope behaves as.
    func effectiveRole(of scope: MailScope) -> MailboxRole? {
        switch scope {
        case .unified(let role), .account(_, let role): return role
        case .mailbox(let accountID, _): return plan(for: scope, accountID: accountID)?.role
        }
    }

    // MARK: Building

    /// Every conversation in `scope`, ignoring the Focus / Other filter. Memoized per data version.
    func allConversations(for scope: MailScope) -> [Conversation] {
        if let cached = scopeCache[scope], cached.version == dataVersion { return cached.conversations }
        let result = computeConversations(for: scope)
        scopeCache[scope] = (dataVersion, result)
        return result
    }

    private func computeConversations(for scope: MailScope) -> [Conversation] {
        let accountIDs = self.accountIDs(for: scope)
        if scope.role == .snoozed { return snoozedList(accountIDs: Set(accountIDs)) }
        let me = myAddresses
        var result: [Conversation] = []
        var isInboxScope = false
        for accountID in accountIDs {
            guard let plan = plan(for: scope, accountID: accountID) else { continue }
            if plan.role == .inbox { isInboxScope = true }
            var messages: [MessageSummary] = []
            var seenPaths = Set<String>()
            for path in plan.contextPaths where seenPaths.insert(path).inserted {
                messages += self.messages(accountID: accountID, path: path)
            }
            guard !messages.isEmpty else { continue }
            let primary = plan.primaryPaths
            let inboxPath = mailbox(accountID: accountID, role: .inbox)?.path ?? "INBOX"
            let sentPath = mailbox(accountID: accountID, role: .sent)?.path
            let threads = Threader.thread(messages, myAddresses: me) { message in
                if primary.contains(message.mailboxPath) { return 0 }
                if message.mailboxPath == inboxPath { return 1 }
                if message.mailboxPath == sentPath { return 2 }
                return 3
            }
            var snoozedKeys = Set<String>()
            if plan.role == .inbox {
                for record in snoozes.values where record.accountID == accountID {
                    for message in record.messages { snoozedKeys.insert(message.dedupeKey) }
                }
            }
            for conversation in threads {
                let listed = conversation.messages.filter { primary.contains($0.mailboxPath) }
                guard !listed.isEmpty else { continue }
                if plan.flaggedOnly && !conversation.isFlagged { continue }
                // A snoozed conversation whose inbox copies came back anyway (e.g. the demo server
                // restarted) stays hidden until it wakes, unless something new arrived in it.
                if !snoozedKeys.isEmpty && listed.allSatisfy({ snoozedKeys.contains($0.dedupeKey) }) { continue }
                result.append(conversation)
            }
        }
        if isInboxScope && !persisted.resurfaced.isEmpty {
            let resurfaced = persisted.resurfaced
            func sortDate(_ conversation: Conversation) -> Date {
                var date = conversation.date
                for message in conversation.messages {
                    if let woke = resurfaced[message.dedupeKey], woke > date { date = woke }
                }
                return date
            }
            let keyed = result.map { (sortDate($0), $0) }
            return keyed.sorted { lhs, rhs in
                if lhs.0 != rhs.0 { return lhs.0 > rhs.0 }
                return lhs.1.id < rhs.1.id
            }.map(\.1)
        }
        result.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
        return result
    }

    /// Snoozed conversations for the accounts (all when nil), soonest to wake first.
    func snoozedList(accountIDs: Set<String>?) -> [Conversation] {
        snoozes
            .filter { accountIDs?.contains($0.value.accountID) ?? true }
            .sorted { lhs, rhs in
                if lhs.value.until != rhs.value.until { return lhs.value.until < rhs.value.until }
                return lhs.key < rhs.key
            }
            .map { Conversation(id: $0.key, messages: $0.value.messages) }
    }

    /// Cached mail changed: invalidate memoized lists and rebuild what's on screen.
    func markChanged() {
        dataVersion &+= 1
        if scopeCache.count > 48 { scopeCache.removeAll() }
        rebuildConversations()
    }

    func rebuildConversations() {
        let all = allConversations(for: scope)
        var shown = all
        var other = 0
        var otherUnread = 0
        if effectiveRole(of: scope) == .inbox && focusedInboxEnabled {
            let others = all.filter(\.isBulk)
            other = others.count
            otherUnread = others.reduce(0) { $0 + ($1.isUnread ? 1 : 0) }
            switch inboxFilter {
            case .focused: shown = all.filter { !$0.isBulk }
            case .other: shown = others
            case .everything: break
            }
        }
        if conversations != shown { conversations = shown }
        if otherCount != other { otherCount = other }
        if otherUnreadCount != otherUnread { otherUnreadCount = otherUnread }
        let more = computeCanLoadMore()
        if canLoadMore != more { canLoadMore = more }
    }

    private func computeCanLoadMore() -> Bool {
        for accountID in accountIDs(for: scope) {
            guard let plan = plan(for: scope, accountID: accountID) else { continue }
            for path in plan.pagingPaths where !exhaustedMailboxes.contains(boxKey(accountID, path)) {
                if mailbox(accountID: accountID, path: path) != nil { return true }
            }
        }
        return false
    }

    // MARK: Everything

    /// Every cached message (all folders, plus server search results), threaded per account.
    func everything() -> (conversations: [Conversation], byID: [String: Int]) {
        if let cached = everythingCache, cached.version == dataVersion { return (cached.conversations, cached.byID) }
        var messages: [MessageSummary] = []
        for box in mailboxData.values { messages += box.messages }
        messages += serverSearchOrder.compactMap { serverSearchResults[$0] }
        for record in snoozes.values { messages += record.messages }
        let roles: [String: [String: MailboxRole]] = mailboxIndex.mapValues { $0.mapValues(\.role) }
        let conversations = Threader.thread(messages, myAddresses: myAddresses) { message in
            let role = roles[message.accountID]?[message.mailboxPath]
                ?? (message.mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame ? .inbox : .custom)
            switch role {
            case .inbox: return 0
            case .sent: return 2
            case .drafts: return 3
            case .junk: return 4
            case .trash: return 5
            default: return 1
            }
        }
        var byID: [String: Int] = [:]
        for (index, conversation) in conversations.enumerated() where byID[conversation.id] == nil { byID[conversation.id] = index }
        everythingCache = (dataVersion, conversations, byID)
        return (conversations, byID)
    }

    func findConversation(id: String) -> Conversation? {
        if let shown = conversations.first(where: { $0.id == id }) { return shown }
        for entry in scopeCache.values where entry.version == dataVersion {
            if let match = entry.conversations.first(where: { $0.id == id }) { return match }
        }
        if let record = snoozes[id] { return Conversation(id: id, messages: record.messages) }
        let all = everything()
        if let index = all.byID[id] { return all.conversations[index] }
        return nil
    }

    // MARK: Titles

    func scopeTitle(_ scope: MailScope) -> String {
        switch scope {
        case .unified(let role):
            if role == .inbox { return accounts.count > 1 ? "All Inboxes" : "Inbox" }
            return role.title
        case .account(let id, let role):
            return accounts.count > 1 ? "\(accountLabel(id)) · \(role.title)" : role.title
        case .mailbox(let id, let path):
            let name: String
            if let info = mailbox(accountID: id, path: path) {
                name = info.displayName
            } else {
                name = path.split(separator: "/").last.map(String.init) ?? path
            }
            return accounts.count > 1 ? "\(accountLabel(id)) · \(name)" : name
        }
    }

    /// "Gmail", "iCloud", … or the address when two accounts share a provider.
    func accountLabel(_ id: String) -> String {
        guard let account = account(id: id) else { return "" }
        let label = Self.providerLabel(account)
        let clash = accounts.contains { $0.id != id && Self.providerLabel($0) == label }
        return clash ? account.emailAddress : label
    }

    static func providerLabel(_ account: AccountConfig) -> String {
        switch account.provider {
        case .gmail: return "Gmail"
        case .icloud: return "iCloud"
        case .outlook: return "Outlook"
        case .yahoo: return "Yahoo"
        case .aol: return "AOL"
        case .fastmail: return "Fastmail"
        case .zoho: return "Zoho"
        case .demo: return "Demo"
        case .other: return account.address.domain.isEmpty ? account.emailAddress : account.address.domain
        }
    }
}
