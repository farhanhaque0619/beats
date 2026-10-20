import XCTest
import InkModel
@testable import InkSync

/// A store wired to services the test can see into.
@MainActor
struct Harness {
    let store: MailStore
    let demo: DemoMailService
    let clock: TestClock
    let directory: URL
    let credentials: InMemoryCredentialStore
}

@MainActor
func makeHarness(directory: URL? = nil, clock: TestClock? = nil, services: [String: MailService] = [:]) throws -> Harness {
    let clock = clock ?? TestClock(referenceDate)
    let directory = try directory ?? makeTemporaryDirectory()
    let credentials = InMemoryCredentialStore()
    let demo = DemoMailService(now: clock.function)
    let environment = MailStoreEnvironment(storageDirectory: directory, credentials: credentials, transportFactory: nil, now: clock.function)
    let store = MailStore(environment: environment) { account, _ in
        if account.isDemo { return demo }
        return services[account.id] ?? OfflineMailService(account: account)
    }
    store.undoWindow = 0.05
    store.undoSendDelay = 0.05
    return Harness(store: store, demo: demo, clock: clock, directory: directory, credentials: credentials)
}

@MainActor
func demoHarness(directory: URL? = nil, clock: TestClock? = nil) async throws -> Harness {
    let harness = try makeHarness(directory: directory, clock: clock)
    await harness.store.load()
    await harness.store.addDemoAccount()
    await harness.store.waitUntilIdle()
    return harness
}

/// A plain IMAP-style account (Fastmail) backed by `FakeMailService`.
func fastmailFixture(id: String = "fm-1", inboxCount: Int = 6, email: String = "alex@fastmail.example") -> (AccountConfig, FakeMailService) {
    let account = AccountConfig(
        id: id, provider: .fastmail, displayName: "Alex Rivera", emailAddress: email,
        imap: ServerConfig(host: "imap.fastmail.com", port: 993, security: .tls, username: email),
        smtp: ServerConfig(host: "smtp.fastmail.com", port: 465, security: .tls, username: email),
        colorIndex: 3, createdAt: referenceDate)
    let folders = [
        MailboxInfo(accountID: id, path: "INBOX", role: .inbox),
        MailboxInfo(accountID: id, path: "Sent", role: .sent, attributes: ["\\Sent"]),
        MailboxInfo(accountID: id, path: "Archive", role: .archive, attributes: ["\\Archive"]),
        MailboxInfo(accountID: id, path: "Junk Mail", role: .junk, attributes: ["\\Junk"]),
        MailboxInfo(accountID: id, path: "Trash", role: .trash, attributes: ["\\Trash"]),
        MailboxInfo(accountID: id, path: "Projects", role: .custom),
    ]
    let people = [
        address("Grace Oyelaran", "grace.o@mailbox.example"), address("Dev Mehta", "dev@thebuildlog.example"),
        address("Lena Fischer", "lena@tinkerbit.example"), address("Omar Haddad", "omar@riverbendfoodbank.example"),
    ]
    let inbox = (0..<inboxCount).map { index -> MessageSummary in
        let bulk = index % 5 == 4
        let sender = bulk ? address("Field Notes", "hello@fieldnotesweekly.example") : people[index % people.count]
        return summary(account: id, uid: UInt32(10 + index), messageID: "fm\(index)@\(sender.domain)",
                       subject: bulk ? "Field Notes #\(80 + index)" : "Fastmail topic \(index)", from: sender,
                       to: [address("Alex Rivera", email)], date: referenceDate.addingTimeInterval(-Double(index) * 5_400 - 600),
                       flags: index % 3 == 0 ? [] : [.seen], bulk: bulk, snippet: "Snippet number \(index)")
    }
    return (account, FakeMailService(account: account, folders: folders, contents: ["INBOX": inbox]))
}

@MainActor
func fakeHarness(inboxCount: Int = 6) async throws -> (Harness, AccountConfig, FakeMailService) {
    let (account, fake) = fastmailFixture(inboxCount: inboxCount)
    let harness = try makeHarness(services: [account.id: fake])
    try await harness.store.addAccount(account, credential: .password("app-specific-password"))
    await harness.store.waitUntilIdle()
    return (harness, account, fake)
}

@MainActor
final class MailStoreTests: XCTestCase {
    private func find(_ store: MailStore, _ subjectPrefix: String) -> Conversation? {
        store.conversations.first { $0.subject.hasPrefix(subjectPrefix) }
    }

    private func settle(_ store: MailStore, seconds: Double = 0.25) async {
        try? await Task.sleep(nanoseconds: UInt64(seconds * 1_000_000_000))
        await store.waitUntilIdle()
    }

    // MARK: Load

    func testLoadThenDemoAccountShowsInbox() async throws {
        let harness = try makeHarness()
        let store = harness.store
        await store.load()
        XCTAssertFalse(store.hasAccounts)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertTrue(store.conversations.isEmpty)

        await store.addDemoAccount()
        XCTAssertEqual(store.accounts, [.demo])
        XCTAssertTrue(store.isDemoActive)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertEqual(store.lastSyncedAt, harness.clock.now)
        XCTAssertGreaterThan(store.conversations.count, 10)
        XCTAssertEqual(store.mailboxes(for: "demo").first?.role, .inbox)
        XCTAssertEqual(store.title(for: .allInboxes), "Inbox")

        // Your replies (in Sent) show inside inbox threads.
        let roadmap = try XCTUnwrap(find(store, "Q4 roadmap review"))
        XCTAssertEqual(roadmap.count, 4)
        XCTAssertTrue(roadmap.messages.contains { $0.mailboxPath == "Sent" })
        XCTAssertTrue(roadmap.isUnread)

        // Idempotent.
        let count = store.conversations.count
        await store.addDemoAccount()
        await store.load()
        await store.waitUntilIdle()
        XCTAssertEqual(store.accounts.count, 1)
        XCTAssertEqual(store.conversations.count, count)
        let ids = store.conversations.map(\.id)
        XCTAssertEqual(ids.count, Set(ids).count, "no duplicate conversations")
        XCTAssertEqual(store.conversations, store.conversations.sorted { $0.date > $1.date }, "newest first")
    }

    func testColdLoadShowsCacheInstantlyThenRefreshesOnce() async throws {
        let (account, firstFake) = fastmailFixture()
        let directory = try makeTemporaryDirectory()
        let first = try makeHarness(directory: directory, services: [account.id: firstFake])
        try await first.store.addAccount(account, credential: .password("pw"))
        await first.store.waitUntilIdle()
        let shown = first.store.conversations.map(\.id)
        XCTAssertFalse(shown.isEmpty)
        await first.store.flushPendingActions()

        let (_, secondFake) = fastmailFixture()
        let second = try makeHarness(directory: directory, clock: first.clock, services: [account.id: secondFake])
        // Background refresh and the UI both call load(); only one load and one refresh happen.
        let secondStore = second.store
        async let a: Void = secondStore.load()
        async let b: Void = secondStore.load()
        _ = await (a, b)
        XCTAssertEqual(second.store.accounts, [account])
        XCTAssertEqual(second.store.conversations.map(\.id), shown, "cached mail before any network")
        XCTAssertEqual(second.store.syncStatus, .syncing, "refresh runs in the background")
        XCTAssertNil(second.store.lastSyncedAt)

        await second.store.waitUntilIdle()
        XCTAssertEqual(second.store.syncStatus, .idle)
        XCTAssertNotNil(second.store.lastSyncedAt)
        let syncs = await secondFake.syncCount
        XCTAssertEqual(syncs, 2, "inbox + Sent, once")
        await second.store.load()
        await second.store.waitUntilIdle()
        let after = await secondFake.syncCount
        XCTAssertEqual(after, syncs, "a second load doesn't refresh again")
    }

    // MARK: Scopes

