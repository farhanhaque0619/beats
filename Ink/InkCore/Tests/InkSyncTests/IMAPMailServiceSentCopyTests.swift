import XCTest
import InkModel
import InkIMAP
@testable import InkSync

/// Filing the Sent copy after SMTP (RESEARCH §3.8): look for the server's own copy by
/// Message-ID first, upload Ink's only when none turns up, never upload on Gmail.
final class IMAPMailServiceSentCopyTests: XCTestCase {
    typealias T = IMAPServiceTranscripts
    typealias F = IMAPServiceFixtures

    private func options(_ delays: [TimeInterval], patient: [TimeInterval] = [0]) -> IMAPMailService.Options {
        var options = F.fastOptions
        options.sentCopyPollDelays = delays
        options.sentCopyPatientPollDelays = patient
        return options
    }

    private func message(_ account: AccountConfig, to: String = "grace@example.com") -> OutgoingMessage {
        OutgoingMessage(accountID: account.id, from: account.address, to: [EmailAddress(address: to)], subject: "Hi", body: "Hello")
    }

    private static let emptySearch = "* ESEARCH (TAG \"{TAG}\") UID\r\n{TAG} OK Search completed\r\n"
    private static func found(_ uid: UInt32) -> String { "* ESEARCH (TAG \"{TAG}\") UID ALL \(uid)\r\n{TAG} OK Search completed\r\n" }
    private static let search = "* UID SEARCH RETURN (ALL) HEADER MESSAGE-ID \""

    /// The Message-ID the service searched for, and the one in the uploaded copy, if any.
    private func ids(in transcript: String) -> (searched: [String], appended: String?) {
        func matches(_ pattern: String) -> [String] {
            guard let regex = try? NSRegularExpression(pattern: pattern, options: [.caseInsensitive]) else { return [] }
            let range = NSRange(transcript.startIndex..., in: transcript)
            return regex.matches(in: transcript, range: range).compactMap { match in
                Range(match.range(at: 1), in: transcript).map { String(transcript[$0]) }
            }
        }
        return (matches("HEADER MESSAGE-ID \"([^\"]+)\""), matches("Message-ID: <([^>]+)>").first)
    }

    func testUploadsCopyWhenTheServerFilesNone() async throws {
        let account = F.account(provider: .icloud, email: "ada@icloud.com", host: "imap.mail.me.com")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@icloud.com", recipients: ["grace@example.com"]) + T.smtpData)
        let imap = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect("Sent", exists: 4, uidNext: 12, modSeq: 9),
            .expect(Self.search, reply: Self.emptySearch),
            // The second look: Sent is still selected, so a NOOP lets the server report new mail first.
            .expect("* NOOP", reply: "{TAG} OK NOOP completed.\r\n"),
            .expect(Self.search, reply: Self.emptySearch),
            .expect("* APPEND \"Sent\" (\\Seen) \"", reply: "{TAG} OK [APPENDUID 1792470281 12] Append completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([smtp, imap]), options: options([0, 0.05]))
        try await service.send(message(account))

        let found = ids(in: imap.transcript)
        XCTAssertEqual(found.searched.count, 2)
        XCTAssertEqual(Set(found.searched).count, 1)
        XCTAssertEqual(found.searched.first, found.appended, "looked for the message that was sent")
        XCTAssertTrue(found.appended?.hasSuffix("@icloud.com") ?? false)
        let learned = await service.serverSavesSentCopies
        XCTAssertEqual(learned, false)
    }

    func testServerCopyFoundSkipsUploadAndLaterSendsWaitLonger() async throws {
        let account = F.account()
        let first = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com"]) + T.smtpData)
        let second = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com"]) + T.smtpData)
        let imap = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect("Sent", exists: 4, uidNext: 12, modSeq: 9),
            .expect(Self.search, reply: Self.emptySearch),
            .expect("* NOOP", reply: "* 5 EXISTS\r\n{TAG} OK NOOP completed.\r\n"),
            .expect(Self.search, reply: Self.found(12)),
            // Second send: the patient schedule (here one look), found at once.
            .expect("* NOOP", reply: "* 6 EXISTS\r\n{TAG} OK NOOP completed.\r\n"),
            .expect(Self.search, reply: Self.found(13)),
        ])
        let queue = IMAPServiceTransportQueue([first, imap, second])
        let log = IMAPServiceLog()
        let service = F.service(account, transports: queue, options: options([0, 0.05, 5], patient: [0]), log: log)
        try await service.send(message(account))
        var learned = await service.serverSavesSentCopies
        XCTAssertEqual(learned, true)
        XCTAssertTrue(log.text.contains("filed its own copy"))

