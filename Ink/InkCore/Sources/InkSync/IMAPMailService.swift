import Foundation
import InkModel
import InkIMAP
import InkSMTP
import InkMIME
import InkProviders

/// The `MailService` for real accounts: IMAP for reading and organising mail, SMTP for sending.
///
/// Connections:
/// - One IMAP connection carries every command. It is opened lazily (connect, sign in with the
///   account's password or OAuth token, `ID`), reused while it is healthy, and replaced when it
///   has been idle longer than `Options.maxIdleReuse` (servers and NAT boxes drop quiet
///   connections). When a reused connection turns out to be dead, the operation reconnects and
///   runs once more.
/// - Each `watch(mailbox:)` has its own connection that sits in IDLE.
/// - Each `send` opens its own SMTP connection.
///
/// Operations on the command connection run one at a time (SELECT followed by FETCH must not be
/// interleaved with another caller's SELECT). The folder list is fetched once per session and
/// reused to resolve roles (Sent, Trash, Archive, All Mail …) for actions; a mailbox is
/// re-selected only when a different one is selected.
///
/// Gmail (`X-GM-EXT-1`) is handled natively: summaries carry X-GM-THRID / X-GM-MSGID / labels,
/// archiving drops the Inbox label (MOVE to All Mail), search uses `X-GM-RAW` in All Mail, and
/// "move to inbox" finds messages by X-GM-MSGID.
///
/// Every method throws `MailError`.
public actor IMAPMailService: MailService {
    /// Tuning knobs. The defaults suit real servers; tests shorten the timers.
    public struct Options: Sendable {
        /// Seconds to wait for each server reply.
        public var timeout: TimeInterval
        /// Bytes of a text/plain part fetched to make a snippet.
        public var snippetBytes: Int
        /// Bytes of a text/html part fetched to make a snippet (markup takes room).
        public var htmlSnippetBytes: Int
        /// Messages per FETCH command when fetching summaries or snippets.
        public var fetchBatchSize: Int
        /// A command connection unused for longer than this is replaced instead of reused.
        public var maxIdleReuse: TimeInterval
        /// How long one IDLE lasts before it is renewed (servers end IDLE after ~30 minutes).
        public var idleRefresh: TimeInterval
        /// IDLE renewal on Gmail, which drops connections idle for about 10 minutes (RESEARCH §3.5).
        public var gmailIdleRefresh: TimeInterval
        /// On servers whose IDLE doesn't report deletions (Yahoo, AOL; RESEARCH §3.4), IDLE is
        /// renewed this often and each renewal reports `.changed`, so a re-sync notices them.
        public var deletionCheckInterval: TimeInterval
        /// How often `watch` polls with NOOP when the server has no IDLE (or refuses it).
        public var pollInterval: TimeInterval
        /// Waits between reconnection attempts in `watch`; the last one repeats.
        public var reconnectDelays: [TimeInterval]
        /// Consecutive failed reconnections after which `watch` reports `.connectionLost` and ends.
        public var maxWatchFailures: Int
        /// Sent with IMAP `ID` (RFC 2971) after signing in when the server supports it; nil sends nothing.
        public var clientID: [String: String]?
        /// Search message bodies with `BODY` (true) or `TEXT` (false, faster on some servers).
        public var searchBodies: Bool
        /// Host name announced in SMTP EHLO.
        public var localHostname: String
        /// Waits before each look for the server's own Sent copy after sending, on an account
        /// not known to file one (RESEARCH §3.8: 0, 1, 1, 2 s). Empty uploads Ink's copy at once.
        public var sentCopyPollDelays: [TimeInterval]
        /// The same once this session has seen the server file a copy (it can be late: §3.8).
        public var sentCopyPatientPollDelays: [TimeInterval]

        public init(timeout: TimeInterval = 30, snippetBytes: Int = 2048, htmlSnippetBytes: Int = 4096, fetchBatchSize: Int = 100,
                    maxIdleReuse: TimeInterval = 10 * 60, idleRefresh: TimeInterval = 25 * 60, pollInterval: TimeInterval = 180,
                    reconnectDelays: [TimeInterval] = [2, 5, 15, 30, 60], maxWatchFailures: Int = 5,
                    clientID: [String: String]? = ["name": "Ink", "version": "1.0"], searchBodies: Bool = true,
                    localHostname: String = "localhost", gmailIdleRefresh: TimeInterval = 9 * 60,
                    deletionCheckInterval: TimeInterval = 5 * 60, sentCopyPollDelays: [TimeInterval] = [0, 1, 1, 2],
                    sentCopyPatientPollDelays: [TimeInterval] = [0, 1, 1, 2, 2, 3, 3]) {
            self.timeout = timeout
            self.snippetBytes = snippetBytes
            self.htmlSnippetBytes = htmlSnippetBytes
            self.fetchBatchSize = fetchBatchSize
            self.maxIdleReuse = maxIdleReuse
            self.idleRefresh = idleRefresh
            self.pollInterval = pollInterval
            self.reconnectDelays = reconnectDelays
            self.maxWatchFailures = maxWatchFailures
            self.clientID = clientID
            self.searchBodies = searchBodies
            self.localHostname = localHostname
            self.gmailIdleRefresh = gmailIdleRefresh
            self.deletionCheckInterval = deletionCheckInterval
            self.sentCopyPollDelays = sentCopyPollDelays
            self.sentCopyPatientPollDelays = sentCopyPatientPollDelays
        }
    }

    public nonisolated let account: AccountConfig
    /// The options this service was made with.
    public nonisolated let options: Options
    nonisolated let connector: IMAPMailServiceConnector
    nonisolated let watchRegistry = IMAPMailServiceWatchRegistry()
    let logger: (@Sendable (String) -> Void)?

    /// The command connection, when one is open.
    var client: IMAPClient?
    /// When the command connection last completed an operation.
    var lastActivity = Date.distantPast
    /// Folders from the last LIST of this session.
    var mailboxCache: [MailboxInfo]?
    /// Summaries this service produced, per mailbox path, for detecting flag changes cheaply.
    var memos: [String: IMAPMailServiceMemo] = [:]
    /// The server mangles partial fetches (`BODY[1]<0.2048>`); snippets then fetch whole text parts.
    var partialFetchBroken = false
    /// Whether this session has seen the server file its own copy of sent mail in Sent (nil:
    /// not known yet). Decides how long `send` looks for that copy before uploading one.
    public internal(set) var serverSavesSentCopies: Bool?

    private var busy = false
    private var waiters: [CheckedContinuation<Void, Never>] = []

    /// A service for `account`, signing in with the secret from `credentials`.
    /// `transportFactory` makes a fresh byte stream for every connection.
    public init(account: AccountConfig, credentials: CredentialStore, transportFactory: @escaping MailTransportFactory) {
        self.init(account: account, credentials: credentials, transportFactory: transportFactory, options: Options(), logger: nil)
    }

    /// A service with custom options. `logger` receives redacted IMAP and SMTP protocol traces
    /// (no passwords, tokens or message contents).
    public init(account: AccountConfig, credentials: CredentialStore, transportFactory: @escaping MailTransportFactory,
                options: Options, logger: (@Sendable (String) -> Void)? = nil) {
        self.account = account
        self.options = options
        self.logger = logger
        self.connector = IMAPMailServiceConnector(account: account, credentials: credentials, transportFactory: transportFactory,
                                                  options: options, logger: logger)
    }

    // MARK: - Verify

    /// Connects and signs in to IMAP, lists the folders, connects and signs in to SMTP, then
    /// says goodbye to both. Uses its own connections, so it works before anything is saved.
    ///
    /// iCloud takes either the name part or the full address as the IMAP user name; when the
    /// configured form is refused, the other is tried once (`verifiedAccount` then has the one
    /// that worked, for the caller to save). Refusals from the big providers come back as
    /// `MailError`s whose detail says what to do (`ProviderErrorAdvice`).
    public func verify(progress: @escaping @Sendable (VerificationStep) -> Void) async throws {
        progress(.connectingIMAP)
        var imap = connector.makeIMAPClient()
        do {
            try await imap.connect()
            progress(.signingInIMAP)
            imap = try await connector.signIn(imap)
            progress(.loadingMailboxes)
            let listed = try await imap.listMailboxes()
            let isGmail = await imap.isGmail
            mailboxCache = IMAPMailServiceRoles.mailboxInfos(from: listed, accountID: account.id, isGmail: isGmail)
            await imap.logout()
        } catch {
            await imap.disconnect()
            throw connector.advise(error, server: .imap)
        }

        progress(.connectingSMTP)
        let smtp = connector.makeSMTPClient()
        do {
            try await smtp.connect()
            progress(.signingInSMTP)
            try await connector.authenticate(smtp)
            await smtp.quit()
        } catch {
            await smtp.quit()
            throw connector.advise(error, server: .smtp)
        }
        progress(.done)
    }

    /// `account` with the IMAP user name that last signed in successfully. Differs from
    /// `account` only for iCloud, when the other user name form worked (see `verify`);
    /// callers should save this version so later sessions don't start with the refused form.
    public nonisolated var verifiedAccount: AccountConfig {
        var result = account
        if let confirmed = connector.usernames.confirmed { result.imap.username = confirmed }
        return result
    }

    // MARK: - Disconnect

    /// Ends live updates and logs out of the command connection. The next call reconnects.
    public func disconnect() async {
        watchRegistry.cancelAll()
        let current = client
        client = nil
        mailboxCache = nil
        await current?.logout()
    }

    // MARK: - Serialisation and connection management

    /// Runs `operation` as the only operation using the command connection.
    func exclusive<T>(_ operation: () async throws -> T) async throws -> T {
        await acquire()
        defer { release() }
        if Task.isCancelled { throw MailError.cancelled }
        do {
            return try await operation()
        } catch {
            throw connector.advise(error, server: .imap)
        }
    }

    private func acquire() async {
        if !busy {
            busy = true
            return
        }
        await withCheckedContinuation { waiters.append($0) }
    }

    private func release() {
        if waiters.isEmpty {
            busy = false
        } else {
            waiters.removeFirst().resume()
        }
    }

    /// Runs `body` with a signed-in command connection. If a reused connection turns out to be
    /// dead (closed or timed out), it is replaced and `body` runs once more on the new one.
    /// Call only inside `exclusive`.
    func withClient<T>(_ body: (IMAPClient) async throws -> T) async throws -> T {
        let (current, reused) = try await commandClient()
        do {
            let result = try await body(current)
            lastActivity = Date()
            return result
        } catch {
            let mapped = Self.mailError(error)
            let mustRetry = error is IMAPMailServiceRetry
            guard mustRetry || (reused && Self.isConnectionLoss(mapped)), !Task.isCancelled else { throw mapped }
            log("The connection was lost (\(mapped.localizedDescription)); reconnecting once.")
            await dropClient()
            let (fresh, _) = try await commandClient()
            let result = try await body(fresh)
            lastActivity = Date()
            return result
        }
    }

    /// The command connection, opening a new one when there is none or the old one is unusable.
    /// The flag says whether an existing connection was reused.
    private func commandClient() async throws -> (IMAPClient, Bool) {
        if let current = client {
            let state = await current.state
            if state == .authenticated, Date().timeIntervalSince(lastActivity) < options.maxIdleReuse {
                return (current, true)
            }
            client = nil
            // Idle too long or already broken: close without waiting on a possibly dead socket.
            await current.disconnect()
        }
        let fresh = try await connector.openIMAP()
        client = fresh
        lastActivity = Date()
        return (fresh, false)
    }

    private func dropClient() async {
        let current = client
        client = nil
        await current?.disconnect()
    }

    /// Selects `rawPath` unless it is already the selected mailbox.
    func ensureSelected(_ rawPath: String, client: IMAPClient) async throws -> IMAPSelectInfo {
        if let selected = await client.selectedMailbox, selected.mailbox == rawPath { return selected }
        let condstore = await client.supports("CONDSTORE")
        return try await client.select(rawPath, condstore: condstore)
    }

    // MARK: - Helpers

    /// Converts any error to `MailError`.
    static func mailError(_ error: Error) -> MailError {
        IMAPError.mailError(for: error)
    }

    /// Errors after which the connection is gone and a retry on a new one may succeed.
    static func isConnectionLoss(_ error: MailError) -> Bool {
        switch error {
        case .connectionFailed, .timeout: return true
        default: return false
        }
    }

    /// `MessageSummary.id` for a message in `path`.
    func summaryID(path: String, uidValidity: UInt32, uid: UInt32) -> String {
        "\(account.id)|\(path)|\(uidValidity)|\(uid)"
    }

    func log(_ line: String) {
        logger?("Ink: \(line)")
    }
}