    func testScopeSwitchingSyncsStaleFoldersAndTitles() async throws {
        let store = try await demoHarness().store

        store.scope = .unified(.trash)
        await store.waitUntilIdle()
        XCTAssertEqual(store.conversations.count, 3)
        XCTAssertEqual(store.title(for: store.scope), "Trash")
        XCTAssertEqual(store.otherCount, 0, "Focus / Other is for inboxes only")

        store.scope = .mailbox(accountID: "demo", path: "Receipts")
        await store.waitUntilIdle()
        XCTAssertEqual(store.conversations.count, 2)
        XCTAssertEqual(store.title(for: store.scope), "Receipts")

        store.scope = .unified(.junk)
        await store.waitUntilIdle()
        XCTAssertEqual(store.conversations.count, 3)
        XCTAssertEqual(store.unreadCount(for: .unified(.junk)), 2)

        store.scope = .account(accountID: "demo", role: .sent)
        await store.waitUntilIdle()
        XCTAssertFalse(store.conversations.isEmpty)
        XCTAssertTrue(store.conversations.allSatisfy { $0.messages.contains { $0.mailboxPath == "Sent" } })
        XCTAssertEqual(store.title(for: store.scope), "Sent")

        store.scope = .account(accountID: "demo", role: .drafts)
        await store.waitUntilIdle()
        XCTAssertEqual(store.conversations.count, 1)

        store.scope = .unified(.archive)
        await store.waitUntilIdle()
        XCTAssertGreaterThanOrEqual(store.conversations.count, 5)

        store.scope = .unified(.flagged)
        await store.waitUntilIdle()
        XCTAssertFalse(store.conversations.isEmpty)
        XCTAssertTrue(store.conversations.allSatisfy(\.isFlagged))
        XCTAssertEqual(store.title(for: .unified(.flagged)), "Starred")

        store.scope = .allInboxes
        XCTAssertTrue(store.conversations.contains { $0.subject.hasPrefix("Q4 roadmap review") }, "rebuilt from cache synchronously")
        XCTAssertEqual(store.title(for: .unified(.snoozed)), "Snoozed")
    }

    func testUnifiedInboxMergesAccounts() async throws {
        let (account, fake) = fastmailFixture()
        let harness = try makeHarness(services: [account.id: fake])
        let store = harness.store
        try await store.addAccount(account, credential: .password("pw"))
        await store.addDemoAccount()
        await store.waitUntilIdle()

        XCTAssertEqual(store.accounts.map(\.id), [account.id, "demo"])
        XCTAssertEqual(store.title(for: .allInboxes), "All Inboxes")
        XCTAssertEqual(store.title(for: .account(accountID: account.id, role: .inbox)), "Fastmail · Inbox")
        XCTAssertEqual(store.title(for: .mailbox(accountID: "demo", path: "Receipts")), "Demo · Receipts")
        store.inboxFilter = .everything
        XCTAssertEqual(Set(store.conversations.map(\.accountID)), [account.id, "demo"])
        XCTAssertEqual(store.conversations, store.conversations.sorted { $0.date > $1.date })
        let total = store.unreadCount(for: .allInboxes)
        let parts = store.unreadCount(for: .account(accountID: account.id, role: .inbox)) + store.unreadCount(for: .account(accountID: "demo", role: .inbox))
        XCTAssertEqual(total, parts)
        XCTAssertGreaterThan(total, 0)

        XCTAssertEqual(store.sendingAccounts.map(\.id), [account.id], "demo can't be picked to send when a real account exists")
        XCTAssertEqual(store.newDraft().accountID, account.id)
        XCTAssertEqual(store.newDraft(accountID: "demo").accountID, "demo")

        store.scope = .account(accountID: account.id, role: .inbox)
        XCTAssertTrue(store.conversations.allSatisfy { $0.accountID == account.id })
    }

    // MARK: Accounts

    func testAddingRealAccountReplacesLoneDemo() async throws {
        let (account, fake) = fastmailFixture()
        let harness = try makeHarness(services: [account.id: fake])
        let store = harness.store
        await store.load()
        await store.addDemoAccount()
        await store.waitUntilIdle()
        store.scope = .account(accountID: "demo", role: .inbox)
        await store.flushPendingActions()
        XCTAssertTrue(FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("cache/demo").path))

