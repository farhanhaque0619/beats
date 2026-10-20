import Foundation
import InkModel

// MARK: - Mailboxes

/// A mailbox (folder, or Gmail label) from a LIST, XLIST or LSUB response.
public struct IMAPMailbox: Hashable, Sendable {
    /// The name exactly as the server sent it (modified UTF-7 unless UTF8=ACCEPT is enabled).
    /// Use this on the wire.
    public var rawName: String
    /// The name decoded to Unicode, for display.
    public var name: String
    /// Hierarchy delimiter such as `/` or `.`; nil for a flat namespace.
    public var delimiter: String?
    /// LIST attributes as sent, e.g. `\HasNoChildren`, `\Noselect`, `\Sent`.
    public var attributes: [String]
    /// Role from SPECIAL-USE attributes (RFC 6154) or Gmail's older XLIST ones; `.inbox` for INBOX.
    public var specialUse: MailboxRole?

    public init(rawName: String, name: String? = nil, delimiter: String?, attributes: [String], specialUse: MailboxRole? = nil) {
        self.rawName = rawName
        self.name = name ?? ModifiedUTF7.decode(rawName)
        self.delimiter = delimiter
        self.attributes = attributes
        self.specialUse = specialUse ?? IMAPMailbox.role(forAttributes: attributes, rawName: rawName)
    }

    /// Case-insensitive attribute check, e.g. `hasAttribute("\\Noselect")`.
    public func hasAttribute(_ attribute: String) -> Bool {
        attributes.contains { $0.caseInsensitiveCompare(attribute) == .orderedSame }
    }

    /// False for `\Noselect` / `\NonExistent` placeholders (e.g. Gmail's `[Gmail]` parent).
    public var isSelectable: Bool { !hasAttribute("\\Noselect") && !hasAttribute("\\NonExistent") }

    /// From `\HasChildren` / `\HasNoChildren` when the server reports it.
    public var hasChildren: Bool? {
        if hasAttribute("\\HasChildren") { return true }
        if hasAttribute("\\HasNoChildren") { return false }
        return nil
    }

    /// Maps LIST attributes to a role: RFC 6154 `\All \Archive \Drafts \Flagged \Junk \Sent \Trash`,
    /// Gmail XLIST `\AllMail \Spam \Starred \Inbox`, and the name INBOX (any case).
    public static func role(forAttributes attributes: [String], rawName: String) -> MailboxRole? {
        for attribute in attributes {
            switch attribute.lowercased() {
            case "\\all", "\\allmail": return .all
            case "\\archive": return .archive
            case "\\drafts": return .drafts
            case "\\flagged", "\\starred": return .flagged
            case "\\junk", "\\spam": return .junk
            case "\\sent": return .sent
            case "\\trash": return .trash
            case "\\inbox": return .inbox
            default: continue
            }
        }
        if rawName.caseInsensitiveCompare("INBOX") == .orderedSame { return .inbox }
        return nil
    }
}

/// What SELECT / EXAMINE reported about a mailbox.
public struct IMAPSelectInfo: Hashable, Sendable {
    /// The raw mailbox name that was selected.
    public var mailbox: String
    /// Number of messages (`* n EXISTS`); kept current by later EXISTS / EXPUNGE responses.
    public var exists: UInt32
    /// Messages new since the last session (`* n RECENT`; obsolete in IMAP4rev2).
    public var recent: UInt32
    /// UIDVALIDITY, or 0 if the server didn't send one.
    public var uidValidity: UInt32
    /// UIDNEXT: the UID the next message will get; nil if the server didn't say.
    public var uidNext: UInt32?
    /// HIGHESTMODSEQ when CONDSTORE is active.
    public var highestModSeq: UInt64?
    /// Flags defined in the mailbox (`* FLAGS`).
    public var flags: [String]
    /// Flags the client may change permanently; `\*` means new keywords are allowed.
    public var permanentFlags: [String]
    /// Whether the server reported `[PERMANENTFLAGS]` at all. Without it, RFC 3501 says to
    /// assume every flag can be stored.
    public var hasPermanentFlags: Bool
    /// Opened with EXAMINE, or the server reported `[READ-ONLY]`.
    public var readOnly: Bool
    /// Sequence number of the first unseen message (`[UNSEEN n]`), if sent.
    public var firstUnseen: UInt32?
    /// The server said `[NOMODSEQ]`: this mailbox doesn't support mod-sequences.
    public var noModSeq: Bool

    public init(mailbox: String, exists: UInt32 = 0, recent: UInt32 = 0, uidValidity: UInt32 = 0, uidNext: UInt32? = nil,
                highestModSeq: UInt64? = nil, flags: [String] = [], permanentFlags: [String] = [], readOnly: Bool = false,
                firstUnseen: UInt32? = nil, noModSeq: Bool = false, hasPermanentFlags: Bool? = nil) {
        self.mailbox = mailbox
        self.exists = exists
        self.recent = recent
        self.uidValidity = uidValidity
        self.uidNext = uidNext
        self.highestModSeq = highestModSeq
        self.flags = flags
        self.permanentFlags = permanentFlags
        self.hasPermanentFlags = hasPermanentFlags ?? !permanentFlags.isEmpty
        self.readOnly = readOnly
        self.firstUnseen = firstUnseen
        self.noModSeq = noModSeq
    }
}