/// Thrown inside an operation to have `withClient` reconnect and run it again once.
enum IMAPMailServiceRetry: Error, LocalizedError {
    /// The server broke the connection over a partial fetch; snippets now avoid them.
    case partialFetchFailed

    var errorDescription: String? { "The server couldn't handle a partial fetch." }
}

// MARK: - Connector

/// Opens and signs in IMAP and SMTP connections for one account. Shared by the command
/// connection, `verify`, `send` and each `watch`, so it holds no mutable state.
struct IMAPMailServiceConnector: Sendable {
    let account: AccountConfig
    let credentials: CredentialStore
    let transportFactory: MailTransportFactory
    let options: IMAPMailService.Options
    let logger: (@Sendable (String) -> Void)?
    /// The IMAP user name that worked, shared by every connection of the service.
    let usernames = IMAPMailServiceUsernameMemory()

    init(account: AccountConfig, credentials: CredentialStore, transportFactory: @escaping MailTransportFactory,
         options: IMAPMailService.Options, logger: (@Sendable (String) -> Void)?) {
        self.account = account
        self.credentials = credentials
        self.transportFactory = transportFactory
        self.options = options
        self.logger = logger
    }

    func makeIMAPClient() -> IMAPClient {
        let logger = self.logger
        return IMAPClient(host: account.imap.host, port: account.imap.port, security: account.imap.security,
                          transport: transportFactory(), timeout: options.timeout,
                          logger: logger.map { log in { @Sendable line in log("IMAP \(line)") } })
    }

