import Foundation
import InkModel

/// Groups message summaries into conversations.
///
/// Per account:
/// 1. Copies of the same message (`dedupeKey`: Gmail's X-GM-MSGID, else Message-ID) collapse to
///    one, keeping the copy with the lowest `rank` (by default the INBOX copy).
/// 2. Gmail messages with an X-GM-THRID are grouped by it: Gmail already threaded them.
/// 3. Everything else is joined with union-find over Message-ID, In-Reply-To and References.
/// 4. Messages with neither References nor In-Reply-To also join another such message with the
///    same normalized subject, sent within 30 days of it, when the two share a participant other
///    than you (`myAddresses`). This rescues replies from clients that drop threading headers.
///    Bulk mail is left out of this fallback so weekly newsletters with a fixed subject stay apart.
///
/// Each conversation's ID is `"<accountID>|gm:<thrid>"` for Gmail threads, else
/// `"<accountID>|<root>"` where root is the first References entry (or In-Reply-To, or the
/// Message-ID) of the oldest message, which stays the same as older or newer messages are
/// added. Every returned message has `threadKey` set to its conversation's ID.
public enum Threader {
    /// Default copy preference: INBOX copies win, then anything else.
    public static func defaultRank(_ message: MessageSummary) -> Int {
        message.mailboxPath.caseInsensitiveCompare("INBOX") == .orderedSame ? 0 : 1
    }

    /// How far apart two messages may be to be threaded by subject alone.
    public static let subjectFallbackWindow: TimeInterval = 30 * 24 * 3600

    /// How many earlier same-subject messages the fallback compares each message with.
    static let maxSubjectLookBack = 64

    /// Removes duplicate copies, keeping the lowest-ranked copy of each message (ties: first seen).
    public static func dedupe(_ messages: [MessageSummary], rank: (MessageSummary) -> Int = defaultRank) -> [MessageSummary] {
        var bestIndex: [String: Int] = [:]
        var bestRank: [String: Int] = [:]
        var order: [String] = []
        bestIndex.reserveCapacity(messages.count)
        for (index, message) in messages.enumerated() {
            let key = message.dedupeKey
            let r = rank(message)
            if let existing = bestRank[key] {
                if r < existing {
                    bestRank[key] = r
                    bestIndex[key] = index
                }
            } else {
                bestRank[key] = r
                bestIndex[key] = index
                order.append(key)
            }
        }
        return order.compactMap { key in bestIndex[key].map { messages[$0] } }
    }

    /// Conversations, newest first (by their latest message), with `threadKey` assigned.
    /// - Parameters:
    ///   - myAddresses: your own addresses (any case), ignored when looking for a shared participant.
    ///   - rank: copy preference for de-duplication; lower wins.
    public static func thread(
        _ messages: [MessageSummary],
        myAddresses: Set<String> = [],
        rank: (MessageSummary) -> Int = defaultRank
    ) -> [Conversation] {
        let unique = dedupe(messages, rank: rank)
        let me = Set(myAddresses.map { $0.lowercased() })
        var byAccount: [String: [MessageSummary]] = [:]
        var accountOrder: [String] = []
        for message in unique {
            if byAccount[message.accountID] == nil { accountOrder.append(message.accountID) }
            byAccount[message.accountID, default: []].append(message)
        }
        var conversations: [Conversation] = []
        for accountID in accountOrder {
            conversations += threadAccount(byAccount[accountID] ?? [], accountID: accountID, me: me)
        }
        conversations.sort { lhs, rhs in
            if lhs.date != rhs.date { return lhs.date > rhs.date }
            return lhs.id < rhs.id
        }
        return conversations
    }

    // MARK: Internals

