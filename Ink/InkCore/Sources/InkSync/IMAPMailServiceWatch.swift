import Foundation
import InkModel
import InkIMAP
import InkProviders

// Live updates over a dedicated IDLE connection.
extension IMAPMailService {
    /// Watches `mailbox` on its own connection: SELECT (read-only), then IDLE, renewed every
    /// `Options.idleRefresh` (`Options.gmailIdleRefresh` on Gmail, which drops connections idle for
    /// about ten minutes). Yields `.changed` when messages arrive, disappear or change flags (and
    /// after reconnecting, since something may have happened meanwhile).
    ///
    /// Servers without IDLE, and servers that advertise it but refuse it, are polled with NOOP
    /// every `Options.pollInterval` instead. Yahoo's and AOL's IDLE doesn't report deletions
    /// (RESEARCH §3.4), so there IDLE is renewed every `Options.deletionCheckInterval` and each
    /// renewal yields `.changed` for a re-sync.
    ///
    /// A dropped connection is re-established with backoff (`Options.reconnectDelays`). After
    /// `Options.maxWatchFailures` failed attempts in a row, or a sign-in failure, the stream yields
    /// `.connectionLost` and ends. It also ends when the consuming task is cancelled or stops
    /// iterating, and on `disconnect()`.
    public nonisolated func watch(mailbox: MailboxInfo) -> AsyncStream<MailboxChange> {
        let (stream, continuation) = AsyncStream.makeStream(of: MailboxChange.self, bufferingPolicy: .bufferingNewest(2))
        let watcher = IMAPMailServiceWatcher(connector: connector, mailbox: mailbox, continuation: continuation)
        // Registered and wired for termination before the task exists, so a consumer that goes
        // away at once (or a watch that ends at once) can't leave a connection running.
        let handle = IMAPMailServiceWatchHandle()
        let registry = watchRegistry
        let token = registry.add(handle)
        continuation.onTermination = { _ in
            handle.cancel()
            registry.remove(token)
        }
        handle.start(Task.detached { await watcher.run() })
        return stream
    }
}

/// The loop behind `watch(mailbox:)`.
struct IMAPMailServiceWatcher: Sendable {
    let connector: IMAPMailServiceConnector
    let mailbox: MailboxInfo
    let continuation: AsyncStream<MailboxChange>.Continuation

    private var options: IMAPMailService.Options { connector.options }

    private func log(_ line: String) {
        connector.logger?("Ink watch \(mailbox.path): \(line)")
    }