    func makeSMTPClient() -> SMTPClient {
        let logger = self.logger
        return SMTPClient(host: account.smtp.host, port: account.smtp.port, security: account.smtp.security,
                          transport: transportFactory(), localHostname: options.localHostname, timeout: options.timeout,
                          logger: logger.map { log in { @Sendable line in log("SMTP \(line)") } })
    }

    /// A connected, signed-in IMAP client (with `ID` sent when configured and supported).
    func openIMAP() async throws -> IMAPClient {
        var client = makeIMAPClient()
        do {
            try await client.connect()
            client = try await signIn(client)
            if let fields = options.clientID, !fields.isEmpty {
                // Some servers (NetEase, some hosting panels) insist on ID; others ignore it.
                do {
                    try await client.id(fields)
                } catch let error as MailError where !IMAPMailService.isConnectionLoss(error) {
                    // A refusal doesn't matter.
                }
            }
            return client
        } catch {
            await client.disconnect()
            throw advise(error, server: .imap)
        }
    }

    /// A connected, signed-in SMTP client.
    func openSMTP() async throws -> SMTPClient {
        let client = makeSMTPClient()
        do {
            try await client.connect()
            try await authenticate(client)
            return client
        } catch {
            await client.quit()
            throw advise(error, server: .smtp)
        }
    }

