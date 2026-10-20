import XCTest
import InkModel
import InkIMAP
import InkSMTP
@testable import InkSync

// Integration tests against real servers. Plain `swift test` skips them; to run them, start the
// servers and pass the INK_IT_* variables into the test process (or the swift container, which
// must use --network host):
//
//   # GreenMail 2.1: SMTP 3025, IMAP 3143, any user/password (users are created on first use)
//   docker run -d --name ink-greenmail -p 3025:3025 -p 3143:3143 \
//     -e GREENMAIL_OPTS='-Dgreenmail.setup.test.all -Dgreenmail.hostname=0.0.0.0 -Dgreenmail.auth.disabled' \
//     greenmail/standalone:2.1.0
//
//   # Dovecot 2.4 (IMAP 31143, submission 31587, LMTP 31025; any user, password "pass") with this
//   # conf.d/ink.conf mounted:  listen = *  /  auth_allow_cleartext = yes  /
//   #   service lmtp { inet_listener lmtp { port = 31025 } }  /
//   #   namespace inbox { mailbox Drafts|Sent|Junk|Trash { auto = subscribe } }  /
//   #   submission_relay_host = 127.0.0.1, submission_relay_port = 587, submission_relay_trusted = yes,
//   #   submission_relay_ssl = no
//   docker run -d --name ink-dovecot --network host -e USER_PASSWORD=pass \
//     -v $PWD/ink.conf:/etc/dovecot/conf.d/ink.conf:ro dovecot/dovecot:latest
//
//   # Postfix relays submitted mail back into Dovecot over LMTP (example.org / example.com).
//   docker run -d --name ink-postfix --network host -e ALLOWED_SENDER_DOMAINS="example.org example.com" \
//     -e POSTFIX_inet_interfaces=127.0.0.1 -e "POSTFIX_virtual_mailbox_domains=example.org example.com" \
//     -e POSTFIX_virtual_transport=lmtp:inet:127.0.0.1:31025 -e POSTFIX_smtpd_reject_unlisted_recipient=no \
//     -e "POSTFIX_smtpd_recipient_restrictions=permit_mynetworks,reject" -e "POSTFIX_mydestination=" boky/postfix
//
//   INK_IT_HOST=127.0.0.1 INK_IT_GREENMAIL_IMAP_PORT=3143 INK_IT_GREENMAIL_SMTP_PORT=3025 \
//   INK_IT_DOVECOT_IMAP_PORT=31143 INK_IT_DOVECOT_SMTP_PORT=31587 INK_IT_DOVECOT_PASSWORD=pass \
//   swift test --filter IMAPMailServiceIntegrationTests

/// A real mail server for the integration tests, configured through environment variables
/// (see above). Without them every integration test is skipped.
struct IMAPServiceITServer: Sendable {
    let name: String
    let host: String
    let imapPort: Int
    let smtpPort: Int
    let password: String
    let domain: String
    /// The server checks passwords (GreenMail here runs with authentication disabled).
    let checksPasswords: Bool

    static func greenMail() -> IMAPServiceITServer? {
        let env = ProcessInfo.processInfo.environment
        guard let imap = env["INK_IT_GREENMAIL_IMAP_PORT"].flatMap(Int.init),
              let smtp = env["INK_IT_GREENMAIL_SMTP_PORT"].flatMap(Int.init) else { return nil }
        return IMAPServiceITServer(name: "GreenMail", host: env["INK_IT_HOST"] ?? "127.0.0.1", imapPort: imap, smtpPort: smtp,
                                   password: "secret", domain: "example.com", checksPasswords: false)
    }

    static func dovecot() -> IMAPServiceITServer? {
        let env = ProcessInfo.processInfo.environment
        guard let imap = env["INK_IT_DOVECOT_IMAP_PORT"].flatMap(Int.init),
              let smtp = env["INK_IT_DOVECOT_SMTP_PORT"].flatMap(Int.init) else { return nil }
        return IMAPServiceITServer(name: "Dovecot", host: env["INK_IT_HOST"] ?? "127.0.0.1", imapPort: imap, smtpPort: smtp,
                                   password: env["INK_IT_DOVECOT_PASSWORD"] ?? "pass", domain: "example.org", checksPasswords: true)
    }