extension IMAPSelectInfo {
    /// PERMANENTFLAGS lists `\*`: the client may create new keywords.
    public var allowsNewKeywords: Bool { permanentFlags.contains("\\*") }

    /// Whether a keyword (a flag without a backslash, such as `$Forwarded` or `$Junk`) can be
    /// stored permanently here: PERMANENTFLAGS wasn't reported, or it lists `\*` or the keyword.
    /// Exchange lists neither, so custom keywords fail there (RESEARCH §3.4). System flags
    /// (`\Seen`, `\Deleted`, …) are always true.
    public func canStore(_ flag: String) -> Bool {
        if flag.utf8.first == UInt8(ascii: "\\") { return true }
        if !hasPermanentFlags || allowsNewKeywords { return true }
        return permanentFlags.contains { $0.caseInsensitiveCompare(flag) == .orderedSame }
    }
}

/// A STATUS response. Fields the server didn't send are nil.
public struct IMAPStatus: Hashable, Sendable {
    public var messages: UInt32?
    public var recent: UInt32?
    public var uidNext: UInt32?
    public var uidValidity: UInt32?
    public var unseen: UInt32?
    public var highestModSeq: UInt64?
    /// Total size in bytes (STATUS=SIZE, RFC 8438).
    public var size: UInt64?

    public init(messages: UInt32? = nil, recent: UInt32? = nil, uidNext: UInt32? = nil, uidValidity: UInt32? = nil,
                unseen: UInt32? = nil, highestModSeq: UInt64? = nil, size: UInt64? = nil) {
        self.messages = messages
        self.recent = recent
        self.uidNext = uidNext
        self.uidValidity = uidValidity
        self.unseen = unseen
        self.highestModSeq = highestModSeq
        self.size = size
    }
}

/// How STORE changes flags or labels.
public enum IMAPStoreMode: String, Sendable, CaseIterable {
    /// `+FLAGS`: add to the existing set.
    case add
    /// `-FLAGS`: remove from the existing set.
    case remove
    /// `FLAGS`: replace the whole set.
    case replace

    var prefix: String {
        switch self {
        case .add: return "+"
        case .remove: return "-"
        case .replace: return ""
        }
    }
}

/// Connection state of an `IMAPClient`.
public enum IMAPConnectionState: Sendable, Equatable {
    case disconnected
    case notAuthenticated
    case authenticated
}

// MARK: - Envelope

/// One address from an ENVELOPE, exactly as the server sent it (strings are not
/// RFC 2047-decoded; that's InkMIME's job).
///
/// RFC 3501 group syntax shows up as markers: a group start has a `mailbox` (the group name)
/// and no `host`; a group end has neither.
public struct IMAPAddress: Hashable, Sendable {
    public var name: String?
    /// Source route; obsolete, nearly always nil.
    public var adl: String?
    public var mailbox: String?
    public var host: String?

    public init(name: String? = nil, adl: String? = nil, mailbox: String? = nil, host: String? = nil) {
        self.name = name
        self.adl = adl
        self.mailbox = mailbox
        self.host = host
    }

    /// `mailbox@host`, or just the mailbox when there's no host. Nil for group markers.
    public var address: String? {
        guard !isGroupStart, !isGroupEnd, let mailbox else { return nil }
        guard let host, !host.isEmpty else { return mailbox }
        return "\(mailbox)@\(host)"
    }

    /// `(NIL NIL "group-name" NIL)`.
    public var isGroupStart: Bool { host == nil && mailbox != nil }
    /// `(NIL NIL NIL NIL)`.
    public var isGroupEnd: Bool { host == nil && mailbox == nil }
}

/// A parsed ENVELOPE. Strings are raw (encoded words left in place); addresses keep group markers.
public struct IMAPEnvelope: Hashable, Sendable {
    /// The Date header as sent.
    public var date: String?
    /// The Subject header as sent (may contain RFC 2047 encoded words).
    public var subject: String?
    public var from: [IMAPAddress]
    public var sender: [IMAPAddress]
    public var replyTo: [IMAPAddress]
    public var to: [IMAPAddress]
    public var cc: [IMAPAddress]
    public var bcc: [IMAPAddress]
    /// The In-Reply-To header as sent, e.g. `<abc@example.com>`.
    public var inReplyTo: String?
    /// The Message-ID header as sent, e.g. `<abc@example.com>`.
    public var messageID: String?

    public init(date: String? = nil, subject: String? = nil, from: [IMAPAddress] = [], sender: [IMAPAddress] = [],
                replyTo: [IMAPAddress] = [], to: [IMAPAddress] = [], cc: [IMAPAddress] = [], bcc: [IMAPAddress] = [],
                inReplyTo: String? = nil, messageID: String? = nil) {
        self.date = date
        self.subject = subject
        self.from = from
        self.sender = sender
        self.replyTo = replyTo
        self.to = to
        self.cc = cc
        self.bcc = bcc
        self.inReplyTo = inReplyTo
        self.messageID = messageID
    }
}