    /// Signs a connected `client` in and returns the signed-in client.
    ///
    /// iCloud accepts the name part of the address or the full address as the IMAP user name
    /// (RESEARCH §2.2). Until one form has worked in this service, a refused form is retried once
    /// with the other: on the same connection when the server kept it open, else on a fresh one
    /// (then that one is returned and `client` is closed). The form that works is remembered for
    /// every later connection. Other providers get exactly one attempt (Yahoo locks accounts
    /// out after repeated failures; §3.7).
    ///
    /// A refusal comes back with provider advice (`ProviderErrorAdvice`); a failure of the
    /// credential store (locked keychain, expired sign-in) comes back as the store reported it.
    func signIn(_ client: IMAPClient) async throws -> IMAPClient {
        let credential = try await credential()
        do {
            return try await signIn(client, credential: credential)
        } catch {
            throw adviseRefusal(error, server: .imap)
        }
    }

    private func signIn(_ client: IMAPClient, credential: Credential) async throws -> IMAPClient {
        let configured = Self.username(account.imap, account: account)
        let first = usernames.confirmed ?? configured
        do {
            try await authenticate(client, username: first, credential: credential)
            usernames.confirmed = first
            return client
        } catch {
            let refusal = IMAPMailService.mailError(error)
            guard case .authenticationFailed = refusal, usernames.confirmed == nil,
                  let alternate = Providers.alternateIMAPUsername(for: account, refused: first) else { throw refusal }
            logger?("Ink: iCloud refused that form of the user name; trying the other form once.")
            // On the same connection while the server keeps it open.
            if await client.state == .notAuthenticated {
                do {
                    try await authenticate(client, username: alternate, credential: credential)
                    usernames.confirmed = alternate
                    return client
                } catch {
                    let retryError = IMAPMailService.mailError(error)
                    // Both forms refused: report the first refusal (the server's words for the configured name).
                    if case .authenticationFailed = retryError { throw refusal }
                    guard IMAPMailService.isConnectionLoss(retryError) else { throw retryError }
                }
            }
            // The server hung up after the refusal: the other form on a new connection.
            await client.disconnect()
            let fresh = makeIMAPClient()
            do {
                try await fresh.connect()
                try await authenticate(fresh, username: alternate, credential: credential)
            } catch {
                await fresh.disconnect()
                let retryError = IMAPMailService.mailError(error)
                if case .authenticationFailed = retryError { throw refusal }
                throw retryError
            }
            usernames.confirmed = alternate
            return fresh
        }
    }