        try await service.send(message(account))
        learned = await service.serverSavesSentCopies
        XCTAssertEqual(learned, true)
        XCTAssertFalse(imap.transcript.contains("APPEND"), "the server's copy is enough")
        XCTAssertEqual(ids(in: imap.transcript).searched.count, 3)
        XCTAssertEqual(queue.openedCount, 3, "one IMAP connection serves both sends")
    }

    func testAccountWithoutSentFolderGetsOneMadeForTheCopy() async throws {
        let account = F.account(host: "localhost")
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com"]) + T.smtpData)
        let imap = ScriptedTransport(T.greenMailLogin() + [
            .expect("* LIST \"\" \"*\"", reply: "* LIST () \".\" \"INBOX\"\r\n{TAG} OK LIST completed.\r\n"),
            .expect("* CREATE \"Sent\"", reply: "{TAG} OK CREATE completed.\r\n"),
            .expect("* SUBSCRIBE \"Sent\"", reply: "{TAG} OK SUBSCRIBE completed.\r\n"),
            .expect("* LIST \"\" \"*\"", reply: "* LIST () \".\" \"INBOX\"\r\n* LIST () \".\" \"Sent\"\r\n{TAG} OK LIST completed.\r\n"),
            .expect("* APPEND \"Sent\" (\\Seen)", reply: "{TAG} OK [APPENDUID 1792471486 1] APPEND completed.\r\n"),
        ])
        let service = F.service(account, transports: IMAPServiceTransportQueue([smtp, imap]), options: options([0, 1, 1, 2]))
        let started = Date()
        try await service.send(message(account))
        XCTAssertLessThan(Date().timeIntervalSince(started), 1, "no folder to look in, so no waiting")
        XCTAssertFalse(imap.transcript.contains("SEARCH"))
        XCTAssertTrue(imap.transcript.contains("APPEND \"Sent\""))
    }

    func testGmailNeverUploadsEvenWhileLooking() async throws {
        let account = F.account(provider: .other, email: "ada@gmail.com", host: "imap.gmail.com", smtpHost: "smtp.gmail.com",
                                authMethod: .oauth2, savesSentAutomatically: false)
        let token = Credential.oauth(OAuthToken(accessToken: "ya29.a0AfB_token"))
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@gmail.com", recipients: ["grace@gmail.com"],
                                                   auth: "AUTH XOAUTH2 \(T.xoauth2("ada@gmail.com", "ya29.a0AfB_token"))") + T.smtpData)
        let imap = ScriptedTransport(T.gmailLogin())
        let service = F.service(account, credential: token, transports: IMAPServiceTransportQueue([smtp, imap]), options: options([0, 1, 1, 2]))
        try await service.send(message(account, to: "grace@gmail.com"))
        XCTAssertFalse(imap.transcript.contains("APPEND"))
        XCTAssertFalse(imap.transcript.contains("SEARCH"))
        XCTAssertFalse(imap.transcript.contains("LIST"))
    }

    func testUnknownServerIsCheckedEvenWhenTheAccountSaysItFilesCopies() async throws {
        let account = F.account(provider: .other, savesSentAutomatically: true)
        let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com"]) + T.smtpData)
        let imap = ScriptedTransport(T.dovecotLogin() + [
            T.listStep(),
            T.dovecotSelect("Sent", exists: 5, uidNext: 13, modSeq: 9),
            .expect(Self.search, reply: Self.found(12)),
        ])
        let queue = IMAPServiceTransportQueue([smtp, imap])
        let service = F.service(account, transports: queue, options: options([0, 1, 1, 2]))
        try await service.send(message(account))
        XCTAssertEqual(queue.openedCount, 2)
        XCTAssertFalse(imap.transcript.contains("APPEND"))
    }

    func testKnownProvidersThatFileCopiesGetNoIMAPWork() async throws {
        for provider in [ProviderID.yahoo, .aol, .zoho, .outlook, .gmail] {
            let account = F.account(provider: provider, savesSentAutomatically: true)
            let smtp = ScriptedTransport(T.smtpSession(from: "ada@example.com", recipients: ["grace@example.com"]) + T.smtpData)
            let queue = IMAPServiceTransportQueue([smtp])
            let service = F.service(account, transports: queue, options: options([0, 1, 1, 2]))
            try await service.send(message(account))
            XCTAssertEqual(queue.openedCount, 1, "\(provider): no IMAP connection")
        }
    }
}
