import XCTest
import InkModel
import InkIMAP
@testable import InkSync

/// Scripted sessions against Dovecot- and GreenMail-style servers: sync (reset, incremental with
/// and without CONDSTORE, UIDVALIDITY changes), connection handling, actions, sending, verify.
final class IMAPMailServiceSessionTests: XCTestCase {
    typealias T = IMAPServiceTranscripts
    typealias F = IMAPServiceFixtures

    let account = F.account()
    var inbox: MailboxInfo { F.mailbox("INBOX", role: .inbox, accountID: account.id) }

    private func summaryLine(_ seq: Int, _ uid: UInt32, flags: String = "", subject: String, structure: String = T.plainStructure,
                             headers: [String] = []) -> String {
        T.summary(seq: seq, uid: uid, flags: flags, subject: subject, messageID: "msg-\(uid)@example.com", structure: structure, headers: headers)
    }

    // MARK: Reset sync

    func testFirstSyncFetchesNewestWindowWithSnippets() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 5, uidNext: 31, modSeq: 120),
            .expect("* FETCH 4:5 \(T.summaryItemsPrefix)", reply:
                summaryLine(4, 29, flags: "\\Seen", subject: "Lunch?")
                + summaryLine(5, 30, subject: "Invoice", structure: T.mixedStructure,
                              headers: ["List-Unsubscribe: <mailto:billing@example.com>", "Precedence: bulk"])
                + T.ok()),
            .expect("* UID FETCH 30 (UID BODY.PEEK[1.1]<0.2048>)", reply: T.snippet(seq: 5, uid: 30, section: "1.1", text: "Your invoice for October is attached.") + T.ok()),
            .expect("* UID FETCH 29 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 4, uid: 29, text: "Want to grab lunch at noon?\r\n\r\n-- \r\nGrace") + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: nil, limit: 2)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(result.upserted.map(\.uid), [30, 29], "newest first")
        XCTAssertEqual(result.state, MailboxSyncState(uidValidity: 1792470281, uidNext: 31, highestModSeq: 120, knownUIDs: [29, 30],
                                                      lastSync: result.state.lastSync))
        let invoice = result.upserted[0], lunch = result.upserted[1]
        XCTAssertEqual(invoice.snippet, "Your invoice for October is attached.")
        XCTAssertTrue(invoice.hasAttachments)
        XCTAssertTrue(invoice.isBulk)
        XCTAssertEqual(invoice.listUnsubscribe, "<mailto:billing@example.com>")
        XCTAssertEqual(lunch.snippet, "Want to grab lunch at noon?")
        XCTAssertFalse(lunch.isUnread)
        XCTAssertEqual(lunch.mailboxPath, "INBOX")
        XCTAssertEqual(lunch.id, "\(account.id)|INBOX|1792470281|29")
        XCTAssertFalse(script.transcript.contains("BODY.PEEK[]"), "sync never downloads whole messages")
    }

    func testLargeWindowsAreFetchedInBatches() async throws {
        var options = F.fastOptions
        options.fetchBatchSize = 2
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 5, uidNext: 6, modSeq: 1),
            .expect("* FETCH 1:2 \(T.summaryItemsPrefix)", reply: summaryLine(1, 1, subject: "1") + summaryLine(2, 2, subject: "2") + T.ok()),
            .expect("* FETCH 3:4 \(T.summaryItemsPrefix)", reply: summaryLine(3, 3, subject: "3") + summaryLine(4, 4, subject: "4") + T.ok()),
            .expect("* FETCH 5 \(T.summaryItemsPrefix)", reply: summaryLine(5, 5, subject: "5") + T.ok()),
            .expect("* UID FETCH 1:2 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
            .expect("* UID FETCH 3:4 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
            .expect("* UID FETCH 5 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]), options: options)
        let result = try await service.sync(mailbox: inbox, previous: nil, limit: 50)
        XCTAssertEqual(result.upserted.map(\.uid), [5, 4, 3, 2, 1])
    }

    func testEmptyMailboxAndUnknownUIDNext() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            .expect("* SELECT INBOX (CONDSTORE)", reply: "* 0 EXISTS\r\n* OK [UIDVALIDITY 9] Ok\r\n{TAG} OK [READ-WRITE] Selected\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: nil, limit: 50)
        XCTAssertTrue(result.upserted.isEmpty)
        XCTAssertEqual(result.state.uidValidity, 9)
        XCTAssertEqual(result.state.uidNext, 1)
        XCTAssertTrue(result.state.knownUIDs.isEmpty)
    }

    // MARK: Incremental sync with CONDSTORE

    func testIncrementalCondstoreSyncAfterRelaunch() async throws {
        // A new process: the service has no memory of summaries, so changed messages get full summaries.
        let previous = MailboxSyncState(uidValidity: 1792470281, uidNext: 5, highestModSeq: 10, knownUIDs: [1, 2, 3, 4])
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 4, uidNext: 7, modSeq: 14),
            .expect("* UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE 10)", reply:
                "* 2 FETCH (UID 2 FLAGS (\\Seen) MODSEQ (12))\r\n* 4 FETCH (UID 6 FLAGS () MODSEQ (14))\r\n" + T.ok()),
            .expect("* UID SEARCH RETURN (ALL) UID 1:* UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 1:2,4,6\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 6 \(T.summaryItemsPrefix)", reply: summaryLine(4, 6, subject: "Brand new") + T.ok()),
            .expect("* UID FETCH 6 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 4, uid: 6, text: "Just arrived.") + T.ok()),
            .expect("* UID FETCH 2 \(T.summaryItemsPrefix)", reply: summaryLine(2, 2, flags: "\\Seen", subject: "Old but read") + T.ok()),
            .expect("* UID FETCH 2 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 2, uid: 2, text: "Read on another device.") + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: previous, limit: 50)
        XCTAssertFalse(result.didReset)
        XCTAssertEqual(result.removedIDs, ["\(account.id)|INBOX|1792470281|3"])
        XCTAssertEqual(result.upserted.map(\.uid), [6, 2])
        XCTAssertEqual(result.upserted.map(\.snippet), ["Just arrived.", "Read on another device."])
        XCTAssertFalse(result.upserted[1].isUnread)
        XCTAssertEqual(result.state.knownUIDs, [1, 2, 4, 6])
        XCTAssertEqual(result.state.uidNext, 7)
        XCTAssertEqual(result.state.highestModSeq, 14)
    }

    func testIncrementalCondstoreSyncWithinSessionUsesMemory() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            // 1. First sync.
            T.dovecotSelect(exists: 2, uidNext: 3, modSeq: 50),
            .expect("* FETCH 1:2 \(T.summaryItemsPrefix)", reply: summaryLine(1, 1, subject: "One") + summaryLine(2, 2, subject: "Two") + T.ok()),
            .expect("* UID FETCH 1:2 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 1, uid: 1, text: "First.") + T.snippet(seq: 2, uid: 2, text: "Second.") + T.ok()),
            // 2. Another device flagged message 2: only flags travel.
            T.dovecotSelect(exists: 2, uidNext: 3, modSeq: 51),
            .expect("* UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE 50)", reply: "* 2 FETCH (UID 2 FLAGS (\\Flagged) MODSEQ (51))\r\n" + T.ok()),
            .expect("* UID SEARCH RETURN (ALL) UID 1:* UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 1:2\r\n{TAG} OK Search completed\r\n"),
            // 3. Nothing changed: just the SELECT.
            T.dovecotSelect(exists: 2, uidNext: 3, modSeq: 51),
            // 4. Message 1 deleted elsewhere (flagged \Deleted, not yet expunged).
            T.dovecotSelect(exists: 2, uidNext: 3, modSeq: 52),
            .expect("* UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE 51)", reply: "* 1 FETCH (UID 1 FLAGS (\\Seen \\Deleted) MODSEQ (52))\r\n" + T.ok()),
            .expect("* UID SEARCH RETURN (ALL) UID 1:* UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 2\r\n{TAG} OK Search completed\r\n"),
            T.logoutStep,
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let first = try await service.sync(mailbox: inbox, previous: nil, limit: 10)
        XCTAssertEqual(first.upserted.count, 2)

        let second = try await service.sync(mailbox: inbox, previous: first.state, limit: 10)
        XCTAssertEqual(second.upserted.count, 1)
        XCTAssertEqual(second.upserted.first?.uid, 2)
        XCTAssertEqual(second.upserted.first?.flags, [.flagged])
        XCTAssertEqual(second.upserted.first?.subject, "Two", "the remembered summary, with new flags")
        XCTAssertEqual(second.upserted.first?.snippet, "Second.")
        XCTAssertEqual(second.state.highestModSeq, 51)

        let third = try await service.sync(mailbox: inbox, previous: second.state, limit: 10)
        XCTAssertTrue(third.upserted.isEmpty)
        XCTAssertTrue(third.removedIDs.isEmpty)
        XCTAssertEqual(third.state.knownUIDs, [1, 2])

        let fourth = try await service.sync(mailbox: inbox, previous: third.state, limit: 10)
        XCTAssertTrue(fourth.upserted.isEmpty)
        XCTAssertEqual(fourth.removedIDs, ["\(account.id)|INBOX|1792470281|1"])
        XCTAssertEqual(fourth.state.knownUIDs, [2])
        await service.disconnect()
        let summaryFetches = script.written.filter { $0.contains("ENVELOPE") }.count
        XCTAssertEqual(summaryFetches, 1, "flag changes never refetch envelopes")
    }

    func testOlderStateFromCallerGetsConservativeAnswer() async throws {
        // The caller dropped the second result and syncs from the first state again: changes the
        // service already reported must be reported again.
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 2, uidNext: 3, modSeq: 50),
            .expect("* FETCH 1:2 \(T.summaryItemsPrefix)", reply: summaryLine(1, 1, subject: "One") + summaryLine(2, 2, subject: "Two") + T.ok()),
            .expect("* UID FETCH 1:2 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
            T.dovecotSelect(exists: 2, uidNext: 3, modSeq: 51),
            .expect("* UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE 50)", reply: "* 2 FETCH (UID 2 FLAGS (\\Flagged) MODSEQ (51))\r\n" + T.ok()),
            .expect("* UID SEARCH RETURN (ALL) UID 1:* UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 1:2\r\n{TAG} OK Search completed\r\n"),
            // Same server state, but the caller is behind: no shortcut, no "unchanged" filtering.
            T.dovecotSelect(exists: 2, uidNext: 3, modSeq: 51),
            .expect("* UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE 50)", reply: "* 2 FETCH (UID 2 FLAGS (\\Flagged) MODSEQ (51))\r\n" + T.ok()),
            .expect("* UID SEARCH RETURN (ALL) UID 1:* UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 1:2\r\n{TAG} OK Search completed\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let first = try await service.sync(mailbox: inbox, previous: nil, limit: 10)
        let second = try await service.sync(mailbox: inbox, previous: first.state, limit: 10)
        XCTAssertEqual(second.upserted.map(\.uid), [2])
        let replay = try await service.sync(mailbox: inbox, previous: first.state, limit: 10)
        XCTAssertEqual(replay.upserted.map(\.uid), [2])
        XCTAssertEqual(replay.upserted.first?.flags, [.flagged])
        XCTAssertEqual(replay.upserted.first?.subject, "Two")
    }

    // MARK: Incremental sync without CONDSTORE

    func testIncrementalSyncWithoutCondstore() async throws {
        let account = F.account(email: "bob@example.com", host: "localhost")
        let inbox = F.mailbox("INBOX", role: .inbox, accountID: account.id)
        let script = ScriptedTransport(T.greenMailLogin() + [
            T.greenMailSelect(exists: 3, uidNext: 4),
            .expect("* FETCH 1:3 \(T.summaryItemsPrefix)", reply:
                summaryLine(1, 1, subject: "A") + summaryLine(2, 2, flags: "\\Seen", subject: "B") + summaryLine(3, 3, subject: "C") + T.ok("FETCH completed.")),
            .expect("* UID FETCH 1:3 (UID BODY.PEEK[1]<0.2048>)", reply:
                // GreenMail's own (space-less) spelling garbles partial replies; whole parts are fetched instead.
                "* 1 FETCH (UID 1 BODY[1]<0>\(F.literal("aaa")))\r\n* 2 FETCH (UID 2 BODY[1]<0>\(F.literal("bbb")))\r\n* 3 FETCH (UID 3 BODY[1]<0>\(F.literal("ccc")))\r\n" + T.ok("FETCH completed.")),
            .expect("* UID FETCH 1:3 (UID BODY.PEEK[1])", reply:
                "* 1 FETCH (UID 1 BODY[1] \(F.literal("Alpha text")))\r\n* 2 FETCH (UID 2 BODY[1] \(F.literal("Bravo text")))\r\n* 3 FETCH (UID 3 BODY[1] \(F.literal("Charlie text")))\r\n" + T.ok("FETCH completed.")),
            // Second sync: B unread again, C gone, D new, A marked \Deleted.
            T.greenMailSelect(exists: 3, uidNext: 5),
            .expect("* UID FETCH 1:* (UID FLAGS)", reply:
                "* 1 FETCH (FLAGS (\\Deleted) UID 1)\r\n* 2 FETCH (FLAGS () UID 2)\r\n* 3 FETCH (FLAGS () UID 4)\r\n" + T.ok("FETCH completed.")),
            .expect("* UID FETCH 4 \(T.summaryItemsPrefix)", reply: summaryLine(3, 4, subject: "D") + T.ok("FETCH completed.")),
            .expect("* UID FETCH 4 (UID BODY.PEEK[1])", reply: "* 3 FETCH (UID 4 BODY[1] \(F.literal("Delta text")))\r\n" + T.ok("FETCH completed.")),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let first = try await service.sync(mailbox: inbox, previous: nil, limit: 10)
        XCTAssertEqual(first.upserted.map(\.snippet), ["Charlie text", "Bravo text", "Alpha text"])
        XCTAssertNil(first.state.highestModSeq)

        let second = try await service.sync(mailbox: inbox, previous: first.state, limit: 10)
        XCTAssertFalse(second.didReset)
        let prefix = "\(account.id)|INBOX|1792471486|"
        XCTAssertEqual(second.removedIDs, [prefix + "1", prefix + "3"])
        XCTAssertEqual(second.upserted.map(\.uid), [4, 2])
        XCTAssertEqual(second.upserted.first?.snippet, "Delta text")
        XCTAssertEqual(second.upserted.last?.isUnread, true)
        XCTAssertEqual(second.upserted.last?.subject, "B")
        XCTAssertEqual(second.state.knownUIDs, [2, 4])
        XCTAssertEqual(second.state.uidNext, 5)
    }

    func testUIDValidityChangeResets() async throws {
        let previous = MailboxSyncState(uidValidity: 111, uidNext: 50, highestModSeq: 900, knownUIDs: [48, 49])
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 1, uidValidity: 222, uidNext: 2, modSeq: 3),
            .expect("* FETCH 1 \(T.summaryItemsPrefix)", reply: summaryLine(1, 1, subject: "After the rebuild") + T.ok()),
            .expect("* UID FETCH 1 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 1, uid: 1, text: "Hello again.") + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: previous, limit: 10)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(result.state.uidValidity, 222)
        XCTAssertEqual(result.upserted.map(\.id), ["\(account.id)|INBOX|222|1"])
        XCTAssertEqual(result.removedIDs, ["\(account.id)|INBOX|111|48", "\(account.id)|INBOX|111|49"])
    }

    func testFloodOfNewMailResetsWindow() async throws {
        let previous = MailboxSyncState(uidValidity: 1792470281, uidNext: 11, highestModSeq: 5, knownUIDs: [9, 10])
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 6, uidNext: 15, modSeq: 9),
            .expect("* UID FETCH 9:* (UID FLAGS) (CHANGEDSINCE 5)", reply: T.ok()),
            .expect("* UID SEARCH RETURN (ALL) UID 9:* UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 9:10,11:14\r\n{TAG} OK Search completed\r\n"),
            .expect("* FETCH 5:6 \(T.summaryItemsPrefix)", reply: summaryLine(5, 13, subject: "13") + summaryLine(6, 14, subject: "14") + T.ok()),
            .expect("* UID FETCH 13:14 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: previous, limit: 2)
        XCTAssertTrue(result.didReset, "four new messages don't fit a window of two")
        XCTAssertEqual(result.upserted.map(\.uid), [14, 13])
        XCTAssertEqual(result.state.knownUIDs, [13, 14])
        XCTAssertEqual(result.removedIDs.count, 2)
    }

    func testBodyStructureFailureFallsBackToMinimalItems() async throws {
        // Exchange fails the whole FETCH when one message's MIME tree is broken.
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 1, uidNext: 8, modSeq: 2),
            .expect("* FETCH 1 \(T.summaryItemsPrefix)", reply: "{TAG} NO [SERVERBUG] Internal error occurred. Refer to server log for more information.\r\n"),
            .expect("* FETCH 1 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODY.PEEK[HEADER.FIELDS",
                    reply: "* 1 FETCH (UID 7 FLAGS () INTERNALDATE \"19-Oct-2026 09:00:05 +0000\" RFC822.SIZE 99 ENVELOPE (\"Mon, 19 Oct 2026 09:00:00 +0000\" \"Broken MIME\" ((\"X\" NIL \"x\" \"example.com\")) NIL NIL NIL NIL NIL NIL \"<b@x>\") "
                        + F.headerFields([]) + ")\r\n" + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: nil, limit: 10)
        XCTAssertEqual(result.upserted.map(\.subject), ["Broken MIME"])
        XCTAssertEqual(result.upserted.first?.snippet, "")
        XCTAssertFalse(result.upserted.first?.hasAttachments ?? true)
    }

    // MARK: Connections

    func testReconnectsOnceWhenReusedConnectionDied() async throws {
        let first = IMAPServiceDroppingTransport(ScriptedTransport(T.dovecotLogin() + [T.listStep()]), dropOn: "SELECT")
        let second = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 0, uidNext: 1, modSeq: 1),
        ])
        let queue = IMAPServiceTransportQueue([first, second])
        let log = IMAPServiceLog()
        let service = F.service(account, transports: queue, log: log)
        let boxes = try await service.mailboxes()
        XCTAssertEqual(boxes.map(\.role), [.inbox, .drafts, .sent, .archive, .junk, .trash, .custom])
        let result = try await service.sync(mailbox: inbox, previous: nil, limit: 10)
        XCTAssertTrue(first.didDrop)
        XCTAssertEqual(queue.openedCount, 2)
        XCTAssertEqual(result.state.uidNext, 1)
        XCTAssertTrue(log.text.contains("reconnecting once"))
        XCTAssertFalse(log.text.contains("correct horse"), "passwords never reach the log")
    }

    func testFreshConnectionFailureIsNotRetried() async throws {
        let queue = IMAPServiceTransportQueue([IMAPServiceRefusingTransport(), IMAPServiceRefusingTransport()])
        let service = F.service(account, transports: queue)
        await assertIMAPServiceThrows(where: { if case .connectionFailed = $0 { return true } else { return false } }) {
            try await service.mailboxes()
        }
        XCTAssertEqual(queue.openedCount, 1)
    }

    func testAuthenticationFailureIsReportedOnce() async throws {
        let script = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"),
        ])
        let queue = IMAPServiceTransportQueue([script, ScriptedTransport([])])
        let service = F.service(account, credential: .password("wrong"), transports: queue)
        await assertIMAPServiceThrows(.authenticationFailed("Authentication failed.")) {
            try await service.mailboxes()
        }
        XCTAssertEqual(queue.openedCount, 1)
    }

    func testMissingCredentialIsAnAuthenticationError() async throws {
        let service = IMAPMailService(account: account, credentials: InMemoryCredentialStore(),
                                      transportFactory: IMAPServiceTransportQueue([ScriptedTransport(T.dovecotLogin())]).factory,
                                      options: F.fastOptions)
        await assertIMAPServiceThrows(where: { if case .authenticationFailed = $0 { return true } else { return false } }) {
            try await service.mailboxes()
        }
    }

    func testIdleConnectionIsReplacedInsteadOfReused() async throws {
        var options = F.fastOptions
        options.maxIdleReuse = 0
        let first = ScriptedTransport(T.dovecotLogin() + [T.listStep()])
        let second = ScriptedTransport(T.dovecotLogin() + [T.listStep()])
        let queue = IMAPServiceTransportQueue([first, second])
        let service = F.service(account, transports: queue, options: options)
        _ = try await service.mailboxes()
        _ = try await service.mailboxes()
        XCTAssertEqual(queue.openedCount, 2)
        XCTAssertFalse(first.isOpen, "the stale connection was closed")
    }

    func testIDIsSentWhenConfigured() async throws {
        var options = F.fastOptions
        options.clientID = ["name": "Ink", "version": "1.0"]
        let script = ScriptedTransport(T.dovecotLogin() + [
            .expect("* ID (\"name\" \"Ink\" \"version\" \"1.0\")", reply: "* ID (\"name\" \"Dovecot\")\r\n{TAG} OK ID completed.\r\n"),
            T.listStep(),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]), options: options)
        _ = try await service.mailboxes()
        XCTAssertTrue(script.transcript.contains("ID (\"name\" \"Ink\""))
    }

    func testConcurrentCallsShareOneConnectionAndDontInterleave() async throws {
        // A server that answers by command, so the calls may run in any order; each FETCH
        // answers with the name of the selected mailbox, exposing any interleaving.
        let server = IMAPServiceResponderTransport(greeting: "* OK [CAPABILITY IMAP4rev1 SASL-IR ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.\r\n") { line, tag, state in
            let command = line.uppercased()
            if command.hasPrefix("SELECT ") {
                let name = line.dropFirst("SELECT ".count).split(separator: " ").first.map { String($0).replacingOccurrences(of: "\"", with: "") } ?? ""
                state["selected"] = name
                return "* 3 EXISTS\r\n* OK [UIDVALIDITY 5] Ok\r\n* OK [UIDNEXT 4] Ok\r\n\(tag) OK [READ-WRITE] Selected\r\n"
            }
            if command.hasPrefix("FETCH ") {
                let name = state["selected"] ?? "?"
                return (1...3).map { T.summary(seq: $0, uid: UInt32($0), subject: name, messageID: "\(name)-\($0)@x") }.joined() + "\(tag) OK Fetch completed\r\n"
            }
            if command.hasPrefix("UID FETCH ") {
                let name = state["selected"] ?? "?"
                return (1...3).map { T.snippet(seq: $0, uid: UInt32($0), text: "in \(name)") }.joined() + "\(tag) OK Fetch completed\r\n"
            }
            if command.hasPrefix("LIST ") { return T.dovecotList + "\(tag) OK List completed\r\n" }
            if command.hasPrefix("AUTHENTICATE ") { return "\(tag) OK [CAPABILITY \(T.dovecotCapabilities)] Logged in\r\n" }
            return "\(tag) OK Done\r\n"
        }
        let queue = IMAPServiceTransportQueue([server])
        let service = F.service(account, transports: queue)
        let archive = F.mailbox("Archive", role: .archive, accountID: account.id)
        let clients = F.mailbox("Clients/Acme", role: .custom, accountID: account.id)
        async let a = service.sync(mailbox: inbox, previous: nil, limit: 3)
        async let b = service.sync(mailbox: archive, previous: nil, limit: 3)
        async let c = service.sync(mailbox: clients, previous: nil, limit: 3)
        async let boxes = service.mailboxes()
        let (inboxResult, archiveResult, clientsResult, listed) = try await (a, b, c, boxes)
        XCTAssertEqual(Set(inboxResult.upserted.map(\.subject)), ["INBOX"])
        XCTAssertEqual(Set(inboxResult.upserted.map(\.snippet)), ["in INBOX"])
        XCTAssertEqual(Set(archiveResult.upserted.map(\.subject)), ["Archive"])
        XCTAssertEqual(Set(archiveResult.upserted.map(\.snippet)), ["in Archive"])
        XCTAssertEqual(Set(clientsResult.upserted.map(\.subject)), ["Clients/Acme"])
        XCTAssertEqual(listed.count, 7)
        XCTAssertEqual(queue.openedCount, 1)
    }

    // MARK: Paging, body

    func testFetchOlderUsesAnchorSequenceNumber() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 40, uidNext: 101, modSeq: 7),
            .expect("* UID FETCH 90 (UID)", reply: "* 31 FETCH (UID 90)\r\n" + T.ok()),
            .expect("* FETCH 28:30 \(T.summaryItemsPrefix)", reply:
                summaryLine(28, 85, subject: "85") + summaryLine(29, 87, subject: "87") + summaryLine(30, 89, subject: "89") + T.ok()),
            .expect("* UID FETCH 85,87,89 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
            // Anchor gone: search instead.
            .expect("* UID FETCH 50 (UID)", reply: T.ok()),
            .expect("* UID SEARCH RETURN (ALL) UID 1:49 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 3,7,12\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 7,12 \(T.summaryItemsPrefix)", reply: summaryLine(2, 7, subject: "7") + summaryLine(3, 12, subject: "12") + T.ok()),
            .expect("* UID FETCH 7,12 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
            // First message: nothing older.
            .expect("* UID FETCH 3 (UID)", reply: "* 1 FETCH (UID 3)\r\n" + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let page = try await service.fetchOlder(mailbox: inbox, olderThanUID: 90, limit: 3)
        XCTAssertEqual(page.map(\.uid), [89, 87, 85])
        let gap = try await service.fetchOlder(mailbox: inbox, olderThanUID: 50, limit: 2)
        XCTAssertEqual(gap.map(\.uid), [12, 7])
        let none = try await service.fetchOlder(mailbox: inbox, olderThanUID: 3, limit: 2)
        XCTAssertTrue(none.isEmpty)
        let trivial = try await service.fetchOlder(mailbox: inbox, olderThanUID: 1, limit: 2)
        XCTAssertTrue(trivial.isEmpty)
        XCTAssertEqual(script.written.filter { $0.contains("SELECT") }.count, 1, "the selected mailbox is reused")
    }

    func testBodyDownloadsAndParsesWholeMessage() async throws {
        let raw = F.crlf("""
        From: Grace Hopper <grace@example.com>
        To: Ada Lovelace <ada@example.com>
        Subject: Slides
        Date: Mon, 19 Oct 2026 09:00:00 +0000
        Message-ID: <msg-77@example.com>
        MIME-Version: 1.0
        Content-Type: multipart/mixed; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8
        Content-Transfer-Encoding: quoted-printable

        Here are the slides =E2=80=94 see attached.
        --b1
        Content-Type: application/pdf; name="deck.pdf"
        Content-Disposition: attachment; filename="deck.pdf"
        Content-Transfer-Encoding: base64

        JVBERi0xLjQK
        --b1--

        """)
        let message = MessageSummary(accountID: account.id, mailboxPath: "INBOX", uid: 77, uidValidity: 1792470281,
                                     messageID: "msg-77@example.com", subject: "Slides", from: [], date: Date())
        let stale = MessageSummary(accountID: account.id, mailboxPath: "INBOX", uid: 5, uidValidity: 42,
                                   messageID: "msg-77@example.com", subject: "Slides", from: [], date: Date())
        let gone = MessageSummary(accountID: account.id, mailboxPath: "INBOX", uid: 99, uidValidity: 1792470281,
                                  subject: "Gone", from: [], date: Date())
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect(exists: 3, uidNext: 100, modSeq: 9),
            .expect("* UID FETCH 77 (UID BODY.PEEK[])", reply: "* 3 FETCH (UID 77 BODY[] \(F.literal(raw)))\r\n" + T.ok()),
            // A summary from an older UIDVALIDITY: found again by Message-ID.
            .expect("* UID SEARCH RETURN (ALL) HEADER MESSAGE-ID \"msg-77@example.com\" UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 77\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 77 (UID BODY.PEEK[])", reply: "* 3 FETCH (UID 77 BODY[] \(F.literal(raw)))\r\n" + T.ok()),
            .expect("* UID FETCH 99 (UID BODY.PEEK[])", reply: T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let body = try await service.body(for: message)
        XCTAssertEqual(body.messageID, message.id)
        XCTAssertEqual(body.plainText?.trimmingCharacters(in: .whitespacesAndNewlines), "Here are the slides — see attached.")
        XCTAssertEqual(body.attachments.map(\.filename), ["deck.pdf"])
        XCTAssertEqual(body.attachments.first?.data, Data("%PDF-1.4\n".utf8))
        let again = try await service.body(for: stale)
        XCTAssertEqual(again.messageID, stale.id)
        XCTAssertEqual(again.attachments.count, 1)
        await assertIMAPServiceThrows(.messageNotFound) { try await service.body(for: gone) }
    }

    // MARK: Actions

    private func summary(_ uid: UInt32, in path: String = "INBOX", validity: UInt32 = 1792470281, messageID: String? = nil) -> MessageSummary {
        MessageSummary(accountID: account.id, mailboxPath: path, uid: uid, uidValidity: validity,
                       messageID: messageID ?? "msg-\(uid)@example.com", subject: "S\(uid)", from: [], date: Date())
    }

    func testFlagActionsGroupByMailbox() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect(exists: 9, uidNext: 10, modSeq: 1),
            .expect("* UID STORE 3:4 +FLAGS.SILENT (\\Seen)", reply: "{TAG} OK Store completed.\r\n"),
            T.dovecotSelect("Clients/Acme", exists: 2, uidNext: 3, modSeq: 1),
            .expect("* UID STORE 2 +FLAGS.SILENT (\\Seen)", reply: "{TAG} OK Store completed.\r\n"),
            .expect("* UID STORE 2 -FLAGS.SILENT (\\Flagged)", reply: "{TAG} OK Store completed.\r\n"),
            T.dovecotSelect(exists: 9, uidNext: 10, modSeq: 1),
            .expect("* UID STORE 4 +FLAGS.SILENT (\\Flagged)", reply: "{TAG} OK Store completed.\r\n"),
            .expect("* UID STORE 4 -FLAGS.SILENT (\\Seen)", reply: "{TAG} OK Store completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.markRead, on: [summary(3), summary(2, in: "Clients/Acme"), summary(4), summary(4)])
        try await service.perform(.unflag, on: [summary(2, in: "Clients/Acme")])
        try await service.perform(.flag, on: [summary(4)])
        try await service.perform(.markUnread, on: [summary(4)])
        try await service.perform(.markRead, on: [])
    }

    func testArchiveTrashSpamMoveAndDelete() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect(exists: 9, uidNext: 10, modSeq: 1),
            .expect("* UID MOVE 5 \"Archive\"", reply: "* OK [COPYUID 77 5 12] Moved UIDs.\r\n* 5 EXPUNGE\r\n{TAG} OK Move completed.\r\n"),
            .expect("* UID MOVE 6 \"Trash\"", reply: "* OK [COPYUID 78 6 40] Moved UIDs.\r\n* 5 EXPUNGE\r\n{TAG} OK Move completed.\r\n"),
            .expect("* UID MOVE 7 \"Junk\"", reply: "{TAG} OK Move completed.\r\n"),
            .expect("* UID MOVE 8 \"Clients/Acme\"", reply: "{TAG} OK Move completed.\r\n"),
            T.dovecotSelect("Trash", exists: 1, uidNext: 41, modSeq: 1),
            .expect("* UID STORE 40 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Store completed.\r\n"),
            .expect("* UID EXPUNGE 40", reply: "* 1 EXPUNGE\r\n{TAG} OK Expunge completed.\r\n"),
            T.dovecotSelect(exists: 5, uidNext: 10, modSeq: 2),
            .expect("* UID STORE 9 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Store completed.\r\n"),
            .expect("* UID EXPUNGE 9", reply: "{TAG} OK Expunge completed.\r\n"),
            // An unknown destination: the folder list is refreshed once before giving up.
            T.listStep(),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.archive, on: [summary(5)])
        try await service.perform(.archive, on: [summary(1, in: "Archive")])
        try await service.perform(.trash, on: [summary(6)])
        try await service.perform(.markSpam, on: [summary(7)])
        try await service.perform(.move(toPath: "Clients/Acme"), on: [summary(8)])
        try await service.perform(.move(toPath: "INBOX"), on: [summary(1)])
        try await service.perform(.deletePermanently, on: [summary(40, in: "Trash", validity: 1792470281)])
        try await service.perform(.deletePermanently, on: [summary(9)])
        await assertIMAPServiceThrows(.mailboxNotFound("Nope")) {
            try await service.perform(.move(toPath: "Nope"), on: [summary(8)])
        }
    }

    func testArchiveCreatesFolderOnServerWithoutMove() async throws {
        // A server with UIDPLUS but no MOVE and no Archive folder (Courier style, INBOX. prefix).
        let capabilities = "IMAP4rev1 UIDPLUS CHILDREN NAMESPACE IDLE LITERAL+ AUTH=PLAIN"
        let courierList = F.crlf("""
        * LIST (\\Unmarked \\HasChildren) "." "INBOX"
        * LIST (\\HasNoChildren) "." "INBOX.Sent"
        * LIST (\\HasNoChildren) "." "INBOX.Trash"

        """)
        let afterCreate = courierList + "* LIST (\\HasNoChildren) \".\" \"INBOX.Archive\"\r\n"
        let script = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 UIDPLUS CHILDREN NAMESPACE IDLE LITERAL+ AUTH=PLAIN] Courier-IMAP ready.\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY \(capabilities)] LOGIN Ok.\r\n"),
            T.listStep(courierList, extended: false),
            .expect("* CREATE \"INBOX.Archive\"", reply: "{TAG} OK \"INBOX.Archive\" created.\r\n"),
            .expect("* SUBSCRIBE \"INBOX.Archive\"", reply: "{TAG} OK Folder subscribed.\r\n"),
            T.listStep(afterCreate, extended: false),
            .expect("* SELECT INBOX", reply: "* 3 EXISTS\r\n* OK [UIDVALIDITY 1792470281] Ok\r\n* OK [UIDNEXT 9] Ok\r\n{TAG} OK [READ-WRITE] Ok\r\n"),
            .expect("* UID COPY 2,4 \"INBOX.Archive\"", reply: "{TAG} OK [COPYUID 5 2,4 1:2] COPY completed.\r\n"),
            .expect("* UID STORE 2,4 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK STORE completed.\r\n"),
            .expect("* UID EXPUNGE 2,4", reply: "* 2 EXPUNGE\r\n* 3 EXPUNGE\r\n{TAG} OK EXPUNGE completed.\r\n"),
            // The folder now exists: the next archive goes straight there.
            .expect("* UID COPY 6 \"INBOX.Archive\"", reply: "{TAG} OK COPY completed.\r\n"),
            .expect("* UID STORE 6 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK STORE completed.\r\n"),
            .expect("* UID EXPUNGE 6", reply: "{TAG} OK EXPUNGE completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.archive, on: [summary(2), summary(4)])
        try await service.perform(.archive, on: [summary(6)])
        let cached = await service.mailboxCache
        XCTAssertEqual(cached?.first { $0.role == .archive }?.rawPath, "INBOX.Archive")
    }

    func testMoveToInboxFindsMessagesByMessageID() async throws {
        let snoozed = [summary(5, messageID: "a@example.com"), summary(6, messageID: "b@example.com"), summary(7, messageID: "c@example.com")]
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect(exists: 2, uidNext: 10, modSeq: 4),
            // The summaries' old INBOX copies are gone.
            .expect("* UID SEARCH RETURN (ALL) UID 5:7 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK Search completed\r\n"),
            // Already back in the inbox?
            .expect("* UID SEARCH RETURN (ALL) OR HEADER MESSAGE-ID \"a@example.com\" OR HEADER MESSAGE-ID \"b@example.com\" HEADER MESSAGE-ID \"c@example.com\" UNDELETED",
                    reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK Search completed\r\n"),
            // Two of them are in Archive.
            T.dovecotSelect("Archive", exists: 30, uidNext: 31, modSeq: 4),
            .expect("* UID SEARCH RETURN (ALL) OR HEADER MESSAGE-ID \"a@example.com\" OR HEADER MESSAGE-ID \"b@example.com\" HEADER MESSAGE-ID \"c@example.com\" UNDELETED",
                    reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 21,28\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 21,28 (UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])", reply:
                "* 20 FETCH (UID 21 BODY[HEADER.FIELDS (MESSAGE-ID)] \(F.literal("Message-ID: <b@example.com>\r\n\r\n")))\r\n"
                + "* 27 FETCH (UID 28 BODY[HEADER.FIELDS (MESSAGE-ID)] \(F.literal("Message-Id: <A@EXAMPLE.COM>\r\n\r\n")))\r\n" + T.ok()),
            .expect("* UID MOVE 21,28 INBOX", reply: "{TAG} OK Move completed.\r\n"),
            // The third is in Trash.
            T.dovecotSelect("Trash", exists: 3, uidNext: 9, modSeq: 4),
            .expect("* UID SEARCH RETURN (ALL) HEADER MESSAGE-ID \"c@example.com\" UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 8\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID MOVE 8 INBOX", reply: "{TAG} OK Move completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.moveToInbox, on: snoozed)
        XCTAssertTrue(script.transcript.contains("UID MOVE 8 INBOX"))
    }

    func testMoveToInboxFromStatedFolderAndNothingFound() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect("Junk", exists: 4, uidNext: 20, modSeq: 4),
            .expect("* UID SEARCH RETURN (ALL) UID 11 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 11\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID MOVE 11 INBOX", reply: "{TAG} OK Move completed.\r\n"),
            // A message with no Message-ID that's no longer where the summary says.
            .expect("* UID SEARCH RETURN (ALL) UID 12 UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK Search completed\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.moveToInbox, on: [summary(11, in: "Junk")])
        var orphan = summary(12, in: "Junk")
        orphan.messageID = nil
        await assertIMAPServiceThrows(.messageNotFound) { try await service.perform(.moveToInbox, on: [orphan]) }
    }

    func testDeletePermanentlyWithoutUIDPlusSparesOtherDeletedMail() async throws {
        let capabilities = "IMAP4rev1 IDLE LITERAL+ AUTH=PLAIN"
        let script = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "+ \r\n"),
            // The SASL response line carries no tag; the completion belongs to A001.
            .expect("", reply: "A001 OK [CAPABILITY \(capabilities)] Logged in\r\n"),
            T.listStep(T.dovecotList, extended: false),
            .expect("* SELECT \"Trash\"", reply: "* 4 EXISTS\r\n* OK [UIDVALIDITY 1792470281] Ok\r\n{TAG} OK [READ-WRITE] Ok\r\n"),
            .expect("* UID STORE 3 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Store completed.\r\n"),
            .expect("* UID SEARCH DELETED NOT UID 3", reply: "* SEARCH 1 2\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID STORE 1:2 -FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Store completed.\r\n"),
            .expect("* EXPUNGE", reply: "* 3 EXPUNGE\r\n{TAG} OK Expunge completed.\r\n"),
            .expect("* UID STORE 1:2 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Store completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.deletePermanently, on: [summary(3, in: "Trash")])
        XCTAssertTrue(script.transcript.hasSuffix("UID STORE 1:2 +FLAGS.SILENT (\\Deleted)\r\n"))
    }

    func testActionsOnVanishedFolderAreSkipped() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.listStep(),
            .expect("* SELECT \"Old\"", reply: "{TAG} NO [NONEXISTENT] Mailbox doesn't exist: Old\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.markRead, on: [summary(1, in: "Old")])
    }

    // MARK: Search

    func testSearchMatchesEveryWordAnywhere() async throws {
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 9, uidNext: 10, modSeq: 4),
            .expect("* UID SEARCH RETURN (ALL) OR FROM \"invoice\" OR TO \"invoice\" OR SUBJECT \"invoice\" BODY \"invoice\" OR FROM \"board meeting\" OR TO \"board meeting\" OR SUBJECT \"board meeting\" BODY \"board meeting\" UNDELETED",
                    reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 2,5,8\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 5,8 \(T.summaryItemsPrefix)", reply:
                T.summary(seq: 4, uid: 5, subject: "Board meeting invoice", date: "Tue, 13 Oct 2026 09:00:00 +0000", messageID: "m5@x")
                + T.summary(seq: 7, uid: 8, subject: "Re: Board meeting invoice", date: "Mon, 19 Oct 2026 09:00:00 +0000", messageID: "m8@x") + T.ok()),
            .expect("* UID FETCH 5,8 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let results = try await service.search("invoice \"board meeting\"", in: inbox, limit: 2)
        XCTAssertEqual(results.map(\.uid), [8, 5], "newest first, newest `limit` only")
        let none = try await service.search("  ", in: inbox, limit: 5)
        XCTAssertTrue(none.isEmpty)
    }

    func testSearchWithTextKeyAndNonASCII() async throws {
        var options = F.fastOptions
        options.searchBodies = false
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect("Archive", exists: 9, uidNext: 10, modSeq: 4),
            // Non-ASCII terms travel as literals with CHARSET UTF-8 (LITERAL+ here).
            .expect("* UID SEARCH RETURN (ALL) CHARSET UTF-8 OR FROM {4+}", reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK Search completed\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]), options: options)
        let results = try await service.search("Zoë", in: F.mailbox("Archive", role: .archive, accountID: account.id), limit: 5)
        XCTAssertTrue(results.isEmpty)
        XCTAssertTrue(script.transcript.contains("TEXT {4+}\r\nZoë UNDELETED"), script.transcript)
    }

    // MARK: Send

    func testSendFilesCopyInSentWithBcc() async throws {
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(name: "Grace Hopper", address: "grace@example.com")],
                                      bcc: [EmailAddress(name: "Charles Babbage", address: "charles@example.com")],
                                      subject: "Engine notes", body: "Notes attached in spirit.")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com", "charles@example.com"]) + T.smtpData)
        let imap = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            .expect("* APPEND \"Sent\" (\\Seen) \"", reply: "{TAG} OK [APPENDUID 1792470281 12] Append completed.\r\n"),
        ])
        let queue = IMAPServiceTransportQueue([smtp, imap])
        let log = IMAPServiceLog()
        let service = F.service(account, transports: queue, log: log)
        try await service.send(message)
        let sentData = imap.transcript
        XCTAssertTrue(sentData.contains("Bcc: Charles Babbage <charles@example.com>\r\n"), "the Sent copy records the Bcc")
        XCTAssertTrue(sentData.contains("Subject: Engine notes"))
        XCTAssertFalse(smtp.transcript.contains("Bcc:"), "Bcc never goes over SMTP")
        XCTAssertTrue(smtp.transcript.contains("Subject: Engine notes"))
        XCTAssertFalse(log.text.contains("correct horse"))
        XCTAssertFalse(log.text.contains(Data("\u{0}ada@example.com\u{0}correct horse".utf8).base64EncodedString()))
    }

    func testSendCreatesSentFolderWhenMissing() async throws {
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: "grace@example.com")], subject: "Hi", body: "Hello")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com"]) + T.smtpData)
        let imap = ScriptedTransport(T.greenMailLogin() + [
            .expect("* LIST \"\" \"*\"", reply: "* LIST () \".\" \"INBOX\"\r\n{TAG} OK LIST completed.\r\n"),
            .expect("* CREATE \"Sent\"", reply: "{TAG} OK CREATE completed.\r\n"),
            .expect("* SUBSCRIBE \"Sent\"", reply: "{TAG} OK SUBSCRIBE completed.\r\n"),
            .expect("* LIST \"\" \"*\"", reply: "* LIST () \".\" \"INBOX\"\r\n* LIST () \".\" \"Sent\"\r\n{TAG} OK LIST completed.\r\n"),
            .expect("* APPEND \"Sent\" (\\Seen)", reply: "{TAG} OK [APPENDUID 1792471486 1] APPEND completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([smtp, imap]))
        try await service.send(message)
        XCTAssertTrue(imap.transcript.contains("APPEND \"Sent\""))
    }

    func testSendSkipsCopyWhenServerSavesSent() async throws {
        let account = F.account(provider: .outlook, email: "ada@outlook.com", savesSentAutomatically: true)
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: "grace@example.com")], subject: "Hi", body: "Hello")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@outlook.com", recipients: ["grace@example.com"]) + T.smtpData)
        let queue = IMAPServiceTransportQueue([smtp])
        let service = F.service(account, transports: queue)
        try await service.send(message)
        XCTAssertEqual(queue.openedCount, 1, "no IMAP connection at all")
    }

    func testPartialRejectionStillSendsAndFiles() async throws {
        let message = OutgoingMessage(accountID: account.id, from: account.address,
                                      to: [EmailAddress(address: "grace@example.com"), EmailAddress(address: "nobody@example.com")], subject: "Hi", body: "Hello")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com", "nobody@example.com"],
                                                   rcptReplies: ["250 2.1.5 Ok\r\n", "550 5.1.1 <nobody@example.com>: Recipient address rejected: User unknown\r\n"]) + T.smtpData)
        let imap = ScriptedTransport(T.dovecotLogin() + [T.listStep(), .expect("* APPEND \"Sent\"", reply: "{TAG} OK Append completed.\r\n")])
        let log = IMAPServiceLog()
        let service = F.service(account, transports: IMAPServiceTransportQueue([smtp, imap]), log: log)
        try await service.send(message)
        XCTAssertTrue(log.text.contains("nobody@example.com"))
        XCTAssertTrue(imap.transcript.contains("APPEND \"Sent\""))
    }

    func testSendFailureDoesNotFileCopy() async throws {
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: "nobody@example.com")], subject: "Hi", body: "Hello")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["nobody@example.com"],
                                                   rcptReplies: ["550 5.1.1 <nobody@example.com>: Recipient address rejected: User unknown\r\n"])
                                     + [.expect("RSET", reply: "250 2.0.0 Ok\r\n"), .expect("QUIT", reply: "221 2.0.0 Bye\r\n")])
        let queue = IMAPServiceTransportQueue([smtp])
        let service = F.service(account, transports: queue)
        await assertIMAPServiceThrows(where: { if case .sendFailed = $0 { return true } else { return false } }) {
            try await service.send(message)
        }
        XCTAssertEqual(queue.openedCount, 1)
        await assertIMAPServiceThrows(.sendFailed("Add at least one recipient.")) {
            try await service.send(OutgoingMessage(accountID: self.account.id, from: self.account.address, subject: "Nobody"))
        }
    }

    func testAppendFailureAfterSendingIsSwallowed() async throws {
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: "grace@example.com")], subject: "Hi", body: "Hello")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com"]) + T.smtpData)
        let imap = ScriptedTransport(T.dovecotLogin() + [T.listStep(), .expect("* APPEND \"Sent\"", reply: "{TAG} NO [OVERQUOTA] Quota exceeded (mailbox for user is full)\r\n")])
        let log = IMAPServiceLog()
        let service = F.service(account, transports: IMAPServiceTransportQueue([smtp, imap]), log: log)
        try await service.send(message)
        XCTAssertTrue(log.text.contains("couldn't file a copy in Sent"))
    }

    // MARK: Verify

    func testVerifyReportsEachStep() async throws {
        let imap = ScriptedTransport(T.dovecotLogin() + [T.listStep(), T.logoutStep])
        let smtp = ScriptedTransport(Array(T.smtpSession(from: "x", recipients: []).prefix(3)) + [.expect("QUIT", reply: "221 Bye\r\n")])
        let steps = IMAPServiceSteps()
        let service = F.service(account, transports: IMAPServiceTransportQueue([imap, smtp]))
        try await service.verify { steps.append($0) }
        XCTAssertEqual(steps.steps, VerificationStep.allCases)
        XCTAssertTrue(imap.transcript.hasSuffix("LOGOUT\r\n"))
        XCTAssertTrue(smtp.transcript.hasSuffix("QUIT\r\n"))
        let cached = await service.mailboxCache
        XCTAssertEqual(cached?.count, 7)
    }

    func testVerifyStopsAtSMTPSignIn() async throws {
        let imap = ScriptedTransport(T.dovecotLogin() + [T.listStep(), T.logoutStep])
        let smtp = ScriptedTransport([
            .send("220 smtp.example.com ESMTP\r\n"),
            .expect("EHLO", reply: "250-smtp.example.com\r\n250 AUTH PLAIN LOGIN\r\n"),
            .expect("AUTH PLAIN", reply: "535 5.7.8 Error: authentication failed: authentication failure\r\n"),
            .expect("QUIT", reply: "221 Bye\r\n"),
        ])
        let steps = IMAPServiceSteps()
        let service = F.service(account, transports: IMAPServiceTransportQueue([imap, smtp]))
        await assertIMAPServiceThrows(where: { if case .authenticationFailed = $0 { return true } else { return false } }) {
            try await service.verify { steps.append($0) }
        }
        XCTAssertEqual(steps.steps, [.connectingIMAP, .signingInIMAP, .loadingMailboxes, .connectingSMTP, .signingInSMTP])
    }
}