    func account(_ local: String) -> AccountConfig {
        let email = "\(local)@\(domain)"
        let name = local.split(separator: "-").first.map { $0.prefix(1).uppercased() + $0.dropFirst() } ?? local
        return AccountConfig(id: "it-\(local)", provider: .other, displayName: "\(name) Tester", emailAddress: email,
                             imap: ServerConfig(host: host, port: imapPort, security: .none, username: email),
                             smtp: ServerConfig(host: host, port: smtpPort, security: .none, username: email))
    }

    static let options = IMAPMailService.Options(timeout: 15, reconnectDelays: [0.2, 0.5], maxWatchFailures: 3, clientID: ["name": "Ink tests"])

    func service(_ account: AccountConfig, password: String? = nil, log: IMAPServiceLog? = nil) -> IMAPMailService {
        let credentials = InMemoryCredentialStore([account.id: .password(password ?? self.password)])
        return IMAPMailService(account: account, credentials: credentials, transportFactory: { SocketTransport() },
                               options: Self.options, logger: log?.logger)
    }

    /// A signed-in IMAP client for setting up fixtures directly.
    func client(_ account: AccountConfig) async throws -> IMAPClient {
        let client = IMAPClient(host: host, port: imapPort, security: .none, transport: SocketTransport(), timeout: 15)
        try await client.connect()
        try await client.login(username: account.emailAddress, password: password)
        return client
    }

    /// Runs raw IMAP commands (for things IMAPClient deliberately doesn't offer, like DELETE).
    func raw(_ account: AccountConfig, _ commands: [String]) async throws -> String {
        let transport = SocketTransport()
        try await transport.open(host: host, port: imapPort, tls: false, timeout: 10)
        defer { transport.close() }
        var transcript = ""
        func readUntil(_ tag: String?) async throws {
            var buffer = ""
            while true {
                buffer += String(decoding: try await transport.read(timeout: 10), as: UTF8.self)
                if tag == nil, buffer.contains("\r\n") { break }
                if let tag, buffer.contains("\r\n\(tag) ") || buffer.hasPrefix("\(tag) "), buffer.hasSuffix("\r\n") { break }
            }
            transcript += buffer
        }
        try await readUntil(nil)
        let all = ["LOGIN \"\(account.emailAddress)\" \"\(password)\""] + commands + ["LOGOUT"]
        for (index, command) in all.enumerated() {
            let tag = "r\(index)"
            try await transport.write(Data("\(tag) \(command)\r\n".utf8))
            try await readUntil(tag)
        }
        return transcript
    }
}

/// End-to-end scenarios against real IMAP/SMTP servers (GreenMail and Dovecot) over plain TCP.
final class IMAPMailServiceIntegrationTests: XCTestCase {
    typealias Server = IMAPServiceITServer

    private func require(_ server: Server?) throws -> Server {
        guard let server else { throw XCTSkip("Integration servers not configured (INK_IT_* environment variables).") }
        return server
    }

    /// A short unique suffix so every test gets fresh mailboxes.
    private func uniqueID() -> String { String(UUID().uuidString.prefix(8)).lowercased() }

