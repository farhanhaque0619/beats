import XCTest
import InkModel
import InkIMAP
@testable import InkSync

/// Protocol-robustness cases for IMAPMailService: lookups that must not act on the wrong
/// message, deletion detection that must not empty the cache, and sync that must not download
/// whole bodies.
final class IMAPMailServiceProtocolReviewTests: XCTestCase {
    typealias T = IMAPServiceTranscripts
    typealias F = IMAPServiceFixtures

    let account = F.account()
    var inbox: MailboxInfo { F.mailbox("INBOX", role: .inbox, accountID: account.id) }

    private func summary(_ uid: UInt32, in path: String = "INBOX", validity: UInt32 = 1792470281, messageID: String) -> MessageSummary {
        MessageSummary(accountID: account.id, mailboxPath: path, uid: uid, uidValidity: validity,
                       messageID: messageID, subject: "S\(uid)", from: [], date: Date())
    }

    private func messageIDLiteral(_ id: String) -> String {
        F.literal("Message-ID: <\(id)>\r\n\r\n")
    }

    // MARK: Finding messages by Message-ID

    /// IMAP `HEADER` search is a substring match: searching for `1@example.com` also finds
    /// `<21@example.com>`. Deleting a message found that way must only delete the exact match.
    func testDeleteForeverAfterUIDValidityChangeOnlyHitsTheExactMessageID() async throws {
        let stale = summary(3, in: "Trash", validity: 111, messageID: "1@example.com")
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect("Trash", exists: 10, uidValidity: 222, uidNext: 30, modSeq: 4),
            .expect("* UID SEARCH RETURN (ALL) HEADER MESSAGE-ID \"1@example.com\" UNDELETED",
                    reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 5,9\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 5,9 (UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])", reply:
                "* 4 FETCH (UID 5 BODY[HEADER.FIELDS (MESSAGE-ID)] \(messageIDLiteral("1@example.com")))\r\n"
                + "* 8 FETCH (UID 9 BODY[HEADER.FIELDS (MESSAGE-ID)] \(messageIDLiteral("21@example.com")))\r\n" + T.ok()),
            .expect("* UID STORE 5 +FLAGS.SILENT (\\Deleted)", reply: "{TAG} OK Store completed.\r\n"),
            .expect("* UID EXPUNGE 5", reply: "* 4 EXPUNGE\r\n{TAG} OK Expunge completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        try await service.perform(.deletePermanently, on: [stale])
        XCTAssertFalse(script.transcript.contains("UID STORE 5,9"), "the substring match (UID 9) must be left alone")
        XCTAssertTrue(script.transcript.contains("UID EXPUNGE 5\r\n"))
    }

