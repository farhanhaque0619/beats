import Foundation

/// A mailbox address with an optional display name, e.g. `Ada Lovelace <ada@example.com>`.
///
/// Equality and hashing use the lowercased address only, so the same person written with
/// different display names collapses to one participant.
public struct EmailAddress: Codable, Sendable, CustomStringConvertible {
    public var name: String?
    public var address: String

    public init(name: String? = nil, address: String) {
        let trimmedName = name?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.name = (trimmedName?.isEmpty ?? true) ? nil : trimmedName
        self.address = address.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Lowercased address, used for comparisons.
    public var normalized: String { address.lowercased() }

    public var localPart: String {
        guard let at = address.lastIndex(of: "@") else { return address }
        return String(address[..<at])
    }

    public var domain: String {
        guard let at = address.lastIndex(of: "@") else { return "" }
        return String(address[address.index(after: at)...]).lowercased()
    }

    /// The name to show in lists: the display name, else the local part of the address.
    public var displayName: String {
        if let name, !name.isEmpty, name != address { return name }
        return localPart
    }

    /// First word of the display name ("Ada" for "Ada Lovelace").
    public var firstName: String {
        let base = displayName
        return base.split(whereSeparator: { $0 == " " || $0 == "," }).first.map(String.init) ?? base
    }

    /// Up to two uppercase initials for an avatar.
    public var initials: String {
        let words = displayName
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .filter { !$0.isEmpty }
        let letters: [Character]
        if words.count >= 2 {
            letters = [words[0].first!, words[words.count - 1].first!]
        } else if let first = words.first?.first {
            letters = [first]
        } else {
            letters = ["?"]
        }
        return String(letters).uppercased()
    }

    /// `Name <address>` with the name quoted when it contains specials, or just the address.
    /// Not MIME-encoded; header encoding of non-ASCII names happens in InkMIME.
    public var formatted: String {
        guard let name, !name.isEmpty else { return address }
        let specials = CharacterSet(charactersIn: "()<>[]:;@\\,.\"")
        if name.unicodeScalars.contains(where: { specials.contains($0) }) {
            let escaped = name.replacingOccurrences(of: "\\", with: "\\\\").replacingOccurrences(of: "\"", with: "\\\"")
            return "\"\(escaped)\" <\(address)>"
        }
        return "\(name) <\(address)>"
    }

    public var description: String { formatted }

    /// True when the address looks like `local@domain.tld`.
    public var isValid: Bool {
        let parts = address.split(separator: "@", omittingEmptySubsequences: false)
        guard parts.count == 2, !parts[0].isEmpty, parts[1].contains("."),
              !parts[1].hasPrefix("."), !parts[1].hasSuffix("."),
              !address.contains(" ") else { return false }
        return true
    }

    /// Senders that are clearly automated (noreply@, notifications@, ...).
    public var looksAutomated: Bool {
        let local = localPart.lowercased()
        let markers = ["noreply", "no-reply", "donotreply", "do-not-reply", "notifications", "notification",
                       "mailer-daemon", "newsletter", "news", "updates", "alerts", "info", "hello", "team", "support", "billing", "receipts"]
        return markers.contains(where: { local == $0 || local.hasPrefix($0 + "+") || local.hasPrefix($0 + "-") || local.hasPrefix($0 + ".") })
            || local.contains("noreply") || local.contains("no-reply")
    }
}

extension EmailAddress: Hashable {
    public static func == (lhs: EmailAddress, rhs: EmailAddress) -> Bool { lhs.normalized == rhs.normalized }
    public func hash(into hasher: inout Hasher) { hasher.combine(normalized) }
}

extension Array where Element == EmailAddress {
    /// Removes duplicate addresses (case-insensitive), keeping the first occurrence.
    public func uniqued() -> [EmailAddress] {
        var seen = Set<String>()
        return filter { seen.insert($0.normalized).inserted }
    }

    /// "Ada, Grace & 2 others" style summary.
    public func shortList(maxNames: Int = 2) -> String {
        let names = map(\.firstName)
        guard !names.isEmpty else { return "" }
        if names.count <= maxNames { return ListFormatterLite.join(names) }
        let shown = names.prefix(maxNames).joined(separator: ", ")
        return "\(shown) & \(names.count - maxNames) more"
    }
}

/// Minimal English list joining ("a", "a & b", "a, b & c") that behaves the same on every platform.
public enum ListFormatterLite {
    public static func join(_ items: [String]) -> String {
        switch items.count {
        case 0: return ""
        case 1: return items[0]
        default: return items.dropLast().joined(separator: ", ") + " & " + items[items.count - 1]
        }
    }
}
