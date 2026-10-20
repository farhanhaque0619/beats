import Foundation

/// A set of message sequence numbers or UIDs in IMAP wire form, e.g. `1:5,9,12:*`.
///
/// Build one from numbers (runs are compressed automatically), from a range, or with
/// `from(_:)` / `.all` for open-ended sets. `description` is the wire form.
public struct IMAPSequenceSet: Hashable, Sendable, CustomStringConvertible {
    /// One comma-separated element of a set.
    public enum Element: Hashable, Sendable {
        /// A single number, `n`.
        case number(UInt32)
        /// A closed range `a:b`, kept in the order written (IMAP treats `4:2` like `2:4`).
        case range(UInt32, UInt32)
        /// `n:*`, from `n` to the highest number in the mailbox.
        case rangeToLast(UInt32)
        /// `*`, the highest number in the mailbox.
        case last

        var wire: String {
            switch self {
            case .number(let n): return String(n)
            case .range(let a, let b): return a == b ? String(a) : "\(a):\(b)"
            case .rangeToLast(let n): return "\(n):*"
            case .last: return "*"
            }
        }
    }

    /// The elements in wire order.
    public var elements: [Element]

    /// A set made of the given elements, as written.
    public init(elements: [Element]) {
        self.elements = elements
    }

    /// The given numbers sorted, de-duplicated and compressed into runs: `[5, 1, 2, 3, 9]`
    /// becomes `1:3,5,9`. Zero (never a valid sequence number or UID) is dropped.
    public init<S: Sequence>(_ numbers: S) where S.Element == UInt32 {
        let sorted = Set(numbers).filter { $0 != 0 }.sorted()
        var elements: [Element] = []
        var index = 0
        while index < sorted.count {
            let first = sorted[index]
            var last = first
            while index + 1 < sorted.count, sorted[index + 1] == last &+ 1 {
                index += 1
                last = sorted[index]
            }
            elements.append(first == last ? .number(first) : .range(first, last))
            index += 1
        }
        self.elements = elements
    }

    /// A closed range, e.g. `100...200` → `100:200`.
    public init(_ range: ClosedRange<UInt32>) {
        let lower = max(range.lowerBound, 1)
        let upper = range.upperBound
        if upper < lower {
            elements = []
        } else {
            elements = [lower == upper ? .number(lower) : .range(lower, upper)]
        }
    }

    /// A single number.
    public init(_ number: UInt32) {
        elements = number == 0 ? [] : [.number(number)]
    }

    /// Parses a wire-form set such as `1:5,9,12:*`. Returns nil for an empty or malformed set.
    public init?(_ wire: String) {
        let trimmed = wire.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        var elements: [Element] = []
        for piece in trimmed.split(separator: ",", omittingEmptySubsequences: false) {
            let sides = piece.split(separator: ":", omittingEmptySubsequences: false)
            switch sides.count {
            case 1:
                if sides[0] == "*" {
                    elements.append(.last)
                } else if let n = UInt32(sides[0]) {
                    elements.append(.number(n))
                } else {
                    return nil
                }
            case 2:
                let a = sides[0] == "*" ? nil : UInt32(sides[0])
                let b = sides[1] == "*" ? nil : UInt32(sides[1])
                let aIsStar = sides[0] == "*"
                let bIsStar = sides[1] == "*"
                switch (a, b, aIsStar, bIsStar) {
                case let (a?, b?, _, _): elements.append(.range(a, b))
                case let (a?, nil, _, true): elements.append(.rangeToLast(a))
                case let (nil, b?, true, _): elements.append(.rangeToLast(b))
                case (nil, nil, true, true): elements.append(.last)
                default: return nil
                }
            default:
                return nil
            }
        }
        self.elements = elements
    }

    /// `n:*`.
    public static func from(_ number: UInt32) -> IMAPSequenceSet {
        IMAPSequenceSet(elements: [.rangeToLast(max(number, 1))])
    }

    /// `1:*`, every message.
    public static let all = IMAPSequenceSet(elements: [.rangeToLast(1)])

    /// `*`, the last message.
    public static let last = IMAPSequenceSet(elements: [.last])

    /// The wire form, e.g. `1:5,9,12:*`.
    public var description: String {
        elements.map(\.wire).joined(separator: ",")
    }

    /// True for a set with no elements (never sent: commands with an empty set are skipped).
    public var isEmpty: Bool { elements.isEmpty }

    /// True when the set refers to `*` and so can't be expanded without knowing the mailbox.
    public var containsLast: Bool {
        elements.contains { element in
            switch element {
            case .last, .rangeToLast: return true
            case .number, .range: return false
            }
        }
    }

    /// Number of members, or nil when the set contains `*`.
    public var count: Int? {
        var total = 0
        for element in elements {
            switch element {
            case .number: total += 1
            case .range(let a, let b): total += Int(max(a, b) - min(a, b)) + 1
            case .rangeToLast, .last: return nil
            }
        }
        return total
    }

    /// Whether `number` is in the set. `*` elements are treated as unbounded above.
    public func contains(_ number: UInt32) -> Bool {
        elements.contains { element in
            switch element {
            case .number(let n): return n == number
            case .range(let a, let b): return number >= min(a, b) && number <= max(a, b)
            case .rangeToLast(let n): return number >= n
            case .last: return false
            }
        }
    }

    /// The members in wire order (ranges ascend or descend as written). `*` elements are
    /// skipped. Stops after `limit` numbers so a hostile `1:4294967295` can't exhaust memory.
    public func expanded(limit: Int = 10_000_000) -> [UInt32] {
        var result: [UInt32] = []
        for element in elements {
            guard result.count < limit else { break }
            switch element {
            case .number(let n):
                result.append(n)
            case .range(let a, let b):
                let room = UInt32(clamping: limit - result.count)
                if a <= b {
                    let upper = b - a >= room ? a + (room - 1) : b
                    result.append(contentsOf: a...upper)
                } else {
                    let lower = a - b >= room ? a - (room - 1) : b
                    result.append(contentsOf: (lower...a).reversed())
                }
            case .rangeToLast, .last:
                continue
            }
        }
        return result
    }
}
