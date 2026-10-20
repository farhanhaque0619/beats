import XCTest
import InkModel
import InkMIME
@testable import InkSync

/// The whole stack against real servers (see IMAPMailServiceIntegrationTests.swift for how to
/// start them): a `MailStore` built the way the app builds it, through the public initializer
/// with a transport factory, so accounts get the default `IMAPMailService`, real SMTP and the
/// on-disk cache. Driven the way the UI drives it. Skipped without the INK_IT_* variables.
@MainActor
final class MailStoreIntegrationTests: XCTestCase {
    typealias Server = IMAPServiceITServer

    func testMailStoreEndToEndGreenMail() async throws { try await scenario(try require(Server.greenMail())) }
    func testMailStoreEndToEndDovecot() async throws { try await scenario(try require(Server.dovecot())) }

    private func require(_ server: Server?) throws -> Server {
        guard let server else { throw XCTSkip("Integration servers not configured (INK_IT_* environment variables).") }
        return server
    }

    /// Polls until `condition` holds, failing the test (and stopping the scenario) after `timeout`.
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

    /// What the server holds in `role` for `account`, seen by a separate connection.
    private func onServer(_ observer: IMAPMailService, _ role: MailboxRole) async throws -> [MessageSummary] {
        guard let box = try await observer.mailboxes().first(where: { $0.role == role }) else { return [] }
        return try await observer.sync(mailbox: box, previous: nil, limit: 50).upserted
    }

