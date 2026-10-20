import Foundation
import InkModel

/// Something to FETCH.
public enum IMAPFetchItem: Sendable, Hashable, CustomStringConvertible {
    case uid
    case flags
    case internalDate
    case rfc822Size
    case envelope
    case bodyStructure
    /// `BODY.PEEK[section]<origin.length>` (doesn't set `\Seen`). `section` is e.g. `""` for the
    /// whole message, `"1.2"`, `"HEADER"`, `"TEXT"`, `"1.MIME"`; `partial` is (origin, length).
    case bodyPeek(section: String, partial: (Int, Int)?)
    /// `BODY[section]<origin.length>`: like `bodyPeek` but marks the message `\Seen`.
    case body(section: String, partial: (Int, Int)?)
    /// `BODY.PEEK[HEADER.FIELDS (A B)]` with the names uppercased.
    case headerFields([String])
    /// `BODY.PEEK[HEADER.FIELDS.NOT (A B)]`.
    case headerFieldsNot([String])
    /// Gmail `X-GM-THRID`.
    case gmailThreadID
    /// Gmail `X-GM-MSGID`.
    case gmailMessageID
    /// Gmail `X-GM-LABELS`.
    case gmailLabels
    /// CONDSTORE `MODSEQ`.
    case modSeq
    /// OBJECTID (RFC 8474) `EMAILID`.
    case emailID
    /// OBJECTID (RFC 8474) `THREADID`.
    case threadID
    /// `PREVIEW` (RFC 8970): a server-made text preview.
    case preview

    /// The item as written in a FETCH command.
    public var wire: String {
        switch self {
        case .uid: return "UID"
        case .flags: return "FLAGS"
        case .internalDate: return "INTERNALDATE"
        case .rfc822Size: return "RFC822.SIZE"
        case .envelope: return "ENVELOPE"
        case .bodyStructure: return "BODYSTRUCTURE"
        case .bodyPeek(let section, let partial):
            return "BODY.PEEK[\(section)]" + Self.partialSuffix(partial)
        case .body(let section, let partial):
            return "BODY[\(section)]" + Self.partialSuffix(partial)
        case .headerFields(let names):
            return "BODY.PEEK[\(Self.headerFieldsSection("HEADER.FIELDS", names))]"
        case .headerFieldsNot(let names):
            return "BODY.PEEK[\(Self.headerFieldsSection("HEADER.FIELDS.NOT", names))]"
        case .gmailThreadID: return "X-GM-THRID"
        case .gmailMessageID: return "X-GM-MSGID"
        case .gmailLabels: return "X-GM-LABELS"
        case .modSeq: return "MODSEQ"
        case .emailID: return "EMAILID"
        case .threadID: return "THREADID"
        case .preview: return "PREVIEW"
        }
    }

    public var description: String { wire }

    /// For body-section items, the key its data is stored under in `IMAPFetchResponse.sections`.
    public var sectionKey: String? {
        switch self {
        case .bodyPeek(let section, _), .body(let section, _):
            return IMAPFetchResponse.sectionKey(section)
        case .headerFields(let names):
            return IMAPFetchResponse.sectionKey(Self.headerFieldsSection("HEADER.FIELDS", names))
        case .headerFieldsNot(let names):
            return IMAPFetchResponse.sectionKey(Self.headerFieldsSection("HEADER.FIELDS.NOT", names))
        default:
            return nil
        }
    }

    public static func == (lhs: IMAPFetchItem, rhs: IMAPFetchItem) -> Bool { lhs.wire == rhs.wire }
    public func hash(into hasher: inout Hasher) { hasher.combine(wire) }

    private static func partialSuffix(_ partial: (Int, Int)?) -> String {
        guard let (origin, length) = partial else { return "" }
        return "<\(max(0, origin)).\(max(1, length))>"
    }

    static func headerFieldsSection(_ kind: String, _ names: [String]) -> String {
        let encoded = names.compactMap { name -> String? in
            let upper = name.trimmingCharacters(in: .whitespaces).uppercased()
            guard !upper.isEmpty else { return nil }
            return IMAPEncoder.isAtom(upper) ? upper : IMAPEncoder.quoted(upper)
        }
        return "\(kind) (\(encoded.joined(separator: " ")))"
    }
}

/// The answers to one FETCH, and whether the server answered all of it
/// (`IMAPClient.fetchReportingCompleteness`).
public struct IMAPFetchOutcome: Hashable, Sendable {
    /// One merged response per message, in the order the server sent them.
    public var responses: [IMAPFetchResponse]
    /// True when the command completed with OK, or with NO `[EXPUNGEISSUED]` (what's missing
    /// was expunged). False when the server answered NO after sending only part of the data:
    /// then a message missing from `responses` may still exist.
    public var isComplete: Bool

    public init(responses: [IMAPFetchResponse], isComplete: Bool) {
        self.responses = responses
        self.isComplete = isComplete
    }
}

