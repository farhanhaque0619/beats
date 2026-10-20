import Foundation

/// How the client sends literals (`{n}` + bytes).
public enum IMAPLiteralMode: Sendable, Equatable {
    /// `{n}`: wait for the server's `+` before sending the bytes.
    case synchronizing
    /// LITERAL+ (RFC 7888): `{n+}`, sent straight away.
    case nonSynchronizing
    /// LITERAL- (RFC 7888) and IMAP4rev2: `{n+}` up to 4096 bytes, `{n}` above.
    case nonSynchronizingUpTo4096

    /// The best mode the advertised capabilities (uppercased) allow.
    public init(capabilities: Set<String>) {
        if capabilities.contains("LITERAL+") {
            self = .nonSynchronizing
        } else if capabilities.contains("LITERAL-") || capabilities.contains("IMAP4REV2") {
            self = .nonSynchronizingUpTo4096
        } else {
            self = .synchronizing
        }
    }

    /// Whether a literal of `length` bytes must wait for a continuation.
    public func isSynchronizing(length: Int) -> Bool {
        switch self {
        case .synchronizing: return true
        case .nonSynchronizing: return false
        case .nonSynchronizingUpTo4096: return length > 4096
        }
    }
}

/// A command ready to send, minus its tag: text segments with literals between them.
/// The last text segment ends with CRLF; a segment before a literal ends with `{n}` CRLF.
public struct IMAPCommand: Sendable, Equatable {
    /// A run of command text, or a literal's bytes (sent after `{n}` CRLF).
    public enum Part: Sendable, Equatable {
        case text(Data)
        case literal(Data, synchronizing: Bool)
    }

    /// The command name, e.g. `"UID FETCH"`.
    public var name: String
    /// Text and literal segments in wire order.
    public var parts: [Part]
    /// LOGIN / AUTHENTICATE: never log arguments.
    public var isSensitive: Bool
    /// What a protocol log may show (no secrets, literal contents elided).
    public var logDescription: String

    /// The whole command as bytes (without the tag), as it goes on the wire.
    public var bytes: Data {
        var data = Data()
        for part in parts {
            switch part {
            case .text(let text): data.append(text)
            case .literal(let literal, _): data.append(literal)
            }
        }
        return data
    }

    /// True when at least one literal needs the server's go-ahead.
    public var hasSynchronizingLiteral: Bool {
        parts.contains { part in
            if case .literal(_, true) = part { return true }
            return false
        }
    }
}

/// Builds an `IMAPCommand`, choosing atoms, quoted strings or literals for arguments.
///
///     var builder = IMAPCommandBuilder("UID COPY", literalMode: .init(capabilities: caps))
///     builder.space(); builder.raw(set.description)
///     builder.space(); builder.mailbox("[Gmail]/All Mail")
///     let command = builder.build()   // UID COPY 1:5 "[Gmail]/All Mail"\r\n
public struct IMAPCommandBuilder: Sendable {
    /// The command name, e.g. `"UID STORE"`.
    public let name: String
    /// How literals are announced (`{n}` or `{n+}`).
    public let literalMode: IMAPLiteralMode
    /// After ENABLE UTF8=ACCEPT quoted strings may carry UTF-8 and mailbox names aren't MUTF-7 encoded.
    public let utf8Accepted: Bool
    /// Redact the arguments in `logDescription` (LOGIN, AUTHENTICATE).
    public let isSensitive: Bool

    private var parts: [IMAPCommand.Part] = []
    private var current: [UInt8]
    private var log: String

    public init(_ name: String, literalMode: IMAPLiteralMode = .synchronizing, utf8Accepted: Bool = false, sensitive: Bool = false) {
        self.name = name
        self.literalMode = literalMode
        self.utf8Accepted = utf8Accepted
        self.isSensitive = sensitive
        self.current = Array(name.utf8)
        self.log = name
    }

    /// Appends text verbatim (atoms, sequence sets, parentheses).
    public mutating func raw(_ text: String) {
        current.append(contentsOf: text.utf8)
        log += text
    }

    /// Appends one space.
    public mutating func space() { raw(" ") }

    /// A string argument: quoted when possible, otherwise a literal.
    public mutating func string(_ text: String) {
        if let quoted = IMAPEncoder.quoted(text, utf8Accepted: utf8Accepted) {
            raw(quoted)
        } else {
            literal(Data(text.utf8))
        }
    }

    /// An astring: a bare atom when it's safe to send one, otherwise like `string(_:)`.
    public mutating func astring(_ text: String) {
        if IMAPEncoder.isAtom(text), text.uppercased() != "NIL" {
            raw(text)
        } else {
            string(text)
        }
    }