        try await store.addAccount(account, credential: .password("s3cret"))
        await store.waitUntilIdle()
        XCTAssertEqual(store.accounts, [account])
        XCTAssertEqual(store.scope, .allInboxes)
        XCTAssertFalse(store.isDemoActive)
        let saved = try await harness.credentials.credential(for: account)
        XCTAssertEqual(saved, .password("s3cret"))
        XCTAssertFalse(store.conversations.isEmpty)
        XCTAssertTrue(store.conversations.allSatisfy { $0.accountID == account.id })
        await store.flushPendingActions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: harness.directory.appendingPathComponent("cache/demo").path))

        // A second real account keeps the first; signing in again with the same address replaces it.
        let (other, otherFake) = fastmailFixture(id: "fm-2", email: "alex@fastmail.example")
        _ = otherFake
        try await store.addAccount(other, credential: .password("new"))
        XCTAssertEqual(store.accounts.map(\.id), ["fm-2"], "same address: the old account is replaced")
    }

    func testRemoveAccountDeletesCredentialAndCache() async throws {
        let (harness, account, _) = try await fakeHarness()
        let store = harness.store
        store.scope = .account(accountID: account.id, role: .inbox)
        await store.flushPendingActions()
        let folder = harness.directory.appendingPathComponent("cache/\(account.id)")
        XCTAssertTrue(FileManager.default.fileExists(atPath: folder.path))

        await store.removeAccount(id: account.id)
        XCTAssertTrue(store.accounts.isEmpty)
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertEqual(store.scope, .allInboxes, "a scope for a removed account resets")
        XCTAssertTrue(store.mailboxes(for: account.id).isEmpty)
        do {
            _ = try await harness.credentials.credential(for: account)
            XCTFail("credential should be gone")
        } catch {}
        await store.flushPendingActions()
        XCTAssertFalse(FileManager.default.fileExists(atPath: folder.path))
        let accountsFile = try Data(contentsOf: harness.directory.appendingPathComponent("accounts.json"))
        XCTAssertEqual(String(decoding: accountsFile, as: UTF8.self), "[]")
    }

    func testUpdateAccountPersistsWithoutSecrets() async throws {
        let (harness, account, _) = try await fakeHarness()
        var edited = account
        edited.displayName = "Alex R."
        edited.signature = "Alex\nSent from Ink"
        edited.colorIndex = 5
        harness.store.updateAccount(edited)
        XCTAssertEqual(harness.store.account(id: account.id), edited)
        await harness.store.flushPendingActions()
        let text = String(decoding: try Data(contentsOf: harness.directory.appendingPathComponent("accounts.json")), as: UTF8.self)
        XCTAssertTrue(text.contains("Sent from Ink"))
        XCTAssertFalse(text.contains("app-specific-password"), "secrets never reach accounts.json")
        let reloaded = try makeHarness(directory: harness.directory, clock: harness.clock)
        await reloaded.store.load()
        XCTAssertEqual(reloaded.store.accounts, [edited])
    }

    func testVerifyUsesTheGivenCredentialWithoutSaving() async throws {
        let (account, fake) = fastmailFixture()
        let harness = try makeHarness(services: [account.id: fake])
        let steps = StepRecorder()
        try await harness.store.verify(account, credential: .password("pw")) { steps.append($0) }
        XCTAssertEqual(steps.all, VerificationStep.allCases)
        XCTAssertTrue(harness.store.accounts.isEmpty)
        do {
            _ = try await harness.credentials.credential(for: account)
            XCTFail("verify must not save")
        } catch {}
    }

    // MARK: Triage

    func testArchiveAndUndoWithinWindowNeverCallsServer() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.undoWindow = 30
        let target = try XCTUnwrap(store.conversations.first)
        store.archive([target])
        XCTAssertFalse(store.conversations.contains { $0.id == target.id }, "gone immediately, synchronously")
        XCTAssertEqual(store.toast?.message, "Archived")
        XCTAssertEqual(store.toast?.undoable, true)

        store.undo()
        XCTAssertTrue(store.conversations.contains { $0.id == target.id })
        XCTAssertNil(store.toast)
        await settle(store, seconds: 0.2)
        let performed = await fake.performed
        XCTAssertTrue(performed.isEmpty, "undo is local: no reverse operation is sent")
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertTrue(inbox.contains { $0.messageID == target.latest?.messageID })
    }

    func testArchiveCommitsAfterWindow() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let roadmap = try XCTUnwrap(find(store, "Q4 roadmap review"))
        let ids = Set(roadmap.messages.compactMap(\.messageID))
        store.archive([roadmap])
        XCTAssertNil(find(store, "Q4 roadmap review"))
        await settle(store, seconds: 0.3)

        let inbox = await harness.demo.messages(in: "INBOX")
        XCTAssertFalse(inbox.contains { ids.contains($0.messageID ?? "") }, "server state changed")
        let archive = await harness.demo.messages(in: "Archive")
        XCTAssertEqual(archive.filter { ids.contains($0.messageID ?? "") }.count, 3, "the inbox copies, not your Sent reply")
        XCTAssertEqual(store.toast?.message, "Archived")
        XCTAssertEqual(store.toast?.undoable, false, "the window closed")

        store.undo()
        XCTAssertNil(find(store, "Q4 roadmap review"), "too late to undo")
        await store.refresh()
        XCTAssertNil(find(store, "Q4 roadmap review"), "the server agrees after a refresh")

        store.scope = .unified(.archive)
        await store.waitUntilIdle()
        XCTAssertNotNil(find(store, "Q4 roadmap review"))
    }

    func testStartingAnotherActionCommitsThePreviousOne() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.undoWindow = 30
        store.inboxFilter = .everything
        let first = store.conversations[0]
        let second = store.conversations[1]
        store.archive([first])
        store.trash([second])
        XCTAssertEqual(store.toast?.message, "Moved to Trash")
        await store.waitUntilIdle()
        var performed = await fake.performed
        XCTAssertEqual(performed.count, 1)
        XCTAssertEqual(performed.first?.action, .archive)

        store.undo()
        XCTAssertTrue(store.conversations.contains { $0.id == second.id }, "undo reverts the latest action")
        XCTAssertFalse(store.conversations.contains { $0.id == first.id }, "the earlier one is already committed")
        store.undo()
        XCTAssertFalse(store.conversations.contains { $0.id == first.id }, "nothing left to undo")
        await settle(store, seconds: 0.1)
        performed = await fake.performed
        XCTAssertEqual(performed.count, 1)
    }

    func testSyncDuringUndoWindowDoesNotUndoTheChange() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.undoWindow = 30
        store.inboxFilter = .everything
        let archived = store.conversations[0]
        store.archive([archived])
        await store.refresh()
        XCTAssertFalse(store.conversations.contains { $0.id == archived.id }, "a sync must not resurrect it")

        let unread = try XCTUnwrap(store.conversations.first { $0.isUnread })
        store.setRead(true, [unread])
        await store.refresh()
        XCTAssertEqual(store.conversations.first { $0.id == unread.id }?.isUnread, false, "nor revert the flag")
        XCTAssertEqual(store.toast?.message, "Marked as Read")

        await store.flushPendingActions()
        let performed = await fake.performed.map(\.action)
        XCTAssertEqual(performed, [.archive, .markRead])
        await store.refresh()
        XCTAssertFalse(store.conversations.contains { $0.id == archived.id })
        XCTAssertEqual(store.conversations.first { $0.id == unread.id }?.isUnread, false)
    }

    func testFailedCommitPutsThingsBackWithErrorToast() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        await fake.failPerform(.connectionFailed("Network is unreachable."))
        let target = try XCTUnwrap(store.conversations.first)
        store.archive([target])
        XCTAssertFalse(store.conversations.contains { $0.id == target.id })
        await settle(store, seconds: 0.3)
        XCTAssertTrue(store.conversations.contains { $0.id == target.id }, "reverted when the server refused")
        XCTAssertEqual(store.toast?.style, .error)
        XCTAssertEqual(store.toast?.message, "Couldn't archive. Couldn't reach the server. Network is unreachable.")
        store.dismissToast()
        XCTAssertNil(store.toast)
    }

    func testReadAndStarAreUndoableAndCommit() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let unread = try XCTUnwrap(store.conversations.first { $0.isUnread })
        store.toggleRead([unread])
        XCTAssertEqual(store.conversations.first { $0.id == unread.id }?.isUnread, false)
        XCTAssertEqual(store.toast?.message, "Marked as Read")
        store.undo()
        XCTAssertEqual(store.conversations.first { $0.id == unread.id }?.isUnread, true)

        let plain = try XCTUnwrap(store.conversations.first { !$0.isFlagged && !$0.isUnread })
        store.perform(.flag, on: [plain])
        XCTAssertEqual(store.toast?.message, "Starred")
        XCTAssertEqual(store.conversations.first { $0.id == plain.id }?.isFlagged, true)
        await store.flushPendingActions()
        let latestID = plain.latest?.messageID
        let flagged = await harness.demo.messages(in: "INBOX").filter { $0.isFlagged }.compactMap(\.messageID)
        XCTAssertTrue(flagged.contains(latestID ?? "-"))

        store.toggleFlag([try XCTUnwrap(store.conversations.first { $0.id == plain.id })])
        XCTAssertEqual(store.toast?.message, "Unstarred")
        XCTAssertEqual(store.conversations.first { $0.id == plain.id }?.isFlagged, false)

        store.toggleRead([try XCTUnwrap(store.conversations.first { $0.id == plain.id })])
        XCTAssertEqual(store.toast?.message, "Marked as Unread")
        XCTAssertEqual(store.conversations.first { $0.id == plain.id }?.unreadCount, 1, "only the latest message becomes unread")
        store.perform(.none, on: [plain])
        store.perform(.snooze, on: [plain])
        XCTAssertEqual(store.toast?.message, "Marked as Unread", "no-ops leave the last toast alone")
    }

    func testMarkOpenedCommitsRightAwayWithoutToast() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        store.undoWindow = 60
        let unread = try XCTUnwrap(find(store, "Dinner Saturday?"))
        XCTAssertTrue(unread.isUnread)
        store.markOpened(unread)
        XCTAssertEqual(find(store, "Dinner Saturday?")?.isUnread, false)
        XCTAssertNil(store.toast)
        await store.waitUntilIdle()
        let server = await harness.demo.messages(in: "INBOX").first { $0.subject == "Dinner Saturday?" }
        XCTAssertEqual(server?.isUnread, false, "committed without waiting for an undo window")
    }

    func testMoveToFolderAndBackToInbox() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let receipt = try XCTUnwrap(store.allConversations(for: .allInboxes).first { $0.subject.hasPrefix("Your Harbor & Pine order #HP-48213") })
        let receipts = try XCTUnwrap(store.mailboxes(for: "demo").first { $0.path == "Receipts" })
        store.move([receipt], to: receipts)
        XCTAssertEqual(store.toast?.message, "Moved to Receipts")
        await store.flushPendingActions()
        let filed = await harness.demo.messages(in: "Receipts").contains { $0.subject.hasPrefix("Your Harbor & Pine order #HP-48213") }
        XCTAssertTrue(filed)

        store.scope = .mailbox(accountID: "demo", path: "Receipts")
        await store.waitUntilIdle()
        let moved = try XCTUnwrap(find(store, "Your Harbor & Pine order #HP-48213"))
        store.moveToInbox([moved])
        XCTAssertNil(find(store, "Your Harbor & Pine order #HP-48213"))
        XCTAssertEqual(store.toast?.message, "Moved to Inbox")
        await store.flushPendingActions()
        await store.waitUntilIdle()
        XCTAssertTrue(store.allConversations(for: .allInboxes).contains { $0.subject.hasPrefix("Your Harbor & Pine order #HP-48213") })
    }

    func testTrashAndSpamFromInbox() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let doomed = Array(store.conversations.prefix(2))
        store.trash(doomed)
        XCTAssertEqual(store.toast?.message, "Moved 2 conversations to Trash")
        let spam = try XCTUnwrap(store.conversations.first { $0.isBulk })
        store.markSpam([spam])
        XCTAssertEqual(store.toast?.message, "Marked as Spam")
        await store.flushPendingActions()
        let junk = await harness.demo.messages(in: "Junk")
        XCTAssertTrue(junk.contains { $0.messageID == spam.latest?.messageID })
        store.scope = .unified(.trash)
        await store.waitUntilIdle()
        for conversation in doomed {
            XCTAssertTrue(store.conversations.contains { candidate in candidate.messages.contains { $0.messageID == conversation.latest?.messageID } })
        }
    }

    // MARK: Snooze

    func testSnoozeHidesThenWakeBringsItBackUnreadOnTop() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let hike = try XCTUnwrap(find(store, "Photos from Saturday"))
        XCTAssertFalse(hike.isUnread)
        XCTAssertNotEqual(store.conversations.first?.id, hike.id)
        let until = harness.clock.now.addingTimeInterval(3_600)
        store.snooze([hike], until: until)
        XCTAssertNil(find(store, "Photos from Saturday"))
        XCTAssertEqual(store.snoozeDate(for: hike), until)
        XCTAssertTrue(store.toast?.message.hasPrefix("Snoozed until ") ?? false, store.toast?.message ?? "")
        XCTAssertEqual(store.snoozedConversations.map(\.id), [hike.id])
        XCTAssertEqual(store.conversation(id: hike.id)?.id, hike.id)

        await store.flushPendingActions()
        let inbox = await harness.demo.messages(in: "INBOX")
        XCTAssertFalse(inbox.contains { $0.subject == "Photos from Saturday's hike" }, "archived on the server while snoozed")
        await store.refresh()
        XCTAssertNil(find(store, "Photos from Saturday"), "stays hidden across refreshes")

        store.scope = .unified(.snoozed)
        XCTAssertEqual(store.conversations.map(\.id), [hike.id])
        store.scope = .allInboxes

        // Not due yet.
        await store.wakeDueSnoozes()
        XCTAssertNil(find(store, "Photos from Saturday"))

        harness.clock.advance(2 * 3_600)
        await store.wakeDueSnoozes()
        await store.waitUntilIdle()
        XCTAssertEqual(store.conversations.first?.subject, "Photos from Saturday's hike", "back at the top")
        XCTAssertEqual(store.conversations.first?.isUnread, true, "and unread")
        XCTAssertNil(store.snoozeDate(for: hike))
        XCTAssertTrue(store.snoozedConversations.isEmpty)
        let serverCopy = await harness.demo.messages(in: "INBOX").first { $0.subject == "Photos from Saturday's hike" }
        XCTAssertEqual(serverCopy?.isUnread, true)
    }

    func testRefreshWakesDueSnoozes() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let hike = try XCTUnwrap(find(store, "Photos from Saturday"))
        store.snooze([hike], until: harness.clock.now.addingTimeInterval(60))
        harness.clock.advance(120)
        await store.refresh()
        await store.waitUntilIdle()
        XCTAssertEqual(find(store, "Photos from Saturday")?.isUnread, true)
    }

    func testUndoSnoozeAndUnsnooze() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        store.undoWindow = 30
        let hike = try XCTUnwrap(find(store, "Photos from Saturday"))
        store.snooze([hike], until: harness.clock.now.addingTimeInterval(86_400))
        store.undo()
        XCTAssertNotNil(find(store, "Photos from Saturday"))
        XCTAssertNil(store.snoozeDate(for: hike))

        store.snooze([hike], until: harness.clock.now.addingTimeInterval(86_400))
        await store.flushPendingActions()
        store.unsnooze([hike])
        XCTAssertNil(store.snoozeDate(for: hike))
        XCTAssertEqual(store.toast?.message, "Moved to Inbox")
        await store.flushPendingActions()
        await store.waitUntilIdle()
        XCTAssertNotNil(find(store, "Photos from Saturday"), "back in the inbox from the server")
    }

    // MARK: Send

    func testSendWithUndoThenSendForReal() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let dinner = try XCTUnwrap(find(store, "Dinner Saturday?")?.latest)
        var draft = store.draft(replyingTo: dinner, mode: .reply, body: nil)
        draft.body = "We're in! 7 works for us." + draft.body
        let sentBefore = await harness.demo.messages(in: "Sent").count

        store.undoSendDelay = 30
        store.send(draft)
        XCTAssertEqual(store.outbox.map(\.id), [draft.id])
        XCTAssertEqual(store.toast?.message, "Sending…")
        XCTAssertEqual(store.toast?.undoable, true)
        store.undo()
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertNil(store.toast)
        XCTAssertEqual(store.restoredDraft?.id, draft.id, "Compose can reopen it")
        XCTAssertEqual(store.takeRestoredDraft()?.body, draft.body)
        XCTAssertNil(store.restoredDraft)
        await settle(store, seconds: 0.1)
        var sentNow = await harness.demo.messages(in: "Sent").count
        XCTAssertEqual(sentNow, sentBefore, "nothing went out")

        store.undoSendDelay = 0.05
        store.send(draft)
        await settle(store, seconds: 0.3)
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(store.toast?.message, "Sent")
        XCTAssertEqual(store.toast?.style, .success)
        sentNow = await harness.demo.messages(in: "Sent").count
        XCTAssertEqual(sentNow, sentBefore + 1)
        let thread = try XCTUnwrap(find(store, "Dinner Saturday?"))
        XCTAssertEqual(thread.count, 2, "the reply shows in its thread")
        XCTAssertTrue(thread.messages.first?.flags.contains(.answered) ?? false)
    }

    func testSendValidation() async throws {
        let store = try await demoHarness().store
        store.send(store.newDraft())
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(store.toast?.message, "Add at least one recipient.")
        XCTAssertEqual(store.toast?.style, .error)
        var draft = store.newDraft()
        draft.to = [EmailAddress(address: "sam at mailbox")]
        store.send(draft)
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(store.toast?.message, "“sam at mailbox” doesn't look like an email address.")
        var orphan = store.newDraft()
        orphan.accountID = "gone"
        orphan.to = [address("Sam", "sam.chen@mailbox.example")]
        store.send(orphan)
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertEqual(store.toast?.style, .error)
    }

    func testFailedSendStaysInOutboxForRetry() async throws {
        let (harness, account, fake) = try await fakeHarness()
        let store = harness.store
        await fake.failSend(.sendFailed("bob@nowhere.example: mailbox unavailable"))
        var message = store.newDraft(accountID: account.id)
        message.to = [address("Bob", "bob@nowhere.example")]
        message.subject = "Hello"
        store.send(message)
        await settle(store, seconds: 0.3)
        XCTAssertEqual(store.outbox.map(\.id), [message.id])
        XCTAssertEqual(store.failedSendIDs, [message.id])
        XCTAssertEqual(store.toast?.message, "Couldn't send. bob@nowhere.example: mailbox unavailable")

        await fake.failSend(nil)
        store.retrySend(id: message.id)
        await store.waitUntilIdle()
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertTrue(store.failedSendIDs.isEmpty)
        let sent = await fake.sent
        XCTAssertEqual(sent.map(\.id), [message.id])

        await fake.failSend(.authenticationFailed(""))
        message.id = UUID()
        store.send(message)
        await settle(store, seconds: 0.3)
        XCTAssertEqual(store.toast?.message, "Couldn't send. The server didn't accept that password.")
        store.discardOutboxMessage(id: message.id)
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testFlushSendsPendingMessagesNow() async throws {
        let (harness, account, fake) = try await fakeHarness()
        let store = harness.store
        store.undoSendDelay = 60
        var message = store.newDraft(accountID: account.id)
        message.to = [address("Grace", "grace.o@mailbox.example")]
        store.send(message)
        await store.flushPendingActions()
        let sent = await fake.sent
        XCTAssertEqual(sent.count, 1)
        XCTAssertTrue(store.outbox.isEmpty)
    }

    // MARK: Focus / Other

    func testFocusAndOtherCounts() async throws {
        let store = try await demoHarness().store
        XCTAssertEqual(store.inboxFilter, .focused)
        let focused = store.conversations
        XCTAssertFalse(focused.isEmpty)
        XCTAssertTrue(focused.allSatisfy { !$0.isBulk })
        XCTAssertGreaterThan(store.otherCount, 3)
        XCTAssertGreaterThan(store.otherUnreadCount, 0)
        XCTAssertLessThanOrEqual(store.otherUnreadCount, store.otherCount)

        store.inboxFilter = .other
        XCTAssertEqual(store.conversations.count, store.otherCount)
        XCTAssertTrue(store.conversations.allSatisfy(\.isBulk))
        XCTAssertEqual(store.conversations.filter(\.isUnread).count, store.otherUnreadCount)

        store.inboxFilter = .everything
        XCTAssertEqual(store.conversations.count, focused.count + store.otherCount)

        store.inboxFilter = .focused
        store.focusedInboxEnabled = false
        XCTAssertEqual(store.otherCount, 0)
        XCTAssertEqual(store.otherUnreadCount, 0)
        XCTAssertEqual(store.conversations.count, focused.count + store.allConversations(for: .allInboxes).filter(\.isBulk).count)
        XCTAssertEqual(store.unreadCount(for: .allInboxes), store.allConversations(for: .allInboxes).filter(\.isUnread).count,
                       "inbox counts ignore the split")
    }

    // MARK: Search

    func testLocalSearch() async throws {
        let store = try await demoHarness().store
        let lisbon = store.searchLocal("lisbon")
        XCTAssertTrue(lisbon.contains { $0.subject.hasPrefix("Your trip to Lisbon") })
        XCTAssertEqual(lisbon, lisbon.sorted { $0.date > $1.date }, "newest first")
        XCTAssertTrue(store.searchLocal("LISBON").map(\.id) == lisbon.map(\.id), "case-insensitive")

        let priya = store.searchLocal("from:priya")
        XCTAssertFalse(priya.isEmpty)
        XCTAssertTrue(priya.allSatisfy { $0.messages.contains { $0.from.first?.address == "priya@fieldstone.example" } })

        let unreadLease = store.searchLocal("is:unread lease")
        XCTAssertEqual(unreadLease.map(\.subject), ["Lease renewal for unit 4B"])
        XCTAssertTrue(store.searchLocal("\"small teams\"").contains { $0.subject.contains("small teams") })
        XCTAssertTrue(store.searchLocal("has:attachment roadmap").contains { $0.subject.hasPrefix("Q4 roadmap") })
        XCTAssertTrue(store.searchLocal("").isEmpty)
        XCTAssertTrue(store.searchLocal("   ").isEmpty)
        XCTAssertTrue(store.searchLocal("zzqx-no-such-thing").isEmpty)
        XCTAssertTrue(store.searchLocal("candle").isEmpty, "Trash is left out")
        XCTAssertTrue(store.searchLocal("ease").isEmpty || !store.searchLocal("ease").contains { $0.subject.hasPrefix("Lease") },
                      "words match from their start")
        XCTAssertTrue(store.searchLocal("natara").contains { $0.subject.hasPrefix("Q4 roadmap") }, "prefix of a name")
    }

    func testServerSearchFindsUncachedMailAndOpensIt() async throws {
        let store = try await demoHarness().store
        XCTAssertTrue(store.searchLocal("Sylvan").isEmpty, "archived mail isn't cached yet")
        let results = try await store.searchServer("Sylvan")
        let tickets = try XCTUnwrap(results.first { $0.subject.hasPrefix("Your tickets: Sylvan") })
        XCTAssertNotNil(store.conversation(id: tickets.id), "the reader can open search results")
        let merged = try await store.searchServer("lisbon")
        XCTAssertTrue(merged.contains { $0.subject.hasPrefix("Your trip to Lisbon") })
        XCTAssertEqual(Set(merged.map(\.id)).count, merged.count, "merged without duplicates")
        let blank = try await store.searchServer("  ")
        XCTAssertTrue(blank.isEmpty)
    }

    func testServerSearchErrorsSurfaceOnlyWhenNothingElseFound() async throws {
        let (harness, _, fake) = try await fakeHarness()
        await fake.failSync(.timeout)
        do {
            _ = try await harness.store.searchServer("nothing-local")
            XCTFail("expected an error")
        } catch let error as MailError {
            XCTAssertEqual(error, .timeout)
        }
        let local = try await harness.store.searchServer("Fastmail topic")
        XCTAssertFalse(local.isEmpty, "local results still come back when the server is down")
    }

    func testRecentSearches() async throws {
        let store = try await demoHarness().store
        store.recordSearch("lisbon")
        store.recordSearch("  ")
        store.recordSearch("lease")
        store.recordSearch("Lisbon")
        XCTAssertEqual(store.recentSearches, ["Lisbon", "lease"])
        for index in 0..<15 { store.recordSearch("query \(index)") }
        XCTAssertEqual(store.recentSearches.count, 10)
        XCTAssertEqual(store.recentSearches.first, "query 14")
        store.clearRecentSearches()
        XCTAssertTrue(store.recentSearches.isEmpty)
    }

    // MARK: People

    func testContactSuggestions() async throws {
        let store = try await demoHarness().store
        XCTAssertEqual(store.contactSuggestions(matching: "pri").first?.address, "priya@fieldstone.example")
        XCTAssertEqual(store.contactSuggestions(matching: "Natara").first?.name, "Priya Natarajan")
        let fieldstone = store.contactSuggestions(matching: "fieldstone", limit: 10)
        XCTAssertGreaterThanOrEqual(fieldstone.count, 3)
        XCTAssertTrue(fieldstone.allSatisfy { $0.domain == "fieldstone.example" })
        let top = store.contactSuggestions(matching: "")
        XCTAssertEqual(top.count, 6)
        XCTAssertFalse(top.contains { store.isMe($0) })
        XCTAssertFalse(top.contains { $0.looksAutomated })
        XCTAssertTrue(store.isMe(address("Me", "ALEX@ink.example")))
        XCTAssertFalse(store.isMe(address("Priya", "priya@fieldstone.example")))
        XCTAssertEqual(store.contactSuggestions(matching: "pri", limit: 1).count, 1)
    }

    // MARK: Drafts

    func testReplyDraftsAndSignatures() async throws {
        let store = try await demoHarness().store
        var account = try XCTUnwrap(store.account(id: "demo"))
        account.signature = "Alex Rivera\nProduct designer, Fieldstone"
        store.updateAccount(account)
        let blank = store.newDraft()
        XCTAssertEqual(blank.body, "\n\n-- \nAlex Rivera\nProduct designer, Fieldstone")
        XCTAssertEqual(blank.from, account.address)
        XCTAssertTrue(blank.to.isEmpty)

        let roadmap = try XCTUnwrap(find(store, "Q4 roadmap review"))
        let latest = try XCTUnwrap(roadmap.latest)
        XCTAssertEqual(latest.from.first?.address, "priya@fieldstone.example")
        let body = try await store.body(for: latest)

        let reply = store.draft(replyingTo: latest, mode: .reply, body: body)
        XCTAssertEqual(reply.to.map(\.address), ["priya@fieldstone.example"])
        XCTAssertTrue(reply.cc.isEmpty)
        XCTAssertEqual(reply.subject, "Re: Q4 roadmap review — draft for Thursday", "no Re: Re:")
        XCTAssertEqual(reply.inReplyTo, latest.messageID)
        XCTAssertEqual(reply.references.last, latest.messageID)
        XCTAssertEqual(reply.references.count, 4)
        XCTAssertTrue(reply.quotedText?.contains("wrote:") ?? false)
        XCTAssertTrue(reply.quotedText?.contains("> Thanks both") ?? false)
        XCTAssertEqual(reply.body, blank.body, "signature below the cursor")
        XCTAssertEqual(reply.replyMode, .reply)

        let all = store.draft(replyingTo: latest, mode: .replyAll, body: nil)
        XCTAssertEqual(all.to.map(\.address), ["priya@fieldstone.example"])
        XCTAssertEqual(all.cc.map(\.address), ["marcus.bell@fieldstone.example"])
        XCTAssertFalse((all.to + all.cc).contains { store.isMe($0) })
        XCTAssertNotNil(all.quotedText, "the cached body fills the quote")

        let forward = store.draft(replyingTo: latest, mode: .forward, body: body)
        XCTAssertTrue(forward.to.isEmpty)
        XCTAssertTrue(forward.subject.hasPrefix("Fwd: "), forward.subject)
        XCTAssertTrue(forward.subject.hasSuffix("Q4 roadmap review — draft for Thursday"))
        XCTAssertFalse(forward.subject.hasPrefix("Fwd: Fwd:"))

        account.signature = "-- \nA."
        store.updateAccount(account)
        XCTAssertEqual(store.newDraft().body, "\n\n-- \nA.", "no doubled separator")
        account.signature = "   "
        store.updateAccount(account)
        XCTAssertEqual(store.newDraft().body, "")
    }

    // MARK: Persistence

    func testPersistenceRoundTripAcrossStores() async throws {
        let first = try await demoHarness()
        let store = first.store
        let receipt = try XCTUnwrap(store.allConversations(for: .allInboxes).first { $0.subject.hasPrefix("Your Harbor & Pine order #HP-48213") })
        store.archive([receipt])
        let hike = try XCTUnwrap(find(store, "Photos from Saturday"))
        let until = first.clock.now.addingTimeInterval(86_400)
        store.snooze([hike], until: until)
        store.recordSearch("lisbon")
        var account = try XCTUnwrap(store.account(id: "demo"))
        account.signature = "Alex"
        store.updateAccount(account)
        let body = try await store.body(for: try XCTUnwrap(find(store, "Dinner Saturday?")?.latest))
        await store.flushPendingActions()
        let expected = store.allConversations(for: .allInboxes).map(\.id)

        let second = try makeHarness(directory: first.directory, clock: first.clock)
        await second.store.load()
        // Straight from disk, before the refresh lands.
        XCTAssertEqual(second.store.accounts, [account])
        XCTAssertEqual(second.store.allConversations(for: .allInboxes).map(\.id), expected)
        XCTAssertFalse(second.store.allConversations(for: .allInboxes).contains { $0.id == receipt.id })
        XCTAssertEqual(second.store.snoozeDate(for: hike), until)
        XCTAssertEqual(second.store.recentSearches, ["lisbon"])
        XCTAssertEqual(second.store.mailboxes(for: "demo").map(\.path), store.mailboxes(for: "demo").map(\.path))
        let dinner = try XCTUnwrap(second.store.allConversations(for: .allInboxes).first { $0.subject == "Dinner Saturday?" }?.latest)
        XCTAssertEqual(second.store.cachedBody(for: dinner)?.plainText, body.plainText)

        await second.store.waitUntilIdle()
        XCTAssertFalse(second.store.allConversations(for: .allInboxes).contains { $0.id == hike.id },
                       "still snoozed even though the new demo server has it in its inbox")
    }

    func testCorruptStateFilesAreIgnored() async throws {
        let directory = try makeTemporaryDirectory()
        for name in ["accounts.json", "snoozes.json", "state.json", "outbox.json"] {
            try Data("{ not json".utf8).write(to: directory.appendingPathComponent(name))
        }
        let harness = try makeHarness(directory: directory)
        await harness.store.load()
        XCTAssertTrue(harness.store.accounts.isEmpty)
        XCTAssertTrue(harness.store.recentSearches.isEmpty)
        await harness.store.addDemoAccount()
        await harness.store.waitUntilIdle()
        XCTAssertFalse(harness.store.conversations.isEmpty)
    }

    func testUnsentOutboxSurvivesRelaunchAsFailed() async throws {
        let first = try await demoHarness()
        first.store.undoSendDelay = 600
        var message = first.store.newDraft()
        message.to = [address("Sam Chen", "sam.chen@mailbox.example")]
        message.subject = "Saturday"
        first.store.send(message)
        await first.store.cache?.flush()

        let second = try makeHarness(directory: first.directory, clock: first.clock)
        await second.store.load()
        XCTAssertEqual(second.store.outbox.map(\.id), [message.id])
        XCTAssertEqual(second.store.failedSendIDs, [message.id])
        second.store.retrySend(id: message.id)
        await second.store.waitUntilIdle()
        XCTAssertTrue(second.store.outbox.isEmpty)
        let sent = await second.demo.messages(in: "Sent")
        XCTAssertTrue(sent.contains { $0.subject == "Saturday" })
        first.store.discardOutboxMessage(id: message.id)
    }

    // MARK: Refresh

    func testRefreshAllInboxesReportsOnlyNewMailSinceLastCall() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let initial = await store.refreshAllInboxes()
        XCTAssertTrue(initial.isEmpty, "existing mail isn't news")

        let arrived = await harness.demo.deliverSampleMessage()
        await store.refresh() // a foreground refresh in between must not swallow it
        XCTAssertNotNil(find(store, "Running a little late"))
        let news = await store.refreshAllInboxes()
        XCTAssertEqual(news.map(\.messageID), [arrived.messageID])
        let again = await store.refreshAllInboxes()
        XCTAssertTrue(again.isEmpty)

        var bulk = arrived
        bulk.messageID = "digest-\(UUID().uuidString)@neighborly.example"
        bulk.subject = "Your weekly digest"
        bulk.isBulk = true
        await harness.demo.deliver(bulk)
        var fromMe = arrived
        fromMe.messageID = "self-\(UUID().uuidString)@ink.example"
        fromMe.from = [AccountConfig.demo.address]
        await harness.demo.deliver(fromMe)
        let quiet = await store.refreshAllInboxes()
        XCTAssertTrue(quiet.isEmpty, "newsletters and your own mail don't notify")
    }

    func testSyncFailureSetsStatusAndToast() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        await fake.failSync(.connectionFailed("No route to host."))
        await store.refresh()
        XCTAssertEqual(store.syncStatus, .failed("Couldn't reach the server. No route to host."))
        XCTAssertEqual(store.toast?.style, .error)
        XCTAssertEqual(store.toast?.message, "Couldn't refresh. Couldn't reach the server. No route to host.")
        XCTAssertFalse(store.conversations.isEmpty, "cached mail stays on screen")
        await fake.failSync(nil)
        harness.clock.advance(30)
        await store.refresh()
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertEqual(store.lastSyncedAt, harness.clock.now)
    }

    func testLoadMorePagesOlderMail() async throws {
        let (harness, _, _) = try await fakeHarness(inboxCount: 130)
        let store = harness.store
        store.inboxFilter = .everything
        XCTAssertEqual(store.conversations.count, MailStore.inboxWindow)
        XCTAssertTrue(store.canLoadMore)
        await store.loadMore()
        XCTAssertFalse(store.isLoadingMore)
        XCTAssertEqual(store.conversations.count, 130)
        XCTAssertFalse(store.canLoadMore, "the server has nothing older")
        await store.loadMore()
        XCTAssertEqual(store.conversations.count, 130)

        // Paged-in mail stays through the next incremental sync.
        await store.refresh()
        XCTAssertEqual(store.conversations.count, 130)
    }

    func testSmallMailboxNeedsNoPaging() async throws {
        let store = try await demoHarness().store
        XCTAssertFalse(store.canLoadMore, "the whole demo inbox fits the first window")
    }

    func testLiveUpdatesPullNewMail() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        store.startLiveUpdates()
        try await Task.sleep(nanoseconds: 200_000_000)
        await harness.demo.deliverSampleMessage()
        let arrived = await waitFor(5) {
            await store.waitUntilIdle()
            return store.conversations.contains { $0.subject == "Running a little late" }
        }
        XCTAssertTrue(arrived)
        store.stopLiveUpdates()
        XCTAssertTrue(store.liveTasks.isEmpty)
    }

    // MARK: Reading

    func testBodiesAreCachedPerMessageNotPerCopy() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let message = try XCTUnwrap(find(store, "Lease renewal")?.messages.first)
        XCTAssertNil(store.cachedBody(for: message))
        let body = try await store.body(for: message)
        XCTAssertEqual(body.messageID, message.id)
        XCTAssertTrue(body.plainText?.contains("Your lease on 4B") ?? false)
        XCTAssertEqual(store.cachedBody(for: message)?.plainText, body.plainText)
        var otherCopy = message
        otherCopy.mailboxPath = "Archive"
        otherCopy.uid = 9_999
        XCTAssertEqual(store.cachedBody(for: otherCopy)?.messageID, otherCopy.id)

        var ghost = message
        ghost.messageID = "missing@nowhere.example"
        ghost.uid = 77_777
        do {
            _ = try await store.body(for: ghost)
            XCTFail("expected messageNotFound")
        } catch let error as MailError {
            XCTAssertEqual(error, .messageNotFound)
        }
    }

    func testConversationLookupFindsThreadsOutsideTheCurrentList() async throws {
        let store = try await demoHarness().store
        store.scope = .unified(.trash)
        await store.waitUntilIdle()
        let trashed = try XCTUnwrap(store.conversations.first)
        store.scope = .allInboxes
        XCTAssertNotNil(store.conversation(id: trashed.id))
        let other = try XCTUnwrap(store.allConversations(for: .allInboxes).first { $0.isBulk })
        XCTAssertEqual(store.conversation(id: other.id)?.id, other.id, "Other while Focus is showing")
        XCTAssertNil(store.conversation(id: "no-such-thread"))
    }

    // MARK: Gmail

    func testGmailCopiesDedupeAndArchiveKeepsAllMail() async throws {
        let (account, folders) = gmailFixture()
        let priya = address("Priya Natarajan", "priya@fieldstone.example")
        let me = account.address
        func gmail(_ mailbox: String, uid: UInt32, msg: UInt64, thread: UInt64, subject: String, from: EmailAddress,
                   minutesAgo: Double, unread: Bool = false) -> MessageSummary {
            summary(account: account.id, mailbox: mailbox, uid: uid, messageID: "gm\(msg)@mail.gmail.example", gmailThread: thread,
                    gmailMessage: msg, subject: subject, from: from, to: [from == me ? priya : me],
                    date: referenceDate.addingTimeInterval(-minutesAgo * 60), flags: unread ? [] : [.seen])
        }
        let contents: [String: [MessageSummary]] = [
            "INBOX": [
                gmail("INBOX", uid: 10, msg: 1, thread: 100, subject: "Venue shortlist", from: priya, minutesAgo: 300),
                gmail("INBOX", uid: 11, msg: 3, thread: 100, subject: "Re: Venue shortlist", from: priya, minutesAgo: 60, unread: true),
            ],
            "[Gmail]/All Mail": [
                gmail("[Gmail]/All Mail", uid: 50, msg: 1, thread: 100, subject: "Venue shortlist", from: priya, minutesAgo: 300),
                gmail("[Gmail]/All Mail", uid: 51, msg: 2, thread: 100, subject: "Re: Venue shortlist", from: me, minutesAgo: 120),
                gmail("[Gmail]/All Mail", uid: 52, msg: 3, thread: 100, subject: "Re: Venue shortlist", from: priya, minutesAgo: 60, unread: true),
                gmail("[Gmail]/All Mail", uid: 40, msg: 4, thread: 200, subject: "Old receipts", from: priya, minutesAgo: 9_000),
            ],
            "[Gmail]/Sent Mail": [
                gmail("[Gmail]/Sent Mail", uid: 7, msg: 2, thread: 100, subject: "Re: Venue shortlist", from: me, minutesAgo: 120),
            ],
        ]
        let fake = FakeMailService(account: account, folders: folders, contents: contents)
        let harness = try makeHarness(services: [account.id: fake])
        let store = harness.store
        try await store.addAccount(account, credential: .oauth(OAuthToken(accessToken: "ya29.token", refreshToken: "1//refresh")))
        await store.waitUntilIdle()

        XCTAssertEqual(store.conversations.count, 1)
        let thread = try XCTUnwrap(store.conversations.first)
        XCTAssertEqual(thread.id, "\(account.id)|gm:100")
        XCTAssertEqual(thread.count, 3, "inbox + sent, one copy each")
        XCTAssertEqual(store.unreadCount(for: .allInboxes), 1)

        store.scope = .unified(.archive) // Gmail has no Archive: All Mail stands in
        await store.waitUntilIdle()
        XCTAssertEqual(store.conversations.count, 2)
        XCTAssertEqual(store.conversations.first { $0.id == thread.id }?.count, 3, "All Mail copies collapse with Inbox/Sent copies")
        XCTAssertEqual(store.unreadCount(for: .unified(.archive)), 1)

        store.scope = .allInboxes
        store.archive([thread])
        await store.flushPendingActions()
        let performed = await fake.performed
        XCTAssertEqual(performed.first?.action, .archive)
        XCTAssertEqual(performed.first?.ids.count, 2, "only the INBOX copies are archived")
        XCTAssertTrue(store.conversations.isEmpty)
        XCTAssertTrue(store.allConversations(for: .unified(.archive)).contains { $0.id == thread.id }, "still in All Mail")

        store.scope = .unified(.archive)
        let old = try XCTUnwrap(store.conversations.first { $0.subject == "Old receipts" })
        store.trash([old])
        XCTAssertFalse(store.conversations.contains { $0.id == old.id }, "Gmail Trash removes it from All Mail")
    }

    // MARK: Preview

    func testPreviewIsReadySynchronously() async {
        let store = MailStore.preview()
        XCTAssertEqual(store.accounts, [.demo])
        XCTAssertFalse(store.conversations.isEmpty)
        XCTAssertNotNil(store.lastSyncedAt)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertGreaterThan(store.otherCount, 0)
        let message = try? XCTUnwrap(store.conversations.first?.latest)
        XCTAssertNotNil(message.flatMap { store.cachedBody(for: $0) }, "bodies are there for the reader preview")
        XCTAssertFalse(store.mailboxes(for: "demo").isEmpty)
        store.scope = .unified(.trash)
        XCTAssertEqual(store.conversations.count, 3, "every folder is filled, no sync needed")
        store.scope = .allInboxes
        let first = store.conversations[0]
        store.archive([first])
        XCTAssertFalse(store.conversations.contains { $0.id == first.id })
        store.undo()
        XCTAssertTrue(store.conversations.contains { $0.id == first.id })
        XCTAssertFalse(store.contactSuggestions(matching: "").isEmpty)
    }

    /// The app's screenshot mode builds the store with `preview()` on launch and immediately
    /// picks a long thread, replies to it, searches "flight" and opens the Other pill.
    func testPreviewHasEverythingTheScreenshotsShow() async throws {
        let started = Date()
        let store = MailStore.preview()
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "preview() must not block launch")
        XCTAssertEqual(store.scope, .allInboxes)
        XCTAssertEqual(store.inboxFilter, .focused)

        // Focus: long threads, read and unread mail, a star, attachments.
        let focus = store.conversations
        XCTAssertGreaterThanOrEqual(focus.count, 10)
        let thread = try XCTUnwrap(focus.first { $0.count >= 3 }, "a thread with 3+ messages for the thread screenshot")
        XCTAssertGreaterThan(Set(thread.messages.compactMap { $0.sender?.normalized }).count, 1, "more than one person on the thread")
        XCTAssertTrue(focus.contains { $0.isUnread })
        XCTAssertTrue(focus.contains { !$0.isUnread })
        XCTAssertTrue(focus.contains { $0.isFlagged }, "a starred conversation")
        XCTAssertFalse(focus.contains { $0.isBulk }, "bulk mail stays in Other")
        XCTAssertEqual(focus.map(\.date), focus.map(\.date).sorted(by: >), "newest first")
        let withFiles = try XCTUnwrap(focus.first { $0.hasAttachments })
        let fileMessage = try XCTUnwrap(withFiles.messages.last { $0.hasAttachments })
        let fileBody = try XCTUnwrap(store.cachedBody(for: fileMessage))
        XCTAssertFalse(fileBody.visibleAttachments.isEmpty)
        XCTAssertTrue(fileBody.visibleAttachments.allSatisfy { ($0.data?.count ?? 0) > 0 }, "attachments open without a network")

        // Every message in the thread reads straight from memory.
        for message in thread.messages {
            let body = try XCTUnwrap(store.cachedBody(for: message), message.subject)
            XCTAssertTrue((body.plainText ?? body.html ?? "").count > 20, message.subject)
        }
        let latest = try XCTUnwrap(thread.latest)
        let draft = store.draft(replyingTo: latest, mode: .reply, body: store.cachedBody(for: latest))
        XCTAssertTrue(draft.subject.hasPrefix("Re: "), draft.subject)
        XCTAssertFalse(draft.to.isEmpty)
        XCTAssertNotNil(draft.inReplyTo)

        // Other: newsletters and notifications.
        XCTAssertGreaterThan(store.otherCount, 0)
        XCTAssertGreaterThan(store.otherUnreadCount, 0)
        store.inboxFilter = .other
        XCTAssertEqual(store.conversations.count, store.otherCount)
        XCTAssertTrue(store.conversations.allSatisfy(\.isBulk))
        store.inboxFilter = .focused

        // The other folders are filled too.
        let roles = Set(store.mailboxes(for: AccountConfig.demo.id).map(\.role))
        XCTAssertTrue(roles.isSuperset(of: [.inbox, .sent, .archive, .trash, .junk, .drafts]), "\(roles)")
        for role in [MailboxRole.sent, .archive, .junk] {
            store.scope = .unified(role)
            XCTAssertFalse(store.conversations.isEmpty, "\(role)")
        }
        store.scope = .allInboxes
        XCTAssertGreaterThan(store.unreadCount(for: .allInboxes), 0)

        // Search screenshot: "flight" finds something locally and on the demo "server".
        XCTAssertFalse(store.searchLocal("flight").isEmpty)
        let server = try await store.searchServer("flight")
        XCTAssertFalse(server.isEmpty)

        // Nothing is running in the background and nothing touched the disk.
        await store.waitUntilIdle()
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertFalse(FileManager.default.fileExists(atPath: store.environment.storageDirectory
            .appendingPathComponent("accounts.json").path))
    }
}

