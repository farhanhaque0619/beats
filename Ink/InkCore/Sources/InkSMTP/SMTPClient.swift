import Foundation
import InkModel

/// A recipient the server refused during `RCPT TO` (or after it deferred too many recipients).
public struct SMTPRecipientRejection: Sendable, Equatable {
    /// The envelope address as sent.
    public var address: String
    /// The server's reply to `RCPT TO`.
    public var reply: SMTPReply

    public init(address: String, reply: SMTPReply) {
        self.address = address
        self.reply = reply
    }

    /// `grace@example.com: The email account that you tried to reach does not exist.`
    public var message: String {
        let reason = reply.text
        return reason.isEmpty ? "\(address): refused (\(reply.code))" : "\(address): \(reason)"
    }
}

/// What happened to a message `SMTPClient.send` handed to the server.
public struct SMTPSendResult: Sendable, Equatable {
    /// Recipients the server accepted (the message is on its way to them).
    public var accepted: [String]
    /// Recipients the server refused. Non-empty means a partial failure: the others still got it.
    public var rejected: [SMTPRecipientRejection]
    /// The server's final reply for each mail transaction (usually one; more when the server
    /// limits recipients per message with `452 4.5.3`).
    public var finalReplies: [SMTPReply]

    public init(accepted: [String], rejected: [SMTPRecipientRejection], finalReplies: [SMTPReply]) {
        self.accepted = accepted
        self.rejected = rejected
        self.finalReplies = finalReplies
    }

    /// True when some recipients were refused although the message was sent to others.
    public var isPartial: Bool { !rejected.isEmpty }

    /// A sentence for the people who didn't get it, or nil when everyone did.
    public var rejectionSummary: String? {
        guard !rejected.isEmpty else { return nil }
        return "Not delivered to " + rejected.map(\.message).joined(separator: "; ")
    }
}

