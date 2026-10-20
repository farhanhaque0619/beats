import Foundation
import InkModel

/// People you've exchanged mail with, ranked for address autocompletion.
///
/// Built from the From/To/Cc of cached mail. Every appearance adds to an address's score, scaled
/// by how recent the message is (half-life of 45 days, with a floor so old regulars still
/// count). Mail you sent counts most: recipients of your messages get 3 points, senders of mail you
/// received 1, and others copied on it 0.5. Your own addresses are left out, and so are
/// automated senders (noreply@, notifications@ …) unless you've written to them yourself.
public struct ContactIndex: Sendable {
    /// One ranked person.
    public struct Entry: Sendable, Hashable {
        public var address: EmailAddress
        public var score: Double
        public var lastSeen: Date
        /// Number of messages the address appeared on.
        public var count: Int
    }

    /// Entries, best first.
    public private(set) var entries: [Entry]
    private var tokens: [[String]]

    public static let sentWeight = 3.0
    public static let fromWeight = 1.0
    public static let copiedWeight = 0.5
    public static let halfLifeDays = 45.0

    public init(messages: [MessageSummary], myAddresses: Set<String>, now: Date = Date()) {
        let me = Set(myAddresses.map { $0.lowercased() })
        struct Accumulator {
            var address: EmailAddress
            var nameDate: Date
            var score: Double = 0
            var lastSeen: Date
            var count = 0
            var wroteTo = false
        }
        var table: [String: Accumulator] = [:]
        var seenMessages = Set<String>()

        func add(_ address: EmailAddress, weight: Double, date: Date, recency: Double, wroteTo: Bool) {
            let key = address.normalized
            guard !key.isEmpty, address.isValid, !me.contains(key) else { return }
            var entry = table[key] ?? Accumulator(address: address, nameDate: .distantPast, lastSeen: date)
            entry.score += weight * recency
            entry.count += 1
            if date > entry.lastSeen { entry.lastSeen = date }
            // Prefer the most recent non-empty display name.
            if let name = address.name, !name.isEmpty, date >= entry.nameDate {
                entry.address = EmailAddress(name: name, address: entry.address.address)
                entry.nameDate = date
            }
            if wroteTo { entry.wroteTo = true }
            table[key] = entry
        }

        for message in messages {
            // Each message once, even when it has copies in several mailboxes.
            guard seenMessages.insert(message.dedupeKey).inserted else { continue }
            let ageDays = max(0, now.timeIntervalSince(message.date) / 86_400)
            let recency = 0.25 + 0.75 * pow(0.5, ageDays / Self.halfLifeDays)
            let fromMe = message.from.contains { me.contains($0.normalized) }
            if fromMe {
                for address in (message.to + message.cc + message.bcc).uniqued() {
                    add(address, weight: Self.sentWeight, date: message.date, recency: recency, wroteTo: true)
                }
            } else {
                for address in message.from.uniqued() {
                    add(address, weight: Self.fromWeight, date: message.date, recency: recency, wroteTo: false)
                }
                for address in (message.to + message.cc).uniqued() {
                    add(address, weight: Self.copiedWeight, date: message.date, recency: recency, wroteTo: false)
                }
            }
        }

        var entries = table.values
            .filter { $0.wroteTo || !$0.address.looksAutomated }
            .map { Entry(address: $0.address, score: $0.score, lastSeen: $0.lastSeen, count: $0.count) }
        entries.sort { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.lastSeen != rhs.lastSeen { return lhs.lastSeen > rhs.lastSeen }
            return lhs.address.normalized < rhs.address.normalized
        }
        self.entries = entries
        self.tokens = entries.map(Self.searchTokens(for:))
    }

    /// Best matches for what the user typed: a prefix of any word of the name, of the address,
    /// or of the domain. An empty prefix returns the top contacts.
    public func suggestions(matching prefix: String, limit: Int = 6, excluding excluded: Set<String> = []) -> [EmailAddress] {
        guard limit > 0 else { return [] }
        let needle = Self.fold(prefix.trimmingCharacters(in: .whitespacesAndNewlines))
        var result: [EmailAddress] = []
        for (index, entry) in entries.enumerated() {
            if excluded.contains(entry.address.normalized) { continue }
            if needle.isEmpty || tokens[index].contains(where: { $0.hasPrefix(needle) }) {
                result.append(entry.address)
                if result.count == limit { break }
            }
        }
        return result
    }

    private static func searchTokens(for entry: Entry) -> [String] {
        var tokens: [String] = []
        let address = entry.address.normalized
        tokens.append(address)
        tokens.append(fold(entry.address.domain))
        if let name = entry.address.name {
            let folded = fold(name)
            tokens.append(folded)
            tokens += folded.split(whereSeparator: { !$0.isLetter && !$0.isNumber }).map(String.init)
        }
        tokens += address.split(whereSeparator: { $0 == "." || $0 == "_" || $0 == "-" || $0 == "+" || $0 == "@" }).map(String.init)
        return tokens
    }

    /// Lowercased, accents removed ("José" → "jose").
    static func fold(_ s: String) -> String {
        s.folding(options: [.caseInsensitive, .diacriticInsensitive, .widthInsensitive], locale: Locale(identifier: "en_US_POSIX"))
    }
}
