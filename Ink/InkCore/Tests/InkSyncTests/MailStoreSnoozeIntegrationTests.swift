import XCTest
import InkModel
@testable import InkSync

/// Snoozed mail and triage that outlives the app, against real servers (skipped without the
/// INK_IT_* variables; see IMAPMailServiceIntegrationTests.swift). A `MailStore` with the default
/// `IMAPMailService`, real SMTP and the on-disk cache, and a clock the test moves forward.
@MainActor
final class MailStoreSnoozeIntegrationTests: XCTestCase {
    typealias Server = IMAPServiceITServer

    func testSnoozedTriageGreenMail() async throws { try await scenario(try require(Server.greenMail())) }
    func testSnoozedTriageDovecot() async throws { try await scenario(try require(Server.dovecot())) }

    private func require(_ server: Server?) throws -> Server {
        guard let server else { throw XCTSkip("Integration servers not configured (INK_IT_* environment variables).") }
        return server
    }

    private func eventually(_ what: String, timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
                            _ condition: @MainActor () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        XCTFail("\(what): not within \(timeout)s", file: file, line: line)
        throw XCTSkip("giving up on this scenario")
    }

    private func onServer(_ observer: IMAPMailService, _ role: MailboxRole) async throws -> [MessageSummary] {
        guard let box = try await observer.mailboxes().first(where: { $0.role == role }) else { return [] }
        return try await observer.sync(mailbox: box, previous: nil, limit: 50).upserted
    }

    private func scenario(_ server: Server) async throws {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let ada = server.account("ada-\(id)"), bob = server.account("bob-\(id)")
        let adaService = server.service(ada)
        let observer = server.service(bob)
        let subjects = ["Trash me later \(id)", "Star me later \(id)", "Archive then quit \(id)"]
        for subject in subjects {
            try await adaService.send(OutgoingMessage(accountID: ada.id, from: ada.address, to: [bob.address], subject: subject,
                                                      body: "About \(subject).\n\nAda"))
        }
        try await eventually("delivery to Bob") { try await self.onServer(observer, .inbox).count == subjects.count }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let clock = TestClock(Date())
        let credentials = InMemoryCredentialStore()
        let environment = MailStoreEnvironment(storageDirectory: directory, credentials: credentials,
                                               transportFactory: { SocketTransport() }, now: clock.function)
        let store = MailStore(environment: environment)
        store.undoWindow = 0
        store.undoSendDelay = 0
        await store.load()
        try await store.addAccount(bob, credential: .password(server.password))
        await store.waitUntilIdle()
        store.inboxFilter = .everything
        func shown(_ subject: String) -> Conversation? { store.conversations.first { $0.subject == subject } }
        let trashLater = try XCTUnwrap(shown(subjects[0]), store.conversations.map(\.subject).description)
        let starLater = try XCTUnwrap(shown(subjects[1]))

        // Snoozed: archived on the server (the service creates Archive where there's none).
        store.snooze([trashLater, starLater], until: clock.now.addingTimeInterval(3_600))
        await store.flushPendingActions()
        await store.waitUntilIdle()
        try await eventually("snoozed mail archived on the server") {
            try await self.onServer(observer, .archive).filter { $0.subject == subjects[0] || $0.subject == subjects[1] }.count == 2
        }

        // From the Snoozed list, with Archive never synced: trash one, star the other.
        store.scope = .unified(.snoozed)
        let snoozedTrash = try XCTUnwrap(store.conversations.first { $0.id == trashLater.id })
        store.trash([snoozedTrash])
        let snoozedStar = try XCTUnwrap(store.conversations.first { $0.id == starLater.id })
        store.setFlagged(true, [snoozedStar])
        await store.flushPendingActions()
        await store.waitUntilIdle()
        XCTAssertNotEqual(store.toast?.style, .error, store.toast?.message ?? "")
        try await eventually("trashed from Snoozed, starred while snoozed") {
            let trash = try await self.onServer(observer, .trash)
            let archive = try await self.onServer(observer, .archive)
            return trash.contains { $0.subject == subjects[0] } && !archive.contains { $0.subject == subjects[0] }
                && archive.first { $0.subject == subjects[1] }?.isFlagged == true
        }
        XCTAssertEqual(store.snoozedConversations.map(\.id), [starLater.id])

        // Time's up: back in the inbox, unread and still starred.
        clock.advance(7_200)
        await store.wakeDueSnoozes()
        await store.waitUntilIdle()
        store.scope = .allInboxes
        let woken = try XCTUnwrap(shown(subjects[1]), store.conversations.map(\.subject).description)
        XCTAssertTrue(woken.isUnread)
        XCTAssertTrue(woken.isFlagged)
        try await eventually("woken on the server") {
            let inbox = try await self.onServer(observer, .inbox)
            return inbox.first { $0.subject == subjects[1] }.map { $0.isUnread && $0.isFlagged } == true
        }

        // Archived, then the app quits inside the undo window: the next launch sends it.
        store.undoWindow = 600
        let quitter = try XCTUnwrap(shown(subjects[2]))
        store.archive([quitter])
        await store.cache?.flush()
        let relaunched = MailStore(environment: environment)
        relaunched.undoWindow = 0
        await relaunched.load()
        relaunched.inboxFilter = .everything
        XCTAssertFalse(relaunched.conversations.contains { $0.subject == subjects[2] })
        await relaunched.waitUntilIdle()
        try await eventually("the archive reached the server after the relaunch") {
            let inbox = try await self.onServer(observer, .inbox)
            let archive = try await self.onServer(observer, .archive)
            return !inbox.contains { $0.subject == subjects[2] } && archive.contains { $0.subject == subjects[2] }
        }
        XCTAssertFalse(relaunched.conversations.contains { $0.subject == subjects[2] })
        XCTAssertNotEqual(relaunched.toast?.style, .error, relaunched.toast?.message ?? "")

        await relaunched.removeAccount(id: bob.id)
        await relaunched.flushPendingActions()
        await adaService.disconnect()
        await observer.disconnect()
    }
}
