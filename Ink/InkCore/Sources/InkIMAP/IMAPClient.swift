import Foundation
import InkModel

/// An IMAP4rev1 / IMAP4rev2 client over a `MailTransport`.
///
/// One command is in flight at a time: calls made while another is running wait their turn,
/// so the client can be shared freely between tasks. Multi-command operations (`connect`,
/// the `uidMove` fallback, `idle`) run as one unit, so nothing interleaves with them.
///
/// Every method throws `MailError`:
/// - NO to LOGIN / AUTHENTICATE (or `[AUTHENTICATIONFAILED]`) → `.authenticationFailed`, with
///   any `[ALERT]` text included;
/// - SELECT / EXAMINE / STATUS refused, or `[TRYCREATE]` / `[NONEXISTENT]` → `.mailboxNotFound`;
/// - other NO → `.serverError`, BAD → `.protocolError`;
/// - read timeouts → `.timeout`; a closed connection or `* BYE` → `.connectionFailed`.
///
/// After a timeout, a transport error or a framing error the connection is closed (its state
/// can't be trusted) and `state` becomes `.disconnected`; call `connect()` again.
///
/// The optional `logger` receives one line per command and response (`C: …` / `S: …`).
/// LOGIN and AUTHENTICATE arguments and SASL responses are redacted, and literal contents
/// (message bodies) are elided.
public actor IMAPClient {
    /// Server host name, as passed to the transport.
    public let host: String
    /// Server port (993 for TLS, 143 for STARTTLS).
    public let port: Int
    /// How the connection is secured.
    public let security: ConnectionSecurity
    /// Seconds to wait for each read from the server.
    public let timeout: TimeInterval

    /// Capabilities the server advertised, uppercased (`IMAP4REV1`, `IDLE`, `AUTH=PLAIN`, …).
    /// Refreshed after STARTTLS and after signing in.
    public internal(set) var capabilities: Set<String> = []
    /// Where the session is: disconnected, connected but not signed in, or signed in.
    public internal(set) var state: IMAPConnectionState = .disconnected
    /// The selected mailbox, kept current by EXISTS / EXPUNGE / VANISHED responses.
    public internal(set) var selectedMailbox: IMAPSelectInfo?
    /// Extensions the server confirmed with `* ENABLED` (uppercased).
    public internal(set) var enabledExtensions: Set<String> = []
    /// The server's answer to `ID`, keys lowercased.
    public internal(set) var serverID: [String: String]?
    /// The most recent `[ALERT]` text. RFC 3501 requires showing these to the user.
    public internal(set) var lastAlert: String?
    /// The greeting's human-readable text.
    public internal(set) var greetingText: String?

    let transport: MailTransport
    let logger: (@Sendable (String) -> Void)?
    var parser = IMAPResponseParser()
    var tags = IMAPTagGenerator()
    /// A read handed to a detached task (IDLE, cancellation clean-up) that hasn't finished yet.
    /// The next read awaits it instead of starting another, so no bytes are lost.
    var pendingRead: Task<Data, Error>?
    /// Text of a `* BYE`, used to explain the closed connection that follows.
    var byeText: String?
    /// The `[ALERT]` seen during the running command.
    var commandAlert: String?

    private var isBusy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// - Parameters:
    ///   - security: `.tls` opens TLS straight away (993); `.startTLS` upgrades the plaintext
    ///     connection before anything else is sent (143); `.none` stays plaintext (tests only).
    ///   - timeout: Seconds to wait for each read from the server.
    ///   - logger: Receives a redacted protocol trace.
    public init(host: String, port: Int, security: ConnectionSecurity, transport: MailTransport, timeout: TimeInterval = 30,
                logger: (@Sendable (String) -> Void)? = nil) {
        self.host = host
        self.port = port
        self.security = security
        self.transport = transport
        self.timeout = timeout
        self.logger = logger
        parser.capturesSummary = logger != nil
    }

    /// The server is Gmail (advertises `X-GM-EXT-1`): labels, X-GM-THRID / X-GM-MSGID, X-GM-RAW.
    public var isGmail: Bool { capabilities.contains("X-GM-EXT-1") }

    /// True from a successful `connect()` until `logout()` or a fatal error.
    public var isConnected: Bool { state != .disconnected }

    /// Whether the server advertised `capability` (case-insensitive).
    public func supports(_ capability: String) -> Bool { capabilities.contains(capability.uppercased()) }

    var utf8Accepted: Bool { enabledExtensions.contains("UTF8=ACCEPT") }

    deinit {
        pendingRead?.cancel()
        transport.close()
    }

    // MARK: - Connecting and signing in

    /// Opens the connection and reads the greeting. With `.startTLS` security it sends
    /// STARTTLS, upgrades the transport, discards anything received before the upgrade and asks
    /// for CAPABILITY again. A `* PREAUTH` greeting leaves the client signed in (and is refused
    /// with `.startTLS`, since the session would never be encrypted); `* BYE` throws.
    /// Does nothing when already connected.
    public func connect() async throws {
        try await serialized {
            guard self.state == .disconnected else { return }
            do {
                try await self.performConnect()
            } catch {
                self.teardown()
                throw error
            }
        }
    }

    private func performConnect() async throws {
        parser.reset()
        parser.utf8Mode = false
        tags = IMAPTagGenerator()
        byeText = nil
        capabilities = []
        enabledExtensions = []
        selectedMailbox = nil
        serverID = nil
        greetingText = nil
        log("Connecting to \(host):\(port) (\(security.rawValue))")
        do {
            try await transport.open(host: host, port: port, tls: security == .tls, timeout: timeout)
        } catch {
            throw IMAPError.mailError(for: error)
        }
        state = .notAuthenticated

        switch try await readResponse() {
        case .untagged(.ok(let text)):
            greetingText = text.text
            apply(code: text.code, text: text.text)
        case .untagged(.preauth(let text)):
            greetingText = text.text
            apply(code: text.code, text: text.text)
            state = .authenticated
        case .untagged(.bye(let text)):
            let cleaned = IMAPError.clean(text)
            throw MailError.connectionFailed(cleaned.isEmpty ? "The server refused the connection." : "The server refused the connection: \(cleaned)")
        default:
            throw MailError.protocolError("It didn't greet like an IMAP server.")
        }

        if security == .startTLS {
            if state == .authenticated {
                throw MailError.tlsFailed("The server signed in before the connection was secured, so it can't be used safely.")
            }
            if capabilities.isEmpty { try await refreshCapabilitiesUnlocked() }
            guard capabilities.contains("STARTTLS") else {
                throw MailError.tlsFailed("The server doesn't offer STARTTLS.")
            }
            let result = try await send(IMAPCommandBuilder("STARTTLS").build())
            guard result.tagged.status == .ok else {
                let detail = IMAPError.clean(result.tagged.text.text)
                throw MailError.tlsFailed(detail.isEmpty ? "The server refused STARTTLS." : "The server refused STARTTLS: \(detail)")
            }
            // Bytes after the tagged OK arrived in plaintext but would be read as if they came
            // over TLS: a response-injection attack ("NO STARTTLS", USENIX Security 2021), so
            // the connection is abandoned rather than cleaned up (RESEARCH §3.2, STARTTLS rule 2).
            guard parser.bufferedByteCount == 0, pendingRead == nil else {
                throw MailError.tlsFailed("The server sent unexpected data before the secure connection started, so it can't be used safely.")
            }
            discardPlaintextState()
            do {
                try await transport.startTLS()
            } catch {
                let mapped = IMAPError.mailError(for: error)
                if case .tlsFailed = mapped { throw mapped }
                throw MailError.tlsFailed(mapped.localizedDescription)
            }
            // The first read over TLS (where certificate problems surface) happens here, before
            // any credentials are sent (RESEARCH §3.2 rules 3 and 5, §3.4).
            try await refreshCapabilitiesUnlocked()
        } else if capabilities.isEmpty {
            try await refreshCapabilitiesUnlocked()
        }
    }

    /// Forgets everything learned before STARTTLS: none of it was protected, and untagged data
    /// answering STARTTLS (`* CAPABILITY`, `* ENABLED`, `[ALERT]`) could have been injected.
    private func discardPlaintextState() {
        parser.reset()
        parser.utf8Mode = false
        capabilities = []
        enabledExtensions = []
        selectedMailbox = nil
        serverID = nil
        lastAlert = nil
        commandAlert = nil
        byeText = nil
    }

    /// Asks the server for its capabilities again.
    @discardableResult
    public func refreshCapabilities() async throws -> Set<String> {
        try await serialized {
            try self.requireConnection()
            try await self.refreshCapabilitiesUnlocked()
            return self.capabilities
        }
    }

    /// CAPABILITY; the `* CAPABILITY` response (or a `[CAPABILITY]` code) updates `capabilities`.
    private func refreshCapabilitiesUnlocked() async throws {
        _ = try await execute(IMAPCommandBuilder("CAPABILITY").build())
    }

    /// Signs in with a password. Uses `AUTHENTICATE PLAIN` when advertised (with the initial
    /// response inline when SASL-IR is offered), else `LOGIN` with quoted strings or literals.
    /// Falls back from PLAIN to LOGIN only when PLAIN is rejected as BAD (unsupported), never on
    /// NO, so a wrong password is only tried once. Capabilities are refreshed afterwards.
    public func login(username: String, password: String) async throws {
        try await serialized {
            try self.requireConnection()
            guard self.state == .notAuthenticated else { return }
            var result: IMAPCommandResult?
            if self.capabilities.contains("AUTH=PLAIN") {
                let attempt = try await self.authenticate(mechanism: "PLAIN", initialResponse: IMAPSASL.plain(username: username, password: password))
                if attempt.result.tagged.status == .ok || attempt.result.tagged.status == .no || self.capabilities.contains("LOGINDISABLED") {
                    result = attempt.result
                }
            } else if self.capabilities.contains("LOGINDISABLED") {
                throw MailError.notSupported("password sign-in on this connection")
            }
            if result == nil {
                var builder = IMAPCommandBuilder("LOGIN", literalMode: self.literalMode, utf8Accepted: self.utf8Accepted, sensitive: true)
                builder.space()
                builder.astring(username)
                builder.space()
                builder.astring(password)
                result = try await self.send(builder.build())
            }
            guard let final = result else { return }
            try self.check(final, command: "LOGIN")
            try await self.didAuthenticate(final)
        }
    }

    /// Signs in with an OAuth 2.0 access token (SASL XOAUTH2, Gmail and Outlook). When the
    /// server rejects the token it first sends an error challenge (`+ <base64 JSON>`), which is
    /// answered with an empty line as the mechanism requires; the following NO becomes
    /// `.authenticationFailed`.
    public func authenticateXOAUTH2(username: String, accessToken: String) async throws {
        try await serialized {
            try self.requireConnection()
            guard self.state == .notAuthenticated else { return }
            if !self.capabilities.isEmpty, !self.capabilities.contains("AUTH=XOAUTH2") {
                throw MailError.notSupported("signing in with OAuth (XOAUTH2)")
            }
            let attempt = try await self.authenticate(mechanism: "XOAUTH2", initialResponse: IMAPSASL.xoauth2(username: username, accessToken: accessToken))
            if attempt.result.tagged.status != .ok {
                var response = attempt.result.tagged
                if IMAPError.clean(response.text.text).isEmpty, let status = attempt.errorStatus {
                    response.text.text = "The access token was rejected (status \(status))."
                }
                throw IMAPError.commandFailed(command: "AUTHENTICATE", response: response, mailbox: nil, alert: self.commandAlert).mailError
            }
            try await self.didAuthenticate(attempt.result)
        }
    }

    private struct AuthenticateAttempt {
        var result: IMAPCommandResult
        /// `status` from an XOAUTH2 error challenge.
        var errorStatus: String?
    }

    /// Runs `AUTHENTICATE <mechanism>` with one initial response. Without SASL-IR the response
    /// is sent after the first `+`. A further challenge is treated as an error report: it gets
    /// an empty response once, then `*` (cancel).
    private func authenticate(mechanism: String, initialResponse: String) async throws -> AuthenticateAttempt {
        let inline = capabilities.contains("SASL-IR")
        var builder = IMAPCommandBuilder("AUTHENTICATE", sensitive: true)
        builder.raw(" \(mechanism)")
        if inline { builder.raw(" \(initialResponse.isEmpty ? "=" : initialResponse)") }
        var sentInitial = inline
        var challenges = 0
        var errorStatus: String?
        let result = try await send(builder.build()) { challenge in
            if !sentInitial {
                sentInitial = true
                return Data(initialResponse.utf8)
            }
            challenges += 1
            if errorStatus == nil { errorStatus = IMAPSASL.xoauth2ErrorStatus(challenge) }
            return challenges == 1 ? Data() : Data("*".utf8)
        }
        return AuthenticateAttempt(result: result, errorStatus: errorStatus)
    }

    private func didAuthenticate(_ result: IMAPCommandResult) async throws {
        state = .authenticated
        selectedMailbox = nil
        let gotCapabilities: Bool
        if case .capability? = result.tagged.text.code {
            gotCapabilities = true
        } else {
            gotCapabilities = result.untagged.contains { if case .capability = $0 { return true } else { return false } }
        }
        if !gotCapabilities {
            // Servers advertise more (or different) capabilities once signed in.
            try await refreshCapabilitiesUnlocked()
        }
    }

    /// `ENABLE` the given extensions (e.g. `QRESYNC`, `UTF8=ACCEPT`, `CONDSTORE`), skipping any
    /// the server doesn't advertise. Does nothing without the ENABLE capability.
    /// After `UTF8=ACCEPT` mailbox names travel as UTF-8 instead of modified UTF-7.
    ///
    /// The server lists what it turned on in `* ENABLED`, and only those count. A server that
    /// answers OK with no `* ENABLED` at all (iCloud) is taken to have enabled everything that
    /// was asked for (RESEARCH §3.3, §3.4).
    public func enable(_ caps: [String]) async throws {
        try await serialized {
            try self.requireAuthenticated()
            guard self.capabilities.contains("ENABLE") else { return }
            var wanted: [String] = []
            for cap in caps.map({ $0.uppercased() })
            where IMAPEncoder.isAtom(cap) && self.capabilities.contains(cap) && !self.enabledExtensions.contains(cap) && !wanted.contains(cap) {
                wanted.append(cap)
            }
            guard !wanted.isEmpty else { return }
            var builder = IMAPCommandBuilder("ENABLE")
            for cap in wanted { builder.raw(" \(cap)") }
            let result = try await self.execute(builder.build())
            let reported = result.untagged.contains { if case .enabled = $0 { return true } else { return false } }
            if !reported {
                self.log("No ENABLED response; treating OK as success for \(wanted.joined(separator: " "))")
                self.handle(.enabled(wanted))
            }
        }
    }

    /// Identifies the client (RFC 2971 `ID`), recording the server's answer in `serverID`.
    /// Does nothing when the server lacks ID; a refusal is ignored.
    public func id(_ fields: [String: String]) async throws {
        try await serialized {
            try self.requireConnection()
            guard self.capabilities.contains("ID") else { return }
            var builder = IMAPCommandBuilder("ID", literalMode: self.literalMode, utf8Accepted: self.utf8Accepted)
            if fields.isEmpty {
                builder.raw(" NIL")
            } else {
                builder.raw(" (")
                for (index, key) in fields.keys.sorted().enumerated() {
                    if index > 0 { builder.space() }
                    builder.string(key)
                    builder.space()
                    builder.string(fields[key] ?? "")
                }
                builder.raw(")")
            }
            let result = try await self.send(builder.build())
            for case .id(let values) in result.untagged { self.serverID = values }
        }
    }

    // MARK: - Mailboxes

    /// Every mailbox: `LIST "" "*"`, with `RETURN (SPECIAL-USE)` when the server has SPECIAL-USE
    /// and LIST-EXTENDED, or Gmail's older `XLIST` when that's all it has. Names are decoded from
    /// modified UTF-7 (or UTF-8 after `UTF8=ACCEPT`); duplicates are dropped.
    public func listMailboxes() async throws -> [IMAPMailbox] {
        try await serialized {
            try self.requireAuthenticated()
            let specialUse = self.capabilities.contains("SPECIAL-USE")
            func listCommand(_ verb: String, returnSpecialUse: Bool = false) -> IMAPCommand {
                var builder = IMAPCommandBuilder(verb)
                builder.raw(returnSpecialUse ? " \"\" \"*\" RETURN (SPECIAL-USE)" : " \"\" \"*\"")
                return builder.build()
            }
            var result: IMAPCommandResult
            var usedXList = false
            var usedExtension = true
            if specialUse, self.capabilities.contains("LIST-EXTENDED") {
                result = try await self.send(listCommand("LIST", returnSpecialUse: true))
            } else if !specialUse, self.capabilities.contains("XLIST") {
                usedXList = true
                result = try await self.send(listCommand("XLIST"))
            } else {
                usedExtension = false
                result = try await self.send(listCommand("LIST"))
            }
            if result.tagged.status != .ok, usedExtension {
                // The extended form was refused: fall back to plain LIST.
                usedXList = false
                result = try await self.send(listCommand("LIST"))
            }
            try self.check(result, command: "LIST")
            var seen = Set<String>()
            var mailboxes: [IMAPMailbox] = []
            for response in result.untagged {
                guard case .list(var mailbox) = response else { continue }
                if usedXList, mailbox.hasAttribute("\\Inbox") {
                    // XLIST names the inbox in the user's language ("Posteingang"); it's selected as INBOX.
                    mailbox.rawName = "INBOX"
                    mailbox.name = "INBOX"
                }
                if seen.insert(mailbox.rawName).inserted { mailboxes.append(mailbox) }
            }
            return mailboxes
        }
    }

    /// Selects (or with `readOnly`, examines) a mailbox. `rawPath` is the name as LIST sent it;
    /// a non-ASCII name is modified-UTF-7 encoded first. With `condstore` (and server support)
    /// the mailbox reports HIGHESTMODSEQ.
    public func select(_ rawPath: String, readOnly: Bool = false, condstore: Bool = false) async throws -> IMAPSelectInfo {
        try await serialized {
            try self.requireAuthenticated()
            var builder = self.builder(readOnly ? "EXAMINE" : "SELECT")
            builder.space()
            builder.mailbox(rawPath)
            if condstore, self.capabilities.contains("CONDSTORE") {
                builder.raw(" (CONDSTORE)")
            }
            // A failed SELECT leaves no mailbox selected.
            self.selectedMailbox = nil
            let result = try await self.send(builder.build())
            try self.check(result, command: readOnly ? "EXAMINE" : "SELECT", mailbox: rawPath)
            var info = IMAPSelectInfo(mailbox: rawPath, readOnly: readOnly)
            for response in result.untagged {
                switch response {
                case .exists(let count): info.exists = count
                case .recent(let count): info.recent = count
                case .expunge: info.exists = info.exists > 0 ? info.exists - 1 : 0
                case .flags(let flags): info.flags = flags
                case .ok(let text), .no(let text):
                    Self.fold(text.code, into: &info)
                default: break
                }
            }
            Self.fold(result.tagged.text.code, into: &info)
            self.selectedMailbox = info
            return info
        }
    }

    private static func fold(_ code: IMAPResponseCode?, into info: inout IMAPSelectInfo) {
        switch code {
        case .uidValidity(let value)?: info.uidValidity = value
        case .uidNext(let value)?: info.uidNext = value
        case .unseen(let value)?: info.firstUnseen = value
        case .permanentFlags(let flags)?:
            info.permanentFlags = flags
            info.hasPermanentFlags = true
        case .highestModSeq(let value)?: info.highestModSeq = value
        case .noModSeq?: info.noModSeq = true
        case .readOnly?: info.readOnly = true
        case .readWrite?: info.readOnly = false
        default: break
        }
    }

    /// STATUS with MESSAGES UIDNEXT UIDVALIDITY UNSEEN (and HIGHESTMODSEQ with CONDSTORE).
    public func status(_ rawPath: String) async throws -> IMAPStatus {
        try await serialized {
            try self.requireAuthenticated()
            var builder = self.builder("STATUS")
            builder.space()
            builder.mailbox(rawPath)
            builder.raw(self.capabilities.contains("CONDSTORE") ? " (MESSAGES UIDNEXT UIDVALIDITY UNSEEN HIGHESTMODSEQ)" : " (MESSAGES UIDNEXT UIDVALIDITY UNSEEN)")
            let result = try await self.send(builder.build())
            try self.check(result, command: "STATUS", mailbox: rawPath)
            var found: IMAPStatus?
            for case .status(_, let status) in result.untagged { found = status }
            guard let found else { throw MailError.protocolError("It didn't report the folder's status.") }
            return found
        }
    }

    /// Creates a mailbox. Succeeds quietly when it already exists.
    public func create(_ rawPath: String) async throws {
        try await serialized {
            try self.requireAuthenticated()
            var builder = self.builder("CREATE")
            builder.space()
            builder.mailbox(rawPath)
            let result = try await self.send(builder.build())
            if result.tagged.status == .no {
                if case .alreadyExists? = result.tagged.text.code { return }
                if IMAPText.contains(result.tagged.text.text, "already exists", ignoringASCIICase: true) { return }
            }
            try self.check(result, command: "CREATE", mailbox: rawPath)
        }
    }

    /// Subscribes to a mailbox (some clients only show subscribed folders).
    public func subscribe(_ rawPath: String) async throws {
        try await serialized {
            try self.requireAuthenticated()
            var builder = self.builder("SUBSCRIBE")
            builder.space()
            builder.mailbox(rawPath)
            try self.check(try await self.send(builder.build()), command: "SUBSCRIBE", mailbox: rawPath)
        }
    }

    /// Leaves the selected mailbox without expunging (UNSELECT). Without UNSELECT support this
    /// does nothing rather than send CLOSE, which would expunge `\Deleted` messages.
    public func unselect() async throws {
        try await serialized {
            try self.requireAuthenticated()
            guard self.selectedMailbox != nil, self.capabilities.contains("UNSELECT") else { return }
            _ = try await self.execute(IMAPCommandBuilder("UNSELECT").build())
            self.selectedMailbox = nil
        }
    }

    // MARK: - Messages

    /// FETCH (or UID FETCH) the given items. Gmail-only items are dropped on other servers, as
    /// are MODSEQ without CONDSTORE and EMAILID/THREADID/PREVIEW without their extensions;
    /// `changedSince` (CONDSTORE `CHANGEDSINCE`) is ignored without CONDSTORE, which only makes
    /// the result larger. Responses for messages outside `set` are left out (unsolicited flag
    /// updates for other messages). With `byUID`, UID is always fetched, and that also drops
    /// the highest-UID message servers return for `n:*` when n is above every UID (so
    /// `UID FETCH <uidNext>:*` yields only new mail). Responses for the same message are merged.
    ///
    /// Section data is stored under the canonical key (`IMAPFetchResponse.sectionKey`) and also
    /// under the section string exactly as passed in the item.
    public func fetch(_ set: IMAPSequenceSet, byUID: Bool, items: [IMAPFetchItem], changedSince: UInt64? = nil) async throws -> [IMAPFetchResponse] {
        try await fetchReportingCompleteness(set, byUID: byUID, items: items, changedSince: changedSince).responses
    }

    /// Like `fetch(_:byUID:items:changedSince:)`, and also says whether the answer was complete.
    ///
    /// `fetch` returns what a server sent before answering NO (messages vanished mid-fetch,
    /// one message couldn't be read), which is fine for showing mail but not for deciding what
    /// was deleted: a message left out of a partial answer may well still be there. Use this
    /// when absence matters. `isComplete` is true for OK, and for NO `[EXPUNGEISSUED]`, where
    /// what's missing really was expunged.
    public func fetchReportingCompleteness(_ set: IMAPSequenceSet, byUID: Bool, items: [IMAPFetchItem],
                                           changedSince: UInt64? = nil) async throws -> IMAPFetchOutcome {
        try await serialized {
            try self.requireSelected()
            return try await self.performFetch(set, byUID: byUID, items: items, changedSince: changedSince)
        }
    }

    private func performFetch(_ set: IMAPSequenceSet, byUID: Bool, items requested: [IMAPFetchItem], changedSince: UInt64?) async throws -> IMAPFetchOutcome {
        guard !set.isEmpty else { return IMAPFetchOutcome(responses: [], isComplete: true) }
        var items = requested.filter(isFetchItemSupported)
        if byUID, !items.contains(.uid) { items.insert(.uid, at: 0) }
        if items.isEmpty { items = [.flags] }
        var unique: [IMAPFetchItem] = []
        for item in items where !unique.contains(item) { unique.append(item) }

        var builder = self.builder(byUID ? "UID FETCH" : "FETCH")
        builder.raw(" \(set) (" + unique.map(\.wire).joined(separator: " ") + ")")
        let condstore = capabilities.contains("CONDSTORE")
        if let changedSince, condstore {
            builder.raw(" (CHANGEDSINCE \(changedSince))")
        }
        let result = try await send(builder.build())

        var order: [UInt32] = []
        var bySeq: [UInt32: IMAPFetchResponse] = [:]
        let bareLast = set.elements.contains(.last)
        for case .fetch(let response) in result.untagged {
            if byUID {
                // Drops unsolicited flag updates for other messages, and the message a server
                // returns for `n:*` when n is above the highest UID (RFC 3501 §6.4.8).
                guard let uid = response.uid else { continue }
                if !bareLast, !set.contains(uid) { continue }
            } else if !bareLast, !set.contains(response.seq) {
                // An unsolicited flag update for another message. Sequence numbers can't shift
                // during a FETCH (no EXPUNGE may be sent then, RFC 3501 §7.4.1), so anything
                // outside the set isn't an answer.
                continue
            }
            if var existing = bySeq[response.seq] {
                existing.merge(response)
                bySeq[response.seq] = existing
            } else {
                order.append(response.seq)
                bySeq[response.seq] = response
            }
        }
        var isComplete = true
        if result.tagged.status != .ok {
            // Partial results when messages vanished mid-fetch are still useful.
            let expunged: Bool
            if case .expungeIssued? = result.tagged.text.code { expunged = true } else { expunged = false }
            if result.tagged.status == .bad || (!expunged && order.isEmpty) {
                try check(result, command: byUID ? "UID FETCH" : "FETCH")
            }
            isComplete = expunged
        }
        let aliases: [(String, String)] = requested.compactMap { item in
            guard let key = item.sectionKey else { return nil }
            switch item {
            case .bodyPeek(let section, _), .body(let section, _):
                return section == key ? nil : (key, section)
            case .headerFields(let names):
                let spelled = "HEADER.FIELDS (\(names.joined(separator: " ")))"
                return spelled == key ? nil : (key, spelled)
            case .headerFieldsNot(let names):
                let spelled = "HEADER.FIELDS.NOT (\(names.joined(separator: " ")))"
                return spelled == key ? nil : (key, spelled)
            default:
                return nil
            }
        }
        let responses: [IMAPFetchResponse] = order.compactMap { seq in
            guard var response = bySeq[seq] else { return nil }
            for (key, alias) in aliases {
                if let data = response.sections[key], response.sections[alias] == nil { response.sections[alias] = data }
            }
            return response
        }
        return IMAPFetchOutcome(responses: responses, isComplete: isComplete)
    }

    private func isFetchItemSupported(_ item: IMAPFetchItem) -> Bool {
        switch item {
        case .gmailThreadID, .gmailMessageID, .gmailLabels: return isGmail
        case .modSeq: return capabilities.contains("CONDSTORE")
        case .emailID, .threadID: return capabilities.contains("OBJECTID")
        case .preview: return capabilities.contains("PREVIEW")
        default: return true
        }
    }

    /// UID SEARCH; results ascending. Uses `RETURN (ALL)` with ESEARCH (compact for big
    /// results) and `CHARSET UTF-8` when a string isn't ASCII (strings then go as literals).
    /// Gmail-only criteria throw `.notSupported` on other servers.
    public func uidSearch(_ criteria: IMAPSearchCriteria) async throws -> [UInt32] {
        try await serialized {
            try self.requireSelected()
            return try await self.performSearch(criteria)
        }
    }

    private func performSearch(_ criteria: IMAPSearchCriteria) async throws -> [UInt32] {
        if criteria.requiresGmail, !isGmail { throw MailError.notSupported("Gmail search") }
        func command(esearch: Bool) -> IMAPCommand {
            var builder = self.builder("UID SEARCH")
            if esearch { builder.raw(" RETURN (ALL)") }
            if criteria.requiresUTF8, !utf8Accepted { builder.raw(" CHARSET UTF-8") }
            builder.space()
            criteria.encode(into: &builder)
            return builder.build()
        }
        let esearch = capabilities.contains("ESEARCH")
        var result = try await send(command(esearch: esearch))
        if esearch, result.tagged.status == .bad {
            // Some servers advertise ESEARCH but reject RETURN with some search keys.
            result = try await send(command(esearch: false))
        }
        if result.tagged.status == .no, case .badCharset? = result.tagged.text.code {
            throw MailError.notSupported("searching for text in this language")
        }
        try check(result, command: "UID SEARCH")
        var uids = Set<UInt32>()
        for response in result.untagged {
            switch response {
            case .search(let numbers, _):
                uids.formUnion(numbers)
            case .esearch(let answer):
                if let tag = answer.tag, tag != result.tag { continue }
                if let all = answer.all { uids.formUnion(all.expanded()) }
            default:
                break
            }
        }
        return uids.sorted()
    }

    /// UID STORE flags (`+FLAGS.SILENT (\Seen)` etc.). Invalid flag names are left out; adding
    /// or removing nothing sends nothing.
    ///
    /// Keywords (`$Forwarded`, `$Junk`, …) are best effort: ones the selected mailbox can't
    /// store (its PERMANENTFLAGS has neither `\*` nor the keyword, as on Exchange) are left out,
    /// and if the server still refuses a STORE that mixes keywords with system flags, the system
    /// flags are stored on their own (RESEARCH §3.4).
    public func uidStore(_ uids: IMAPSequenceSet, flags: [String], mode: IMAPStoreMode, silent: Bool = true) async throws {
        try await serialized {
            try self.requireSelected()
            try await self.performStore(uids, flags: flags, mode: mode, silent: silent)
        }
    }

    private func performStore(_ uids: IMAPSequenceSet, flags: [String], mode: IMAPStoreMode, silent: Bool) async throws {
        guard !uids.isEmpty else { return }
        var valid: [String] = []
        for flag in flags where IMAPEncoder.isFlag(flag) {
            if let mailbox = selectedMailbox, !mailbox.canStore(flag) {
                log("Leaving out \(flag): this folder can't store custom keywords")
                continue
            }
            valid.append(flag)
        }
        if valid.isEmpty, mode != .replace { return }
        func store(_ list: [String]) async throws -> IMAPCommandResult {
            var builder = self.builder("UID STORE")
            builder.raw(" \(uids) \(mode.prefix)FLAGS\(silent ? ".SILENT" : "") ")
            builder.flagList(list)
            return try await send(builder.build())
        }
        var result = try await store(valid)
        if result.tagged.status == .no, case .expungeIssued? = result.tagged.text.code { return }
        let systemFlags = valid.filter { $0.utf8.first == UInt8(ascii: "\\") }
        if result.tagged.status != .ok, !systemFlags.isEmpty, systemFlags.count < valid.count {
            log("STORE with keywords refused; storing the system flags alone")
            result = try await store(systemFlags)
            if result.tagged.status == .no, case .expungeIssued? = result.tagged.text.code { return }
        }
        try check(result, command: "UID STORE")
    }

    /// Gmail: adds, removes or replaces labels (`X-GM-LABELS`). System labels such as `\Inbox`,
    /// `\Starred` and `\Important` are sent as written; others are modified-UTF-7 encoded
    /// (unless UTF8=ACCEPT is on) and quoted as needed.
    public func gmailStoreLabels(_ uids: IMAPSequenceSet, labels: [String], mode: IMAPStoreMode) async throws {
        try await serialized {
            try self.requireSelected()
            guard self.isGmail else { throw MailError.notSupported("Gmail labels") }
            guard !uids.isEmpty else { return }
            let cleaned = labels.filter { !$0.isEmpty }
            if cleaned.isEmpty, mode != .replace { return }
            var builder = self.builder("UID STORE")
            builder.raw(" \(uids) \(mode.prefix)X-GM-LABELS (")
            for (index, label) in cleaned.enumerated() {
                if index > 0 { builder.space() }
                if label.hasPrefix("\\"), IMAPEncoder.isFlag(label) {
                    builder.raw(label)
                } else {
                    builder.astring(IMAPEncoder.wireMailboxName(label, utf8Accepted: self.utf8Accepted))
                }
            }
            builder.raw(")")
            try self.check(try await self.send(builder.build()), command: "UID STORE")
        }
    }

    /// UID COPY. Returns source → destination UIDs from `[COPYUID]` (UIDPLUS); empty when the
    /// server doesn't say.
    public func uidCopy(_ uids: IMAPSequenceSet, to rawPath: String) async throws -> [UInt32: UInt32] {
        try await serialized {
            try self.requireSelected()
            return try await self.performCopy(uids, to: rawPath)
        }
    }

    private func performCopy(_ uids: IMAPSequenceSet, to rawPath: String) async throws -> [UInt32: UInt32] {
        guard !uids.isEmpty else { return [:] }
        var builder = self.builder("UID COPY")
        builder.raw(" \(uids) ")
        builder.mailbox(rawPath)
        let result = try await send(builder.build())
        try check(result, command: "UID COPY", mailbox: rawPath)
        return Self.copyMapping(result)
    }

    /// Moves messages to another mailbox and returns source → destination UIDs when known.
    ///
    /// Uses `UID MOVE` (RFC 6851) when available. Otherwise: `UID COPY`, then
    /// `UID STORE +FLAGS.SILENT (\Deleted)`, then `UID EXPUNGE` of just those messages (UIDPLUS).
    /// A server with neither MOVE nor UIDPLUS can only expunge everything marked `\Deleted`
    /// at once, which could destroy mail the user deleted elsewhere but meant to keep for now.
    /// So by default the originals are left in place marked `\Deleted` (most clients hide
    /// them; they disappear at the next expunge). Pass `allowPlainExpunge: true` to expunge
    /// anyway: other `\Deleted` messages are unmarked first and marked again afterwards.
    public func uidMove(_ uids: IMAPSequenceSet, to rawPath: String, allowPlainExpunge: Bool = false) async throws -> [UInt32: UInt32] {
        try await serialized {
            try self.requireSelected()
            guard !uids.isEmpty else { return [:] }
            if self.capabilities.contains("MOVE") {
                var builder = self.builder("UID MOVE")
                builder.raw(" \(uids) ")
                builder.mailbox(rawPath)
                let result = try await self.send(builder.build())
                try self.check(result, command: "UID MOVE", mailbox: rawPath)
                return Self.copyMapping(result)
            }
            let mapping = try await self.performCopy(uids, to: rawPath)
            try await self.performStore(uids, flags: ["\\Deleted"], mode: .add, silent: true)
            if self.capabilities.contains("UIDPLUS") {
                try await self.performUIDExpunge(uids)
            } else if allowPlainExpunge {
                try await self.performSafeExpunge(keeping: uids)
            }
            return mapping
        }
    }

    /// Permanently removes the given messages if they're marked `\Deleted` (UIDPLUS
    /// `UID EXPUNGE`). Throws `.notSupported` without UIDPLUS rather than expunge everything.
    public func uidExpunge(_ uids: IMAPSequenceSet) async throws {
        try await serialized {
            try self.requireSelected()
            guard !uids.isEmpty else { return }
            guard self.capabilities.contains("UIDPLUS") else {
                throw MailError.notSupported("removing individual messages (UIDPLUS)")
            }
            try await self.performUIDExpunge(uids)
        }
    }

    /// Plain EXPUNGE: removes every message marked `\Deleted` in the selected mailbox.
    public func expunge() async throws {
        try await serialized {
            try self.requireSelected()
            _ = try await self.execute(IMAPCommandBuilder("EXPUNGE").build())
        }
    }

    private func performUIDExpunge(_ uids: IMAPSequenceSet) async throws {
        var builder = self.builder("UID EXPUNGE")
        builder.raw(" \(uids)")
        _ = try await execute(builder.build())
    }

    /// EXPUNGE that spares messages other than `uids` which were already marked `\Deleted`.
    private func performSafeExpunge(keeping uids: IMAPSequenceSet) async throws {
        let others = try await performSearch(.and([.deleted, .not(.uid(uids))]))
        let otherSet = IMAPSequenceSet(others)
        if !otherSet.isEmpty { try await performStore(otherSet, flags: ["\\Deleted"], mode: .remove, silent: true) }
        _ = try await execute(IMAPCommandBuilder("EXPUNGE").build())
        if !otherSet.isEmpty { try await performStore(otherSet, flags: ["\\Deleted"], mode: .add, silent: true) }
    }

    static func copyMapping(_ result: IMAPCommandResult) -> [UInt32: UInt32] {
        var codes: [IMAPResponseCode] = []
        for response in result.untagged {
            if case .ok(let text) = response, let code = text.code { codes.append(code) }
        }
        if let code = result.tagged.text.code { codes.append(code) }
        var mapping: [UInt32: UInt32] = [:]
        for case .copyUID(_, let source, let destination) in codes {
            for (from, to) in zip(source.expanded(limit: 1_000_000), destination.expanded(limit: 1_000_000)) { mapping[from] = to }
        }
        return mapping
    }

    /// Appends a message (as a literal: `{n+}` with LITERAL+, otherwise waiting for the
    /// server's go-ahead). Returns the new UID from `[APPENDUID]` when the server reports it.
    /// Respects APPENDLIMIT.
    public func append(to rawPath: String, message: Data, flags: [String] = [], date: Date? = nil) async throws -> UInt32? {
        try await serialized {
            try self.requireAuthenticated()
            if let limit = self.appendLimit, message.count > limit {
                throw MailError.serverError("The message is too large for this server (limit \(Self.formatSize(limit))).")
            }
            var builder = self.builder("APPEND")
            builder.space()
            builder.mailbox(rawPath)
            let valid = flags.filter(IMAPEncoder.isFlag)
            if !valid.isEmpty {
                builder.space()
                builder.flagList(valid)
            }
            if let date { builder.raw(" \"\(IMAPDate.formatInternalDate(date))\"") }
            builder.space()
            builder.literal(message)
            let result = try await self.send(builder.build())
            try self.check(result, command: "APPEND", mailbox: rawPath)
            if case .appendUID(_, let uids)? = result.tagged.text.code { return uids.expanded(limit: 1).first }
            return nil
        }
    }

    /// `512 KB`, `5.2 MB`, `34 MB` (binary units, as SMTPClient words its size errors). Done by
    /// hand: ByteCountFormatter's output differs between Apple platforms and Linux.
    static func formatSize(_ bytes: Int) -> String {
        if bytes < 1_048_576 { return "\(max(1, (bytes + 512) / 1024)) KB" }
        let tenths = Int((Double(bytes) / 1_048_576 * 10).rounded())
        if tenths >= 100 { return "\((tenths + 5) / 10) MB" }
        return "\(tenths / 10).\(tenths % 10) MB"
    }

    /// `APPENDLIMIT=n` from the capabilities, if any.
    var appendLimit: Int? {
        for capability in capabilities where capability.hasPrefix("APPENDLIMIT=") {
            if let value = Int(capability.dropFirst("APPENDLIMIT=".count)), value > 0 { return value }
        }
        return nil
    }

    /// NOOP; returns whatever the server reported meanwhile (EXISTS, EXPUNGE, FETCH flags, …).
    public func noop() async throws -> [IMAPUntagged] {
        try await serialized {
            try self.requireConnection()
            return try await self.execute(IMAPCommandBuilder("NOOP").build()).untagged
        }
    }

    // MARK: - IDLE

    /// How long one IDLE may last before it should be ended and re-issued on Gmail, which drops
    /// connections that sit in IDLE for about 10 minutes (RESEARCH §3.4, §3.5 item 9; MailKit's
    /// Gmail sample uses 9 minutes).
    public static let gmailIdleInterval: TimeInterval = 9 * 60
    /// How long one IDLE may last elsewhere: RFC 2177 allows 29 minutes before the server may
    /// log the client off, minus a safety margin.
    public static let standardIdleInterval: TimeInterval = 25 * 60

    /// How often this server's IDLE should be re-issued: `gmailIdleInterval` on Gmail,
    /// `standardIdleInterval` elsewhere. `idle(timeout:onEvent:)` never waits longer than this.
    public var idleReissueInterval: TimeInterval {
        isGmail ? Self.gmailIdleInterval : Self.standardIdleInterval
    }

    /// Waits for changes with IDLE (RFC 2177). Each untagged response the server sends is
    /// passed to `onEvent`; return false to stop. The wait also ends after `timeout` and when
    /// the calling task is cancelled. In every case DONE is sent and the server's completion
    /// read, leaving the connection ready for the next command, and the method returns normally,
    /// so callers loop to re-issue IDLE.
    ///
    /// `timeout` is the re-issue interval. Nil (the default) means `idleReissueInterval`: 9
    /// minutes on Gmail, 25 elsewhere. A longer value is capped at `idleReissueInterval`, since
    /// servers drop an IDLE that runs past it.
    ///
    /// The client is busy for the whole wait, so use a dedicated connection for IDLE.
    /// `* BYE` is delivered to `onEvent` and then thrown as `.connectionFailed`. Servers without
    /// IDLE throw `.notSupported` (poll with `noop()` instead; `supports("IDLE")` tells which).
    public func idle(timeout: TimeInterval? = nil, onEvent: @Sendable (IMAPUntagged) -> Bool) async throws {
        try await serialized {
            try self.requireAuthenticated()
            guard self.capabilities.contains("IDLE") else { throw MailError.notSupported("IDLE (push updates)") }
            try await self.performIdle(timeout: self.effectiveIdleTimeout(timeout), onEvent: onEvent)
        }
    }

    /// The IDLE wait for a requested timeout: the re-issue interval when none is given, never
    /// longer than it, never negative.
    func effectiveIdleTimeout(_ requested: TimeInterval?) -> TimeInterval {
        let interval = idleReissueInterval
        guard let requested, !requested.isNaN else { return interval }
        return max(0, min(requested, interval))
    }

    private enum IdleStop {
        case requested, timeout, cancelled
    }

    private func performIdle(timeout idleTimeout: TimeInterval, onEvent: @Sendable (IMAPUntagged) -> Bool) async throws {
        let tag = tags.next()
        log("C: \(tag) IDLE")
        try await write(Data("\(tag) IDLE\r\n".utf8))
        commandAlert = nil

        // Wait for "+ idling" (or an immediate refusal). DONE may only follow the "+", so a
        // stop requested before it is remembered.
        var stop: IdleStop?
        accepted: while true {
            switch try await readResponse() {
            case .continuation:
                break accepted
            case .tagged(let tagged) where tagged.tag == tag:
                apply(code: tagged.text.code, text: tagged.text.text)
                if tagged.status == .ok { return }
                throw IMAPError.commandFailed(command: "IDLE", response: tagged, mailbox: nil, alert: commandAlert).mailError
            case .tagged(let tagged):
                log("Ignoring completion for unknown tag \(tagged.tag)")
            case .untagged(.bye(let text)):
                handle(.bye(text))
                _ = onEvent(.bye(text))
                throw IMAPError.bye(text)
            case .untagged(let untagged):
                handle(untagged)
                if stop == nil, !onEvent(untagged) { stop = .requested }
            }
        }

        let deadline = Date().addingTimeInterval(max(0, idleTimeout))
        while stop == nil {
            if let response = try nextBufferedResponse() {
                switch response {
                case .untagged(.bye(let text)):
                    // The server is hanging up; there's nothing to send DONE to.
                    handle(.bye(text))
                    _ = onEvent(.bye(text))
                    throw IMAPError.bye(text)
                case .untagged(let untagged):
                    handle(untagged)
                    if !onEvent(untagged) { stop = .requested }
                case .tagged(let tagged) where tagged.tag == tag:
                    // The server ended IDLE by itself.
                    apply(code: tagged.text.code, text: tagged.text.text)
                    if tagged.status == .ok { return }
                    throw IMAPError.commandFailed(command: "IDLE", response: tagged, mailbox: nil, alert: commandAlert).mailError
                case .tagged, .continuation:
                    continue
                }
                continue
            }
            let remaining = deadline.timeIntervalSinceNow
            if remaining <= 0 {
                stop = .timeout
                break
            }
            if Task.isCancelled {
                stop = .cancelled
                break
            }
            let read = pendingRead ?? makeDetachedRead(timeout: remaining + max(60, self.timeout))
            pendingRead = read
            switch await IMAPReadRace.wait(for: read, timeout: remaining, cancellable: true) {
            case .data(let data):
                pendingRead = nil
                guard !data.isEmpty else { throw TransportError.closed }
                parser.append(data)
            case .failure(TransportError.timeout):
                pendingRead = nil
                stop = .timeout
            case .failure(let error):
                pendingRead = nil
                throw error
            case .deadline:
                stop = .timeout
            case .cancelled:
                stop = .cancelled
            }
        }

        log("C: DONE")
        try await write(Data("DONE\r\n".utf8))
        while true {
            switch try await readResponse() {
            case .tagged(let tagged) where tagged.tag == tag:
                apply(code: tagged.text.code, text: tagged.text.text)
                if tagged.status != .ok {
                    throw IMAPError.commandFailed(command: "IDLE", response: tagged, mailbox: nil, alert: commandAlert).mailError
                }
                return
            case .untagged(let untagged):
                handle(untagged)
                // After a timeout the caller is still listening; after a stop request or
                // cancellation it isn't.
                if stop == .timeout { _ = onEvent(untagged) }
            case .tagged, .continuation:
                continue
            }
        }
    }

    // MARK: - Logout

    /// Says LOGOUT (waiting briefly for the reply) and closes the connection. Never throws.
    public func logout() async {
        await acquire()
        defer { release() }
        guard state != .disconnected else { return }
        do {
            _ = try await send(IMAPCommandBuilder("LOGOUT").build(), readTimeout: min(timeout, 5))
        } catch {
            // Closing anyway.
        }
        teardown()
    }

    /// Closes the connection without saying goodbye.
    public func disconnect() {
        teardown()
    }

    // MARK: - Serialization

    /// Runs `operation` as the only command sequence in flight; maps errors to `MailError`
    /// and closes the connection when the failure leaves the stream unusable.
    func serialized<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        if Task.isCancelled { throw MailError.cancelled }
        do {
            return try await operation()
        } catch {
            throw handleFailure(error)
        }
    }

    private func acquire() async {
        if !isBusy {
            isBusy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            isBusy = false
        } else {
            // Ownership passes straight to the next waiter.
            waiters.removeFirst().resume()
        }
    }

    // MARK: - Helpers

    var literalMode: IMAPLiteralMode { IMAPLiteralMode(capabilities: capabilities) }

    func builder(_ name: String) -> IMAPCommandBuilder {
        IMAPCommandBuilder(name, literalMode: literalMode, utf8Accepted: utf8Accepted)
    }

    func requireConnection() throws {
        guard state != .disconnected else { throw MailError.connectionFailed("Not connected.") }
    }

    func requireAuthenticated() throws {
        try requireConnection()
        guard state == .authenticated else { throw MailError.protocolError("Not signed in yet.") }
    }

    func requireSelected() throws {
        try requireAuthenticated()
        guard selectedMailbox != nil else { throw MailError.protocolError("No folder is selected.") }
    }

    /// Throws the mapped error unless the command completed with OK.
    func check(_ result: IMAPCommandResult, command: String, mailbox rawPath: String? = nil) throws {
        guard result.tagged.status != .ok else { return }
        let decoded = rawPath.map { utf8Accepted ? $0 : ModifiedUTF7.decode($0) }
        throw IMAPError.commandFailed(command: command, response: result.tagged, mailbox: decoded, alert: commandAlert).mailError
    }

    /// Sends a command and requires OK.
    func execute(_ command: IMAPCommand) async throws -> IMAPCommandResult {
        let result = try await send(command)
        try check(result, command: command.name)
        return result
    }
}

/// What a command produced: its completion and the untagged responses that arrived meanwhile.
struct IMAPCommandResult: Sendable {
    var tag: String
    var command: String
    var tagged: IMAPTaggedResponse
    var untagged: [IMAPUntagged]
}