/// An SMTP submission client (RFC 5321, 6409) over any `MailTransport`.
///
/// Typical use: `connect()`, then `login(...)` or `authenticateXOAUTH2(...)`, then `send(...)` one or
/// more times, then `quit()`. Implicit TLS (465) opens the transport with TLS; STARTTLS (587) upgrades
/// after the first EHLO and refuses to continue if the server doesn't offer it, so credentials never
/// cross an unencrypted connection by accident.
///
/// Calls are serialised: a second call waits until the first finishes, so commands never interleave.
/// Secrets (AUTH payloads) and message contents are never passed to `logger`.
public actor SMTPClient {
    public nonisolated let host: String
    public nonisolated let port: Int
    public nonisolated let security: ConnectionSecurity

    /// EHLO keywords (uppercased) mapped to their parameters (`"SIZE": "35882577"`, `"AUTH": "LOGIN PLAIN XOAUTH2"`, `"8BITMIME": ""`).
    public private(set) var extensions: [String: String] = [:]
    /// The server's 220 greeting.
    public private(set) var greeting: SMTPReply?
    /// True between a successful `connect()` and `quit()` or a fatal error.
    public private(set) var isConnected = false
    /// True after a successful AUTH.
    public private(set) var isAuthenticated = false
    /// True when the server didn't understand EHLO and the client fell back to HELO (no extensions).
    public private(set) var usedHELO = false
    /// The outcome of the last successful `send`.
    public private(set) var lastSendResult: SMTPSendResult?

    private let transport: MailTransport
    private let localHostname: String
    private let timeout: TimeInterval
    private let logger: (@Sendable (String) -> Void)?

    private var parser = SMTPReplyParser()
    private var transportOpen = false
    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// Bytes of message handed to the transport per write while streaming DATA.
    private let dataChunkSize = 256 * 1024

    /// - Parameters:
    ///   - localHostname: the name sent with EHLO. Anything that isn't a plausible host name is replaced with `localhost`.
    ///   - timeout: seconds to wait for each server reply (the reply to the end of DATA gets at least 10 minutes, per RFC 5321 §4.5.3.2).
    ///   - logger: receives a protocol trace (`C: …` / `S: …`) with AUTH payloads and message contents redacted.
    public init(host: String, port: Int, security: ConnectionSecurity, transport: MailTransport, localHostname: String = "localhost", timeout: TimeInterval = 30, logger: (@Sendable (String) -> Void)? = nil) {
        self.host = host
        self.port = port
        self.security = security
        self.transport = transport
        self.localHostname = Self.sanitizedHostname(localHostname)
        self.timeout = timeout > 0 ? timeout : 30
        self.logger = logger
    }

    // MARK: Extensions

    /// SASL mechanisms from the `AUTH` extension, uppercased.
    public var authMechanisms: Set<String> {
        guard let value = extensions["AUTH"] else { return [] }
        return Set(value.split(whereSeparator: { $0 == " " || $0 == "\t" }).map { $0.uppercased() })
    }

    /// The server's `SIZE` limit in bytes, or nil when it declares none (or 0, meaning no fixed limit).
    public var maxMessageSize: Int? {
        guard let value = extensions["SIZE"], let limit = Int(value.trimmingCharacters(in: .whitespaces)), limit > 0 else { return nil }
        return limit
    }

    /// Whether the server advertised an EHLO keyword (case-insensitive).
    public func supports(_ keyword: String) -> Bool { extensions[keyword.uppercased()] != nil }

    // MARK: Connect

    /// Opens the connection, reads the 220 greeting, says EHLO (HELO if EHLO isn't understood) and,
    /// for `.startTLS`, upgrades with STARTTLS and says EHLO again. Calling it while connected does nothing.
    public func connect() async throws {
        try await exclusive {
            guard !isConnected else { return }
            closeTransport()
            do {
                try await transport.open(host: host, port: port, tls: security == .tls, timeout: timeout)
            } catch {
                throw Self.mailError(error)
            }
            transportOpen = true
            do {
                let hello = try await readReply()
                guard hello.code == 220 else {
                    let text = hello.text
                    throw MailError.connectionFailed(text.isEmpty ? "The sending server refused the connection (\(hello.code))." : text)
                }
                greeting = hello
                try await sayHello()
                if security == .startTLS {
                    try await upgradeToTLS()
                }
                isConnected = true
            } catch {
                closeTransport()
                throw Self.mailError(error)
            }
        }
    }

    private func sayHello() async throws {
        extensions = [:]
        usedHELO = false
        let ehlo = try await command("EHLO \(localHostname)")
        if ehlo.code == 250 {
            extensions = Self.parseExtensions(ehlo)
            return
        }
        let helo = try await command("HELO \(localHostname)")
        guard helo.code == 250 else {
            let text = helo.text.isEmpty ? ehlo.text : helo.text
            throw MailError.serverError(text.isEmpty ? "The sending server refused the greeting (\(helo.code))." : text)
        }
        usedHELO = true
    }

    private func upgradeToTLS() async throws {
        guard extensions["STARTTLS"] != nil else {
            throw MailError.tlsFailed("The sending server doesn't offer STARTTLS, so Ink won't send your password over an unencrypted connection.")
        }
        let reply = try await command("STARTTLS")
        guard reply.code == 220 else {
            throw MailError.tlsFailed(reply.text.isEmpty ? "The server refused STARTTLS (\(reply.code))." : reply.text)
        }
        // Anything the server sent after its 220 arrived unencrypted and must not be trusted
        // as if it came over TLS (STARTTLS command injection, CVE-2011-0411).
        guard !parser.hasBufferedBytes else {
            throw MailError.tlsFailed("The server sent unexpected data before the secure connection started.")
        }
        do {
            try await transport.startTLS()
        } catch let error as TransportError {
            if case .tlsFailed(let detail) = error { throw MailError.tlsFailed(detail) }
            throw Self.mailError(error)
        } catch {
            throw MailError.tlsFailed(error.localizedDescription)
        }
        logger?("-- TLS started")
        try await sayHello()
    }

    /// Parses an EHLO reply: the first line is the server's name, each following line a keyword
    /// with optional parameters. Old-style `AUTH=LOGIN PLAIN` lines merge into `AUTH`.
    static func parseExtensions(_ reply: SMTPReply) -> [String: String] {
        var result: [String: String] = [:]
        for line in reply.lines.dropFirst() {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.isEmpty else { continue }
            var keyword: String
            var params: String
            if let space = trimmed.firstIndex(where: { $0 == " " || $0 == "\t" }) {
                keyword = String(trimmed[..<space])
                params = trimmed[space...].trimmingCharacters(in: .whitespaces)
            } else {
                keyword = trimmed
                params = ""
            }
            if keyword.uppercased().hasPrefix("AUTH=") {
                params = String(keyword.dropFirst(5)) + (params.isEmpty ? "" : " " + params)
                keyword = "AUTH"
            }
            keyword = keyword.uppercased()
            guard keyword.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }) else { continue }
            if keyword == "AUTH", let existing = result["AUTH"] {
                var mechanisms = existing.split(separator: " ").map(String.init)
                for mechanism in params.split(separator: " ").map(String.init)
                where !mechanisms.contains(where: { $0.caseInsensitiveCompare(mechanism) == .orderedSame }) {
                    mechanisms.append(mechanism)
                }
                result["AUTH"] = mechanisms.joined(separator: " ")
            } else if result[keyword] == nil {
                result[keyword] = params
            }
        }
        return result
    }

    // MARK: Authentication

    /// Signs in with a password (or app password): AUTH PLAIN with an initial response when the server
    /// offers PLAIN (or advertises nothing), else AUTH LOGIN.
    ///
    /// - Throws: `MailError.authenticationFailed` with the server's text on 535 / 534 / 530 / 538,
    ///   `MailError.notSupported` when the server takes no password mechanism.
    public func login(username: String, password: String) async throws {
        try await exclusive {
            try ensureConnected()
            let mechanisms = authMechanisms
            let offersPlain = mechanisms.contains("PLAIN")
            let offersLogin = mechanisms.contains("LOGIN")
            if !mechanisms.isEmpty && !offersPlain && !offersLogin {
                throw MailError.notSupported("signing in with a password (it only offers \(mechanisms.sorted().joined(separator: ", ")))")
            }
            if offersPlain || !offersLogin {
                let reply = try await authPlain(username: username, password: password)
                if reply.code == 504, offersLogin {
                    try finishAuthentication(try await authLogin(username: username, password: password), advertised: !mechanisms.isEmpty)
                } else {
                    try finishAuthentication(reply, advertised: !mechanisms.isEmpty)
                }
            } else {
                try finishAuthentication(try await authLogin(username: username, password: password), advertised: true)
            }
        }
    }

    private func authPlain(username: String, password: String) async throws -> SMTPReply {
        let payload = SASL.plain(username: username, password: password)
        let (reply, inline) = try await startAuth(mechanism: "PLAIN", initialResponse: payload)
        guard reply.code == 334 else { return reply }
        // The server ignored the initial response and asks for it now.
        if inline, reply.text.isEmpty {
            let answer = try await command(payload, logAs: "[redacted]")
            return answer.code == 334 ? try await abortSASL() : answer
        }
        return try await abortSASL()
    }

    /// The longest AUTH command line, CRLF included (RFC 5321 §4.5.3.1.4).
    static let maxAuthLineLength = 512

    /// Starts `AUTH <mechanism>`. The initial response goes on the same line only when that line
    /// fits in 512 octets; otherwise (long OAuth tokens, RFC 4954 §4) it is sent after the
    /// server's empty `334` challenge. Returns the reply to the last line sent and whether the
    /// initial response went inline. Payloads never reach the log.
    private func startAuth(mechanism: String, initialResponse: String) async throws -> (reply: SMTPReply, inline: Bool) {
        let line = "AUTH \(mechanism) \(initialResponse)"
        if line.utf8.count + 2 <= Self.maxAuthLineLength {
            return (try await command(line, logAs: "AUTH \(mechanism) [redacted]"), true)
        }
        let challenge = try await command("AUTH \(mechanism)")
        guard challenge.code == 334 else { return (challenge, false) }
        return (try await command(initialResponse, logAs: "[redacted]"), false)
    }

    private func authLogin(username: String, password: String) async throws -> SMTPReply {
        var reply = try await command("AUTH LOGIN")
        guard reply.code == 334 else { return reply }
        reply = try await command(SASL.login(username), logAs: "[redacted]")
        guard reply.code == 334 else { return reply }
        return try await command(SASL.login(password), logAs: "[redacted]")
    }

    /// Signs in with an OAuth 2.0 access token using XOAUTH2 (or OAUTHBEARER when only that is offered).
    ///
    /// A rejected token makes the server send a `334` challenge with a base64 JSON error; the client
    /// answers with an empty line (`AQ==` for OAUTHBEARER) and the server then sends the final 535.
    public func authenticateXOAUTH2(username: String, accessToken: String) async throws {
        try await exclusive {
            try ensureConnected()
            let mechanisms = authMechanisms
            let useBearer = !mechanisms.contains("XOAUTH2") && mechanisms.contains("OAUTHBEARER")
            if !mechanisms.isEmpty && !mechanisms.contains("XOAUTH2") && !useBearer {
                throw MailError.notSupported("signing in with OAuth")
            }
            let name = useBearer ? "OAUTHBEARER" : "XOAUTH2"
            let payload = useBearer
                ? SASL.oauthBearer(username: username, accessToken: accessToken, host: host, port: port)
                : SASL.xoauth2(username: username, accessToken: accessToken)
            var reply = try await startAuth(mechanism: name, initialResponse: payload).reply
            var challenge: SASL.OAuthErrorChallenge?
            if reply.code == 334 {
                challenge = SASL.decodeOAuthErrorChallenge(reply.lines.first ?? "")
                reply = try await command(useBearer ? "AQ==" : "", logAs: "(error challenge acknowledged)")
                if reply.code == 334 { reply = try await abortSASL() }
            }
            if reply.code == 235 {
                isAuthenticated = true
                return
            }
            if let challenge, Self.isAuthenticationFailure(reply.code) || reply.code == 501 {
                let serverText = reply.text
                throw MailError.authenticationFailed(serverText.isEmpty ? challenge.explanation : "\(serverText) \(challenge.explanation)")
            }
            try finishAuthentication(reply, advertised: !mechanisms.isEmpty)
        }
    }

    /// Cancels a SASL exchange with `*` (RFC 4954 §4) and returns the server's reply.
    private func abortSASL() async throws -> SMTPReply {
        try await command("*")
    }

    private static func isAuthenticationFailure(_ code: Int) -> Bool {
        [530, 534, 535, 538].contains(code)
    }

    private func finishAuthentication(_ reply: SMTPReply, advertised: Bool) throws {
        if reply.code == 235 {
            isAuthenticated = true
            return
        }
        let text = reply.text
        switch reply.code {
        case 530, 534, 535, 538:
            throw MailError.authenticationFailed(text)
        case 500, 502, 503, 504:
            if !advertised { throw MailError.notSupported("signing in (it doesn't offer authentication)") }
            if reply.code == 504 { throw MailError.notSupported("this sign-in method") }
            throw MailError.authenticationFailed(text)
        case 400..<500:
            throw MailError.serverError(text.isEmpty ? "The sending server couldn't check your password right now. Try again in a moment." : text)
        default:
            throw MailError.authenticationFailed(text)
        }
    }

    // MARK: Send

    /// Sends `message` (a complete RFC 5322 message) to `recipients`.
    ///
    /// Declares `SIZE=` when the server supports it (and refuses up front if the message is over the
    /// server's limit), `BODY=8BITMIME` when the message has 8-bit bytes, and `SMTPUTF8` when an address
    /// or a header needs it. Non-ASCII domains are converted to `xn--` form for servers without SMTPUTF8.
    /// Recipients are sent one `RCPT TO` each (pipelined when the server offers PIPELINING). Recipients
    /// the server refuses are collected; the message still goes to the rest, and only when nobody is
    /// accepted does the call throw. When the server defers recipients with `452 4.5.3` (too many),
    /// they go in a further transaction.
    ///
    /// - Returns: who got it and who was refused. Refusals don't throw unless everyone was refused.
    /// - Throws: `MailError.sendFailed` ("<address>: <reason>" for refused recipients, "too large" for
    ///   size limits, the server's text otherwise), `.authenticationFailed` on 530, `.timeout`,
    ///   `.connectionFailed`.
    @discardableResult
    public func send(from: String, recipients: [String], message: Data) async throws -> SMTPSendResult {
        try await exclusive {
            try ensureConnected()
            if Task.isCancelled { throw MailError.cancelled }

            let sender: String
            do {
                sender = try SMTPAddress.clean(from, allowEmpty: true)
            } catch {
                throw MailError.sendFailed("The sender address “\(Self.printable(from))” isn't valid.")
            }
            var cleaned: [String] = []
            var seen = Set<String>()
            for raw in recipients {
                let address: String
                do {
                    address = try SMTPAddress.clean(raw, allowEmpty: false)
                } catch SMTPAddress.Problem.empty {
                    continue
                } catch {
                    throw MailError.sendFailed("“\(Self.printable(raw))” isn't a valid email address.")
                }
                if seen.insert(address.lowercased()).inserted { cleaned.append(address) }
            }
            guard !cleaned.isEmpty else { throw MailError.sendFailed("There's no one to send this to.") }

            let traits = MessageTraits.scan(message)
            let size = SMTPDataEncoder.encodedLength(of: message)
            if let limit = maxMessageSize, size > limit {
                throw MailError.sendFailed(Self.tooLargeMessage(size: size, limit: limit))
            }

            let supportsUTF8 = extensions["SMTPUTF8"] != nil
            var needsUTF8 = traits.hasEightBitHeaders && supportsUTF8
            func envelopeForm(_ address: String) throws -> String {
                if SMTPAddress.isASCII(address) { return address }
                if supportsUTF8 {
                    needsUTF8 = true
                    return address
                }
                if let ascii = SMTPAddress.asciiForm(address) { return ascii }
                throw MailError.sendFailed("This server can't send mail to or from “\(address)”: it doesn't support international addresses.")
            }
            let envelopeSender = try sender.isEmpty ? "" : envelopeForm(sender)
            var envelopeRecipients: [String] = []
            var originalFor: [String: String] = [:]
            for address in cleaned {
                let form = try envelopeForm(address)
                originalFor[form] = address
                envelopeRecipients.append(form)
            }

            var parameters: [String] = []
            if extensions["SIZE"] != nil { parameters.append("SIZE=\(size)") }
            if traits.hasEightBit, extensions["8BITMIME"] != nil || needsUTF8 { parameters.append("BODY=8BITMIME") }
            if needsUTF8 { parameters.append("SMTPUTF8") }

            var accepted: [String] = []
            var rejected: [SMTPRecipientRejection] = []
            var finalReplies: [SMTPReply] = []
            var pending = envelopeRecipients
            while !pending.isEmpty {
                let outcome = try await transaction(from: envelopeSender, parameters: parameters, recipients: pending, message: message, size: size)
                accepted += outcome.accepted
                rejected += outcome.rejected
                if let final = outcome.final { finalReplies.append(final) }
                if outcome.accepted.isEmpty {
                    rejected += outcome.deferred
                    break
                }
                pending = outcome.deferred.map(\.address)
            }

            rejected = rejected.map { SMTPRecipientRejection(address: originalFor[$0.address] ?? $0.address, reply: $0.reply) }
            accepted = accepted.map { originalFor[$0] ?? $0 }
            guard !accepted.isEmpty else {
                throw MailError.sendFailed(rejected.map(\.message).joined(separator: "; "))
            }
            let result = SMTPSendResult(accepted: accepted, rejected: rejected, finalReplies: finalReplies)
            if let summary = result.rejectionSummary { logger?("-- partial delivery: \(summary)") }
            lastSendResult = result
            return result
        }
    }

    private struct TransactionOutcome {
        var accepted: [String] = []
        var rejected: [SMTPRecipientRejection] = []
        var deferred: [SMTPRecipientRejection] = []
        var final: SMTPReply?
    }

    private func transaction(from sender: String, parameters: [String], recipients: [String], message: Data, size: Int) async throws -> TransactionOutcome {
        let mailCommand = (["MAIL FROM:<\(sender)>"] + parameters).joined(separator: " ")
        let rcptCommands = recipients.map { "RCPT TO:<\($0)>" }

        let mailReply: SMTPReply
        var rcptReplies: [SMTPReply] = []
        if extensions["PIPELINING"] != nil {
            try await writeLines([mailCommand] + rcptCommands)
            mailReply = try await readReply()
            for _ in rcptCommands { rcptReplies.append(try await readReply()) }
        } else {
            mailReply = try await command(mailCommand)
            if mailReply.isPositiveCompletion {
                for rcpt in rcptCommands { rcptReplies.append(try await command(rcpt)) }
            }
        }
        guard mailReply.isPositiveCompletion else {
            await resetQuietly()
            throw mailFromError(mailReply, sender: sender, size: size)
        }

        var outcome = TransactionOutcome()
        for (address, reply) in zip(recipients, rcptReplies) {
            if reply.code == 250 || reply.code == 251 {
                outcome.accepted.append(address)
            } else if Self.isTooManyRecipients(reply) {
                outcome.deferred.append(SMTPRecipientRejection(address: address, reply: reply))
            } else if reply.code == 530 {
                await resetQuietly()
                throw MailError.authenticationFailed(reply.text)
            } else {
                outcome.rejected.append(SMTPRecipientRejection(address: address, reply: reply))
            }
        }
        guard !outcome.accepted.isEmpty else {
            await resetQuietly()
            return outcome
        }

        let dataReply = try await command("DATA")
        guard dataReply.code == 354 else {
            await resetQuietly()
            throw dataError(dataReply, size: size)
        }
        try await streamMessage(message)
        let final = try await readReply(timeout: max(timeout, 600))
        guard final.isPositiveCompletion else {
            throw dataError(final, size: size)
        }
        outcome.final = final
        return outcome
    }

    private func streamMessage(_ message: Data) async throws {
        var encoder = SMTPDataEncoder()
        logger?("C: [message, \(message.count) bytes]")
        var offset = message.startIndex
        while offset < message.endIndex {
            if Task.isCancelled {
                // Dropping the connection mid-DATA makes the server discard the partial message.
                closeTransport()
                throw MailError.cancelled
            }
            let end = message.index(offset, offsetBy: dataChunkSize, limitedBy: message.endIndex) ?? message.endIndex
            let encoded = encoder.encode(message[offset..<end])
            if !encoded.isEmpty { try await write(encoded) }
            offset = end
        }
        try await write(encoder.finish())
        logger?("C: .")
    }

    private static func isTooManyRecipients(_ reply: SMTPReply) -> Bool {
        guard reply.code == 452 || reply.code == 451 else { return false }
        if reply.enhancedStatus == "4.5.3" { return true }
        return SMTPText.contains(reply.text, "too many recipients")
    }

    private static func isSizeFailure(_ reply: SMTPReply) -> Bool {
        if let status = reply.enhancedStatus, status.hasSuffix(".3.4") || status.hasSuffix(".2.3") { return true }
        return false
    }

    private func mailFromError(_ reply: SMTPReply, sender: String, size: Int) -> MailError {
        if reply.code == 530 { return .authenticationFailed(reply.text) }
        if reply.code == 552 || Self.isSizeFailure(reply) {
            return .sendFailed(Self.tooLargeMessage(size: size, limit: maxMessageSize, serverText: reply.text))
        }
        let text = reply.text
        return .sendFailed(text.isEmpty ? "The server refused the sender <\(sender)> (\(reply.code))." : text)
    }

    private func dataError(_ reply: SMTPReply, size: Int) -> MailError {
        if reply.code == 530 { return .authenticationFailed(reply.text) }
        if reply.code == 552 || Self.isSizeFailure(reply) {
            return .sendFailed(Self.tooLargeMessage(size: size, limit: maxMessageSize, serverText: reply.text))
        }
        let text = reply.text
        return .sendFailed(text.isEmpty ? "The server refused the message (\(reply.code))." : text)
    }

    static func tooLargeMessage(size: Int, limit: Int?, serverText: String? = nil) -> String {
        var sentence = "The message is too large for this server"
        if let limit, size > limit {
            sentence += " (\(formatMegabytes(size)); the limit is \(formatMegabytes(limit)))"
        }
        sentence += "."
        if let serverText, !serverText.isEmpty { sentence += " \(serverText)" }
        return sentence
    }

    private static func formatMegabytes(_ bytes: Int) -> String {
        if bytes < 1_048_576 { return "\(max(1, (bytes + 512) / 1024)) KB" }
        let megabytes = Double(bytes) / 1_048_576
        if megabytes >= 10 { return "\(Int(megabytes.rounded())) MB" }
        return String(format: "%.1f MB", megabytes)
    }

    /// RSET after a failed transaction so the connection can be reused. Errors are ignored.
    private func resetQuietly() async {
        guard transportOpen else { return }
        _ = try? await command("RSET")
    }

    // MARK: Quit

    /// Says QUIT (waiting briefly for 221) and closes the connection. Never throws.
    public func quit() async {
        await exclusive {
            guard transportOpen else { return }
            if isConnected || greeting != nil {
                do {
                    try await writeLines(["QUIT"])
                    _ = try await readReply(timeout: min(timeout, 5))
                } catch {
                    // The connection is going away anyway.
                }
            }
            closeTransport()
        }
    }

    // MARK: Wire

    private func ensureConnected() throws {
        guard isConnected, transportOpen else {
            throw MailError.connectionFailed("Not connected to the sending server.")
        }
    }

    /// Sends one command line and reads its reply. `logAs` replaces the line in the log (for secrets).
    private func command(_ line: String, logAs: String? = nil) async throws -> SMTPReply {
        try await writeLines([line], logAs: logAs)
        return try await readReply()
    }

    private func writeLines(_ lines: [String], logAs: String? = nil) async throws {
        var data = Data()
        for line in lines {
            if let logger {
                logger("C: " + (logAs ?? line))
            }
            data.append(contentsOf: line.utf8)
            data.append(contentsOf: [0x0D, 0x0A])
        }
        try await write(data)
    }

    private func write(_ data: Data) async throws {
        guard transportOpen else { throw MailError.connectionFailed("Not connected to the sending server.") }
        do {
            try await transport.write(data)
        } catch {
            closeTransport()
            throw Self.mailError(error)
        }
    }

    /// Reads one complete reply. A 421 anywhere means the server is closing: it becomes
    /// `MailError.connectionFailed` and the connection is dropped.
    private func readReply(timeout readTimeout: TimeInterval? = nil) async throws -> SMTPReply {
        while true {
            let next: SMTPReply?
            do {
                next = try parser.nextReply()
            } catch {
                closeTransport()
                throw MailError.protocolError(Self.describe(error))
            }
            if let reply = next {
                if let logger {
                    if reply.lines.isEmpty { logger("S: \(reply.code)") }
                    for (index, line) in reply.lines.enumerated() {
                        logger("S: \(reply.code)\(index == reply.lines.count - 1 ? " " : "-")\(line)")
                    }
                }
                if reply.code == 421 {
                    closeTransport()
                    let text = reply.text
                    throw MailError.connectionFailed(text.isEmpty ? "The sending server closed the connection." : text)
                }
                return reply
            }
            guard transportOpen else { throw MailError.connectionFailed("Not connected to the sending server.") }
            let chunk: Data
            do {
                chunk = try await transport.read(timeout: readTimeout ?? timeout)
            } catch {
                closeTransport()
                throw Self.mailError(error)
            }
            parser.append(chunk)
        }
    }

    private func closeTransport() {
        if transportOpen { transport.close() }
        transportOpen = false
        isConnected = false
        isAuthenticated = false
        parser.reset()
    }

    // MARK: Serialisation

    private func exclusive<T>(_ body: () async throws -> T) async rethrows -> T {
        if busy {
            await withCheckedContinuation { waiters.append($0) }
        } else {
            busy = true
        }
        defer {
            if waiters.isEmpty { busy = false } else { waiters.removeFirst().resume() }
        }
        return try await body()
    }

    // MARK: Helpers

    static func mailError(_ error: Error) -> MailError {
        if let error = error as? MailError { return error }
        if error is CancellationError { return .cancelled }
        if let error = error as? TransportError {
            switch error {
            case .timeout: return .timeout
            case .closed: return .connectionFailed("The sending server closed the connection.")
            case .notConnected: return .connectionFailed("Not connected to the sending server.")
            case .connectFailed(let detail): return .connectionFailed(detail)
            case .tlsFailed(let detail): return .tlsFailed(detail)
            case .io(let detail): return .connectionFailed(detail)
            }
        }
        return .connectionFailed(error.localizedDescription)
    }

    private static func describe(_ error: Error) -> String {
        switch error as? SMTPReplyParser.ParseError {
        case .malformedLine(let excerpt)?: return "Unreadable reply from the sending server: “\(excerpt)”."
        case .lineTooLong?: return "The sending server sent an overlong line."
        case .tooManyLines?: return "The sending server sent an overlong reply."
        case nil: return error.localizedDescription
        }
    }

    static func sanitizedHostname(_ name: String) -> String {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        let allowed = trimmed.unicodeScalars.allSatisfy {
            $0.isASCII && (CharacterSet.alphanumerics.contains($0) || "-.[]:".unicodeScalars.contains($0))
        }
        guard !trimmed.isEmpty, allowed, trimmed.count <= 253 else { return "localhost" }
        return trimmed
    }

    private static func printable(_ text: String) -> String {
        String(text.unicodeScalars.filter { $0.value >= 0x20 && $0.value != 0x7F }.map(Character.init)).trimmingCharacters(in: .whitespaces)
    }
}