    /// Polls `condition` until it is true or `timeout` passes.
    private func waitUntil(timeout: TimeInterval = 20, file: StaticString = #filePath, line: UInt = #line,
                           _ condition: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await condition() { return }
            try await Task.sleep(nanoseconds: 300_000_000)
        }
        XCTFail("condition not met within \(timeout)s", file: file, line: line)
        throw XCTSkip("giving up on this scenario")
    }

    private func inbox(_ service: IMAPMailService) async throws -> MailboxInfo {
        let found = try await service.mailboxes().first { $0.role == .inbox }
        return try XCTUnwrap(found)
    }

    private func mailbox(_ service: IMAPMailService, role: MailboxRole) async throws -> MailboxInfo {
        let found = try await service.mailboxes().first { $0.role == role }
        return try XCTUnwrap(found, "no \(role) folder")
    }

    /// Sends a plain message from `from` to `to` through the service.
    private func deliver(_ sender: IMAPMailService, from: AccountConfig, to: [AccountConfig], subject: String, body: String,
                         attachments: [OutgoingAttachment] = [], bcc: [EmailAddress] = []) async throws {
        let message = OutgoingMessage(accountID: from.id, from: from.address, to: to.map(\.address), bcc: bcc, subject: subject,
                                      body: body, attachments: attachments)
        try await sender.send(message)
    }

    /// Syncs from scratch until `count` messages are there.
    private func syncUntil(_ service: IMAPMailService, _ mailbox: MailboxInfo, count: Int, limit: Int = 50) async throws -> MailboxSyncResult {
        var result: MailboxSyncResult?
        try await waitUntil {
            result = try await service.sync(mailbox: mailbox, previous: nil, limit: limit)
            return (result?.upserted.count ?? 0) >= count
        }
        return try XCTUnwrap(result)
    }

    private func appendMessage(_ client: IMAPClient, to rawPath: String, subject: String, from: String = "Grace Hopper <grace@example.net>",
                               to recipient: String, body: String, messageID: String = "\(UUID().uuidString)@example.net") async throws {
        let text = "From: \(from)\r\nTo: \(recipient)\r\nSubject: \(subject)\r\nDate: \(RFC5322DateLike.now())\r\nMessage-ID: <\(messageID)>\r\n"
            + "MIME-Version: 1.0\r\nContent-Type: text/plain; charset=utf-8\r\n\r\n\(body)\r\n"
        _ = try await client.append(to: rawPath, message: Data(text.utf8))
    }

    // MARK: - verify

    func testVerifyGreenMail() async throws { try await scenarioVerify(try require(Server.greenMail())) }
    func testVerifyDovecot() async throws { try await scenarioVerify(try require(Server.dovecot())) }

    private func scenarioVerify(_ server: Server) async throws {
        let ada = server.account("ada-\(uniqueID())")
        let steps = IMAPServiceSteps()
        try await server.service(ada).verify { steps.append($0) }
        XCTAssertEqual(steps.steps, [.connectingIMAP, .signingInIMAP, .loadingMailboxes, .connectingSMTP, .signingInSMTP, .done])
        if server.checksPasswords {
            let failed = IMAPServiceSteps()
            await assertIMAPServiceThrows(where: { if case .authenticationFailed = $0 { return true } else { return false } }) {
                try await server.service(ada, password: "wrong").verify { failed.append($0) }
            }
            XCTAssertEqual(failed.steps, [.connectingIMAP, .signingInIMAP])
        }
        // Nothing listening there.
        var nowhere = ada
        nowhere.imap.port = 1
        await assertIMAPServiceThrows(where: { if case .connectionFailed = $0 { return true } else { return false } }) {
            try await server.service(nowhere).verify { _ in }
        }
    }

    // MARK: - send, sync, read

    func testSendSyncAndReadGreenMail() async throws { try await scenarioSendSyncAndRead(try require(Server.greenMail())) }
    func testSendSyncAndReadDovecot() async throws { try await scenarioSendSyncAndRead(try require(Server.dovecot())) }

    private func scenarioSendSyncAndRead(_ server: Server) async throws {
        let id = uniqueID()
        let ada = server.account("ada-\(id)"), bob = server.account("bob-\(id)"), carol = server.account("carol-\(id)")
        let adaService = server.service(ada), bobService = server.service(bob), carolService = server.service(carol)
        let started = Date()
        let csv = Data("region,total\nnorth,42\nsouth,17\n".utf8)
        let subject = "Quarterly report — draft \(id)"
        try await deliver(adaService, from: ada, to: [bob], subject: subject,
                          body: "Hi Bob,\n\nHere is the draft of the quarterly report. Numbers are in the CSV.\n\nAda",
                          attachments: [OutgoingAttachment(filename: "report.csv", mimeType: "text/csv", data: csv)],
                          bcc: [carol.address])

        let bobInbox = try await inbox(bobService)
        let result = try await syncUntil(bobService, bobInbox, count: 1)
        XCTAssertTrue(result.didReset)
        let summary = try XCTUnwrap(result.upserted.first)
        XCTAssertEqual(summary.subject, subject)
        XCTAssertEqual(summary.from.first?.address, ada.emailAddress)
        XCTAssertEqual(summary.from.first?.name, "Ada Tester")
        XCTAssertEqual(summary.to.map(\.address), [bob.emailAddress])
        XCTAssertTrue(summary.bcc.isEmpty, "Bcc never travels in the sent message")
        XCTAssertLessThan(abs(summary.date.timeIntervalSince(started)), 300)
        XCTAssertLessThan(abs(summary.receivedDate.timeIntervalSince(started)), 300)
        XCTAssertTrue(summary.snippet.hasPrefix("Hi Bob, Here is the draft of the quarterly report."), summary.snippet)
        XCTAssertTrue(summary.isUnread)
        XCTAssertTrue(summary.hasAttachments)
        XCTAssertFalse(summary.isBulk)
        XCTAssertNotNil(summary.messageID)
        XCTAssertGreaterThan(summary.size, 500)
        XCTAssertEqual(result.state.knownUIDs, [summary.uid])
        XCTAssertGreaterThan(result.state.uidNext, summary.uid)

        let body = try await bobService.body(for: summary)
        XCTAssertEqual(body.messageID, summary.id)
        XCTAssertTrue(body.plainText?.contains("Here is the draft of the quarterly report.") ?? false, body.plainText ?? "nil")
        XCTAssertTrue(body.html?.contains("quarterly report") ?? false)
        XCTAssertEqual(body.attachments.count, 1)
        XCTAssertEqual(body.attachments.first?.filename, "report.csv")
        XCTAssertEqual(body.attachments.first?.data, csv)

        // Reading the body didn't mark it read (BODY.PEEK).
        let again = try await bobService.sync(mailbox: bobInbox, previous: result.state, limit: 50)
        XCTAssertTrue(again.upserted.isEmpty)
        XCTAssertTrue(again.removedIDs.isEmpty)

        // The blind copy arrived, without revealing itself.
        let carolResult = try await syncUntil(carolService, try await inbox(carolService), count: 1)
        XCTAssertEqual(carolResult.upserted.first?.subject, subject)
        XCTAssertTrue(carolResult.upserted.first?.bcc.isEmpty ?? false)

        // Ada's Sent copy: \Seen, with the Bcc recorded.
        let sent = try await mailbox(adaService, role: .sent)
        let sentResult = try await syncUntil(adaService, sent, count: 1)
        let sentCopy = try XCTUnwrap(sentResult.upserted.first)
        XCTAssertEqual(sentCopy.subject, subject)
        XCTAssertFalse(sentCopy.isUnread)
        XCTAssertEqual(sentCopy.bcc.map(\.address), [carol.emailAddress])
        XCTAssertEqual(sentCopy.messageID, summary.messageID)
    }

    // MARK: - flags and incremental sync

    func testFlagsAndIncrementalSyncGreenMail() async throws { try await scenarioFlagsAndIncremental(try require(Server.greenMail())) }
    func testFlagsAndIncrementalSyncDovecot() async throws { try await scenarioFlagsAndIncremental(try require(Server.dovecot())) }

    private func scenarioFlagsAndIncremental(_ server: Server) async throws {
        let id = uniqueID()
        let ada = server.account("ada-\(id)"), bob = server.account("bob-\(id)")
        let adaService = server.service(ada), bobService = server.service(bob)
        for n in 1...3 {
            try await deliver(adaService, from: ada, to: [bob], subject: "Incremental \(n) \(id)", body: "Message number \(n).")
        }
        let inboxBox = try await inbox(bobService)
        let first = try await syncUntil(bobService, inboxBox, count: 3)
        let bySubject = Dictionary(uniqueKeysWithValues: first.upserted.map { ($0.subject, $0) })
        let one = try XCTUnwrap(bySubject["Incremental 1 \(id)"])
        let two = try XCTUnwrap(bySubject["Incremental 2 \(id)"])
        let three = try XCTUnwrap(bySubject["Incremental 3 \(id)"])

        try await bobService.perform(.markRead, on: [one])
        try await bobService.perform(.flag, on: [two])
        let second = try await bobService.sync(mailbox: inboxBox, previous: first.state, limit: 50)
        XCTAssertFalse(second.didReset)
        XCTAssertTrue(second.removedIDs.isEmpty)
        let changed = Dictionary(uniqueKeysWithValues: second.upserted.map { ($0.uid, $0) })
        // This service remembers what it reported, and it changed these flags itself: the
        // caller already knows, so they may or may not be repeated. A second client's view must match.
        let otherClient = server.service(bob)
        let fresh = try await otherClient.sync(mailbox: inboxBox, previous: first.state, limit: 50)
        let freshByUID = Dictionary(uniqueKeysWithValues: fresh.upserted.map { ($0.uid, $0) })
        XCTAssertEqual(freshByUID[one.uid]?.flags.contains(.seen), true)
        XCTAssertEqual(freshByUID[two.uid]?.flags.contains(.flagged), true)
        XCTAssertEqual(freshByUID[one.uid]?.subject, one.subject, "complete summaries, not just flags")
        if let echoed = changed[one.uid] { XCTAssertTrue(echoed.flags.contains(.seen)) }

        // Another client changes flags; this one notices on its next sync.
        try await otherClient.perform(.markUnread, on: [one])
        try await otherClient.perform(.unflag, on: [two])
        try await otherClient.perform(.flag, on: [three])
        let third = try await bobService.sync(mailbox: inboxBox, previous: second.state, limit: 50)
        let thirdByUID = Dictionary(uniqueKeysWithValues: third.upserted.map { ($0.uid, $0) })
        XCTAssertEqual(thirdByUID[one.uid]?.isUnread, true)
        XCTAssertEqual(thirdByUID[two.uid]?.isFlagged, false)
        XCTAssertEqual(thirdByUID[three.uid]?.isFlagged, true)
        XCTAssertEqual(thirdByUID[three.uid]?.subject, three.subject)
        XCTAssertEqual(third.upserted.count, 3)

        // New mail: only the new message comes back.
        try await deliver(adaService, from: ada, to: [bob], subject: "Incremental 4 \(id)", body: "Late arrival.")
        var fourth: MailboxSyncResult?
        var state = third.state
        try await waitUntil {
            let result = try await bobService.sync(mailbox: inboxBox, previous: state, limit: 50)
            state = result.state
            if !result.upserted.isEmpty { fourth = result }
            return !result.upserted.isEmpty
        }
        let newOnes = try XCTUnwrap(fourth).upserted
        XCTAssertEqual(newOnes.map(\.subject), ["Incremental 4 \(id)"])
        XCTAssertEqual(newOnes.first?.snippet, "Late arrival.")
        XCTAssertEqual(state.knownUIDs.count, 4)

        // Deleted elsewhere: reported as removed.
        try await otherClient.perform(.deletePermanently, on: [three])
        let fifth = try await bobService.sync(mailbox: inboxBox, previous: state, limit: 50)
        XCTAssertEqual(fifth.removedIDs, [three.id])
        XCTAssertTrue(fifth.upserted.isEmpty)
        XCTAssertFalse(fifth.state.knownUIDs.contains(three.uid))

        // Nothing changed: nothing reported.
        let sixth = try await bobService.sync(mailbox: inboxBox, previous: fifth.state, limit: 50)
        XCTAssertTrue(sixth.upserted.isEmpty)
        XCTAssertTrue(sixth.removedIDs.isEmpty)
        XCTAssertEqual(sixth.state.knownUIDs, fifth.state.knownUIDs)
        await otherClient.disconnect()
    }

    // MARK: - archive, trash, spam, move, move back

    func testTriageGreenMail() async throws { try await scenarioTriage(try require(Server.greenMail())) }
    func testTriageDovecot() async throws { try await scenarioTriage(try require(Server.dovecot())) }

    private func scenarioTriage(_ server: Server) async throws {
        let id = uniqueID()
        let ada = server.account("ada-\(id)"), bob = server.account("bob-\(id)")
        let adaService = server.service(ada), bobService = server.service(bob)
        for subject in ["Archive me", "Trash me", "Spam me", "File me"] {
            try await deliver(adaService, from: ada, to: [bob], subject: "\(subject) \(id)", body: "\(subject), please.")
        }
        let inboxBox = try await inbox(bobService)
        let initial = try await syncUntil(bobService, inboxBox, count: 4)
        func find(_ subject: String, in summaries: [MessageSummary]) throws -> MessageSummary {
            try XCTUnwrap(summaries.first { $0.subject == "\(subject) \(id)" }, "\(subject) missing")
        }
        let archiveMe = try find("Archive me", in: initial.upserted)
        let trashMe = try find("Trash me", in: initial.upserted)
        let spamMe = try find("Spam me", in: initial.upserted)
        let fileMe = try find("File me", in: initial.upserted)
        let before = try await bobService.mailboxes()
        XCTAssertNil(before.first { $0.role == .archive }, "no Archive yet on this server")

        // Archive creates the folder.
        try await bobService.perform(.archive, on: [archiveMe])
        let archive = try await mailbox(bobService, role: .archive)
        XCTAssertEqual(archive.path.components(separatedBy: archive.delimiter ?? "/").last, "Archive")
        let archived = try await bobService.sync(mailbox: archive, previous: nil, limit: 10)
        XCTAssertEqual(archived.upserted.map(\.subject), ["Archive me \(id)"])
        var inboxState = try await bobService.sync(mailbox: inboxBox, previous: initial.state, limit: 50)
        XCTAssertEqual(inboxState.removedIDs, [archiveMe.id])

        // Back to the inbox, from the stale INBOX summary (as after a snooze): found by Message-ID.
        try await bobService.perform(.moveToInbox, on: [archiveMe])
        inboxState = try await bobService.sync(mailbox: inboxBox, previous: inboxState.state, limit: 50)
        XCTAssertEqual(inboxState.upserted.map(\.subject), ["Archive me \(id)"])
        XCTAssertNotEqual(inboxState.upserted.first?.uid, archiveMe.uid, "a moved message gets a new UID")
        let archiveAfter = try await bobService.sync(mailbox: archive, previous: archived.state, limit: 10)
        XCTAssertEqual(archiveAfter.removedIDs.count, 1)

        // Trash (created when missing), then back out of Trash using the Trash copy's summary.
        try await bobService.perform(.trash, on: [trashMe])
        let trash = try await mailbox(bobService, role: .trash)
        let trashed = try await bobService.sync(mailbox: trash, previous: nil, limit: 10)
        let trashCopy = try find("Trash me", in: trashed.upserted)
        try await bobService.perform(.moveToInbox, on: [trashCopy])
        let trashAfter = try await bobService.sync(mailbox: trash, previous: trashed.state, limit: 10)
        XCTAssertEqual(trashAfter.removedIDs, [trashCopy.id])

        // Spam.
        try await bobService.perform(.markSpam, on: [spamMe])
        let junk = try await mailbox(bobService, role: .junk)
        let junked = try await bobService.sync(mailbox: junk, previous: nil, limit: 10)
        XCTAssertEqual(junked.upserted.map(\.subject), ["Spam me \(id)"])

        // A user folder with a non-ASCII name (modified UTF-7 on the wire).
        let client = try await server.client(bob)
        let folderName = "Réunions \(id)"
        try await client.create(ModifiedUTF7.encode(folderName))
        await client.logout()
        try await bobService.perform(.move(toPath: folderName), on: [fileMe])
        let listed = try await bobService.mailboxes()
        let folder = try XCTUnwrap(listed.first { $0.path == folderName })
        XCTAssertEqual(folder.rawPath, ModifiedUTF7.encode(folderName))
        XCTAssertEqual(folder.role, .custom)
        let filed = try await bobService.sync(mailbox: folder, previous: nil, limit: 10)
        XCTAssertEqual(filed.upserted.map(\.subject), ["File me \(id)"])
        await assertIMAPServiceThrows(.mailboxNotFound("No Such Folder \(id)")) {
            try await bobService.perform(.move(toPath: "No Such Folder \(id)"), on: [filed.upserted[0]])
        }

        // Delete for good from Trash.
        let latestInbox = try await bobService.sync(mailbox: inboxBox, previous: nil, limit: 50)
        XCTAssertEqual(Set(latestInbox.upserted.map(\.subject)), ["Archive me \(id)", "Trash me \(id)"])
        let doomed = try find("Trash me", in: latestInbox.upserted)
        try await bobService.perform(.trash, on: [doomed])
        let trashNow = try await bobService.sync(mailbox: trash, previous: nil, limit: 10)
        try await bobService.perform(.deletePermanently, on: trashNow.upserted)
        let trashEnd = try await bobService.sync(mailbox: trash, previous: trashNow.state, limit: 10)
        XCTAssertEqual(trashEnd.removedIDs.count, trashNow.upserted.count)
        XCTAssertTrue(trashEnd.state.knownUIDs.isEmpty)

        // Nothing to find: moving a long-gone message back fails clearly.
        await assertIMAPServiceThrows(.messageNotFound) {
            try await bobService.perform(.moveToInbox, on: [trashNow.upserted[0]])
        }
    }

    // MARK: - search

    func testSearchGreenMail() async throws { try await scenarioSearch(try require(Server.greenMail())) }
    func testSearchDovecot() async throws { try await scenarioSearch(try require(Server.dovecot())) }

    private func scenarioSearch(_ server: Server) async throws {
        let id = uniqueID()
        let ada = server.account("ada-\(id)"), bob = server.account("bob-\(id)")
        let adaService = server.service(ada), bobService = server.service(bob)
        try await deliver(adaService, from: ada, to: [bob], subject: "Invoice 2026-10 \(id)", body: "Total due: 120 EUR by Friday.")
        try await deliver(adaService, from: ada, to: [bob], subject: "Lunch on Friday? \(id)", body: "Pizza or ramen, your pick.")
        try await deliver(adaService, from: ada, to: [bob], subject: "Quarterly numbers \(id)", body: "The invoice total is in the sheet.")
        let inboxBox = try await inbox(bobService)
        _ = try await syncUntil(bobService, inboxBox, count: 3)

        let invoice = try await bobService.search("invoice", in: inboxBox, limit: 10)
        XCTAssertEqual(Set(invoice.map(\.subject)), ["Invoice 2026-10 \(id)", "Quarterly numbers \(id)"], "subject and body matches")
        XCTAssertTrue(invoice.allSatisfy { !$0.snippet.isEmpty })
        let lunch = try await bobService.search("lunch", in: inboxBox, limit: 10)
        XCTAssertEqual(lunch.map(\.subject), ["Lunch on Friday? \(id)"])
        let pizza = try await bobService.search("ramen", in: inboxBox, limit: 10)
        XCTAssertEqual(pizza.map(\.subject), ["Lunch on Friday? \(id)"], "body text")
        let both = try await bobService.search("friday invoice", in: inboxBox, limit: 10)
        XCTAssertEqual(both.map(\.subject), ["Invoice 2026-10 \(id)"], "every word must match")
        // A whole address (GreenMail only matches FROM against complete addresses).
        let bySender = try await bobService.search(ada.emailAddress, in: inboxBox, limit: 10)
        XCTAssertEqual(bySender.count, 3)
        let limited = try await bobService.search(ada.emailAddress, in: inboxBox, limit: 2)
        XCTAssertEqual(limited.count, 2)
        XCTAssertEqual(limited.map(\.subject), ["Quarterly numbers \(id)", "Lunch on Friday? \(id)"], "newest first")
        let none = try await bobService.search("zebra-crossing-\(id)", in: inboxBox, limit: 10)
        XCTAssertTrue(none.isEmpty)
        let empty = try await bobService.search("   ", in: inboxBox, limit: 10)
        XCTAssertTrue(empty.isEmpty)
    }

    // MARK: - paging and UIDVALIDITY

    func testPagingAndUIDValidityResetGreenMail() async throws { try await scenarioPagingAndReset(try require(Server.greenMail())) }
    func testPagingAndUIDValidityResetDovecot() async throws { try await scenarioPagingAndReset(try require(Server.dovecot())) }

    private func scenarioPagingAndReset(_ server: Server) async throws {
        let id = uniqueID()
        let bob = server.account("bob-\(id)")
        let service = server.service(bob)
        let client = try await server.client(bob)
        let folder = "Projects \(id)"
        try await client.create(folder)
        for n in 1...5 {
            try await appendMessage(client, to: folder, subject: "Page \(n)", to: bob.emailAddress, body: "Body of page \(n).")
        }
        let listed = try await service.mailboxes()
        let box = try XCTUnwrap(listed.first { $0.path == folder })
        let newest = try await service.sync(mailbox: box, previous: nil, limit: 2)
        XCTAssertEqual(newest.upserted.map(\.subject), ["Page 5", "Page 4"])
        XCTAssertEqual(newest.upserted.first?.snippet, "Body of page 5.")
        let oldestKnown = try XCTUnwrap(newest.state.knownUIDs.min())
        let older = try await service.fetchOlder(mailbox: box, olderThanUID: oldestKnown, limit: 2)
        XCTAssertEqual(older.map(\.subject), ["Page 3", "Page 2"])
        let oldest = try await service.fetchOlder(mailbox: box, olderThanUID: try XCTUnwrap(older.map(\.uid).min()), limit: 5)
        XCTAssertEqual(oldest.map(\.subject), ["Page 1"])
        let beyond = try await service.fetchOlder(mailbox: box, olderThanUID: try XCTUnwrap(oldest.first?.uid), limit: 5)
        XCTAssertTrue(beyond.isEmpty)

        // The anchor itself is gone: fall back to searching.
        _ = try await client.select(folder)
        try await client.uidStore(IMAPSequenceSet(oldestKnown), flags: ["\\Deleted"], mode: .add)
        try await client.expunge()
        let afterGap = try await service.fetchOlder(mailbox: box, olderThanUID: oldestKnown, limit: 2)
        XCTAssertEqual(afterGap.map(\.subject), ["Page 3", "Page 2"])

        // More new mail than the window holds: start over with the newest.
        for n in 6...9 {
            try await appendMessage(client, to: folder, subject: "Page \(n)", to: bob.emailAddress, body: "Body \(n).")
        }
        let flood = try await service.sync(mailbox: box, previous: newest.state, limit: 2)
        XCTAssertTrue(flood.didReset)
        XCTAssertEqual(flood.upserted.map(\.subject), ["Page 9", "Page 8"])
        await client.logout()

        // Replace the folder with a new one of the same name: UIDVALIDITY changes and sync
        // starts over. (RENAME rather than DELETE: GreenMail 2.1 crashes deleting a folder that
        // any earlier session had selected.)
        try await Task.sleep(nanoseconds: 1_200_000_000)
        let transcript = try await server.raw(bob, ["RENAME \"\(folder)\" \"\(folder) old\"", "CREATE \"\(folder)\""])
        XCTAssertFalse(transcript.contains(" NO "), transcript)
        let again = try await server.client(bob)
        try await appendMessage(again, to: folder, subject: "Fresh start", to: bob.emailAddress, body: "New folder, new UIDs.")
        await again.logout()
        let reset = try await service.sync(mailbox: box, previous: flood.state, limit: 10)
        XCTAssertTrue(reset.didReset)
        XCTAssertNotEqual(reset.state.uidValidity, flood.state.uidValidity)
        XCTAssertEqual(reset.upserted.map(\.subject), ["Fresh start"])
        XCTAssertEqual(reset.removedIDs.count, flood.state.knownUIDs.count, "every old copy is reported gone")
        // A summary from before the reset now finds its message by Message-ID… or reports it gone.
        await assertIMAPServiceThrows(.messageNotFound) {
            try await service.body(for: flood.upserted[0])
        }
    }

    // MARK: - watch

    func testWatchGreenMail() async throws { try await scenarioWatch(try require(Server.greenMail())) }
    func testWatchDovecot() async throws { try await scenarioWatch(try require(Server.dovecot())) }

    private func scenarioWatch(_ server: Server) async throws {
        let id = uniqueID()
        let ada = server.account("ada-\(id)"), bob = server.account("bob-\(id)")
        let adaService = server.service(ada), bobService = server.service(bob)
        let inboxBox = try await inbox(bobService)
        let changed = expectation(description: "IDLE reported new mail")
        changed.assertForOverFulfill = false
        let consumer = Task {
            for await change in bobService.watch(mailbox: inboxBox) where change == .changed {
                changed.fulfill()
            }
        }
        // Give the watcher time to connect and enter IDLE.
        try await Task.sleep(nanoseconds: 1_500_000_000)
        XCTAssertEqual(bobService.watchRegistry.count, 1)
        try await deliver(adaService, from: ada, to: [bob], subject: "Ping \(id)", body: "Are you there?")
        await fulfillment(of: [changed], timeout: 30)
        // Cancelling the consuming task ends the watch (DONE, LOGOUT).
        consumer.cancel()
        try await waitUntil(timeout: 10) { bobService.watchRegistry.count == 0 }

        // disconnect() ends watches too.
        let second = bobService.watch(mailbox: inboxBox)
        let ended = expectation(description: "stream finished")
        let waiter = Task {
            for await _ in second {}
            ended.fulfill()
        }
        try await Task.sleep(nanoseconds: 500_000_000)
        await bobService.disconnect()
        await fulfillment(of: [ended], timeout: 15)
        waiter.cancel()
    }
}

/// RFC 5322 dates for fixtures, without depending on InkMIME's formatter details.
enum RFC5322DateLike {
    static func now() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "EEE, d MMM yyyy HH:mm:ss Z"
        return formatter.string(from: Date())
    }
}