/// Everything one FETCH response said about a message. Attributes that weren't sent are nil.
public struct IMAPFetchResponse: Hashable, Sendable {
    /// Message sequence number.
    public var seq: UInt32
    /// UID; always present in answers to UID FETCH.
    public var uid: UInt32?
    /// FLAGS as sent (`\Seen`, `$Forwarded`, …); nil when not fetched, `[]` when none are set.
    public var flags: [String]?
    /// INTERNALDATE: when the server received the message.
    public var internalDate: Date?
    /// RFC822.SIZE in bytes.
    public var size: Int?
    /// ENVELOPE, raw (strings not RFC 2047-decoded).
    public var envelope: IMAPEnvelope?
    /// BODYSTRUCTURE (or BODY), with section numbers on every part.
    public var bodyStructure: BodyStructure?
    /// Body sections keyed by `IMAPFetchResponse.sectionKey(spec)`: the section as requested,
    /// uppercased with quotes and extra spaces removed — `"1.2"`, `"HEADER.FIELDS (REFERENCES)"`,
    /// `""` for the whole message. `RFC822`, `RFC822.HEADER` and `RFC822.TEXT` are stored as
    /// `""`, `"HEADER"` and `"TEXT"`. Use `section(_:)` to look up with any spelling.
    public var sections: [String: Data]
    /// The origin a partial section started at (`BODY[1]<0>`), by section key.
    public var sectionOrigins: [String: Int]
    /// Gmail `X-GM-THRID`: the conversation id.
    public var gmailThreadID: UInt64?
    /// Gmail `X-GM-MSGID`: the same in every label (mailbox) the message appears in.
    public var gmailMessageID: UInt64?
    /// Gmail labels as sent (`\Inbox`, `\Important`, label names in modified UTF-7).
    public var gmailLabels: [String]?
    /// CONDSTORE mod-sequence of the message's last change.
    public var modSeq: UInt64?
    /// OBJECTID `EMAILID` (RFC 8474).
    public var emailID: String?
    /// OBJECTID `THREADID` (RFC 8474).
    public var threadID: String?
    /// Server-made preview text (RFC 8970 `PREVIEW`).
    public var preview: String?

    public init(seq: UInt32, uid: UInt32? = nil, flags: [String]? = nil, internalDate: Date? = nil, size: Int? = nil,
                envelope: IMAPEnvelope? = nil, bodyStructure: BodyStructure? = nil, sections: [String: Data] = [:],
                sectionOrigins: [String: Int] = [:], gmailThreadID: UInt64? = nil, gmailMessageID: UInt64? = nil,
                gmailLabels: [String]? = nil, modSeq: UInt64? = nil, emailID: String? = nil, threadID: String? = nil,
                preview: String? = nil) {
        self.seq = seq
        self.uid = uid
        self.flags = flags
        self.internalDate = internalDate
        self.size = size
        self.envelope = envelope
        self.bodyStructure = bodyStructure
        self.sections = sections
        self.sectionOrigins = sectionOrigins
        self.gmailThreadID = gmailThreadID
        self.gmailMessageID = gmailMessageID
        self.gmailLabels = gmailLabels
        self.modSeq = modSeq
        self.emailID = emailID
        self.threadID = threadID
        self.preview = preview
    }

    /// Data for a body section, however the section is spelled (`"header.fields (References)"`
    /// finds `HEADER.FIELDS (REFERENCES)`).
    public func section(_ spec: String) -> Data? {
        sections[Self.sectionKey(spec)]
    }

    /// The flags as `MessageFlags` (empty when FLAGS wasn't fetched).
    public var messageFlags: MessageFlags { MessageFlags(imapFlags: flags ?? []) }

    /// Gmail labels decoded from modified UTF-7 for display.
    public var decodedGmailLabels: [String] { (gmailLabels ?? []).map(ModifiedUTF7.decode) }

    /// Folds a second FETCH response for the same message into this one (servers may split
    /// attributes across several responses).
    public mutating func merge(_ other: IMAPFetchResponse) {
        uid = other.uid ?? uid
        flags = other.flags ?? flags
        internalDate = other.internalDate ?? internalDate
        size = other.size ?? size
        envelope = other.envelope ?? envelope
        bodyStructure = other.bodyStructure ?? bodyStructure
        sections.merge(other.sections) { _, new in new }
        sectionOrigins.merge(other.sectionOrigins) { _, new in new }
        gmailThreadID = other.gmailThreadID ?? gmailThreadID
        gmailMessageID = other.gmailMessageID ?? gmailMessageID
        gmailLabels = other.gmailLabels ?? gmailLabels
        modSeq = other.modSeq ?? modSeq
        emailID = other.emailID ?? emailID
        threadID = other.threadID ?? threadID
        preview = other.preview ?? preview
    }

    /// Canonical form of a section spec: uppercased, quotes dropped, whitespace collapsed and
    /// trimmed inside parentheses. `"header.fields ( \"From\"  To )"` → `"HEADER.FIELDS (FROM TO)"`.
    ///
    /// Works on Unicode scalars, not Characters: Swift treats `"\r\n"` as one Character, which
    /// would match neither `"\r"` nor `"\n"`.
    public static func sectionKey(_ spec: String) -> String {
        var output = String.UnicodeScalarView()
        var pendingSpace = false
        for scalar in spec.uppercased().unicodeScalars {
            switch scalar {
            case "\"":
                continue
            case " ", "\t", "\r", "\n":
                pendingSpace = true
            case ")":
                pendingSpace = false
                output.append(scalar)
            default:
                if pendingSpace, let last = output.last, last != "(" { output.append(" ") }
                pendingSpace = false
                output.append(scalar)
            }
        }
        return String(output)
    }
}