    /// Opening a stale summary must not open a different message whose Message-ID merely
    /// contains the one searched for.
    func testBodyOfStaleSummaryIgnoresSubstringMatches() async throws {
        let stale = summary(5, validity: 42, messageID: "77@example.com")
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect(exists: 3, uidNext: 100, modSeq: 9),
            .expect("* UID SEARCH RETURN (ALL) HEADER MESSAGE-ID \"77@example.com\" UNDELETED",
                    reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 61\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 61 (UID BODY.PEEK[HEADER.FIELDS (MESSAGE-ID)])", reply:
                "* 2 FETCH (UID 61 BODY[HEADER.FIELDS (MESSAGE-ID)] \(messageIDLiteral("177@example.com")))\r\n" + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        await assertIMAPServiceThrows(.messageNotFound) { try await service.body(for: stale) }
        XCTAssertFalse(script.transcript.contains("BODY.PEEK[]"), "the wrong message must not be downloaded")
    }

    // MARK: Deletion detection

    /// Without CONDSTORE the known window is listed with `UID FETCH n:* (UID FLAGS)`. When the
    /// server answers NO after sending only part of it, the messages it left out are not gone:
    /// reporting them removed would empty the cache.
    func testPartialFlagListingDoesNotRemoveKnownMessages() async throws {
        let account = F.account(email: "bob@example.com", host: "localhost")
        let inbox = F.mailbox("INBOX", role: .inbox, accountID: account.id)
        let previous = MailboxSyncState(uidValidity: 1792471486, uidNext: 4, highestModSeq: nil, knownUIDs: [1, 2, 3])
        let script = ScriptedTransport(T.greenMailLogin() + [
            T.greenMailSelect(exists: 4, uidNext: 5),
            .expect("* UID FETCH 1:* (UID FLAGS)", reply:
                "* 1 FETCH (FLAGS (\\Seen) UID 1)\r\n* 2 FETCH (FLAGS (\\Deleted) UID 2)\r\n* 4 FETCH (FLAGS () UID 4)\r\n"
                + "{TAG} NO Some messages could not be FETCHed (Failure)\r\n"),
            .expect("* UID FETCH 4 \(T.summaryItemsPrefix)", reply:
                T.summary(seq: 4, uid: 4, subject: "New", messageID: "msg-4@example.com") + T.ok()),
            .expect("* UID FETCH 4 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 4, uid: 4, text: "Fresh.") + T.ok()),
            .expect("* UID FETCH 1 \(T.summaryItemsPrefix)", reply:
                T.summary(seq: 1, uid: 1, flags: "\\Seen", subject: "Old", messageID: "msg-1@example.com") + T.ok()),
            .expect("* UID FETCH 1 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 1, uid: 1, text: "Still here.") + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: previous, limit: 50)
        XCTAssertFalse(result.didReset)
        let prefix = "\(account.id)|INBOX|1792471486|"
        XCTAssertEqual(result.removedIDs, [prefix + "2"], "only the message seen marked \\Deleted is gone; 3 wasn't listed")
        XCTAssertEqual(result.state.knownUIDs, [1, 3, 4])
        XCTAssertEqual(Set(result.upserted.map(\.uid)), [1, 4])
    }

    /// With CONDSTORE, a partial answer to `CHANGEDSINCE` must not move the state's
    /// HIGHESTMODSEQ forward, or the changes the server didn't send are never asked for again.
    func testPartialChangedSinceAnswerKeepsTheOldModSeq() async throws {
        let previous = MailboxSyncState(uidValidity: 1792470281, uidNext: 4, highestModSeq: 100, knownUIDs: [1, 2, 3])
        let script = ScriptedTransport(T.dovecotLogin() + [
            T.dovecotSelect(exists: 3, uidNext: 4, modSeq: 120),
            .expect("* UID FETCH 1:* (UID FLAGS) (CHANGEDSINCE 100)", reply:
                "* 1 FETCH (UID 1 FLAGS (\\Seen) MODSEQ (110))\r\n{TAG} NO Some messages could not be FETCHed\r\n"),
            .expect("* UID SEARCH RETURN (ALL) UID 1:* UNDELETED", reply: "* ESEARCH (TAG \"{TAG}\") UID ALL 1:3\r\n{TAG} OK Search completed\r\n"),
            .expect("* UID FETCH 1 \(T.summaryItemsPrefix)", reply:
                T.summary(seq: 1, uid: 1, flags: "\\Seen", subject: "Old", messageID: "msg-1@example.com") + T.ok()),
            .expect("* UID FETCH 1 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 1, uid: 1, text: "Read now.") + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: previous, limit: 50)
        XCTAssertEqual(result.removedIDs, [])
        XCTAssertEqual(result.upserted.map(\.uid), [1])
        XCTAssertEqual(result.state.highestModSeq, 100, "the next sync asks for the changes since 100 again")
        XCTAssertEqual(result.state.knownUIDs, [1, 2, 3])
    }

    /// A complete listing still removes what it leaves out.
    func testCompleteFlagListingStillRemovesMissingMessages() async throws {
        let account = F.account(email: "bob@example.com", host: "localhost")
        let inbox = F.mailbox("INBOX", role: .inbox, accountID: account.id)
        let previous = MailboxSyncState(uidValidity: 1792471486, uidNext: 4, highestModSeq: nil, knownUIDs: [1, 2, 3])
        let script = ScriptedTransport(T.greenMailLogin() + [
            T.greenMailSelect(exists: 1, uidNext: 4),
            .expect("* UID FETCH 1:* (UID FLAGS)", reply: "* 1 FETCH (FLAGS (\\Seen) UID 1)\r\n" + T.ok()),
            .expect("* UID FETCH 1 \(T.summaryItemsPrefix)", reply:
                T.summary(seq: 1, uid: 1, flags: "\\Seen", subject: "Old", messageID: "msg-1@example.com") + T.ok()),
            .expect("* UID FETCH 1 (UID BODY.PEEK[1]<0.2048>)", reply: T.snippet(seq: 1, uid: 1, text: "Still here.") + T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let result = try await service.sync(mailbox: inbox, previous: previous, limit: 50)
        let prefix = "\(account.id)|INBOX|1792471486|"
        XCTAssertEqual(result.removedIDs, [prefix + "2", prefix + "3"])
        XCTAssertEqual(result.state.knownUIDs, [1])
    }
}
