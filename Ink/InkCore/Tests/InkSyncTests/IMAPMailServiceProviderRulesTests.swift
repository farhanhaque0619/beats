import XCTest
import InkModel
import InkIMAP
import InkProviders
@testable import InkSync

/// Provider-specific behaviour of `IMAPMailService` from RESEARCH §2–§3: iCloud's two user name
/// forms, sign-in advice, Gmail folders by attribute only, IDLE renewal and polling, and Yahoo's
/// MESSAGELIMIT.
final class IMAPMailServiceProviderRulesTests: XCTestCase {
    typealias T = IMAPServiceTranscripts
    typealias F = IMAPServiceFixtures

    private func plain(_ user: String, _ password: String = "correct horse") -> String {
        Data("\u{0}\(user)\u{0}\(password)".utf8).base64EncodedString()
    }

    private func count(_ needle: String, in haystack: String) -> Int {
        haystack.components(separatedBy: needle).count - 1
    }

    // MARK: iCloud user names

    private static let icloudGreeting = ScriptedTransport.Step.send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN AUTH=PLAIN-CLIENTTOKEN IDLE] iCloud IMAP4 service is ready.\r\n")
    private static let icloudCapabilities = "IMAP4rev1 SASL-IR AUTH=PLAIN IDLE UIDPLUS ESEARCH SORT LIST-STATUS ENABLE CONDSTORE QRESYNC"
    private static let icloudList = IMAPServiceFixtures.crlf("""
    * LIST (\\HasNoChildren) "/" "INBOX"
    * LIST (\\HasNoChildren \\Sent) "/" "Sent Messages"
    * LIST (\\HasNoChildren \\Trash) "/" "Deleted Messages"
    * LIST (\\HasNoChildren) "/" "Archive"

    """)

    private func icloudAccount(username: String = "ada") -> AccountConfig {
        var account = F.account(provider: .icloud, email: "ada@icloud.com", host: "imap.mail.me.com", smtpHost: "smtp.mail.me.com")
        account.imap.username = username
        return account
    }

    func testICloudVerifyTriesTheFullAddressAfterTheNamePart() async throws {
        let account = icloudAccount()
        let imap = ScriptedTransport([
            Self.icloudGreeting,
            .expect("* AUTHENTICATE PLAIN \(plain("ada"))", reply: "{TAG} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"),
            .expect("* AUTHENTICATE PLAIN \(plain("ada@icloud.com"))", reply: "{TAG} OK [CAPABILITY \(Self.icloudCapabilities)] Authentication successful.\r\n"),
            T.listStep(Self.icloudList, extended: false),
            T.logoutStep,
        ])
        let smtp = ScriptedTransport(Array(T.smtpSession(from: "x", recipients: []).prefix(3)) + [.expect("QUIT", reply: "221 Bye\r\n")])
        let later = ScriptedTransport([
            Self.icloudGreeting,
            // The form that worked comes first from now on.
            .expect("* AUTHENTICATE PLAIN \(plain("ada@icloud.com"))", reply: "{TAG} OK [CAPABILITY \(Self.icloudCapabilities)] Authentication successful.\r\n"),
            T.listStep(Self.icloudList, extended: false),
        ])
        let queue = IMAPServiceTransportQueue([imap, smtp, later])
        let steps = IMAPServiceSteps()
        let service = F.service(account, transports: queue)
        try await service.verify { steps.append($0) }
        XCTAssertEqual(steps.steps, VerificationStep.allCases)
        XCTAssertEqual(count("AUTHENTICATE", in: imap.transcript), 2, "one retry, on the same connection")
        XCTAssertEqual(service.verifiedAccount.imap.username, "ada@icloud.com", "for the caller to save")
        XCTAssertEqual(service.verifiedAccount.smtp, account.smtp)
        XCTAssertTrue(smtp.transcript.contains(plain("ada@icloud.com")), "SMTP always takes the full address")

        let boxes = try await service.mailboxes()
        XCTAssertEqual(boxes.first(where: { $0.role == .sent })?.path, "Sent Messages")
        XCTAssertEqual(count("AUTHENTICATE", in: later.transcript), 1)
        XCTAssertEqual(queue.openedCount, 3)
    }

    func testICloudRetryUsesANewConnectionWhenTheServerHangsUp() async throws {
        let account = icloudAccount(username: "ada@icloud.com")
        // The server says goodbye after the refusal and closes the socket: the retry on that
        // connection goes nowhere.
        let first = IMAPServiceDroppingTransport(ScriptedTransport([
            Self.icloudGreeting,
            .expect("* AUTHENTICATE PLAIN \(plain("ada@icloud.com"))",
                    reply: "{TAG} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n* BYE Too many failed attempts.\r\n"),
        ]), dropOn: plain("ada"))
        let second = ScriptedTransport([
            Self.icloudGreeting,
            .expect("* AUTHENTICATE PLAIN \(plain("ada"))", reply: "{TAG} OK [CAPABILITY \(Self.icloudCapabilities)] Authentication successful.\r\n"),
            T.listStep(Self.icloudList, extended: false),
        ])
        let queue = IMAPServiceTransportQueue([first, second])
        let service = F.service(account, transports: queue)
        let boxes = try await service.mailboxes()
        XCTAssertEqual(boxes.first?.role, .inbox)
        XCTAssertEqual(queue.openedCount, 2)
        XCTAssertTrue(second.transcript.contains(plain("ada")))
        XCTAssertEqual(service.verifiedAccount.imap.username, "ada")
    }

    func testICloudBothFormsRefusedGivesAdvice() async throws {
        let account = icloudAccount()
        let imap = ScriptedTransport([
            Self.icloudGreeting,
            .expect("* AUTHENTICATE PLAIN \(plain("ada"))", reply: "{TAG} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"),
            .expect("* AUTHENTICATE PLAIN \(plain("ada@icloud.com"))", reply: "{TAG} NO [AUTHENTICATIONFAILED] Authentication failed.\r\n"),
        ])
        let steps = IMAPServiceSteps()
        let queue = IMAPServiceTransportQueue([imap])
        let service = F.service(account, transports: queue)
        await assertIMAPServiceThrows(.authenticationFailed(ProviderErrorAdvice.icloudAppPasswordRejected)) {
            try await service.verify { steps.append($0) }
        }
        XCTAssertEqual(steps.steps, [.connectingIMAP, .signingInIMAP])
        XCTAssertEqual(count("AUTHENTICATE", in: imap.transcript), 2, "two forms, once each")
        XCTAssertEqual(queue.openedCount, 1)
        XCTAssertEqual(service.verifiedAccount.imap.username, "ada", "nothing worked, nothing changed")
    }

    func testOtherProvidersGetOneSignInAttempt() async throws {
        // Yahoo locks accounts out after repeated failures (RESEARCH §3.7).
        let account = F.account(provider: .yahoo, email: "ada@yahoo.com", host: "imap.mail.yahoo.com")
        let imap = ScriptedTransport([
            .send("* OK [CAPABILITY IMAP4rev1 SASL-IR AUTH=PLAIN AUTH=XOAUTH2 ID MOVE NAMESPACE XYMHIGHESTMODSEQ UIDPLUS LITERAL+ CHILDREN X-MSG-EXT UIDONLY OBJECTID] IMAP4rev1 Hello\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} NO [AUTHENTICATIONFAILED] AUTHENTICATE Invalid credentials\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([imap]))
        await assertIMAPServiceThrows(.authenticationFailed(ProviderErrorAdvice.yahooAppPasswordRejected)) {
            try await service.mailboxes()
        }
        XCTAssertEqual(count("AUTHENTICATE", in: imap.transcript), 1)
    }

    // MARK: Advice

    func testGmailPasswordInsteadOfAppPassword() async throws {
        let account = F.account(provider: .gmail, email: "ada@gmail.com", host: "imap.gmail.com", smtpHost: "smtp.gmail.com")
        let imap = ScriptedTransport([
            .send("* OK Gimap ready for requests from 203.0.113.5 f1mb123456789abc\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(T.gmailPreAuthCapabilities)\r\n{TAG} OK Thats all she wrote!\r\n"),
            .expect("* AUTHENTICATE PLAIN",
                    reply: "{TAG} NO [ALERT] Application-specific password required: https://support.google.com/accounts/answer/185833 (Failure)\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([imap]))
        await assertIMAPServiceThrows(.authenticationFailed(ProviderErrorAdvice.gmailAppPasswordRequired)) {
            try await service.verify { _ in }
        }
    }

    func testGmailSMTPRefusalGetsAdvice() async throws {
        let account = F.account(provider: .gmail, email: "ada@gmail.com", host: "imap.gmail.com", smtpHost: "smtp.gmail.com",
                                savesSentAutomatically: true)
        let smtp = ScriptedTransport([
            .send("220 smtp.gmail.com ESMTP a640c23a62f3a-12345 - gsmtp\r\n"),
            .expect("EHLO", reply: "250-smtp.gmail.com at your service\r\n250-SIZE 35882577\r\n250-AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH\r\n250 SMTPUTF8\r\n"),
            .expect("AUTH PLAIN", reply: "535-5.7.8 Username and Password not accepted. For more information, go to\r\n535 5.7.8  https://support.google.com/mail/?p=BadCredentials a640c23a62f3a-12345 - gsmtp\r\n"),
            .expect("QUIT", reply: "221 2.0.0 closing connection\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([smtp]))
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: "grace@example.com")], subject: "Hi", body: "Hello")
        await assertIMAPServiceThrows(.authenticationFailed(ProviderErrorAdvice.gmailAppPasswordRejected)) {
            try await service.send(message)
        }
    }

    func testCredentialStoreFailuresAreNotDressedUpAsServerRefusals() async throws {
        // The app's Keychain store says "Sign in again" itself; that isn't Gmail refusing a password.
        let account = F.account(provider: .gmail, email: "ada@gmail.com", host: "imap.gmail.com", smtpHost: "smtp.gmail.com")
        let imap = ScriptedTransport([
            .send("* OK Gimap ready for requests from 203.0.113.5 f1mb123456789abc\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(T.gmailPreAuthCapabilities)\r\n{TAG} OK Thats all she wrote!\r\n"),
        ])
        let smtp = ScriptedTransport([
            .send("220 smtp.gmail.com ESMTP a640c23a62f3a-12345 - gsmtp\r\n"),
            .expect("EHLO", reply: "250-smtp.gmail.com at your service\r\n250 AUTH LOGIN PLAIN XOAUTH2\r\n"),
            .expect("QUIT", reply: "221 2.0.0 closing connection\r\n"),
        ])
        let queue = IMAPServiceTransportQueue([imap, smtp])
        let service = IMAPMailService(account: account, credentials: FailingCredentialStore(), transportFactory: queue.factory,
                                      options: F.fastOptions)
        await assertIMAPServiceThrows(.authenticationFailed("Keychain locked.")) {
            try await service.mailboxes()
        }
        let message = OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: "grace@example.com")], subject: "Hi", body: "Hello")
        await assertIMAPServiceThrows(.authenticationFailed("Keychain locked.")) {
            try await service.send(message)
        }
    }

    private func outlookLogin() -> [ScriptedTransport.Step] {
        [
            .send("* OK The Microsoft Exchange IMAP4 service is ready. [TQBOADIAUABSADAAMgBDAEEAMAAwADEAMQAuAG4AYQBtAHAAcgBkADAAMgAuAHAAcgBvAGQALgBvAHUAdABsAG8AbwBrAC4AYwBvAG0A]\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2 SASL-IR UIDPLUS MOVE ID UNSELECT CHILDREN IDLE NAMESPACE LITERAL+\r\n{TAG} OK CAPABILITY completed.\r\n"),
            .expect("* AUTHENTICATE XOAUTH2", reply: "{TAG} OK AUTHENTICATE completed.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY IMAP4 IMAP4rev1 AUTH=PLAIN AUTH=XOAUTH2 SASL-IR UIDPLUS MOVE ID UNSELECT CHILDREN IDLE NAMESPACE LITERAL+\r\n{TAG} OK CAPABILITY completed.\r\n"),
        ]
    }

    func testOutlookWithIMAPSwitchedOff() async throws {
        let account = F.account(provider: .outlook, email: "ada@outlook.com", host: "outlook.office365.com",
                                smtpHost: "smtp-mail.outlook.com", authMethod: .oauth2, savesSentAutomatically: true)
        let token = Credential.oauth(OAuthToken(accessToken: "EwBIA8l6BAAU_token"))
        let imap = ScriptedTransport(outlookLogin() + [
            .expect("* LIST", reply: "{TAG} BAD User is authenticated but not connected.\r\n"),
        ])
        let watchConnection = ScriptedTransport(outlookLogin() + [
            .expect("* EXAMINE INBOX", reply: "{TAG} BAD User is authenticated but not connected.\r\n"),
        ])
        let queue = IMAPServiceTransportQueue([imap, watchConnection])
        let service = F.service(account, credential: token, transports: queue)
        await assertIMAPServiceThrows(.serverError(ProviderErrorAdvice.outlookIMAPDisabled)) {
            try await service.mailboxes()
        }

        // Watching stops at once instead of retrying something only the person can fix.
        var changes: [MailboxChange] = []
        for await change in service.watch(mailbox: F.mailbox("INBOX", role: .inbox, accountID: account.id)) { changes.append(change) }
        XCTAssertEqual(changes, [.connectionLost])
        XCTAssertEqual(queue.openedCount, 2)
    }

    // MARK: Gmail folders

    func testGmailFoldersAreRecognisedOnlyByAttribute() throws {
        // "[Google Mail]" prefix, All Mail and Spam hidden from IMAP, and user labels with system-like names.
        let list = """
        * LIST (\\HasNoChildren) "/" "INBOX"
        * LIST (\\HasChildren \\Noselect) "/" "[Google Mail]"
        * LIST (\\Drafts \\HasNoChildren) "/" "[Google Mail]/Drafts"
        * LIST (\\HasNoChildren \\Sent) "/" "[Google Mail]/Sent Mail"
        * LIST (\\HasNoChildren \\Trash) "/" "[Google Mail]/Bin"
        * LIST (\\HasNoChildren) "/" "Archive"
        * LIST (\\HasNoChildren) "/" "Junk"
        * LIST (\\HasNoChildren) "/" "All Mail"
        """
        let responses = try IMAPResponseParser.parseAll(F.crlf(list + "\n"))
        let mailboxes: [IMAPMailbox] = responses.compactMap { if case .untagged(.list(let box)) = $0 { return box } else { return nil } }

        let gmail = IMAPMailServiceRoles.mailboxInfos(from: mailboxes, accountID: "a", isGmail: true)
        let roles = Dictionary(gmail.map { ($0.path, $0.role) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(roles["INBOX"], .inbox)
        XCTAssertEqual(roles["[Google Mail]/Sent Mail"], .sent)
        XCTAssertEqual(roles["[Google Mail]/Bin"], .trash)
        XCTAssertEqual(roles["[Google Mail]/Drafts"], .drafts)
        XCTAssertEqual(roles["Archive"], .custom, "a user label, not Gmail's archive")
        XCTAssertEqual(roles["Junk"], .custom)
        XCTAssertEqual(roles["All Mail"], .custom)
        XCTAssertFalse(gmail.contains { $0.role == .all || $0.role == .junk || $0.role == .archive }, "hidden folders stay missing")

        // The same names on any other server are system folders.
        let other = IMAPMailServiceRoles.mailboxInfos(from: mailboxes, accountID: "a", isGmail: false)
        let otherRoles = Dictionary(other.map { ($0.path, $0.role) }, uniquingKeysWith: { first, _ in first })
        XCTAssertEqual(otherRoles["Archive"], .archive)
        XCTAssertEqual(otherRoles["Junk"], .junk)
    }

    func testGmailSessionFolderListUsesAttributesOnly() async throws {
        let account = F.account(provider: .gmail, email: "ada@gmail.com", host: "imap.gmail.com", authMethod: .oauth2)
        let list = IMAPServiceFixtures.crlf("""
        * LIST (\\HasNoChildren) "/" "INBOX"
        * LIST (\\HasChildren \\Noselect) "/" "[Gmail]"
        * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"
        * LIST (\\HasNoChildren \\Trash) "/" "[Gmail]/Trash"
        * LIST (\\HasNoChildren) "/" "Archive"

        """)
        let imap = ScriptedTransport(T.gmailLogin() + [T.listStep(list)])
        let service = F.service(account, credential: .oauth(OAuthToken(accessToken: "ya29.a0AfB_token")), transports: IMAPServiceTransportQueue([imap]))
        let boxes = try await service.mailboxes()
        XCTAssertEqual(boxes.first(where: { $0.path == "Archive" })?.role, .custom)
        XCTAssertNil(boxes.first(where: { $0.role == .all }))
    }

    // MARK: IDLE

    func testIdlePlans() {
        let options = IMAPMailService.Options()
        XCTAssertEqual(options.idleRefresh, 25 * 60)
        XCTAssertEqual(options.gmailIdleRefresh, 9 * 60)
        XCTAssertEqual(options.pollInterval, 180, "NOOP every 3 minutes without IDLE")
        XCTAssertEqual(IMAPMailServiceIdlePlan(options: options, isGmail: false, missesDeletions: false),
                       IMAPMailServiceIdlePlan(refresh: 25 * 60, resyncEachRenewal: false))
        XCTAssertEqual(IMAPMailServiceIdlePlan(options: options, isGmail: true, missesDeletions: false),
                       IMAPMailServiceIdlePlan(refresh: 9 * 60, resyncEachRenewal: false))
        XCTAssertEqual(IMAPMailServiceIdlePlan(options: options, isGmail: false, missesDeletions: true),
                       IMAPMailServiceIdlePlan(refresh: 5 * 60, resyncEachRenewal: true))

        let plain = F.account()
        XCTAssertFalse(IMAPMailServiceWatcher.idleMissesDeletions(account: plain, capabilities: ["IMAP4REV1", "IDLE"]))
        XCTAssertTrue(IMAPMailServiceWatcher.idleMissesDeletions(account: plain, capabilities: ["IMAP4REV1", "IDLE", "XYMHIGHESTMODSEQ"]))
        XCTAssertTrue(IMAPMailServiceWatcher.idleMissesDeletions(account: F.account(provider: .aol), capabilities: []))
        XCTAssertTrue(IMAPMailServiceWatcher.idleMissesDeletions(account: F.account(host: "imap.mail.yahoo.com"), capabilities: []))
        XCTAssertTrue(IMAPMailServiceWatcher.idleMissesDeletions(account: F.account(host: "export.imap.aol.com"), capabilities: []))
    }

    /// Collects watch values in the background.
    final class Collector: @unchecked Sendable {
        private let lock = NSLock()
        private var values: [MailboxChange] = []
        private var finished = false
        func append(_ value: MailboxChange) { lock.withLock { values.append(value) } }
        func finish() { lock.withLock { finished = true } }
        var snapshot: [MailboxChange] { lock.withLock { values } }
        var isFinished: Bool { lock.withLock { finished } }
    }

    private func collect(_ stream: AsyncStream<MailboxChange>) -> (Collector, Task<Void, Never>) {
        let collector = Collector()
        let task = Task {
            for await value in stream { collector.append(value) }
            collector.finish()
        }
        return (collector, task)
    }

    private func wait(timeout: TimeInterval = 10, file: StaticString = #filePath, line: UInt = #line, _ condition: () -> Bool) async {
        let deadline = Date().addingTimeInterval(timeout)
        while !condition() && Date() < deadline { try? await Task.sleep(nanoseconds: 20_000_000) }
        XCTAssertTrue(condition(), "timed out", file: file, line: line)
    }

    func testRefusedIdleFallsBackToPolling() async throws {
        var options = F.fastOptions
        options.pollInterval = 0.2
        let script = ScriptedTransport(T.dovecotLogin() + [
            IMAPMailServiceWatchTests.examine,
            .expect("* IDLE", reply: "{TAG} NO IDLE is disabled for this account.\r\n"),
            .expect("* NOOP", reply: "* 5 EXISTS\r\n{TAG} OK NOOP completed.\r\n"),
            T.logoutStep,
        ])
        let queue = IMAPServiceTransportQueue([script])
        let log = IMAPServiceLog()
        let account = F.account()
        let service = F.service(account, transports: queue, options: options, log: log)
        let (collector, task) = collect(service.watch(mailbox: F.mailbox("INBOX", role: .inbox, accountID: account.id)))
        await wait { collector.snapshot == [.changed] }
        XCTAssertEqual(queue.openedCount, 1, "no reconnecting: the connection is fine")
        XCTAssertTrue(log.text.contains("refused IDLE"))
        await service.disconnect()
        await wait { collector.isFinished }
        task.cancel()
    }

    func testYahooIdleRenewalTriggersResync() async throws {
        var options = F.fastOptions
        options.deletionCheckInterval = 0.3
        let account = F.account(provider: .yahoo, email: "ada@yahoo.com", host: "imap.mail.yahoo.com")
        let script = ScriptedTransport(T.dovecotLogin() + [
            IMAPMailServiceWatchTests.examine,
            .expect("* IDLE", reply: "+ idling\r\n"),
            .expect("DONE", reply: "A003 OK Idle completed.\r\n"),
            .expect("* IDLE", reply: "+ idling\r\n"),
            .expect("DONE", reply: "A004 OK Idle completed.\r\n"),
            T.logoutStep,
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]), options: options)
        let started = Date()
        let (collector, task) = collect(service.watch(mailbox: F.mailbox("INBOX", role: .inbox, accountID: account.id)))
        await wait { collector.snapshot == [.changed] }
        XCTAssertGreaterThanOrEqual(Date().timeIntervalSince(started), 0.25, "only when IDLE was renewed")
        await service.disconnect()
        await wait { collector.isFinished }
        await wait { script.transcript.contains("LOGOUT") }
        XCTAssertEqual(collector.snapshot, [.changed])
        task.cancel()
    }

    // MARK: MESSAGELIMIT

    func testMessageLimitParsingAndSpans() {
        XCTAssertEqual(IMAPMailService.messageLimit(["IMAP4REV1", "MESSAGELIMIT=1000", "IDLE"]), 1000)
        XCTAssertNil(IMAPMailService.messageLimit(["IMAP4REV1", "IDLE"]))
        XCTAssertNil(IMAPMailService.messageLimit(["MESSAGELIMIT=0", "MESSAGELIMIT=X"]))

        XCTAssertEqual(IMAPMailService.uidSpans(known: [10, 11, 12, 13, 14], from: 10, perSpan: nil).map(\.description), ["10:*"])
        XCTAssertEqual(IMAPMailService.uidSpans(known: [14, 10, 11, 13, 12], from: 10, perSpan: 2).map(\.description), ["10:11", "12:13", "14:*"])
        XCTAssertEqual(IMAPMailService.uidSpans(known: [10, 20], from: 10, perSpan: 2).map(\.description), ["10:*"])
        XCTAssertEqual(IMAPMailService.uidSpans(known: [3, 7, 9, 40, 41], from: 3, perSpan: 2).map(\.description), ["3:7", "8:40", "41:*"])
    }

    private static let yahooCapabilities = "IMAP4rev1 SASL-IR ID MOVE UIDPLUS IDLE NAMESPACE MESSAGELIMIT=4 XYMHIGHESTMODSEQ UIDONLY OBJECTID"

    private func summaryLine(_ seq: Int, _ uid: UInt32) -> String {
        T.summary(seq: seq, uid: uid, subject: "Message \(uid)", messageID: "msg-\(uid)@example.com")
    }

    func testSyncKeepsEveryCommandUnderTheMessageLimit() async throws {
        let account = F.account(provider: .yahoo, email: "ada@yahoo.com", host: "imap.mail.yahoo.com")
        let inbox = F.mailbox("INBOX", role: .inbox, accountID: account.id)
        let script = ScriptedTransport(T.dovecotLogin(capabilities: Self.yahooCapabilities) + [
            T.dovecotSelect(exists: 6, uidNext: 7, condstore: false),
            .expect("* FETCH 1:4 \(T.summaryItemsPrefix)", reply: (1...4).map { summaryLine($0, UInt32($0)) }.joined() + T.ok()),
            .expect("* FETCH 5:6 \(T.summaryItemsPrefix)", reply: summaryLine(5, 5) + summaryLine(6, 6) + T.ok()),
            .expect("* UID FETCH 1:4 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
            .expect("* UID FETCH 5:6 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
            // Next sync: 3 is gone, 7 is new. The window is checked in spans of two known messages.
            T.dovecotSelect(exists: 6, uidNext: 8, condstore: false),
            .expect("* UID FETCH 1:2 (UID FLAGS)", reply: "* 1 FETCH (UID 1 FLAGS ())\r\n* 2 FETCH (UID 2 FLAGS ())\r\n" + T.ok()),
            .expect("* UID FETCH 3:4 (UID FLAGS)", reply: "* 3 FETCH (UID 4 FLAGS ())\r\n" + T.ok()),
            .expect("* UID FETCH 5:* (UID FLAGS)", reply: "* 4 FETCH (UID 5 FLAGS ())\r\n* 5 FETCH (UID 6 FLAGS ())\r\n* 6 FETCH (UID 7 FLAGS ())\r\n" + T.ok()),
            .expect("* UID FETCH 7 \(T.summaryItemsPrefix)", reply: summaryLine(6, 7) + T.ok()),
            .expect("* UID FETCH 7 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let first = try await service.sync(mailbox: inbox, previous: nil, limit: 10)
        XCTAssertEqual(first.upserted.map(\.uid), [6, 5, 4, 3, 2, 1])

        let second = try await service.sync(mailbox: inbox, previous: first.state, limit: 10)
        XCTAssertFalse(second.didReset)
        XCTAssertEqual(second.removedIDs, ["\(account.id)|INBOX|1792470281|3"])
        XCTAssertEqual(second.upserted.map(\.uid), [7])
        XCTAssertEqual(second.state.knownUIDs, [1, 2, 4, 5, 6, 7])
        XCTAssertFalse(script.transcript.contains("SEARCH"), "SEARCH can be cut short silently")
    }

    func testReplyReachingTheMessageLimitReloadsTheNewestWindow() async throws {
        let account = F.account(provider: .yahoo, email: "ada@yahoo.com", host: "imap.mail.yahoo.com")
        let inbox = F.mailbox("INBOX", role: .inbox, accountID: account.id)
        let script = ScriptedTransport(T.dovecotLogin(capabilities: Self.yahooCapabilities) + [
            T.dovecotSelect(exists: 6, uidNext: 7, condstore: false),
            .expect("* UID FETCH 1:* (UID FLAGS)", reply: (1...4).map { "* \($0) FETCH (UID \($0) FLAGS ())\r\n" }.joined() + T.ok()),
            .expect("* FETCH 4:6 \(T.summaryItemsPrefix)", reply: summaryLine(4, 4) + summaryLine(5, 5) + summaryLine(6, 6) + T.ok()),
            .expect("* UID FETCH 4:6 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
        ])
        let log = IMAPServiceLog()
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]), log: log)
        let previous = MailboxSyncState(uidValidity: 1792470281, uidNext: 3, knownUIDs: [1, 2])
        let result = try await service.sync(mailbox: inbox, previous: previous, limit: 3)
        XCTAssertTrue(result.didReset)
        XCTAssertEqual(result.upserted.map(\.uid), [6, 5, 4])
        XCTAssertTrue(log.text.contains("message limit"))
    }

    func testFetchOlderWalksDownInSpansWhenTheAnchorIsGone() async throws {
        let account = F.account(provider: .yahoo, email: "ada@yahoo.com", host: "imap.mail.yahoo.com")
        let inbox = F.mailbox("INBOX", role: .inbox, accountID: account.id)
        let script = ScriptedTransport(T.dovecotLogin(capabilities: Self.yahooCapabilities) + [
            T.dovecotSelect(exists: 10, uidNext: 30, condstore: false),
            .expect("* UID FETCH 20 (UID)", reply: T.ok()),
            .expect("* UID FETCH 16:19 (UID FLAGS)", reply: "* 3 FETCH (UID 17 FLAGS ())\r\n* 4 FETCH (UID 19 FLAGS ())\r\n" + T.ok()),
            .expect("* UID FETCH 12:15 (UID FLAGS)", reply: "* 1 FETCH (UID 12 FLAGS (\\Seen))\r\n* 2 FETCH (UID 15 FLAGS (\\Deleted))\r\n" + T.ok()),
            .expect("* UID FETCH 12,17,19 \(T.summaryItemsPrefix)", reply: summaryLine(1, 12) + summaryLine(3, 17) + summaryLine(4, 19) + T.ok()),
            .expect("* UID FETCH 12,17,19 (UID BODY.PEEK[1]<0.2048>)", reply: T.ok()),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([script]))
        let older = try await service.fetchOlder(mailbox: inbox, olderThanUID: 20, limit: 3)
        XCTAssertEqual(older.map(\.uid), [19, 17, 12])
        XCTAssertFalse(script.transcript.contains("SEARCH"))
    }
}