extension Array where Element == IMAPAddress {
    /// The real addresses, without group start/end markers.
    public var mailboxes: [IMAPAddress] { filter { !$0.isGroupStart && !$0.isGroupEnd } }
}

// MARK: - Responses

/// The status word of a tagged response.
public enum IMAPResponseStatus: String, Sendable, Hashable {
    case ok = "OK"
    case no = "NO"
    case bad = "BAD"
}

/// A bracketed response code such as `[UIDVALIDITY 3857529045]` or `[COPYUID 38505 304 3956]`.
public enum IMAPResponseCode: Hashable, Sendable {
    case alert
    case parse
    case readOnly
    case readWrite
    case tryCreate
    case noModSeq
    case uidNotSticky
    case closed
    case uidNext(UInt32)
    case uidValidity(UInt32)
    case unseen(UInt32)
    case highestModSeq(UInt64)
    case permanentFlags([String])
    case capability([String])
    case badCharset([String])
    /// UIDPLUS: UIDs of the source messages and of their copies, in matching order.
    case copyUID(uidValidity: UInt32, source: IMAPSequenceSet, destination: IMAPSequenceSet)
    /// UIDPLUS: UID(s) of the appended message(s).
    case appendUID(uidValidity: UInt32, uids: IMAPSequenceSet)
    case modified(IMAPSequenceSet)
    // RFC 5530
    case unavailable
    case authenticationFailed
    case authorizationFailed
    case expired
    case privacyRequired
    case contactAdmin
    case noPerm
    case inUse
    case expungeIssued
    case corruption
    case serverBug
    case clientBug
    case cannot
    case limit
    case overQuota
    case alreadyExists
    case nonExistent
    /// Any other code, with its arguments as raw text.
    case other(String, String?)
}

/// Response text with its optional code: `[ALERT] Your account is over quota`.
public struct IMAPResponseText: Hashable, Sendable {
    public var code: IMAPResponseCode?
    /// Human-readable text after the code.
    public var text: String

    public init(code: IMAPResponseCode? = nil, text: String) {
        self.code = code
        self.text = text
    }
}

/// The completion of a command: `A001 OK [READ-WRITE] SELECT completed`.
public struct IMAPTaggedResponse: Hashable, Sendable {
    public var tag: String
    public var status: IMAPResponseStatus
    public var text: IMAPResponseText

    public init(tag: String, status: IMAPResponseStatus, text: IMAPResponseText) {
        self.tag = tag
        self.status = status
        self.text = text
    }
}

/// An ESEARCH response (RFC 4731).
public struct IMAPESearchResponse: Hashable, Sendable {
    /// The command tag this answers, from `(TAG "A001")`.
    public var tag: String?
    /// True when the results are UIDs.
    public var isUID: Bool
    public var min: UInt32?
    public var max: UInt32?
    public var count: Int?
    public var all: IMAPSequenceSet?
    public var modSeq: UInt64?

    public init(tag: String? = nil, isUID: Bool = false, min: UInt32? = nil, max: UInt32? = nil, count: Int? = nil,
                all: IMAPSequenceSet? = nil, modSeq: UInt64? = nil) {
        self.tag = tag
        self.isUID = isUID
        self.min = min
        self.max = max
        self.count = count
        self.all = all
        self.modSeq = modSeq
    }
}

/// Server data that isn't the completion of a command (`* …` lines).
public enum IMAPUntagged: Hashable, Sendable {
    /// `* n EXISTS`: the mailbox now has n messages.
    case exists(UInt32)
    /// `* n EXPUNGE`: message n is gone (later numbers shift down).
    case expunge(UInt32)
    case recent(UInt32)
    case fetch(IMAPFetchResponse)
    /// QRESYNC: UIDs that are gone. `earlier` marks the replay in answer to a FETCH/SELECT.
    case vanished(IMAPSequenceSet, earlier: Bool)
    case flags([String])
    case capability([String])
    /// `* BYE`: the server is closing the connection.
    case bye(String)
    case ok(IMAPResponseText)
    case no(IMAPResponseText)
    case bad(IMAPResponseText)
    case preauth(IMAPResponseText)
    case list(IMAPMailbox)
    case lsub(IMAPMailbox)
    case status(mailbox: String, IMAPStatus)
    case search([UInt32], modSeq: UInt64?)
    case esearch(IMAPESearchResponse)
    case enabled([String])
    case id([String: String])
    /// Anything else, as the raw first line.
    case other(String)
}

/// One complete server response.
public enum IMAPResponse: Hashable, Sendable {
    case untagged(IMAPUntagged)
    case tagged(IMAPTaggedResponse)
    /// `+ …`: the server waits for more client data (a literal, or a SASL step).
    case continuation(String)
}