@MainActor
final class MailStoreEdgeCaseTests: XCTestCase {
    func testSyncThatStartedBeforeCommitCannotResurrect() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        store.undoWindow = 0
        let target = try XCTUnwrap(store.conversations.first)
        // A slow sync starts while the message is still on the server…
        await fake.delaySync(0.4)
        let slowRefresh = Task { await store.refresh() }
        try await Task.sleep(nanoseconds: 50_000_000)
        // …the archive commits and finishes while that sync is still out…
        store.archive([target])
        try await Task.sleep(nanoseconds: 100_000_000)
        let performed = await fake.performed.map(\.action)
        XCTAssertEqual(performed, [.archive])
        // …and its stale answer must not bring the message back.
        await slowRefresh.value
        await store.waitUntilIdle()
        XCTAssertFalse(store.conversations.contains { $0.id == target.id })
        await fake.delaySync(0)
        await store.refresh()
        XCTAssertFalse(store.conversations.contains { $0.id == target.id })
    }

    func testUndoGoesNewestFirstAcrossSendsAndActions() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        store.undoWindow = 30
        store.undoSendDelay = 30
        var message = store.newDraft()
        message.to = [address("Sam Chen", "sam.chen@mailbox.example")]
        store.send(message)
        let target = try XCTUnwrap(store.conversations.first)
        store.archive([target])
        store.undo()
        XCTAssertTrue(store.conversations.contains { $0.id == target.id }, "the archive came last, so it's undone first")
        XCTAssertEqual(store.outbox.count, 1)
        store.undo()
        XCTAssertTrue(store.outbox.isEmpty, "then the send")
        store.undo()
        XCTAssertTrue(store.outbox.isEmpty)
    }

    func testWakeFailureKeepsTheSnoozeForTheNextCheck() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(60))
        await store.flushPendingActions()
        await fake.failPerform(.connectionFailed("Offline."))
        harness.clock.advance(120)
        await store.wakeDueSnoozes()
        XCTAssertNotNil(store.snoozeDate(for: target), "still snoozed until the server can be reached")
        await fake.failPerform(nil)
        await store.wakeDueSnoozes()
        await store.waitUntilIdle()
        XCTAssertNil(store.snoozeDate(for: target))
        XCTAssertTrue(store.conversations.contains { conversation in
            conversation.messages.contains { $0.messageID == target.latest?.messageID } && conversation.isUnread
        })
    }

    func testSnoozedListIsSoonestFirst() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        let first = store.conversations[0]
        let second = store.conversations[1]
        store.snooze([first], until: harness.clock.now.addingTimeInterval(7 * 86_400))
        store.snooze([second], until: harness.clock.now.addingTimeInterval(3_600))
        XCTAssertEqual(store.snoozedConversations.map(\.id), [second.id, first.id])
        XCTAssertEqual(store.unreadCount(for: .unified(.snoozed)), [first, second].filter(\.isUnread).count)
        // Snoozing again just changes the time.
        store.snooze([first], until: harness.clock.now.addingTimeInterval(60))
        XCTAssertEqual(store.snoozedConversations.map(\.id), [first.id, second.id])
        store.undo()
        XCTAssertEqual(store.snoozeDate(for: first), harness.clock.now.addingTimeInterval(7 * 86_400))
        store.scope = .account(accountID: "demo", role: .snoozed)
        XCTAssertEqual(store.conversations.count, 2)
        store.archive([store.conversations[0]])
        XCTAssertEqual(store.snoozedConversations.count, 1, "archiving from Snoozed cancels the snooze")
    }

    func testAddAccountFailsCleanlyWhenTheCredentialCantBeSaved() async throws {
        let (account, fake) = fastmailFixture()
        let directory = try makeTemporaryDirectory()
        let environment = MailStoreEnvironment(storageDirectory: directory, credentials: FailingCredentialStore(), transportFactory: nil,
                                               now: { referenceDate })
        let store = MailStore(environment: environment) { _, _ in fake }
        do {
            try await store.addAccount(account, credential: .password("pw"))
            XCTFail("expected the keychain error")
        } catch let error as MailError {
            XCTAssertEqual(error, .serverError("The keychain is locked."))
        }
        XCTAssertTrue(store.accounts.isEmpty, "nothing half-added")
    }

    func testBodyFallsBackToAnotherCopyWhenTheUIDIsGone() async throws {
        let harness = try await demoHarness()
        let store = harness.store
        store.scope = .unified(.archive)
        await store.waitUntilIdle()
        let archived = try XCTUnwrap(store.conversations.first?.latest)
        var stale = archived
        stale.mailboxPath = "INBOX"
        stale.uid = 4_000
        stale.messageID = nil // not findable by Message-ID either
        let body = try await store.body(for: MessageSummary(
            accountID: stale.accountID, mailboxPath: "INBOX", uid: 4_000, uidValidity: stale.uidValidity,
            messageID: archived.messageID, subject: stale.subject, from: stale.from, date: stale.date))
        XCTAssertNotNil(body.plainText)
    }

    func testTitlesForTwoAccountsOnTheSameProvider() async throws {
        let (first, firstFake) = fastmailFixture(id: "fm-a", email: "alex@fastmail.example")
        let (second, secondFake) = fastmailFixture(id: "fm-b", email: "rivera@fastmail.example")
        let harness = try makeHarness(services: [first.id: firstFake, second.id: secondFake])
        try await harness.store.addAccount(first, credential: .password("a"))
        try await harness.store.addAccount(second, credential: .password("b"))
        await harness.store.waitUntilIdle()
        XCTAssertEqual(harness.store.title(for: .account(accountID: "fm-b", role: .trash)), "rivera@fastmail.example · Trash")
        XCTAssertEqual(harness.store.title(for: .mailbox(accountID: "fm-a", path: "Projects")), "alex@fastmail.example · Projects")
        XCTAssertEqual(harness.store.title(for: .mailbox(accountID: "fm-a", path: "Gone/Folder")), "alex@fastmail.example · Folder")
        XCTAssertEqual(harness.store.mailboxes(for: "fm-a").map(\.role), [.inbox, .sent, .archive, .junk, .trash, .custom], "well-known roles first")
    }

    func testInboxMailboxScopeGetsFocusSplitAndSyncsSent() async throws {
        let store = try await demoHarness().store
        store.scope = .mailbox(accountID: "demo", path: "INBOX")
        XCTAssertGreaterThan(store.otherCount, 0)
        XCTAssertTrue(store.conversations.allSatisfy { !$0.isBulk })
        XCTAssertEqual(store.title(for: store.scope), "Inbox")
    }

    func testRemovingAnAccountWithPendingWorkIsSafe() async throws {
        let (harness, account, fake) = try await fakeHarness()
        let store = harness.store
        store.undoWindow = 30
        store.undoSendDelay = 30
        store.inboxFilter = .everything
        store.archive([store.conversations[0]])
        store.snooze([store.conversations[0]], until: harness.clock.now.addingTimeInterval(3_600))
        var message = store.newDraft(accountID: account.id)
        message.to = [address("Dev", "dev@thebuildlog.example")]
        store.send(message)
        await store.removeAccount(id: account.id)
        await store.flushPendingActions()
        XCTAssertTrue(store.outbox.isEmpty)
        XCTAssertTrue(store.snoozedConversations.isEmpty)
        let sent = await fake.sent
        XCTAssertTrue(sent.isEmpty, "nothing goes out for a removed account")
        store.undo()
        XCTAssertTrue(store.conversations.isEmpty)
    }
}