    private func scenario(_ server: Server) async throws {
        let id = String(UUID().uuidString.prefix(8)).lowercased()
        let ada = server.account("ada-\(id)"), bob = server.account("bob-\(id)")
        let adaService = server.service(ada)
        let observer = server.service(bob)
        let subject = "Lunch plan \(id)"

        // Ada writes first; wait for delivery so the first sync sees it.
        try await adaService.send(OutgoingMessage(accountID: ada.id, from: ada.address, to: [bob.address], subject: subject,
                                                  body: "Shall we try the new ramen place on Thursday?\n\nAda"))
        try await eventually("delivery to Bob") { try await !self.onServer(observer, .inbox).isEmpty }

        let directory = try makeTemporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let credentials = InMemoryCredentialStore()
        let environment = MailStoreEnvironment(storageDirectory: directory, credentials: credentials,
                                               transportFactory: { SocketTransport() })
        let store = MailStore(environment: environment)
        store.undoWindow = 0
        store.undoSendDelay = 0
        await store.load()
        XCTAssertFalse(store.hasAccounts)

        // Onboarding: check the details, then add the account.
        let steps = IMAPServiceSteps()
        try await store.verify(bob, credential: .password(server.password)) { steps.append($0) }
        XCTAssertEqual(steps.steps.last, .done)
        try await store.addAccount(bob, credential: .password(server.password))
        await store.waitUntilIdle()
        XCTAssertEqual(store.accounts.map(\.id), [bob.id])
        XCTAssertNotNil(store.lastSyncedAt)
        XCTAssertEqual(store.syncStatus, .idle)
        XCTAssertTrue(store.mailboxes(for: bob.id).contains { $0.role == .inbox })
        let hadSent = store.mailboxes(for: bob.id).contains { $0.role == .sent }
        let lunch = try XCTUnwrap(store.conversations.first { $0.subject == subject }, store.conversations.map(\.subject).description)
        XCTAssertTrue(lunch.isUnread)
        XCTAssertEqual(lunch.latest?.from.first?.address, ada.emailAddress)
        XCTAssertEqual(lunch.snippet, "Shall we try the new ramen place on Thursday? Ada")
        XCTAssertEqual(store.unreadCount(for: .allInboxes), 1)

        // Reading: the body comes from the server; opening it marks it read there too.
        let first = try XCTUnwrap(lunch.latest)
        let body = try await store.body(for: first)
        XCTAssertTrue(body.plainText?.contains("ramen place") ?? false, body.plainText ?? "nil")
        XCTAssertNotNil(store.cachedBody(for: first))
        store.markOpened(lunch)
        XCTAssertEqual(store.conversation(id: lunch.id)?.isUnread, false)
        await store.waitUntilIdle()
        try await eventually("\\Seen on the server") {
            try await self.onServer(observer, .inbox).first { $0.subject == subject }?.isUnread == false
        }

        // Replying from the store: Ada gets it, and the Sent copy joins the thread.
        var reply = store.draft(replyingTo: first, mode: .reply, body: body)
        XCTAssertEqual(reply.to.map(\.address), [ada.emailAddress])
        XCTAssertEqual(reply.subject, "Re: \(subject)")
        reply.body = "Thursday works. 12:30?\n\nBob" + reply.body
        store.send(reply)
        try await eventually("the outbox empties") { store.outbox.isEmpty }
        await store.waitUntilIdle()
        XCTAssertTrue(store.failedSendIDs.isEmpty)
        XCTAssertEqual(store.toast?.message, "Sent")
        // GreenMail starts without Sent: the service created it for the copy, and the store found it.
        XCTAssertTrue(store.mailboxes(for: bob.id).contains { $0.role == .sent }, "Sent listed (was there before: \(hadSent))")
        let twoMessages = try XCTUnwrap(store.conversations.first { $0.subject == subject })
        XCTAssertEqual(twoMessages.count, 2, "the reply shows in its thread")

        let adaObserver = server.service(ada)
        var adaCopy: MessageSummary?
        try await eventually("Bob's reply reaches Ada") {
            adaCopy = try await self.onServer(adaObserver, .inbox).first { $0.subject == "Re: \(subject)" }
            return adaCopy != nil
        }
        XCTAssertEqual(adaCopy?.inReplyTo, first.messageID.map { [$0] })

        // Ada answers (a moment later: Date headers count whole seconds); a refresh brings the
        // third message into the same conversation.
        try await Task.sleep(nanoseconds: 1_100_000_000)
        var answer = ReplyBuilder.draft(replyingTo: try XCTUnwrap(adaCopy), body: nil, mode: .reply, from: ada,
                                        myAddresses: [ada.emailAddress])
        answer.body = "12:30 it is."
        try await adaService.send(answer)
        try await eventually("Ada's answer threads in") {
            await store.refresh()
            return store.conversations.first { $0.subject == subject }?.count == 3
        }
        let thread = try XCTUnwrap(store.conversations.first { $0.subject == subject })
        XCTAssertEqual(thread.messages.compactMap { $0.sender?.normalized }, [ada.emailAddress, bob.emailAddress, ada.emailAddress])
        XCTAssertTrue(thread.isUnread)
        XCTAssertEqual(store.unreadCount(for: .allInboxes), 1)

        // A cold launch from the same folder shows the cached thread before any network work.
        await store.flushPendingActions()
        let relaunched = MailStore(environment: MailStoreEnvironment(storageDirectory: directory, credentials: credentials,
                                                                     transportFactory: nil))
        await relaunched.load()
        XCTAssertEqual(relaunched.accounts.map(\.id), [bob.id])
        XCTAssertEqual(relaunched.conversations.first { $0.subject == subject }?.count, 3)
        await relaunched.waitUntilIdle()

        // Star, archive, back to the inbox, trash: each change lands on the server.
        store.setFlagged(true, [thread])
        XCTAssertEqual(store.conversation(id: thread.id)?.isFlagged, true)
        await store.waitUntilIdle()
        try await eventually("\\Flagged on the server") {
            try await self.onServer(observer, .inbox).contains { $0.isFlagged && $0.normalizedSubject == subject }
        }

        store.archive([thread])
        XCTAssertFalse(store.conversations.contains { $0.subject == subject }, "the list closes up right away")
        await store.waitUntilIdle()
        try await eventually("archived on the server") {
            let inbox = try await self.onServer(observer, .inbox)
            let archive = try await self.onServer(observer, .archive)
            return !inbox.contains { $0.normalizedSubject == subject } && archive.filter { $0.normalizedSubject == subject }.count == 2
        }

        store.scope = .unified(.archive)
        try await eventually("the store lists Archive") {
            await store.refresh()
            return store.conversations.contains { $0.subject == subject }
        }
        let archived = try XCTUnwrap(store.conversations.first { $0.subject == subject })
        store.moveToInbox([archived])
        await store.waitUntilIdle()
        try await eventually("back in the inbox on the server") {
            try await self.onServer(observer, .inbox).filter { $0.normalizedSubject == subject }.count == 2
        }

        store.scope = .allInboxes
        try await eventually("the store shows it in the inbox again") {
            await store.refresh()
            return store.conversations.contains { $0.subject == subject }
        }
        let back = try XCTUnwrap(store.conversations.first { $0.subject == subject })
        store.trash([back])
        XCTAssertFalse(store.conversations.contains { $0.subject == subject })
        await store.waitUntilIdle()
        try await eventually("in Trash on the server") {
            let inbox = try await self.onServer(observer, .inbox)
            let trash = try await self.onServer(observer, .trash)
            return !inbox.contains { $0.normalizedSubject == subject } && trash.filter { $0.normalizedSubject == subject }.count == 2
        }
        XCTAssertNotEqual(store.toast?.style, .error, store.toast?.message ?? "")

        // Removing the account deletes its credential and cached mail.
        await store.removeAccount(id: bob.id)
        XCTAssertFalse(store.hasAccounts)
        XCTAssertTrue(store.conversations.isEmpty)
        await store.flushPendingActions()
        let saved = try? await credentials.credential(for: bob)
        XCTAssertNil(saved)
        let cacheFolder = directory.appendingPathComponent("cache", isDirectory: true)
            .appendingPathComponent(MailCache.safeComponent(bob.id), isDirectory: true)
        XCTAssertFalse(FileManager.default.fileExists(atPath: cacheFolder.path), cacheFolder.path)

        await adaService.disconnect()
        await adaObserver.disconnect()
        await observer.disconnect()
    }
}