    /// A mailbox name. INBOX is sent bare; other names are quoted (or a literal). A name with
    /// non-ASCII characters is modified-UTF-7 encoded unless UTF8=ACCEPT is on.
    public mutating func mailbox(_ name: String) {
        if name.caseInsensitiveCompare("INBOX") == .orderedSame {
            raw("INBOX")
            return
        }
        string(IMAPEncoder.wireMailboxName(name, utf8Accepted: utf8Accepted))
    }

    /// A literal (`{n}` or `{n+}` per `literalMode`).
    public mutating func literal(_ data: Data) {
        let synchronizing = literalMode.isSynchronizing(length: data.count)
        let header = "{\(data.count)\(synchronizing ? "" : "+")}"
        current.append(contentsOf: header.utf8)
        current.append(contentsOf: [Byte.cr, Byte.lf])
        parts.append(.text(Data(current)))
        current.removeAll(keepingCapacity: true)
        parts.append(.literal(data, synchronizing: synchronizing))
        log += "\(header) <\(data.count) bytes>"
    }

    /// `(\Seen $Forwarded)`; entries that aren't valid flags are left out.
    public mutating func flagList(_ flags: [String]) {
        raw("(" + flags.filter(IMAPEncoder.isFlag).joined(separator: " ") + ")")
    }

    /// The finished command, CRLF-terminated.
    public func build() -> IMAPCommand {
        var parts = self.parts
        var last = current
        last.append(contentsOf: [Byte.cr, Byte.lf])
        parts.append(.text(Data(last)))
        let description = isSensitive ? "\(name) [redacted]" : log
        return IMAPCommand(name: name, parts: parts, isSensitive: isSensitive, logDescription: description)
    }
}

/// Encoding rules for command arguments.
public enum IMAPEncoder {
    /// Whether `text` can be sent as a bare atom (RFC 3501 ATOM-CHAR; `]` allowed as in astring).
    public static func isAtom(_ text: String) -> Bool {
        guard !text.isEmpty else { return false }
        return text.utf8.allSatisfy(isAtomChar)
    }

    static func isAtomChar(_ byte: UInt8) -> Bool {
        guard byte > 0x20, byte < 0x7F else { return false }
        switch byte {
        case Byte.openParen, Byte.closeParen, Byte.openBrace, Byte.quote, Byte.backslash, UInt8(ascii: "%"), Byte.star:
            return false
        default:
            return true
        }
    }

    /// A system flag (`\Seen`) or keyword (`$Forwarded`, `NonJunk`).
    public static func isFlag(_ flag: String) -> Bool {
        var text = Substring(flag)
        if text.hasPrefix("\\") { text = text.dropFirst() }
        guard !text.isEmpty else { return false }
        return text.utf8.allSatisfy { isAtomChar($0) && $0 != Byte.closeBracket }
    }

    /// `"text"` with `\` and `"` escaped, or nil when it must be a literal (CR, LF, NUL,
    /// 8-bit bytes without UTF8=ACCEPT, or very long).
    public static func quoted(_ text: String, utf8Accepted: Bool = false) -> String? {
        var output = "\""
        var length = 0
        for byte in text.utf8 {
            length += 1
            if byte == 0 || byte == Byte.cr || byte == Byte.lf { return nil }
            if byte >= 0x80 && !utf8Accepted { return nil }
        }
        guard length <= 1024 else { return nil }
        for scalar in text.unicodeScalars {
            if scalar == "\\" || scalar == "\"" { output.append("\\") }
            output.unicodeScalars.append(scalar)
        }
        output.append("\"")
        return output
    }

    /// The form of a mailbox name for the wire: unchanged when ASCII (assumed already in wire
    /// form) or when UTF8=ACCEPT is on; otherwise modified UTF-7.
    public static func wireMailboxName(_ name: String, utf8Accepted: Bool) -> String {
        if utf8Accepted || name.utf8.allSatisfy({ $0 < 0x80 }) { return name }
        return ModifiedUTF7.encode(name)
    }
}

/// Generates command tags `A001`, `A002`, … (`A1000` after `A999`).
public struct IMAPTagGenerator: Sendable {
    /// Letters before the counter, `"A"` by default.
    public let prefix: String
    /// The number used by the last tag handed out.
    public private(set) var counter: Int

    public init(prefix: String = "A", counter: Int = 0) {
        self.prefix = prefix
        self.counter = counter
    }

    /// The next tag: `A001`, `A002`, …
    public mutating func next() -> String {
        counter += 1
        let digits = String(counter)
        return prefix + String(repeating: "0", count: max(0, 3 - digits.count)) + digits
    }
}
