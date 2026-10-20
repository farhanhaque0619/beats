import XCTest
import InkModel
@testable import InkIMAP

/// Message-level commands on a selected mailbox.
final class IMAPClientMessageTests: XCTestCase {
    /// A transport that greets with `capabilities`, accepts AUTHENTICATE PLAIN and selects INBOX,
    /// then follows `steps`.
    private func selectedClient(capabilities: String, exists: Int = 10, _ steps: [ScriptedTransport.Step],
                                logger: (@Sendable (String) -> Void)? = nil) -> (IMAPClient, ScriptedTransport) {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY \(capabilities)] Logged in\r\n"),
            .expect("* SELECT INBOX", reply: "* \(exists) EXISTS\r\n* OK [UIDVALIDITY 7] ok\r\n* OK [UIDNEXT 500] ok\r\n{TAG} OK [READ-WRITE] Select completed\r\n"),
        ] + steps)
        return (IMAPClient(host: "h", port: 993, security: .tls, transport: transport, logger: logger), transport)
    }

    private func open(_ client: IMAPClient, condstore: Bool = false) async throws {
        try await client.connect()
        try await client.login(username: "ada", password: "pw")
        _ = try await client.select("INBOX", condstore: condstore)
    }

    private static let gmail = IMAPClientSessionTests.gmailCapabilities
    private static let dovecot = IMAPClientSessionTests.dovecotCapabilities
    private static let bare = "IMAP4rev1 IDLE"

    // MARK: FETCH

    func testGmailIncrementalFetchWithLabelsAndChangedSince() async throws {
        let (client, transport) = selectedClient(capabilities: Self.gmail, [
            .expect("* SELECT INBOX (CONDSTORE)", reply: IMAPClientSessionTests.gmailSelect + "{TAG} OK [READ-WRITE] INBOX selected. (Success)\r\n"),
            .expect("* UID FETCH 35850:* (UID FLAGS X-GM-THRID X-GM-MSGID X-GM-LABELS MODSEQ) (CHANGEDSINCE 4416000)", reply: crlf("""
            * 2759 FETCH (X-GM-THRID 1781234567890123456 X-GM-MSGID 1781234567890123457 X-GM-LABELS (\\Important) UID 35850 FLAGS (\\Seen) MODSEQ (4416100))
            * 12 FETCH (UID 120 FLAGS (\\Seen))
            * 2761 FETCH (X-GM-THRID 1781234567890123999 X-GM-MSGID 1781234567890124000 X-GM-LABELS ("\\\\Important" "Travel/2026" &AMk-t&AOk-) UID 35855 FLAGS () MODSEQ (4416200))
            {TAG} OK Success
            """) + "\r\n"),
        ])
        // The helper's SELECT is consumed by the plain select; this test re-selects with CONDSTORE.
        let responses = try await withWatchdog(transport) { () -> [IMAPFetchResponse] in
            try await client.connect()
            try await client.login(username: "ada", password: "pw")
            _ = try await client.select("INBOX")
            _ = try await client.select("INBOX", condstore: true)
            return try await client.fetch(.from(35850), byUID: true, items: [.flags, .gmailThreadID, .gmailMessageID, .gmailLabels, .modSeq], changedSince: 4_416_000)
        }
        XCTAssertEqual(responses.map(\.uid), [35850, 35855], "the unsolicited update for UID 120 is left out")
        XCTAssertEqual(responses[0].gmailThreadID, 1_781_234_567_890_123_456)
        XCTAssertEqual(responses[0].gmailMessageID, 1_781_234_567_890_123_457)
        XCTAssertEqual(responses[0].messageFlags, [.seen])
        XCTAssertEqual(responses[1].gmailLabels, ["\\Important", "Travel/2026", "&AMk-t&AOk-"])
        XCTAssertEqual(responses[1].decodedGmailLabels, ["\\Important", "Travel/2026", "Été"])
        XCTAssertEqual(responses[1].modSeq, 4_416_200)
        XCTAssertEqual(responses[1].flags, [])
    }

    func testUIDFetchFromUIDNextDropsTheLastMessageEcho() async throws {
        // `UID FETCH 500:*` with nothing new returns the highest existing message (RFC 3501).
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* UID FETCH 500:* (UID FLAGS)", reply: "* 10 FETCH (UID 499 FLAGS (\\Seen))\r\n{TAG} OK Fetch completed\r\n"),
        ])
        let responses = try await withWatchdog(transport) { () -> [IMAPFetchResponse] in
            try await open(client)
            return try await client.fetch(.from(500), byUID: true, items: [.uid, .flags])
        }
        XCTAssertEqual(responses, [])
    }

    func testSummaryFetchWithLiteralsAndSectionAliases() async throws {
        let headers = "References: <a@example.com>\r\nList-Id: Weekly <weekly.news.example>\r\n\r\n"
        let preview = "Hi Ada,\r\n\r\nThe Q3 numbers are in and they look {good}.\r\n"
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* UID FETCH 101:102 (UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-ID)])",
                    reply: "* 1 FETCH (UID 101 FLAGS (\\Seen) INTERNALDATE \"20-Oct-2026 08:41:12 +0000\" RFC822.SIZE 4410 ENVELOPE (\"Tue, 20 Oct 2026 08:41:07 +0000\" \"Q3\" ((\"Grace\" NIL \"grace\" \"example.org\")) NIL NIL ((NIL NIL \"ada\" \"example.com\")) NIL NIL NIL \"<q3@example.org>\") BODYSTRUCTURE (\"TEXT\" \"PLAIN\" (\"CHARSET\" \"utf-8\") NIL NIL \"7BIT\" 120 4 NIL NIL NIL NIL) BODY[HEADER.FIELDS (REFERENCES LIST-ID)] "
                        + literal(headers) + ")\r\n"
                        + "* 2 FETCH (UID 102 FLAGS () BODY[HEADER.FIELDS (REFERENCES LIST-ID)] {2}\r\n\r\n)\r\n"
                        + "* 2 FETCH (UID 102 RFC822.SIZE 99)\r\n"
                        + "{TAG} OK Fetch completed (0.002 + 0.000 secs).\r\n"),
            .expect("* UID FETCH 101 (UID BODY.PEEK[1]<0.2048>)", reply: "* 1 FETCH (UID 101 BODY[1]<0> " + literal(preview) + ")\r\n{TAG} OK Fetch completed\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let summaries = try await client.fetch(IMAPSequenceSet([101, 102]), byUID: true, items: [
                .uid, .flags, .internalDate, .rfc822Size, .envelope, .bodyStructure, .headerFields(["References", "List-Id"]),
            ])
            XCTAssertEqual(summaries.count, 2)
            XCTAssertEqual(summaries[0].envelope?.subject, "Q3")
            XCTAssertEqual(summaries[0].bodyStructure?.preferredTextPart()?.section, "1")
            XCTAssertEqual(summaries[0].sections["HEADER.FIELDS (REFERENCES LIST-ID)"], Data(headers.utf8))
            XCTAssertEqual(summaries[0].sections["HEADER.FIELDS (References List-Id)"], Data(headers.utf8), "also stored as the caller spelled it")
            XCTAssertEqual(summaries[1].size, 99, "split responses for one message are merged")
            XCTAssertEqual(summaries[1].flags, [])

            let bodies = try await client.fetch(IMAPSequenceSet(101), byUID: true, items: [.bodyPeek(section: "1", partial: (0, 2048))])
            XCTAssertEqual(bodies.first?.sections["1"], Data(preview.utf8))
            XCTAssertEqual(bodies.first?.sectionOrigins["1"], 0)
        }
    }

    func testGmailItemsAreDroppedOnOtherServers() async throws {
        let (client, transport) = selectedClient(capabilities: Self.bare, [
            .expect("* FETCH 1:3 (FLAGS)", reply: "* 1 FETCH (FLAGS (\\Seen))\r\n* 2 FETCH (FLAGS ())\r\n* 3 FETCH (FLAGS (\\Flagged))\r\n{TAG} OK done\r\n"),
            .expect("* UID FETCH 1:* (UID)", reply: "{TAG} OK done\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let responses = try await client.fetch(IMAPSequenceSet(1...3), byUID: false, items: [.flags, .gmailLabels, .modSeq, .emailID, .preview], changedSince: 5)
            XCTAssertEqual(responses.map(\.seq), [1, 2, 3])
            XCTAssertEqual(responses[2].messageFlags, [.flagged])
            _ = try await client.fetch(.all, byUID: true, items: [.gmailThreadID])
            let empty = try await client.fetch(IMAPSequenceSet([UInt32]()), byUID: true, items: [.flags])
            XCTAssertEqual(empty, [], "an empty set sends nothing")
        }
    }

    func testFetchNoWithPartialResultsAndPlainNo() async throws {
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* UID FETCH 5:6 (UID FLAGS)", reply: "* 1 FETCH (UID 5 FLAGS (\\Seen))\r\n{TAG} NO [EXPUNGEISSUED] Some messages were expunged\r\n"),
            .expect("* UID FETCH 7 (UID FLAGS)", reply: "{TAG} NO Server unavailable for this mailbox\r\n"),
            .expect("* UID FETCH 8 (UID FLAGS)", reply: "{TAG} BAD Error in IMAP command\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let partial = try await client.fetch(IMAPSequenceSet([5, 6]), byUID: true, items: [.flags])
            XCTAssertEqual(partial.map(\.uid), [5])
            await assertThrowsMailError(.serverError("Server unavailable for this mailbox.")) {
                try await client.fetch(IMAPSequenceSet(7), byUID: true, items: [.flags])
            }
            await assertThrowsMailError(.protocolError("UID FETCH was rejected: Error in IMAP command")) {
                try await client.fetch(IMAPSequenceSet(8), byUID: true, items: [.flags])
            }
            let state = await client.state
            XCTAssertEqual(state, .authenticated, "NO and BAD don't close the connection")
        }
    }

    func testFetchWholeMessageInTinyChunks() async throws {
        let message = crlf("""
        Return-Path: <grace@example.org>
        From: Grace Hopper <grace@example.org>
        To: Ada <ada@example.com>
        Subject: =?UTF-8?Q?Gr=C3=BC=C3=9Fe?=
        Message-ID: <x1@example.org>
        Content-Type: multipart/alternative; boundary="b1"

        --b1
        Content-Type: text/plain; charset=utf-8

        A line with {braces} and ) parens (
        --b1--
        """) + "\r\n"
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR LITERAL+] ready\r\n", maxChunk: 3, seed: 99, [
            ("AUTHENTICATE PLAIN", "{TAG} OK [CAPABILITY IMAP4rev1 LITERAL+ UIDPLUS] in\r\n"),
            ("SELECT INBOX", "* 1 EXISTS\r\n* OK [UIDVALIDITY 3] x\r\n{TAG} OK [READ-WRITE] done\r\n"),
            ("UID FETCH 42 (UID BODY.PEEK[])", "* 1 FETCH (UID 42 BODY[] " + literal(message) + " FLAGS (\\Seen))\r\n{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        let responses = try await withWatchdog(server) { () -> [IMAPFetchResponse] in
            try await open(client)
            return try await client.fetch(IMAPSequenceSet(42), byUID: true, items: [.bodyPeek(section: "", partial: nil)])
        }
        XCTAssertEqual(responses.first?.section(""), Data(message.utf8))
        XCTAssertEqual(responses.first?.flags, ["\\Seen"])
    }

    func testMessageBodyThatLooksLikeProtocolIsJustData() async throws {
        // A literal is framed by its byte count, so lines inside it that look like server
        // responses (a forwarded IMAP log, say) can't end the command early.
        let body = crlf("""
        Subject: IMAP trace

        A005 OK UID FETCH completed
        * BYE fake
        + continue
        * 3 EXISTS
        {12}
        not a literal
        """) + "\r\n"
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* UID FETCH 9 (UID BODY.PEEK[])", reply: "* 1 FETCH (UID 9 BODY[] " + literal(body) + ")\r\n{TAG} OK Fetch completed\r\n"),
            .expect("* NOOP", reply: "{TAG} OK done\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let responses = try await client.fetch(IMAPSequenceSet(9), byUID: true, items: [.bodyPeek(section: "", partial: nil)])
            XCTAssertEqual(responses.first?.section(""), Data(body.utf8))
            let selected = await client.selectedMailbox
            XCTAssertEqual(selected?.exists, 10)
            let events = try await client.noop()
            XCTAssertEqual(events, [])
        }
    }

    func testConnectionDroppedMidLiteral() async throws {
        let server = MockIMAPServer(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n") { command, server in
            switch command.text {
            case let text where text.hasPrefix("AUTHENTICATE"): return ["\(command.tag) OK [CAPABILITY IMAP4rev1] in\r\n"]
            case let text where text.hasPrefix("SELECT"): return ["* 1 EXISTS\r\n\(command.tag) OK [READ-WRITE] ok\r\n"]
            default:
                server.close()
                return ["* 1 FETCH (UID 1 BODY[] {5000}\r\nonly part of it"]
            }
        }
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server) {
            try await open(client)
            await assertThrowsMailError(.connectionFailed("The server closed the connection.")) {
                try await client.fetch(IMAPSequenceSet(1), byUID: true, items: [.bodyPeek(section: "", partial: nil)])
            }
        }
        let state = await client.state
        XCTAssertEqual(state, .disconnected)
    }

    func testExchangeEchoesQuotedHeaderNames() async throws {
        let (client, transport) = selectedClient(capabilities: Self.bare, [
            .expect("* UID FETCH 3 (UID BODY.PEEK[HEADER.FIELDS (REFERENCES LIST-ID)])",
                    reply: "* 1 FETCH (UID 3 BODY[HEADER.FIELDS (\"REFERENCES\" \"LIST-ID\")] {2}\r\n\r\n)\r\n{TAG} OK FETCH completed.\r\n"),
        ])
        let responses = try await withWatchdog(transport) { () -> [IMAPFetchResponse] in
            try await open(client)
            return try await client.fetch(IMAPSequenceSet(3), byUID: true, items: [.headerFields(["REFERENCES", "LIST-ID"])])
        }
        XCTAssertEqual(responses.first?.sections["HEADER.FIELDS (REFERENCES LIST-ID)"], Data("\r\n".utf8))
    }

    // MARK: SEARCH

    func testESearchRefusedFallsBackToPlainSearch() async throws {
        let (client, transport) = selectedClient(capabilities: "IMAP4rev1 ESEARCH", [
            .expect("* UID SEARCH RETURN (ALL) UNSEEN", reply: "{TAG} BAD Unknown search return option\r\n"),
            .expect("* UID SEARCH UNSEEN", reply: "* SEARCH 4 2\r\n{TAG} OK done\r\n"),
        ])
        let uids = try await withWatchdog(transport) { () -> [UInt32] in
            try await open(client)
            return try await client.uidSearch(.unseen)
        }
        XCTAssertEqual(uids, [2, 4])
    }

    func testSearchWithPlainSearchResponse() async throws {
        let since = Date(timeIntervalSince1970: 1_792_454_400)
        let (client, transport) = selectedClient(capabilities: Self.bare, [
            .expect("* UID SEARCH SINCE 20-Oct-2026 UNSEEN", reply: "* SEARCH 7 3 12\r\n{TAG} OK SEARCH completed\r\n"),
            .expect("* UID SEARCH HEADER Message-ID \"<abc@example.com>\"", reply: "* SEARCH\r\n{TAG} OK SEARCH completed\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let uids = try await client.uidSearch(.and([.since(since), .unseen]))
            XCTAssertEqual(uids, [3, 7, 12])
            let none = try await client.uidSearch(.header("Message-ID", "<abc@example.com>"))
            XCTAssertEqual(none, [])
        }
    }

    func testSearchWithESearch() async throws {
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* UID SEARCH RETURN (ALL) OR FROM \"ada\" OR SUBJECT \"ada\" BODY \"ada\"",
                    reply: "* ESEARCH (TAG \"A999\") UID ALL 1:2\r\n* ESEARCH (TAG \"{TAG}\") UID ALL 4:6,9\r\n{TAG} OK Search completed (0.001 + 0.000 secs).\r\n"),
            .expect("* UID SEARCH RETURN (ALL) DELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK done\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let uids = try await client.uidSearch(.anyOf([.from("ada"), .subject("ada"), .body("ada")]))
            XCTAssertEqual(uids, [4, 5, 6, 9], "results for another tag are ignored")
            let empty = try await client.uidSearch(.deleted)
            XCTAssertEqual(empty, [])
        }
    }

    func testNonASCIISearchUsesCharsetAndLiteral() async throws {
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n", [
            ("AUTHENTICATE PLAIN", "{TAG} OK [CAPABILITY IMAP4rev1] in\r\n"),
            ("SELECT INBOX", "* 3 EXISTS\r\n{TAG} OK [READ-WRITE] done\r\n"),
            ("UID SEARCH CHARSET UTF-8 SUBJECT {7}<literal>", "* SEARCH 2\r\n{TAG} OK done\r\n"),
            ("UID SEARCH CHARSET UTF-8 TEXT {6}<literal>", "{TAG} NO [BADCHARSET (US-ASCII)] Unsupported charset\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        try await withWatchdog(server) {
            try await open(client)
            let uids = try await client.uidSearch(.subject("Grüße"))
            XCTAssertEqual(uids, [2])
            XCTAssertEqual(server.commands[2].literals, [Data("Grüße".utf8)])
            XCTAssertFalse(server.literalSentEarly)
            await assertThrowsMailError(.notSupported("searching for text in this language")) {
                try await client.uidSearch(.text("日本"))
            }
        }
    }

    func testGmailRawSearch() async throws {
        let (client, transport) = selectedClient(capabilities: Self.gmail, [
            .expect("* UID SEARCH RETURN (ALL) X-GM-RAW \"has:attachment from:grace\"", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 35801,35850:35852\r\n{TAG} OK SEARCH completed (Success)\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let uids = try await client.uidSearch(.gmailRaw("has:attachment from:grace"))
            XCTAssertEqual(uids, [35801, 35850, 35851, 35852])
        }
        let (other, otherTransport) = selectedClient(capabilities: Self.bare, [])
        await assertThrowsMailError(.notSupported("Gmail search")) {
            try await withWatchdog(otherTransport) {
                try await open(other)
                return try await other.uidSearch(.gmailRaw("x"))
            }
        }
    }

    // MARK: STORE

    func testStoreFlags() async throws {
        let (client, transport) = selectedClient(capabilities: Self.bare, [
            .expect("* UID STORE 4:6,9 +FLAGS.SILENT (\\Seen)", reply: "{TAG} OK Store completed\r\n"),
            .expect("* UID STORE 4 -FLAGS (\\Flagged)", reply: "* 2 FETCH (UID 4 FLAGS (\\Seen))\r\n{TAG} OK Store completed\r\n"),
            .expect("* UID STORE 4 FLAGS.SILENT ()", reply: "{TAG} OK Store completed\r\n"),
            .expect("* UID STORE 5 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} NO [CANNOT] Mailbox is read-only\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            try await client.uidStore(IMAPSequenceSet([4, 5, 6, 9]), flags: ["\\Seen"], mode: .add)
            try await client.uidStore(IMAPSequenceSet(4), flags: ["\\Flagged"], mode: .remove, silent: false)
            try await client.uidStore(IMAPSequenceSet(4), flags: [], mode: .replace)
            try await client.uidStore(IMAPSequenceSet(4), flags: ["bad flag"], mode: .add)
            try await client.uidStore(IMAPSequenceSet([UInt32]()), flags: ["\\Seen"], mode: .add)
            await assertThrowsMailError(.serverError("Mailbox is read-only.")) {
                try await client.uidStore(IMAPSequenceSet(5), flags: ["\\Deleted"], mode: .add)
            }
        }
        XCTAssertFalse(transport.transcript.contains("bad flag"))
    }

    func testGmailLabels() async throws {
        let (client, transport) = selectedClient(capabilities: Self.gmail, [
            .expect("* UID STORE 35855 +X-GM-LABELS (\\Starred Travel/2026 &AMk-t&AOk- \"Two Words\")",
                    reply: "* 2761 FETCH (X-GM-LABELS (\\Inbox \\Starred \"Travel/2026\") UID 35855)\r\n{TAG} OK Success\r\n"),
            .expect("* UID STORE 35855 -X-GM-LABELS (\\Inbox)", reply: "{TAG} OK Success\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            try await client.gmailStoreLabels(IMAPSequenceSet(35855), labels: ["\\Starred", "Travel/2026", "Été", "Two Words"], mode: .add)
            try await client.gmailStoreLabels(IMAPSequenceSet(35855), labels: ["\\Inbox"], mode: .remove)
            try await client.gmailStoreLabels(IMAPSequenceSet(35855), labels: [], mode: .add)
        }
        let (other, otherTransport) = selectedClient(capabilities: Self.bare, [])
        await assertThrowsMailError(.notSupported("Gmail labels")) {
            try await withWatchdog(otherTransport) {
                try await open(other)
                try await other.gmailStoreLabels(IMAPSequenceSet(1), labels: ["x"], mode: .add)
            }
        }
    }

    // MARK: COPY / MOVE / EXPUNGE

    func testCopyWithCopyUID() async throws {
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* UID COPY 304,319:320 \"Archive\"", reply: "{TAG} OK [COPYUID 38505 304,319:320 3956:3958] Copy completed\r\n"),
            .expect("* UID COPY 1 \"Nowhere\"", reply: "{TAG} NO [TRYCREATE] Mailbox doesn't exist: Nowhere\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let mapping = try await client.uidCopy(IMAPSequenceSet([304, 319, 320]), to: "Archive")
            XCTAssertEqual(mapping, [304: 3956, 319: 3957, 320: 3958])
            await assertThrowsMailError(.mailboxNotFound("Nowhere")) { try await client.uidCopy(IMAPSequenceSet(1), to: "Nowhere") }
        }
    }

    func testMoveWithMoveExtension() async throws {
        let (client, transport) = selectedClient(capabilities: Self.gmail, exists: 2763, [
            .expect("* UID MOVE 35855:35856 \"[Gmail]/All Mail\"",
                    reply: "* OK [COPYUID 11 35855:35856 99120:99121]\r\n* 2761 EXPUNGE\r\n* 2761 EXPUNGE\r\n{TAG} OK Success\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let mapping = try await client.uidMove(IMAPSequenceSet(35855...35856), to: "[Gmail]/All Mail")
            XCTAssertEqual(mapping, [35855: 99120, 35856: 99121])
            let selected = await client.selectedMailbox
            XCTAssertEqual(selected?.exists, 2761, "EXPUNGE responses update the selected mailbox")
        }
    }

    func testMoveFallbackWithUIDPlus() async throws {
        let (client, transport) = selectedClient(capabilities: "IMAP4rev1 UIDPLUS IDLE", [
            .expect("* UID COPY 12 \"Trash\"", reply: "{TAG} OK [COPYUID 9 12 801] done\r\n"),
            .expect("* UID STORE 12 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK done\r\n"),
            .expect("* UID EXPUNGE 12", reply: "* 3 EXPUNGE\r\n{TAG} OK done\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let mapping = try await client.uidMove(IMAPSequenceSet(12), to: "Trash")
            XCTAssertEqual(mapping, [12: 801])
        }
        XCTAssertFalse(transport.transcript.contains(" EXPUNGE\r\n"), "never a plain EXPUNGE")
    }

    func testMoveFallbackWithoutUIDPlusLeavesOriginalsFlagged() async throws {
        let (client, transport) = selectedClient(capabilities: Self.bare, [
            .expect("* UID COPY 12 \"Trash\"", reply: "{TAG} OK done\r\n"),
            .expect("* UID STORE 12 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK done\r\n"),
            .expect("* NOOP", reply: "{TAG} OK done\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let mapping = try await client.uidMove(IMAPSequenceSet(12), to: "Trash")
            XCTAssertEqual(mapping, [:])
            _ = try await client.noop()
            await assertThrowsMailError(.notSupported("removing individual messages (UIDPLUS)")) {
                try await client.uidExpunge(IMAPSequenceSet(12))
            }
        }
        XCTAssertFalse(transport.transcript.contains("EXPUNGE"), "other \\Deleted mail must not be expunged behind the user's back")
    }

    func testMoveFallbackWithPlainExpungeProtectsOtherDeletedMessages() async throws {
        let (client, transport) = selectedClient(capabilities: Self.bare, [
            .expect("* UID COPY 12 \"Trash\"", reply: "{TAG} OK done\r\n"),
            .expect("* UID STORE 12 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK done\r\n"),
            .expect("* UID SEARCH DELETED NOT UID 12", reply: "* SEARCH 3 4\r\n{TAG} OK done\r\n"),
            .expect("* UID STORE 3:4 -FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK done\r\n"),
            .expect("* EXPUNGE", reply: "* 5 EXPUNGE\r\n{TAG} OK done\r\n"),
            .expect("* UID STORE 3:4 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK done\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            _ = try await client.uidMove(IMAPSequenceSet(12), to: "Trash", allowPlainExpunge: true)
            let selected = await client.selectedMailbox
            XCTAssertEqual(selected?.exists, 9)
        }
    }

    func testUIDExpungeAndPlainExpunge() async throws {
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* UID EXPUNGE 3000:3002", reply: "* 3 EXPUNGE\r\n* 3 EXPUNGE\r\n* 3 EXPUNGE\r\n{TAG} OK Expunge completed\r\n"),
            .expect("* EXPUNGE", reply: "{TAG} OK Expunge completed\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            try await client.uidExpunge(IMAPSequenceSet(3000...3002))
            let selected = await client.selectedMailbox
            XCTAssertEqual(selected?.exists, 7)
            try await client.expunge()
        }
    }

    // MARK: APPEND

    func testAppendWithLiteralPlusAndAppendUID() async throws {
        let message = Data(crlf("From: ada@example.com\nTo: grace@example.org\nSubject: Draft\n\nHello\n").utf8)
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n", [
            ("AUTHENTICATE PLAIN", "{TAG} OK [CAPABILITY IMAP4rev1 LITERAL+ UIDPLUS] in\r\n"),
            ("APPEND \"Sent\" (\\Seen) \"20-Oct-2026 04:22:03 +0000\" {\(message.count)+}<literal>", "{TAG} OK [APPENDUID 1704067201 2208] Append completed\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        let uid = try await withWatchdog(server) { () -> UInt32? in
            try await client.connect()
            try await client.login(username: "a", password: "b")
            return try await client.append(to: "Sent", message: message, flags: ["\\Seen"], date: Date(timeIntervalSince1970: 1_792_470_123))
        }
        XCTAssertEqual(uid, 2208)
        XCTAssertEqual(server.commands.last?.literals, [message])
    }

    func testAppendWaitsForContinuationWithoutLiteralPlus() async throws {
        let message = Data(repeating: 0x61, count: 5000)
        let (server, _) = MockIMAPServer.scripted(greeting: "* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n", [
            ("AUTHENTICATE PLAIN", "{TAG} OK [CAPABILITY IMAP4rev1 LITERAL-] in\r\n"),
            ("APPEND \"Drafts\" (\\Draft) {5000}<literal>", "{TAG} OK Append completed\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: server)
        let uid = try await withWatchdog(server) { () -> UInt32? in
            try await client.connect()
            try await client.login(username: "a", password: "b")
            return try await client.append(to: "Drafts", message: message, flags: ["\\Draft"])
        }
        XCTAssertNil(uid, "no APPENDUID without UIDPLUS")
        XCTAssertFalse(server.literalSentEarly, "LITERAL- only allows {n+} up to 4096 bytes")
        XCTAssertEqual(server.commands.last?.literals.first?.count, 5000)
    }

    func testAppendRefusedBeforeLiteral() async throws {
        // The server refuses the command instead of sending "+" for the literal.
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 AUTH=PLAIN SASL-IR] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY IMAP4rev1] in\r\n"),
            .expect("* APPEND \"Sent\" {5}", reply: "{TAG} NO [OVERQUOTA] Quota exceeded (mailbox for user is full)\r\n"),
            .expect("* NOOP", reply: "{TAG} OK done\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.login(username: "a", password: "b")
            await assertThrowsMailError(.serverError("The mailbox is full: Quota exceeded (mailbox for user is full)")) {
                try await client.append(to: "Sent", message: Data("hello".utf8))
            }
            _ = try await client.noop()
        }
        XCTAssertFalse(transport.transcript.contains("hello"), "the literal isn't sent after a refusal")
    }

    func testAppendLimitAndTryCreate() async throws {
        let (client, transport) = selectedClient(capabilities: "IMAP4rev1 LITERAL+ APPENDLIMIT=10", [
            .expect("* APPEND \"Gone\"", reply: "{TAG} NO [TRYCREATE] Mailbox doesn't exist: Gone\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            await assertThrowsMailError(matching: { if case .serverError = $0 { return true } else { return false } }) {
                try await client.append(to: "Sent", message: Data(repeating: 0x61, count: 11))
            }
            await assertThrowsMailError(.mailboxNotFound("Gone")) {
                try await client.append(to: "Gone", message: Data("x".utf8))
            }
        }
    }

    // MARK: NOOP

    func testNoopReturnsAndAppliesUntaggedData() async throws {
        let (client, transport) = selectedClient(capabilities: Self.dovecot, [
            .expect("* NOOP", reply: "* 4 EXPUNGE\r\n* 12 EXISTS\r\n* 3 FETCH (FLAGS (\\Seen) UID 77)\r\n* VANISHED 80:81\r\n{TAG} OK NOOP completed (0.001 + 0.000 secs).\r\n"),
        ])
        let events = try await withWatchdog(transport) { () -> [IMAPUntagged] in
            try await open(client)
            return try await client.noop()
        }
        XCTAssertEqual(events.count, 4)
        XCTAssertEqual(events[0], .expunge(4))
        XCTAssertEqual(events[1], .exists(12))
        guard case .fetch(let fetch) = events[2] else { return XCTFail() }
        XCTAssertEqual(fetch.uid, 77)
        let selected = await client.selectedMailbox
        XCTAssertEqual(selected?.exists, 10, "12 EXISTS, then two UIDs vanished")
    }
}
