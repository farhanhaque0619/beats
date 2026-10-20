import XCTest
import InkModel
import InkIMAP
@testable import InkSync

/// `watch(mailbox:)`: IDLE events, reconnection with backoff, giving up, polling without IDLE.
final class IMAPMailServiceWatchTests: XCTestCase {
    typealias T = IMAPServiceTranscripts
    typealias F = IMAPServiceFixtures

    let account = F.account()
    var inbox: MailboxInfo { F.mailbox("INBOX", role: .inbox, accountID: account.id) }

    static let examine = ScriptedTransport.Step.expect("* EXAMINE INBOX", reply: IMAPServiceFixtures.crlf("""
    * FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)
    * 3 EXISTS
    * 0 RECENT
    * OK [UIDVALIDITY 1792470281] UIDs valid
    * OK [UIDNEXT 4] Predicted next UID

    """) + "{TAG} OK [READ-ONLY] Examine completed (0.001 + 0.000 secs).\r\n")

    /// Collects stream values in the background.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MailboxChange] = []
        private(set) var finished = false
        func append(_ value: MailboxChange) { lock.withLock { values.append(value) } }
        func finish() { lock.withLock { finished = true } }
        var snapshot: [MailboxChange] { lock.withLock { values } }
        var isFinished: Bool { lock.withLock { finished } }
    }

    private func collect(_ stream: AsyncStream<MailboxChange>) -> (Collector, Task<Void, Never>) {
        let collector = Collector()
        let task = Task {
            for await value in stream { collector.append(value) }
            collector.finish()
        }
        return (collector, task)
    }

    private func wait(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testIdleReportsNewMailAndStopsCleanly() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            Self.examine,
            // The same count again is not news; a higher one is; RECENT alone isn't.
            .expect("* IDLE", reply: "+ idling\r\n* 3 EXISTS\r\n* 1 RECENT\r\n* 4 EXISTS\r\n"),
            .expect("DONE", reply: "A003 OK Idle completed (0.001 + 4.320 secs).\r\n"),
            T.logoutStep,
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let (collector, task) = collect(service.watch(mailbox: inbox))
        await wait { collector.snapshot == [.changed] }
        XCTAssertEqual(service.watchRegistry.count, 1)
        await service.disconnect()
        await wait { collector.isFinished }
        await wait { script.transcript.contains("LOGOUT") }
        XCTAssertEqual(collector.snapshot, [.changed])
        XCTAssertTrue(script.transcript.contains("A003 IDLE\r\nDONE\r\n"))
        XCTAssertEqual(service.watchRegistry.count, 0)
        task.cancel()
    }

    func testCancellingTheConsumerEndsTheWatch() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            Self.examine,
            .expect("* IDLE", reply: "+ idling\r\n* 2 FETCH (UID 2 FLAGS (\\Seen))\r\n"),
            .expect("DONE", reply: "* 1 EXPUNGE\r\nA003 OK Idle completed.\r\n"),
            T.logoutStep,
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let (collector, task) = collect(service.watch(mailbox: inbox))
        await wait { collector.snapshot == [.changed] }
        task.cancel()
        await wait { service.watchRegistry.count == 0 }
        await wait { script.transcript.contains("LOGOUT") }
    }

    func testReconnectsAfterDropAndReportsChange() async throws {
        let first = ScriptedTransport(T.dovecotLogin() + [
            Self.examine,
            .expect("* IDLE", reply: "+ idling\r\n* BYE Server shutting down.\r\n"),
        ])
        let second = ScriptedTransport(T.dovecotLogin() + [
            Self.examine,
            .expect("* IDLE", reply: "+ idling\r\n"),
            .expect("DONE", reply: "A003 OK Idle completed.\r\n"),
            T.logoutStep,
        ])
        let queue = IMAPServiceTransportQueue([first, second])
        let service = F.service(account, transports: queue)
        let (collector, task) = collect(service.watch(mailbox: inbox))
        await wait { collector.snapshot == [.changed] }
        XCTAssertEqual(queue.openedCount, 2, "reconnected, and reported a change since events may have been missed")
        await service.disconnect()
        await wait { collector.isFinished }
        task.cancel()
    }

    func testGivesUpAfterRepeatedFailures() async throws {
        let queue = IMAPServiceTransportQueue([])
        let service = F.service(account, transports: queue)
        let (collector, task) = collect(service.watch(mailbox: inbox))
        await wait { collector.isFinished }
        XCTAssertEqual(collector.snapshot, [.connectionLost])
        task.cancel()
    }

    func testSignInFailureEndsImmediately() async throws {
        let script = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR IDLE AUTH=PLAIN] Dovecot ready.\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"),
        ])
        let queue = IMAPServiceTransportQueue([script, ScriptedTransport(T.dovecotLogin())])
        let service = F.service(account, transports: queue)
        let (collector, task) = collect(service.watch(mailbox: inbox))
        await wait { collector.isFinished }
        XCTAssertEqual(collector.snapshot, [.connectionLost])
        XCTAssertEqual(queue.openedCount, 1, "no point retrying a wrong password")
        task.cancel()
    }

    func testPollsWithNoopWithoutIdle() async throws {
        var options = F.fastOptions
        options.pollInterval = 0.2
        let script = ScriptedTransport(T.dovecotLogin(capabilities: "IMAP4rev1 UIDPLUS LITERAL+") + [
            Self.examine,
            .expect("* NOOP", reply: "{TAG} OK NOOP completed.\r\n"),
            .expect("* NOOP", reply: "* 5 EXISTS\r\n{TAG} OK NOOP completed.\r\n"),
            T.logoutStep,
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]), options: options)
        let (collector, task) = collect(service.watch(mailbox: inbox))
        await wait(timeout: 15) { collector.snapshot == [.changed] }
        await service.disconnect()
        await wait { collector.isFinished }
        task.cancel()
    }

    func testExistsTracker() {
        let tracker = IMAPMailServiceExistsTracker(10)
        XCTAssertFalse(tracker.isChange(.exists(10)))
        XCTAssertTrue(tracker.isChange(.exists(11)))
        XCTAssertFalse(tracker.isChange(.exists(11)))
        XCTAssertTrue(tracker.isChange(.expunge(3)))
        XCTAssertFalse(tracker.isChange(.exists(10)), "the expunge already brought the count down")
        XCTAssertTrue(tracker.isChange(.fetch(IMAPFetchResponse(seq: 1, uid: 4, flags: ["\\Seen"]))))
        XCTAssertTrue(tracker.isChange(.vanished(IMAPSequenceSet(5), earlier: false)))
        XCTAssertFalse(tracker.isChange(.vanished(IMAPSequenceSet(5), earlier: true)))
        XCTAssertFalse(tracker.isChange(.recent(2)))
        XCTAssertFalse(tracker.isChange(.ok(IMAPResponseText(text: "Still here"))))
    }
}