    func run() async {
        var failures = 0
        var connectedBefore = false
        defer { continuation.finish() }
        while !Task.isCancelled {
            var client: IMAPClient?
            var healthySince: Date?
            do {
                let opened = try await connector.openIMAP()
                client = opened
                let info = try await opened.select(mailbox.rawPath, readOnly: true)
                healthySince = Date()
                if connectedBefore { continuation.yield(.changed) }
                connectedBefore = true
                try await listen(on: opened, exists: info.exists, onHealthy: { failures = 0 })
                await opened.logout()
                return
            } catch {
                await client?.disconnect()
                if Task.isCancelled { return }
                let mapped = connector.advise(error, server: .imap)
                if ProviderErrorAdvice.isAdvice(mapped) {
                    // Something only the person can fix (IMAP switched off, app password revoked).
                    log("Stopping: \(mapped.localizedDescription)")
                    continuation.yield(.connectionLost)
                    return
                }
                switch mapped {
                case .authenticationFailed, .mailboxNotFound, .notSupported, .oauth, .oauthNotConfigured, .tlsFailed:
                    log("Stopping: \(mapped.localizedDescription)")
                    continuation.yield(.connectionLost)
                    return
                case .cancelled:
                    return
                default:
                    break
                }
                // A connection that worked for a while starts the count afresh.
                if let healthySince, Date().timeIntervalSince(healthySince) > 60 { failures = 0 }
                failures += 1
                if failures >= max(1, options.maxWatchFailures) {
                    log("Giving up after \(failures) failures: \(mapped.localizedDescription)")
                    continuation.yield(.connectionLost)
                    return
                }
                let delays = options.reconnectDelays.isEmpty ? [5] : options.reconnectDelays
                let delay = delays[min(failures - 1, delays.count - 1)]
                log("Reconnecting in \(delay)s after: \(mapped.localizedDescription)")
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0, delay) * 1_000_000_000))
                } catch {
                    return
                }
            }
        }
    }

    /// IDLEs (or polls) until the task is cancelled; throws when the connection fails.
    private func listen(on client: IMAPClient, exists: UInt32, onHealthy: () -> Void) async throws {
        let tracker = IMAPMailServiceExistsTracker(exists)
        let continuation = self.continuation
        var canIdle = await client.supports("IDLE")
        let isGmail = await client.isGmail
        let capabilities = await client.capabilities
        let plan = IMAPMailServiceIdlePlan(options: options, isGmail: isGmail,
                                           missesDeletions: Self.idleMissesDeletions(account: connector.account, capabilities: capabilities))
        if !canIdle { log("The server has no IDLE; checking for changes every \(Int(options.pollInterval)) s.") }
        var lastResync = Date()
        while !Task.isCancelled {
            if canIdle {
                do {
                    try await client.idle(timeout: plan.refresh) { event in
                        if tracker.isChange(event) { continuation.yield(.changed) }
                        return true
                    }
                } catch let error as MailError where Self.isRefusal(error) {
                    // Advertised but refused (NO/BAD) on a live connection: poll instead.
                    guard await client.state == .authenticated else { throw error }
                    log("The server refused IDLE (\(error.localizedDescription)); checking for changes every \(Int(options.pollInterval)) s instead.")
                    canIdle = false
                    continue
                }
                if plan.resyncEachRenewal, !Task.isCancelled { continuation.yield(.changed) }
            } else {
                do {
                    try await Task.sleep(nanoseconds: UInt64(max(0.05, options.pollInterval) * 1_000_000_000))
                } catch {
                    return
                }
                let events = try await client.noop()
                if events.contains(where: tracker.isChange) {
                    continuation.yield(.changed)
                    lastResync = Date()
                } else if plan.resyncEachRenewal, Date().timeIntervalSince(lastResync) >= plan.refresh {
                    // NOOP may miss deletions too on these servers.
                    continuation.yield(.changed)
                    lastResync = Date()
                }
            }
            // A full IDLE (or poll) cycle went by: the connection is healthy.
            onHealthy()
        }
    }
}

extension IMAPMailServiceWatcher {
    /// A NO or BAD answer, as opposed to a dead connection.
    static func isRefusal(_ error: MailError) -> Bool {
        switch error {
        case .serverError, .protocolError, .notSupported: return true
        default: return false
        }
    }

    /// Yahoo's and AOL's IDLE reports new mail but not deletions (RESEARCH §3.4). Recognised by
    /// provider, server host, or Yahoo's `XYMHIGHESTMODSEQ` capability.
    static func idleMissesDeletions(account: AccountConfig, capabilities: Set<String>) -> Bool {
        if account.provider == .yahoo || account.provider == .aol { return true }
        if capabilities.contains("XYMHIGHESTMODSEQ") { return true }
        let host = account.imap.host.lowercased()
        return ["yahoo.com", "aol.com"].contains { host == $0 || host.hasSuffix("." + $0) }
    }
}

/// How long each IDLE lasts on a server, and whether renewing it should trigger a re-sync.
struct IMAPMailServiceIdlePlan: Equatable {
    var refresh: TimeInterval
    var resyncEachRenewal: Bool
}

extension IMAPMailServiceIdlePlan {
    init(options: IMAPMailService.Options, isGmail: Bool, missesDeletions: Bool) {
        var refresh = options.idleRefresh
        if isGmail { refresh = min(refresh, options.gmailIdleRefresh) }
        if missesDeletions { refresh = min(refresh, options.deletionCheckInterval) }
        self.refresh = max(0.05, refresh)
        resyncEachRenewal = missesDeletions
    }
}

/// Decides which untagged responses mean "re-sync", remembering the message count so a
/// repeated `EXISTS` with the same number doesn't count.
final class IMAPMailServiceExistsTracker: @unchecked Sendable {
    private let lock = NSLock()
    private var exists: UInt32

    init(_ exists: UInt32) { self.exists = exists }

    func isChange(_ event: IMAPUntagged) -> Bool {
        switch event {
        case .exists(let count):
            return lock.withLock {
                defer { exists = count }
                return count != exists
            }
        case .expunge:
            lock.withLock { exists = exists > 0 ? exists - 1 : 0 }
            return true
        case .vanished(_, let earlier):
            return !earlier
        case .fetch:
            return true
        default:
            return false
        }
    }
}