    private func authenticate(_ client: IMAPClient, username: String, credential: Credential) async throws {
        switch credential {
        case .password(let password):
            try await client.login(username: username, password: password)
        case .oauth(let token):
            try await client.authenticateXOAUTH2(username: username, accessToken: token.accessToken)
        }
    }

    /// `error` as a `MailError`, with provider advice for server replies that only the person can
    /// act on (IMAP switched off in Outlook). Sign-in refusals get their advice where the server
    /// refused (`adviseRefusal`), so an `.authenticationFailed` from anywhere else, such as the
    /// credential store, is passed on as it is.
    func advise(_ error: Error, server: ProviderErrorAdvice.Server) -> MailError {
        let mapped = IMAPMailService.mailError(error)
        if case .authenticationFailed = mapped { return mapped }
        return adviseRefusal(mapped, server: server)
    }

    /// `error`, a server's answer to signing in, with provider advice (`ProviderErrorAdvice`).
    func adviseRefusal(_ error: Error, server: ProviderErrorAdvice.Server) -> MailError {
        let mapped = IMAPMailService.mailError(error)
        let host = server == .imap ? account.imap.host : account.smtp.host
        return ProviderErrorAdvice.advise(mapped, provider: account.provider, host: host, authMethod: account.authMethod, server: server)
    }

