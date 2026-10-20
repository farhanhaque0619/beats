import XCTest
import InkModel
@testable import InkSync

/// Servers that start without Sent / Archive / Trash / Junk: IMAPMailService creates them on first
/// use, and the store has to notice without waiting for its periodic folder-list refresh.
/// (Found against GreenMail, which starts with INBOX only, and Dovecot without an Archive.)
@MainActor
final class MailStoreFolderDiscoveryTests: XCTestCase {
    private let me = address("Alex Rivera", "alex@bare.example")

    /// An account whose server has only `folders`, with two messages from people in the inbox.
    private func bareHarness(folders roles: [MailboxRole] = [.inbox], createsFolders: Bool = true)
        async throws -> (Harness, AccountConfig, FakeMailService) {
        let id = "bare-1"
        let account = AccountConfig(
            id: id, provider: .other, displayName: "Alex Rivera", emailAddress: me.address,
            imap: ServerConfig(host: "mail.bare.example", port: 993, security: .tls, username: me.address),
            smtp: ServerConfig(host: "mail.bare.example", port: 465, security: .tls, username: me.address),
            createdAt: referenceDate)
        let names: [MailboxRole: String] = [.inbox: "INBOX", .sent: "Sent", .archive: "Archive", .trash: "Trash", .junk: "Junk"]
        let folders = roles.map { MailboxInfo(accountID: id, path: names[$0] ?? $0.rawValue, role: $0) }
        let inbox = [
            summary(account: id, uid: 1, messageID: "lunch@people.example", subject: "Lunch on Thursday?",
                    from: address("Grace Oyelaran", "grace@people.example"), to: [me],
                    date: referenceDate.addingTimeInterval(-3_600), flags: []),
            summary(account: id, uid: 2, messageID: "deck@people.example", subject: "Revised deck",
                    from: address("Dev Mehta", "dev@people.example"), to: [me],
                    date: referenceDate.addingTimeInterval(-1_800), flags: []),
            summary(account: id, uid: 3, messageID: "prize@spam.example", subject: "You won",
                    from: address("Prize Desk", "desk@spam.example"), to: [me],
                    date: referenceDate.addingTimeInterval(-900), flags: []),
        ]
        let fake = FakeMailService(account: account, folders: folders, contents: ["INBOX": inbox])
        if createsFolders { await fake.createMissingFolders() }
        let harness = try makeHarness(services: [id: fake])
        await harness.store.load()
        try await harness.store.addAccount(account, credential: .password("app-password"))
        await harness.store.waitUntilIdle()
        harness.store.inboxFilter = .everything
        return (harness, account, fake)
    }

    private func roles(_ store: MailStore, _ account: AccountConfig) -> Set<MailboxRole> {
        Set(store.mailboxes(for: account.id).map(\.role))
    }

    func testFirstSendFindsTheSentFolderTheServiceCreated() async throws {
        let (harness, account, fake) = try await bareHarness()
        let store = harness.store
        XCTAssertEqual(roles(store, account), [.inbox])
        let lunch = try XCTUnwrap(store.conversations.first { $0.subject == "Lunch on Thursday?" })
        var reply = store.draft(replyingTo: try XCTUnwrap(lunch.latest), mode: .reply, body: nil)
        reply.body = "Thursday works."
        store.send(reply)
        await store.flushPendingActions()
        await store.waitUntilIdle()
        XCTAssertTrue(store.outbox.isEmpty)

        let created = await fake.folderList()
        XCTAssertTrue(created.contains { $0.role == .sent }, "the service made Sent for the copy")
        XCTAssertTrue(roles(store, account).contains(.sent), "the store re-read the folder list")
        XCTAssertEqual(store.conversations.first { $0.subject == "Lunch on Thursday?" }?.count, 2, "the reply shows in its thread")
    }

