import Foundation

/// A SEARCH program. Top-level criteria are ANDed; strings become quoted strings or literals,
/// and anything non-ASCII makes the command `SEARCH CHARSET UTF-8 …`.
///
///     .and([.since(lastWeek), .unseen, .or(.from("ada"), .subject("ada"))])
///     // SINCE 13-Oct-2026 UNSEEN OR FROM "ada" SUBJECT "ada"
public indirect enum IMAPSearchCriteria: Sendable, Hashable {
    case all
    /// `UID <set>`.
    case uid(IMAPSequenceSet)
    /// A bare sequence set.
    case sequence(IMAPSequenceSet)
    /// Internal date on or after the (UTC) day.
    case since(Date)
    case before(Date)
    case on(Date)
    /// Date header on or after the (UTC) day.
    case sentSince(Date)
    case sentBefore(Date)
    case seen
    case unseen
    case flagged
    case unflagged
    case answered
    case unanswered
    case deleted
    case undeleted
    case draft
    case undraft
    case keyword(String)
    case unkeyword(String)
    /// `HEADER name value` (an empty value matches any message that has the header).
    case header(String, String)
    case from(String)
    case to(String)
    case cc(String)
    case bcc(String)
    case subject(String)
    case body(String)
    case text(String)
    case larger(Int)
    case smaller(Int)
    /// CONDSTORE `MODSEQ n`.
    case modSeq(UInt64)
    /// Gmail `X-GM-RAW`: Gmail's own search syntax (`from:ada has:attachment`).
    case gmailRaw(String)
    case gmailMessageID(UInt64)
    case gmailThreadID(UInt64)
    case or(IMAPSearchCriteria, IMAPSearchCriteria)
    case and([IMAPSearchCriteria])
    case not(IMAPSearchCriteria)

    /// ORs any number of criteria (`OR a OR b c`); empty means ALL.
    public static func anyOf(_ criteria: [IMAPSearchCriteria]) -> IMAPSearchCriteria {
        guard var result = criteria.last else { return .all }
        for item in criteria.dropLast().reversed() { result = .or(item, result) }
        return result
    }

    /// True when any string argument has non-ASCII characters.
    public var requiresUTF8: Bool {
        switch self {
        case .keyword(let s), .unkeyword(let s), .from(let s), .to(let s), .cc(let s), .bcc(let s),
             .subject(let s), .body(let s), .text(let s), .gmailRaw(let s):
            return !s.utf8.allSatisfy { $0 < 0x80 }
        case .header(let name, let value):
            return !(name + value).utf8.allSatisfy { $0 < 0x80 }
        case .or(let a, let b):
            return a.requiresUTF8 || b.requiresUTF8
        case .and(let items):
            return items.contains(where: \.requiresUTF8)
        case .not(let inner):
            return inner.requiresUTF8
        default:
            return false
        }
    }

    /// True when the criteria use Gmail-only keys.
    public var requiresGmail: Bool {
        switch self {
        case .gmailRaw, .gmailMessageID, .gmailThreadID: return true
        case .or(let a, let b): return a.requiresGmail || b.requiresGmail
        case .and(let items): return items.contains(where: \.requiresGmail)
        case .not(let inner): return inner.requiresGmail
        default: return false
        }
    }

    /// Appends the search keys (without `SEARCH` / `CHARSET`).
    public func encode(into builder: inout IMAPCommandBuilder) {
        encode(into: &builder, nested: false)
    }

    private func encode(into builder: inout IMAPCommandBuilder, nested: Bool) {
        switch self {
        case .all: builder.raw("ALL")
        case .uid(let set): builder.raw(set.isEmpty ? "UID 0" : "UID \(set)")
        case .sequence(let set): builder.raw(set.isEmpty ? "0" : set.description)
        case .since(let date): builder.raw("SINCE \(IMAPDate.formatSearchDate(date))")
        case .before(let date): builder.raw("BEFORE \(IMAPDate.formatSearchDate(date))")
        case .on(let date): builder.raw("ON \(IMAPDate.formatSearchDate(date))")
        case .sentSince(let date): builder.raw("SENTSINCE \(IMAPDate.formatSearchDate(date))")
        case .sentBefore(let date): builder.raw("SENTBEFORE \(IMAPDate.formatSearchDate(date))")
        case .seen: builder.raw("SEEN")
        case .unseen: builder.raw("UNSEEN")
        case .flagged: builder.raw("FLAGGED")
        case .unflagged: builder.raw("UNFLAGGED")
        case .answered: builder.raw("ANSWERED")
        case .unanswered: builder.raw("UNANSWERED")
        case .deleted: builder.raw("DELETED")
        case .undeleted: builder.raw("UNDELETED")
        case .draft: builder.raw("DRAFT")
        case .undraft: builder.raw("UNDRAFT")
        case .keyword(let keyword):
            builder.raw("KEYWORD ")
            builder.astring(keyword)
        case .unkeyword(let keyword):
            builder.raw("UNKEYWORD ")
            builder.astring(keyword)
        case .header(let name, let value):
            builder.raw("HEADER ")
            builder.astring(name)
            builder.space()
            builder.string(value)
        case .from(let value): keyed("FROM", value, &builder)
        case .to(let value): keyed("TO", value, &builder)
        case .cc(let value): keyed("CC", value, &builder)
        case .bcc(let value): keyed("BCC", value, &builder)
        case .subject(let value): keyed("SUBJECT", value, &builder)
        case .body(let value): keyed("BODY", value, &builder)
        case .text(let value): keyed("TEXT", value, &builder)
        case .gmailRaw(let value): keyed("X-GM-RAW", value, &builder)
        case .larger(let size): builder.raw("LARGER \(max(0, size))")
        case .smaller(let size): builder.raw("SMALLER \(max(0, size))")
        case .modSeq(let value): builder.raw("MODSEQ \(value)")
        case .gmailMessageID(let id): builder.raw("X-GM-MSGID \(id)")
        case .gmailThreadID(let id): builder.raw("X-GM-THRID \(id)")
        case .or(let a, let b):
            builder.raw("OR ")
            a.encode(into: &builder, nested: true)
            builder.space()
            b.encode(into: &builder, nested: true)
        case .not(let inner):
            builder.raw("NOT ")
            inner.encode(into: &builder, nested: true)
        case .and(let items):
            switch items.count {
            case 0:
                builder.raw("ALL")
            case 1:
                items[0].encode(into: &builder, nested: nested)
            default:
                if nested { builder.raw("(") }
                for (index, item) in items.enumerated() {
                    if index > 0 { builder.space() }
                    item.encode(into: &builder, nested: false)
                }
                if nested { builder.raw(")") }
            }
        }
    }

    private func keyed(_ key: String, _ value: String, _ builder: inout IMAPCommandBuilder) {
        builder.raw(key)
        builder.space()
        builder.string(value)
    }
}
