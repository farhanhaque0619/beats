import XCTest
import InkModel
@testable import InkIMAP

/// FETCH robustness: unsolicited responses that must not pass as answers, and partial answers
/// that callers must be able to tell apart from complete ones.
final class IMAPClientProtocolReviewTests: XCTestCase {
    private func selectedClient(capabilities: String = "IMAP4rev1 IDLE UIDPLUS", _ steps: [ScriptedTransport.Step]) -> (IMAPClient, ScriptedTransport) {
        let transport = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN] ready\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY \(capabilities)] Logged in\r\n"),
            .expect("* SELECT INBOX", reply: "* 10 EXISTS\r\n* OK [UIDVALIDITY 7] ok\r\n* OK [UIDNEXT 500] ok\r\n{TAG} OK [READ-WRITE] Select completed\r\n"),
        ] + steps)
        return (IMAPClient(host: "h", port: 993, security: .tls, transport: transport), transport)
    }

    private func open(_ client: IMAPClient) async throws {
        try await client.connect()
        try await client.login(username: "ada", password: "pw")
        _ = try await client.select("INBOX")
    }

    /// Another session marks message 7 read while we fetch 1:2 by sequence number: the server
    /// may slip `* 7 FETCH (FLAGS (\Seen))` (with a UID under QRESYNC) into the reply. It
    /// isn't an answer to this FETCH, so it must not come back as one.
    func testSequenceFetchLeavesOutUnsolicitedUpdatesForOtherMessages() async throws {
        let (client, transport) = selectedClient([
            .expect("* FETCH 1:2 (UID FLAGS INTERNALDATE)", reply:
                "* 1 FETCH (UID 101 FLAGS () INTERNALDATE \"19-Oct-2026 09:00:00 +0000\")\r\n"
                + "* 7 FETCH (UID 170 FLAGS (\\Seen))\r\n"
                + "* 2 FETCH (UID 102 FLAGS (\\Flagged) INTERNALDATE \"19-Oct-2026 10:00:00 +0000\")\r\n"
                + "{TAG} OK Fetch completed\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let responses = try await client.fetch(IMAPSequenceSet(1...2), byUID: false, items: [.uid, .flags, .internalDate])
            XCTAssertEqual(responses.map(\.seq), [1, 2])
            XCTAssertEqual(responses.map(\.uid), [101, 102])
        }
    }

    /// `*` in a sequence set reaches the last message, so nothing above the start is filtered.
    func testSequenceFetchToLastKeepsEveryMessageFromTheStart() async throws {
        let (client, transport) = selectedClient([
            .expect("* FETCH 9:* (FLAGS)", reply: "* 9 FETCH (FLAGS ())\r\n* 10 FETCH (FLAGS (\\Seen))\r\n* 3 FETCH (FLAGS (\\Seen))\r\n{TAG} OK Fetch completed\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let responses = try await client.fetch(.from(9), byUID: false, items: [.flags])
            XCTAssertEqual(responses.map(\.seq), [9, 10])
        }
    }

    /// A NO that still carried some data: callers listing a mailbox must be able to tell it
    /// from a complete answer, or the messages left out look deleted.
    func testFetchReportsWhetherTheAnswerWasComplete() async throws {
        let (client, transport) = selectedClient([
            .expect("* UID FETCH 1:* (UID FLAGS)", reply: "* 1 FETCH (UID 5 FLAGS ())\r\n{TAG} NO Some messages could not be FETCHed (Failure)\r\n"),
            .expect("* UID FETCH 1:* (UID FLAGS)", reply: "* 1 FETCH (UID 5 FLAGS ())\r\n{TAG} NO [EXPUNGEISSUED] Some messages were expunged\r\n"),
            .expect("* UID FETCH 1:* (UID FLAGS)", reply: "* 1 FETCH (UID 5 FLAGS ())\r\n* 2 FETCH (UID 6 FLAGS ())\r\n{TAG} OK Fetch completed\r\n"),
            .expect("* UID FETCH 1:* (UID FLAGS)", reply: "{TAG} NO Mailbox is busy\r\n"),
        ])
        try await withWatchdog(transport) {
            try await open(client)
            let partial = try await client.fetchReportingCompleteness(.all, byUID: true, items: [.flags])
            XCTAssertEqual(partial.responses.map(\.uid), [5])
            XCTAssertFalse(partial.isComplete)
            let expunged = try await client.fetchReportingCompleteness(.all, byUID: true, items: [.flags])
            XCTAssertTrue(expunged.isComplete, "with [EXPUNGEISSUED] the messages left out are really gone")
            let complete = try await client.fetchReportingCompleteness(.all, byUID: true, items: [.flags])
            XCTAssertEqual(complete.responses.map(\.uid), [5, 6])
            XCTAssertTrue(complete.isComplete)
            await assertThrowsMailError(.serverError("Mailbox is busy.")) {
                try await client.fetchReportingCompleteness(.all, byUID: true, items: [.flags])
            }
        }
    }
}