    func testFirstArchiveTrashAndSpamListTheFoldersTheServiceCreated() async throws {
        let (harness, account, fake) = try await bareHarness(folders: [.inbox, .sent])
        let store = harness.store
        let before = await fake.mailboxListCount

        let lunch = try XCTUnwrap(store.conversations.first { $0.subject == "Lunch on Thursday?" })
        store.archive([lunch])
        await store.flushPendingActions()
        await store.waitUntilIdle()
        XCTAssertTrue(roles(store, account).contains(.archive))
        store.scope = .unified(.archive)
        let archivedShows = await waitFor(3) { store.conversations.contains { $0.subject == "Lunch on Thursday?" } }
        XCTAssertTrue(archivedShows, "the Archive scope works right after the folder was created")

        store.scope = .allInboxes
        let deck = try XCTUnwrap(store.conversations.first { $0.subject == "Revised deck" })
        store.trash([deck])
        let prize = try XCTUnwrap(store.conversations.first { $0.subject == "You won" })
        store.markSpam([prize])
        await store.flushPendingActions()
        await store.waitUntilIdle()
        XCTAssertTrue(roles(store, account).isSuperset(of: [.archive, .trash, .junk]), "\(roles(store, account))")
        let after = await fake.mailboxListCount
        XCTAssertEqual(after - before, 3, "one re-read per folder created, none otherwise")

        // With every folder there, triage doesn't re-read the list.
        await fake.deliver(summary(uid: 0, messageID: "more@people.example", subject: "One more", from: address("Grace Oyelaran", "grace@people.example"),
                                   date: referenceDate, flags: []))
        await store.refresh()
        let more = try XCTUnwrap(store.conversations.first { $0.subject == "One more" })
        store.archive([more])
        await store.flushPendingActions()
        await store.waitUntilIdle()
        let final = await fake.mailboxListCount
        XCTAssertEqual(final, after)
    }

    func testRefreshingAScopeWhoseFolderIsMissingReReadsTheListNowAndThen() async throws {
        let (harness, account, fake) = try await bareHarness(folders: [.inbox, .sent], createsFolders: false)
        let store = harness.store
        store.scope = .unified(.archive)
        await store.waitUntilIdle()
        XCTAssertTrue(store.conversations.isEmpty)
        let start = await fake.mailboxListCount

        // Just read: a pull-to-refresh doesn't list again.
        await store.refresh()
        var count = await fake.mailboxListCount
        XCTAssertEqual(count, start)

        // An Archive made in the webmail shows up on the next manual refresh after 30 s.
        await fake.addFolder(MailboxInfo(accountID: account.id, path: "Archive", role: .archive),
                             messages: [summary(uid: 0, messageID: "old@people.example", subject: "Old receipts",
                                                from: address("Dev Mehta", "dev@people.example"), date: referenceDate.addingTimeInterval(-86_400))])
        harness.clock.advance(31)
        await store.refresh()
        count = await fake.mailboxListCount
        XCTAssertEqual(count, start + 1)
        XCTAssertTrue(roles(store, account).contains(.archive))
        XCTAssertEqual(store.conversations.map(\.subject), ["Old receipts"])

        // The folder is there now: no more extra reads.
        harness.clock.advance(31)
        await store.refresh()
        count = await fake.mailboxListCount
        XCTAssertEqual(count, start + 1)

        // Inbox refreshes never re-read the list for a folder they don't need.
        store.scope = .allInboxes
        harness.clock.advance(31)
        await store.refresh()
        count = await fake.mailboxListCount
        XCTAssertEqual(count, start + 1)
    }

    func testConversationOrderBreaksDateTiesByArrivalThenUID() {
        let sameSecond = referenceDate
        var question = summary(uid: 7, messageID: "q@x.example", subject: "Plan", from: address("Grace", "grace@x.example"), date: sameSecond)
        question.receivedDate = sameSecond
        var answer = summary(mailbox: "Sent", uid: 3, messageID: "a@x.example", inReplyTo: ["q@x.example"], subject: "Re: Plan",
                             from: me, date: sameSecond)
        answer.receivedDate = sameSecond.addingTimeInterval(1)
        var copy = summary(uid: 9, messageID: "c@x.example", subject: "Re: Plan", from: me, date: sameSecond)
        copy.receivedDate = answer.receivedDate
        for input in [[question, answer, copy], [copy, answer, question], [answer, copy, question]] {
            XCTAssertEqual(Conversation(id: "t", messages: input).messages.map(\.messageID), ["q@x.example", "a@x.example", "c@x.example"])
        }
    }
}