    /// Signs an SMTP client in; a refusal comes back with provider advice.
    func authenticate(_ client: SMTPClient) async throws {
        let username = Self.username(account.smtp, account: account)
        let credential = try await credential()
        do {
            switch credential {
            case .password(let password):
                try await client.login(username: username, password: password)
            case .oauth(let token):
                try await client.authenticateXOAUTH2(username: username, accessToken: token.accessToken)
            }
        } catch {
            throw adviseRefusal(error, server: .smtp)
        }
    }

    private func credential() async throws -> Credential {
        do {
            return try await credentials.credential(for: account)
        } catch let error as MailError {
            throw error
        } catch {
            throw MailError.authenticationFailed(error.localizedDescription)
        }
    }

    private static func username(_ server: ServerConfig, account: AccountConfig) -> String {
        let trimmed = server.username.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? account.emailAddress : trimmed
    }
}

/// The IMAP user name that signed in, shared between the service's connections.
final class IMAPMailServiceUsernameMemory: @unchecked Sendable {
    private let lock = NSLock()
    private var value: String?

    /// The user name that last worked; nil until a sign-in succeeds.
    var confirmed: String? {
        get { lock.withLock { value } }
        set { lock.withLock { value = newValue } }
    }
}

// MARK: - Memo

/// What the service remembers about a mailbox between syncs (in memory only).
struct IMAPMailServiceMemo: Sendable {
    var uidValidity: UInt32
    var byUID: [UInt32: MessageSummary] = [:]
    var exists: UInt32?
    var uidNext: UInt32?
    var highestModSeq: UInt64?
    /// The state the last sync returned for this mailbox (with paged-in UIDs added).
    var lastState: MailboxSyncState?

    /// Whether `state` is the one this memory produced (ignoring `lastSync`), i.e. the caller
    /// has applied everything reported so far.
    func produced(_ state: MailboxSyncState) -> Bool {
        guard let lastState else { return false }
        return lastState.uidValidity == state.uidValidity && lastState.uidNext == state.uidNext
            && lastState.highestModSeq == state.highestModSeq && Set(lastState.knownUIDs) == Set(state.knownUIDs)
    }

    /// Most summaries kept per mailbox; the oldest are dropped first.
    static let capacity = 10_000

    mutating func store(_ summaries: [MessageSummary]) {
        for summary in summaries { byUID[summary.uid] = summary }
        trim()
    }

    mutating func trim() {
        guard byUID.count > Self.capacity else { return }
        let drop = byUID.keys.sorted().prefix(byUID.count - Self.capacity)
        for uid in drop { byUID[uid] = nil }
    }
}

// MARK: - Watch registry

/// Tracks running `watch` tasks so `disconnect()` can stop them.
final class IMAPMailServiceWatchRegistry: @unchecked Sendable {
    private let lock = NSLock()
    private var handles: [UUID: IMAPMailServiceWatchHandle] = [:]

    func add(_ handle: IMAPMailServiceWatchHandle) -> UUID {
        let token = UUID()
        lock.withLock { handles[token] = handle }
        return token
    }

    func remove(_ token: UUID) {
        _ = lock.withLock { handles.removeValue(forKey: token) }
    }

    func cancelAll() {
        let running = lock.withLock { () -> [IMAPMailServiceWatchHandle] in
            let all = Array(handles.values)
            handles.removeAll()
            return all
        }
        for handle in running { handle.cancel() }
    }

    var count: Int { lock.withLock { handles.count } }
}

/// One watch's task, cancellable before or after it starts.
final class IMAPMailServiceWatchHandle: @unchecked Sendable {
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var cancelled = false

    func start(_ task: Task<Void, Never>) {
        let cancelNow = lock.withLock { () -> Bool in
            self.task = task
            return cancelled
        }
        if cancelNow { task.cancel() }
    }

    func cancel() {
        let running = lock.withLock { () -> Task<Void, Never>? in
            cancelled = true
            return task
        }
        running?.cancel()
    }
}