    private static func threadAccount(_ messages: [MessageSummary], accountID: String, me: Set<String>) -> [Conversation] {
        let count = messages.count
        guard count > 0 else { return [] }
        var uf = UnionFind(count: count)
        // Node per distinct identifier; the first message that mentions an identifier owns it.
        var owner: [String: Int] = [:]
        owner.reserveCapacity(count * 2)

        func link(_ index: Int, _ rawID: String) {
            let id = normalizeID(rawID)
            guard !id.isEmpty else { return }
            if let other = owner[id] {
                uf.union(index, other)
            } else {
                owner[id] = index
            }
        }

        var fallbackCandidates: [Int] = []
        for (index, message) in messages.enumerated() {
            if let thread = message.gmailThreadID {
                link(index, "gm:\(thread)")
                continue
            }
            if let id = message.messageID { link(index, id) }
            for reference in message.references { link(index, reference) }
            for parent in message.inReplyTo { link(index, parent) }
            if message.references.isEmpty && message.inReplyTo.isEmpty && !message.isBulk {
                fallbackCandidates.append(index)
            }
        }

        // Subject fallback.
        var buckets: [String: [Int]] = [:]
        for index in fallbackCandidates {
            let subject = messages[index].normalizedSubject.lowercased()
            guard !subject.isEmpty else { continue }
            buckets[subject, default: []].append(index)
        }
        for (_, indices) in buckets where indices.count > 1 {
            let sorted = indices.sorted { messages[$0].date < messages[$1].date }
            let people = sorted.map { participants(of: messages[$0], excluding: me) }
            for j in 1..<sorted.count {
                var i = j - 1
                // Bounded look-back keeps a bucket of hundreds of same-subject mails linear.
                let floor = max(0, j - maxSubjectLookBack)
                while i >= floor {
                    let gap = messages[sorted[j]].date.timeIntervalSince(messages[sorted[i]].date)
                    if gap > subjectFallbackWindow { break }
                    if !people[i].isDisjoint(with: people[j]) {
                        uf.union(sorted[i], sorted[j])
                        break
                    }
                    i -= 1
                }
            }
        }

        var groups: [Int: [Int]] = [:]
        for index in 0..<count { groups[uf.find(index), default: []].append(index) }

        var result: [Conversation] = []
        result.reserveCapacity(groups.count)
        for (_, members) in groups {
            var group = members.map { messages[$0] }
            group.sort { lhs, rhs in
                if lhs.date != rhs.date { return lhs.date < rhs.date }
                return lhs.id < rhs.id
            }
            let key = conversationKey(for: group, accountID: accountID)
            for i in group.indices { group[i].threadKey = key }
            result.append(Conversation(id: key, messages: group))
        }
        return result
    }

    /// The stable ID for a group sorted oldest first.
    static func conversationKey(for group: [MessageSummary], accountID: String) -> String {
        if let thread = group.lazy.compactMap(\.gmailThreadID).first {
            return "\(accountID)|gm:\(thread)"
        }
        guard let oldest = group.first else { return "\(accountID)|empty" }
        let candidates = [oldest.references.first, oldest.inReplyTo.first, oldest.messageID]
        for candidate in candidates {
            if let candidate {
                let id = normalizeID(candidate)
                if !id.isEmpty { return "\(accountID)|\(id)" }
            }
        }
        return "\(accountID)|uid:\(oldest.mailboxPath)|\(oldest.uidValidity)|\(oldest.uid)"
    }

    /// Lowercased, without angle brackets or surrounding whitespace.
    static func normalizeID(_ raw: String) -> String {
        var id = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if id.hasPrefix("<") { id.removeFirst() }
        if id.hasSuffix(">") { id.removeLast() }
        return id.trimmingCharacters(in: .whitespaces).lowercased()
    }

    private static func participants(of message: MessageSummary, excluding me: Set<String>) -> Set<String> {
        var set = Set<String>()
        for address in message.from + message.to + message.cc {
            let normalized = address.normalized
            if !normalized.isEmpty && !me.contains(normalized) { set.insert(normalized) }
        }
        return set
    }
}

/// Union-find with path halving and union by size.
struct UnionFind {
    private var parent: [Int]
    private var size: [Int]

    init(count: Int) {
        parent = Array(0..<count)
        size = Array(repeating: 1, count: count)
    }

    mutating func find(_ x: Int) -> Int {
        var x = x
        while parent[x] != x {
            parent[x] = parent[parent[x]]
            x = parent[x]
        }
        return x
    }

    mutating func union(_ a: Int, _ b: Int) {
        var ra = find(a), rb = find(b)
        guard ra != rb else { return }
        if size[ra] < size[rb] { swap(&ra, &rb) }
        parent[rb] = ra
        size[ra] += size[rb]
    }
}
