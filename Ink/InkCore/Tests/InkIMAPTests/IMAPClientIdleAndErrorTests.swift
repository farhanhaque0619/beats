import XCTest
import InkModel
@testable import InkIMAP

/// IDLE, timeouts, dropped connections, serialization and logging.
final class IMAPClientIdleAndErrorTests: XCTestCase {
    private func idleReadyTransport(_ steps: [ScriptedTransport.Step]) -> (IMAPClient, ScriptedTransport) {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY IMAP4rev1 IDLE UIDPLUS] Logged in\r\n"),
            .expect("* SELECT INBOX", reply: "* 5 EXISTS\r\n* OK [UIDVALIDITY 9] ok\r\n{TAG} OK [READ-WRITE] done\r\n"),
        ] + steps)
        return (IMAPClient(host: "h", port: 993, security: .tls, transport: transport), transport)
    }

    private func open(_ client: IMAPClient) async throws {
        try await client.connect()
        try await client.login(username: "ada", password: "pw")
        _ = try await client.select("INBOX")
    }

    // MARK: IDLE

    func testIdleDeliversEventsUntilStopped() async throws {
        let (client, transport) = idleReadyTransport([
            .expect("* IDLE", reply: "+ idling\r\n* 6 EXISTS\r\n* 1 RECENT\r\n* 2 FETCH (FLAGS (\\Seen))\r\n"),
            .expect("DONE", reply: "* 3 EXPUNGE\r\nA003 OK IDLE terminated (Success)\r\n"),
            .expect("* NOOP", reply: "{TAG} OK done\r\n"),
        ])
        let events = EventBox()
        try await withWatchdog(transport) {
            try await open(client)
            try await client.idle { event in
                events.append(event)
                if case .fetch = event { return false }
                return true
            }
            _ = try await client.noop()
        }
        XCTAssertEqual(events.events.count, 3, "events after DONE aren't delivered once the caller said stop")
        XCTAssertEqual(events.events.first, .exists(6))
        let selected = await client.selectedMailbox
        XCTAssertEqual(selected?.exists, 5, "6 EXISTS, then one EXPUNGE")
        XCTAssertTrue(transport.transcript.contains("A003 IDLE\r\nDONE\r\nA004 NOOP\r\n"))
    }

    func testIdleTimeoutSendsDone() async throws {
        let (client, transport) = idleReadyTransport([
            .expect("* IDLE", reply: "+ idling\r\n"),
            .expect("DONE", reply: "* 7 EXISTS\r\nA003 OK IDLE terminated\r\n"),
        ])
        let events = EventBox()
        let start = Date()
        try await withWatchdog(transport) {
            try await open(client)
            try await client.idle(timeout: 0.3) { event in
                events.append(event)
                return true
            }
        }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(start), 0.3)
        XCTAssertTrue(transport.transcript.hasSuffix("A003 IDLE\r\nDONE\r\n"))
        XCTAssertEqual(events.events, [.exists(7)], "after a timeout the caller still hears about changes")
        let state = await client.state
        XCTAssertEqual(state, .authenticated)
    }

    func testIdleCancellationSendsDoneAndLeavesConnectionUsable() async throws {
        let (client, transport) = idleReadyTransport([
            .expect("* IDLE", reply: "+ idling\r\n"),
            .expect("DONE", reply: "A003 OK IDLE terminated\r\n"),
            .expect("* NOOP", reply: "{TAG} OK done\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let task = Task { try await client.idle { _ in true } }
            for _ in 0..<200 where !transport.transcript.contains("IDLE") {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            try await Task.sleep(nanoseconds: 50_000_000)
            task.cancel()
            try await task.value
            _ = try await client.noop()
        }
        XCTAssertTrue(transport.transcript.contains("A003 IDLE\r\nDONE\r\nA004 NOOP\r\n"))
    }

    func testIdleStopRequestedBeforeContinuationWaitsForIt() async throws {
        let (client, transport) = idleReadyTransport([
            .expect("* IDLE", reply: "* 9 EXISTS\r\n+ idling\r\n"),
            .expect("DONE", reply: "A003 OK IDLE terminated\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            try await client.idle { _ in false }
        }
        XCTAssertTrue(transport.transcript.hasSuffix("A003 IDLE\r\nDONE\r\n"))
    }

    func testIdleByeThrowsConnectionFailed() async throws {
        let (client, transport) = idleReadyTransport([
            .expect("* IDLE", reply: "+ idling\r\n* BYE Session expired, please login again.\r\n"),
        ])
        let events = EventBox()
        await assertThrowsMailError(.connectionFailed("The server closed the connection: Session expired, please login again.")) {
            try await withWatchdog(transport) {
                try await open(client)
                try await client.idle { event in
                    events.append(event)
                    return true
                }
            }
        }
        XCTAssertEqual(events.events, [.bye("Session expired, please login again.")])
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
    }

    func testIdleRefusedOrUnsupported() async throws {
        let (client, transport) = idleReadyTransport([
            .expect("* IDLE", reply: "{TAG} BAD IDLE not allowed now\r\n"),
        ])
        await assertThrowsMailError(.protocolError("IDLE was rejected: IDLE not allowed now")) {
            try await withWatchdog(transport) {
                try await open(client)
                try await client.idle { _ in true }
            }
        }
        let bare = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY IMAP4rev1] in\r\n"),
        ])
        let noIdle = IMAPClient(host: "h", port: 993, security: .tls, transport: bare)
        await assertThrowsMailError(.notSupported("IDLE (push updates)")) {
            try await withWatchdog(bare) {
                try await noIdle.connect()
                try await noIdle.login(username: "a", password: "b")
                try await noIdle.idle { _ in true }
            }
        }
    }

    func testIdleWithUnsolicitedDataInSmallChunks() async throws {
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 IDLE AUTH=PLAIN SASL-IR] ready\r\n", maxChunk: 2, seed: 5, [
            ("AUTHENTICATE PLAIN", "{TAG} OK in\r\n"),
            ("CAPABILITY", "* CAPABILITY IMAP4rev1 IDLE\r\n{TAG} OK done\r\n"),
            ("SELECT INBOX", "* 2 EXISTS\r\n{TAG} OK [READ-WRITE] done\r\n"),
            ("IDLE", "+ idling\r\n"),
            ("DONE", "A004 OK IDLE terminated\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        let events = EventBox()
        try await withWatchdog(server) {
            try await client.connect()
            try await client.login(username: "a", password: "b")
            _ = try await client.select("INBOX")
            let task = Task {
                try await client.idle { event in
                    events.append(event)
                    if case .exists(4) = event { return false }
                    return true
                }
            }
            for _ in 0..<200 where !server.transcript.contains("IDLE") {
                try await Task.sleep(nanoseconds: 5_000_000)
            }
            server.push("* 3 EXISTS\r\n* 1 FETCH (UID 1 FLAGS (\\Seen \\Flagged))\r\n")
            try await Task.sleep(nanoseconds: 50_000_000)
            server.push("* 4 EXISTS\r\n")
            try await task.value
        }
        XCTAssertEqual(events.events.count, 3)
        XCTAssertEqual(events.events.last, .exists(4))
    }

    // MARK: Failures

    func testReadTimeoutClosesTheConnection() async throws {
        let server = MockIMAPServer(greeting: "* OK [CAPABILITY IMAP4rev1] ready\r\n") { command, _ in
            command.text.hasPrefix("NOOP") ? [] : ["\(command.tag) OK done\r\n"]
        }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server, timeout: 0.3)
        try await withWatchdog(server) {
            try await client.connect()
            await assertThrowsMailError(.timeout) { try await client.noop() }
        }
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
        XCTAssertFalse(server.isOpen)
        await assertThrowsMailError(.connectionFailed("Not connected.")) { try await client.noop() }
    }

    func testGreetingTimeout() async {
        let server = MockIMAPServer(greeting: nil) { _, _ in [] }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server, timeout: 0.2)
        await assertThrowsMailError(.timeout) {
            try await withWatchdog(server) { try await client.connect() }
        }
    }

    func testServerHangsUpMidCommandWithBye() async throws {
        let server = MockIMAPServer(greeting: "* OK [CAPABILITY IMAP4rev1] ready\r\n") { command, server in
            server.close()
            return ["* BYE Server shutting down for maintenance\r\n"]
        }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server) {
            try await client.connect()
            await assertThrowsMailError(.connectionFailed("The server closed the connection: Server shutting down for maintenance")) {
                try await client.noop()
            }
        }
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
    }

    func testConnectionDropsWithoutBye() async throws {
        let server = MockIMAPServer(greeting: "* OK [CAPABILITY IMAP4rev1] ready\r\n") { _, server in
            server.close()
            return []
        }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server) {
            try await client.connect()
            await assertThrowsMailError(.connectionFailed("The server closed the connection.")) { try await client.noop() }
        }
    }

    func testReconnectAfterFailure() async throws {
        let server = MockIMAPServer(greeting: "* OK [CAPABILITY IMAP4rev1] ready\r\n") { command, server in
            if command.text.hasPrefix("NOOP") {
                server.close()
                return []
            }
            return ["\(command.tag) OK done\r\n"]
        }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server) {
            try await client.connect()
            await assertThrowsMailError(.connectionFailed("The server closed the connection.")) { try await client.noop() }
            try await client.connect()
            let caps = try await client.refreshCapabilities()
            XCTAssertEqual(caps, ["IMAP4REV1"])
        }
        XCTAssertTrue(server.transcript.hasSuffix("A001 NOOP\r\nA001 CAPABILITY\r\n"), "tags restart on a new connection")
    }

    func testUnknownTagsAndStrayContinuationsAreIgnored() async throws {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1] ready\r\n"),
            .expect("* NOOP", reply: "Z999 OK not yours\r\n+ stray\r\n* 3 RECENT\r\n{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        let events = try await withWatchdog(transport) { () -> [IMAPUntagged] in
            try await client.connect()
            return try await client.noop()
        }
        XCTAssertEqual(events, [.recent(3)])
    }

    func testCancelledTaskDoesNotSendCommands() async throws {
        let transport = ScriptedTransport([.send("* OK [CAPABILITY IMAP4rev1] ready\r\n")])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) { try await client.connect() }
        let task = Task { () -> MailError? in
            withUnsafeCurrentTask { $0?.cancel() }
            do {
                _ = try await client.noop()
                return nil
            } catch let error as MailError {
                return error
            }
        }
        let error = try await task.value
        XCTAssertEqual(error, .cancelled)
        XCTAssertEqual(transport.transcript, "")
    }

    // MARK: Serialization

    func testConcurrentCallersAreSerialized() async throws {
        let server = MockIMAPServer(greeting: "* OK [CAPABILITY IMAP4rev1 LITERAL+] ready\r\n", maxChunk: 7, seed: 3) { command, _ in
            if command.text.hasPrefix("STATUS") {
                return ["* STATUS \"Box\" (MESSAGES \(command.tag.dropFirst()) UIDNEXT 1)\r\n\(command.tag) OK done\r\n"]
            }
            return ["* 1 RECENT\r\n\(command.tag) OK done\r\n"]
        }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server, seconds: 20) {
            try await client.connect()
            try await client.login(username: "a", password: "b")
            try await withThrowingTaskGroup(of: Void.self) { group in
                for index in 0..<40 {
                    group.addTask {
                        if index % 2 == 0 {
                            let events = try await client.noop()
                            XCTAssertEqual(events, [.recent(1)])
                        } else {
                            let status = try await client.status("Box")
                            XCTAssertNotNil(status.messages)
                        }
                    }
                }
                try await group.waitForAll()
            }
        }
        let tags = server.commands.map(\.tag)
        XCTAssertEqual(tags.count, 42, "LOGIN, CAPABILITY and the 40 calls")
        XCTAssertEqual(Set(tags).count, 42, "every command got its own tag")
        XCTAssertFalse(server.commandArrivedWithUnreadReplies, "a command was sent before the previous one's replies were read")
        XCTAssertTrue(server.transcript.split(separator: "\r\n").allSatisfy { $0.hasPrefix("A") }, "commands never interleave")
    }

    // MARK: Logging

    func testProtocolLogRedactsSecretsAndElidesBodies() async throws {
        let message = Data("Subject: Payroll\r\n\r\nSSN 123-45-6789\r\n".utf8)
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 LITERAL+] ready\r\n", [
            ("LOGIN", "{TAG} OK [CAPABILITY IMAP4rev1 LITERAL+ UIDPLUS] in\r\n"),
            ("APPEND", "{TAG} OK [APPENDUID 1 5] done\r\n"),
            ("SELECT", "* 1 EXISTS\r\n{TAG} OK [READ-WRITE] ok\r\n"),
            ("UID FETCH", "* 1 FETCH (UID 5 BODY[] {\(message.count)}\r\n" + String(decoding: message, as: UTF8.self) + ")\r\n{TAG} OK done\r\n"),
        ])
        let log = LogCollector()
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server, logger: log.logger)
        try await withWatchdog(server) {
            try await client.connect()
            try await client.login(username: "ada", password: "s3cr3t-pässword")
            _ = try await client.append(to: "Sent", message: message)
            _ = try await client.select("Sent")
            let fetched = try await client.fetch(IMAPSequenceSet(5), byUID: true, items: [.bodyPeek(section: "", partial: nil)])
            XCTAssertEqual(fetched.first?.section(""), message)
        }
        let text = log.text
        XCTAssertFalse(text.contains("s3cr3t"))
        XCTAssertFalse(text.contains("123-45-6789"))
        XCTAssertTrue(text.contains("C: A001 LOGIN [redacted]"))
        XCTAssertTrue(text.contains("C: A002 APPEND \"Sent\" {\(message.count)+} <\(message.count) bytes>"))
        XCTAssertTrue(text.contains("S: * 1 FETCH (UID 5 BODY[] {\(message.count)} <\(message.count) bytes>)"))
    }

    // MARK: Error mapping

    func testErrorMapping() {
        func failure(_ command: String, _ status: IMAPResponseStatus, _ code: IMAPResponseCode?, _ text: String, mailbox: String? = nil, alert: String? = nil) -> MailError {
            IMAPError.commandFailed(command: command, response: IMAPTaggedResponse(tag: "A1", status: status, text: IMAPResponseText(code: code, text: text)),
                                    mailbox: mailbox, alert: alert).mailError
        }
        XCTAssertEqual(failure("LOGIN", .no, nil, "LOGIN failed."), .authenticationFailed("LOGIN failed."))
        XCTAssertEqual(failure("AUTHENTICATE", .no, .authenticationFailed, "Invalid credentials (Failure)"), .authenticationFailed("Invalid credentials"))
        XCTAssertEqual(failure("SELECT", .no, .expired, "Password expired"), .authenticationFailed("Password expired"))
        XCTAssertEqual(failure("LOGIN", .no, .privacyRequired, "Use TLS"), .tlsFailed("Use TLS"))
        XCTAssertEqual(failure("LOGIN", .no, .unavailable, ""), .serverError("The server is temporarily unavailable. Try again in a few minutes."))
        XCTAssertEqual(failure("SELECT", .no, nil, "No such mailbox", mailbox: "Projects"), .mailboxNotFound("Projects"))
        XCTAssertEqual(failure("UID COPY", .no, .tryCreate, "x", mailbox: "Archive"), .mailboxNotFound("Archive"))
        XCTAssertEqual(failure("UID COPY", .no, nil, "Over quota", mailbox: "Archive"), .serverError("Over quota."))
        XCTAssertEqual(failure("APPEND", .no, .overQuota, ""), .serverError("The mailbox is full."))
        XCTAssertEqual(failure("UID STORE", .bad, nil, "Invalid arguments"), .protocolError("UID STORE was rejected: Invalid arguments"))
        XCTAssertEqual(failure("NOOP", .no, nil, ""), .serverError("The server couldn't complete NOOP."))
        XCTAssertEqual(failure("UID STORE", .no, .noPerm, ""), .serverError("The server doesn't allow that in this folder."))
        XCTAssertEqual(failure("LOGIN", .no, nil, "failed", alert: "Account suspended"), .authenticationFailed("Account suspended failed"))
        XCTAssertEqual(IMAPError.bye("").mailError, .connectionFailed("The server closed the connection."))
        XCTAssertEqual(IMAPError.parse(.lineTooLong).mailError, .protocolError("It sent a response that never ended."))
        XCTAssertEqual(IMAPError.mailError(for: TransportError.timeout), .timeout)
        XCTAssertEqual(IMAPError.mailError(for: TransportError.tlsFailed("bad cert")), .tlsFailed("bad cert"))
        XCTAssertEqual(IMAPError.mailError(for: TransportError.closed), .connectionFailed("The server closed the connection."))
        XCTAssertEqual(IMAPError.mailError(for: CancellationError()), .cancelled)
        XCTAssertEqual(IMAPError.mailError(for: MailError.messageNotFound), .messageNotFound)
    }
}
