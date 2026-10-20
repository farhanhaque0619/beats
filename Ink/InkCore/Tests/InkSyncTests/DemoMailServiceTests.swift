import XCTest
import InkModel
import InkMIME
@testable import InkSync

final class DemoMailServiceTests: XCTestCase {
    let clock = TestClock(referenceDate)
    var calendar: Calendar { Calendar.current }

    private func makeService() -> DemoMailService { DemoMailService(now: clock.function) }

    private func inbox(_ service: DemoMailService) async throws -> [MessageSummary] {
        let boxes = try await service.mailboxes()
        let inbox = try XCTUnwrap(boxes.first { $0.role == .inbox })
        return try await service.sync(mailbox: inbox, previous: nil, limit: 500).upserted
    }

    // MARK: Content

    func testFoldersAndRoles() async throws {
        let boxes = try await makeService().mailboxes()
        XCTAssertEqual(boxes.map(\.role).filter { $0 != .custom }, [.inbox, .drafts, .sent, .archive, .junk, .trash])
        XCTAssertEqual(Set(boxes.filter { $0.role == .custom }.map(\.path)), ["Receipts", "Travel"])
        XCTAssertTrue(boxes.allSatisfy { $0.accountID == "demo" && $0.isSelectable })
    }

    func testInboxLooksLikeARealInbox() async throws {
        let service = makeService()
        let messages = try await inbox(service)
        let conversations = Threader.thread(messages + (await service.messages(in: "Sent")), myAddresses: ["alex@ink.example"])
            .filter { $0.messages.contains { $0.mailboxPath == "INBOX" } }
        XCTAssertGreaterThanOrEqual(conversations.count, 30, "about forty conversations")
        XCTAssertLessThanOrEqual(conversations.count, 60)

        let now = clock.now
        let today = messages.filter { calendar.isDate($0.date, inSameDayAs: now) }
        let yesterday = messages.filter { calendar.isDateInYesterday($0.date, relativeTo: now) }
        let older = messages.filter { $0.date < now.addingTimeInterval(-7 * 86_400) }
        XCTAssertGreaterThanOrEqual(today.count, 4, "several today")
        XCTAssertGreaterThanOrEqual(yesterday.count, 3, "some yesterday")
        XCTAssertGreaterThanOrEqual(older.count, 3, "a tail of older mail")
        XCTAssertTrue(messages.allSatisfy { $0.date <= now }, "nothing from the future")

        let unread = messages.filter(\.isUnread)
        XCTAssertGreaterThanOrEqual(unread.count, 5)
        XCTAssertLessThan(unread.count, messages.count / 2, "a mix, mostly read")
        XCTAssertGreaterThanOrEqual(messages.filter(\.isFlagged).count, 2, "a few starred")
        XCTAssertGreaterThanOrEqual(messages.filter(\.isBulk).count, 6, "newsletters and notifications for Other")
        XCTAssertGreaterThanOrEqual(messages.filter { !$0.isBulk }.count, 15, "real people in Focus")
        XCTAssertTrue(messages.allSatisfy { !$0.snippet.isEmpty && !$0.subject.isEmpty })
        XCTAssertTrue(messages.allSatisfy { $0.from.first?.name?.isEmpty == false }, "every sender has a full name")
    }

    func testOnlyFictionalDomains() async throws {
        let service = makeService()
        var everything: [MessageSummary] = []
        for box in try await service.mailboxes() { everything += await service.messages(in: box.path) }
        for message in everything {
            for person in message.from + message.to + message.cc + message.replyTo {
                XCTAssertTrue(person.domain.hasSuffix(".example"), "\(person.address) must be a reserved example domain")
            }
            if let id = message.messageID { XCTAssertTrue(id.hasSuffix(".example"), id) }
        }
    }

    func testThreadsWithAlexsReplies() async throws {
        let service = makeService()
        let sent = await service.messages(in: "Sent")
        let all = try await inbox(service) + sent
        let conversations = Threader.thread(all, myAddresses: ["alex@ink.example"])
        let withReplies = conversations.filter { conversation in
            conversation.count >= 3 && conversation.messages.contains { $0.from.first?.address == "alex@ink.example" }
        }
        XCTAssertGreaterThanOrEqual(withReplies.count, 2, "multi-message threads where Alex Rivera replied")
        let roadmap = try XCTUnwrap(conversations.first { $0.subject.hasPrefix("Q4 roadmap review") })
        XCTAssertEqual(roadmap.count, 4)
        XCTAssertEqual(roadmap.messages.filter { $0.mailboxPath == "Sent" }.count, 1)
        XCTAssertTrue(roadmap.isUnread)
        XCTAssertEqual(roadmap.messages.last?.references.count, 3, "References grow along the chain")
        XCTAssertTrue(sent.allSatisfy { $0.from.first?.name == "Alex Rivera" })
    }

    func testCalendarInviteHasICS() async throws {
        let service = makeService()
        let inboxMessages = try await inbox(service)
        let invite = try XCTUnwrap(inboxMessages.first { $0.subject.hasPrefix("Invitation:") })
        XCTAssertTrue(invite.hasAttachments)
        let body = try await service.body(for: invite)
        let ics = try XCTUnwrap(body.attachments.first { $0.mimeType == "text/calendar" })
        XCTAssertEqual(ics.filename, "invite.ics")
        let text = String(decoding: try XCTUnwrap(ics.data), as: UTF8.self)
        XCTAssertTrue(text.hasPrefix("BEGIN:VCALENDAR\r\n"))
        XCTAssertTrue(text.contains("METHOD:REQUEST"))
        XCTAssertTrue(text.contains("BEGIN:VEVENT") && text.contains("END:VEVENT"))
        XCTAssertTrue(text.contains("ATTENDEE;") && text.contains("mailto:alex@ink.example"))
        XCTAssertTrue(text.hasSuffix("END:VCALENDAR\r\n"))
        for line in text.components(separatedBy: "\r\n") { XCTAssertLessThanOrEqual(line.utf8.count, 75, line) }
        let start = try XCTUnwrap(text.components(separatedBy: "\r\n").first { $0.hasPrefix("DTSTART:") })
        XCTAssertEqual(start.count, "DTSTART:20261022T140000Z".count)
    }

    func testPDFAttachmentsAreWellFormed() async throws {
        let service = makeService()
        var pdfs: [Attachment] = []
        for message in try await inbox(service) where message.hasAttachments {
            pdfs += try await service.body(for: message).attachments.filter { $0.mimeType == "application/pdf" }
        }
        XCTAssertGreaterThanOrEqual(pdfs.count, 1)
        for pdf in pdfs {
            let bytes = [UInt8](try XCTUnwrap(pdf.data))
            XCTAssertEqual(pdf.size, bytes.count)
            XCTAssertTrue(bytes.starts(with: Array("%PDF-1.4".utf8)))
            let text = String(decoding: bytes, as: UTF8.self)
            XCTAssertTrue(text.hasSuffix("%%EOF\n"))
            // Every xref offset points at its object.
            let xrefStart = try XCTUnwrap(text.range(of: "startxref\n"))
            let offsetLine = text[xrefStart.upperBound...].prefix { $0 != "\n" }
            let xrefOffset = try XCTUnwrap(Int(offsetLine))
            XCTAssertTrue(bytes[xrefOffset...].starts(with: Array("xref".utf8)))
            let table = String(decoding: bytes[xrefOffset...], as: UTF8.self).components(separatedBy: "\n")
            for objectNumber in 1...6 {
                let entry = table[2 + objectNumber]
                let offset = try XCTUnwrap(Int(entry.prefix(10)))
                XCTAssertTrue(bytes[offset...].starts(with: Array("\(objectNumber) 0 obj".utf8)), "object \(objectNumber)")
            }
        }
    }

    func testPNGAttachmentsAreValid() async throws {
        let png = DemoAssets.landscapePNG(width: 24, height: 16, palette: DemoAssets.lake)
        let bytes = [UInt8](png)
        XCTAssertEqual(Array(bytes.prefix(8)), [0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])
        // Walk the chunks and check each CRC.
        var offset = 8
        var types: [String] = []
        while offset + 12 <= bytes.count {
            let length = Int(bytes[offset]) << 24 | Int(bytes[offset + 1]) << 16 | Int(bytes[offset + 2]) << 8 | Int(bytes[offset + 3])
            let type = String(decoding: bytes[(offset + 4)..<(offset + 8)], as: UTF8.self)
            let payload = Array(bytes[(offset + 4)..<(offset + 8 + length)])
            let crcBytes = bytes[(offset + 8 + length)..<(offset + 12 + length)]
            let crc = crcBytes.reduce(UInt32(0)) { $0 << 8 | UInt32($1) }
            XCTAssertEqual(crc, DemoAssets.crc32(payload), type)
            types.append(type)
            offset += 12 + length
        }
        XCTAssertEqual(types, ["IHDR", "IDAT", "IEND"])
        XCTAssertEqual(offset, bytes.count)
        XCTAssertEqual(DemoAssets.adler32(Array("Wikipedia".utf8)), 0x11E6_0398)
        XCTAssertEqual(DemoAssets.crc32(Array("123456789".utf8)), 0xCBF4_3926)
    }

    func testNewslettersAreTastefulSelfContainedHTML() async throws {
        let service = makeService()
        var htmlCount = 0
        for message in try await inbox(service) {
            let body = try await service.body(for: message)
            guard let html = body.html else { continue }
            htmlCount += 1
            XCTAssertEqual(EmailHTMLDocument.countRemoteImages(html), 0, message.subject)
            XCTAssertFalse(html.lowercased().contains("<script"), message.subject)
            XCTAssertFalse(html.contains("src=\"http"), "no remote resources: \(message.subject)")
            XCTAssertTrue(html.contains("style="), "inline CSS: \(message.subject)")
            XCTAssertNotNil(body.plainText, "a text alternative too")
            XCTAssertTrue(EmailHTMLDocument.isDesigned(html), "designed mail keeps its own colours: \(message.subject)")
        }
        XCTAssertGreaterThanOrEqual(htmlCount, 4, "newsletters, receipts, itinerary, statement")
        let all = try await inbox(service)
        let margin = try XCTUnwrap(all.first { $0.subject.hasPrefix("Issue 112") })
        let marginBody = try await service.body(for: margin)
        let html = try XCTUnwrap(marginBody.html)
        XCTAssertTrue(html.contains("src=\"data:image/png;base64,"), "the newsletter's image is embedded, no network")
        XCTAssertGreaterThan(html.count, 4_000, "a long, designed newsletter")
    }

    func testDeterministicForAGivenClock() async throws {
        let a = try await inbox(makeService())
        let b = try await inbox(makeService())
        XCTAssertEqual(a, b)
        let laterClock = TestClock(referenceDate.addingTimeInterval(86_400 * 3))
        let later = try await inbox(DemoMailService(now: laterClock.function))
        func stable(_ list: [MessageSummary]) -> [String] { list.map(\.subject).filter { !$0.hasPrefix("Invitation:") } }
        XCTAssertEqual(stable(a), stable(later), "same mail, dates move with the clock")
        XCTAssertEqual(a.count, later.count)
        XCTAssertNotEqual(a.first?.date, later.first?.date)
    }

    func testEarlyMorningKeepsTodaysMailToday() async throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        let start = utc.startOfDay(for: referenceDate)
        for minutes in [5.0, 45, 200] {
            let now = start.addingTimeInterval(minutes * 60)
            let snapshot = DemoContent.snapshot(account: .demo, now: now, uidValidity: 1, calendar: utc)
            let inbox = snapshot.messages["INBOX"] ?? []
            let today = inbox.filter { utc.isDate($0.date, inSameDayAs: now) }
            XCTAssertGreaterThanOrEqual(today.count, 4, "at \(minutes) minutes past midnight")
            XCTAssertTrue(inbox.allSatisfy { $0.date <= now })
        }
    }

    // MARK: Server behaviour

    func testIncrementalSyncReportsNewFlagsAndRemovals() async throws {
        let service = makeService()
        let boxes = try await service.mailboxes()
        let inboxBox = try XCTUnwrap(boxes.first { $0.role == .inbox })
        let first = try await service.sync(mailbox: inboxBox, previous: nil, limit: 10)
        XCTAssertTrue(first.didReset)
        XCTAssertEqual(first.upserted.count, 10)

        let target = try XCTUnwrap(first.upserted.last)
        try await service.perform(.archive, on: [target])
        let arrived = await service.deliverSampleMessage()
        let second = try await service.sync(mailbox: inboxBox, previous: first.state, limit: 10)
        XCTAssertFalse(second.didReset)
        XCTAssertTrue(second.removedIDs.contains(target.id))
        XCTAssertTrue(second.upserted.contains { $0.id == arrived.id })
        XCTAssertGreaterThan(second.state.uidNext, first.state.uidNext)

        let older = try await service.fetchOlder(mailbox: inboxBox, olderThanUID: first.upserted[0].uid, limit: 5)
        XCTAssertEqual(older.count, 5)
        XCTAssertTrue(older.allSatisfy { $0.uid < first.upserted[0].uid })

        // A stale UIDVALIDITY resets.
        var stale = second.state
        stale.uidValidity &+= 1
        let reset = try await service.sync(mailbox: inboxBox, previous: stale, limit: 10)
        XCTAssertTrue(reset.didReset)
    }

    func testTriageMovesAndFlagsLikeAServer() async throws {
        let service = makeService()
        let messages = try await inbox(service)
        let target = try XCTUnwrap(messages.first { $0.isUnread })
        try await service.perform(.markRead, on: [target])
        try await service.perform(.flag, on: [target])
        var copy = await service.messages(in: "INBOX").first { $0.id == target.id }
        XCTAssertEqual(copy?.isUnread, false)
        XCTAssertEqual(copy?.isFlagged, true)

        try await service.perform(.trash, on: [target])
        let inboxAfterTrash = await service.messages(in: "INBOX")
        XCTAssertNil(inboxAfterTrash.first { $0.id == target.id })
        let trashed = await service.messages(in: "Trash").first { $0.messageID == target.messageID }
        XCTAssertNotNil(trashed)
        XCTAssertNotEqual(trashed?.uid, target.uid)

        // moveToInbox finds the message by Message-ID even with the stale (INBOX) summary.
        try await service.perform(.moveToInbox, on: [target])
        copy = await service.messages(in: "INBOX").first { $0.messageID == target.messageID }
        XCTAssertNotNil(copy)
        let trashAfter = await service.messages(in: "Trash")
        XCTAssertNil(trashAfter.first { $0.messageID == target.messageID })

        try await service.perform(.move(toPath: "Receipts"), on: [try XCTUnwrap(copy)])
        let receipts = await service.messages(in: "Receipts")
        XCTAssertNotNil(receipts.first { $0.messageID == target.messageID })
        do {
            try await service.perform(.move(toPath: "No Such Folder"), on: [target])
            XCTFail("expected mailboxNotFound")
        } catch let error as MailError {
            XCTAssertEqual(error, .mailboxNotFound("No Such Folder"))
        }
    }

    func testSendFilesInSentMarksParentAnsweredAndDeliversToSelf() async throws {
        let service = makeService()
        let inboxMessages = try await inbox(service)
        let parent = try XCTUnwrap(inboxMessages.first { $0.subject == "Dinner Saturday?" })
        var reply = OutgoingMessage(accountID: "demo", from: AccountConfig.demo.address, to: parent.from, subject: "Re: Dinner Saturday?",
                                    body: "We're in!", inReplyTo: parent.messageID, references: [], replyMode: .reply)
        try await service.send(reply)
        let sent = await service.messages(in: "Sent")
        let filed = try XCTUnwrap(sent.last)
        XCTAssertEqual(filed.subject, "Re: Dinner Saturday?")
        XCTAssertEqual(filed.inReplyTo, [parent.messageID ?? ""])
        XCTAssertEqual(filed.references, [parent.messageID ?? ""])
        XCTAssertFalse(filed.isUnread)
        let inboxAfterReply = await service.messages(in: "INBOX")
        XCTAssertEqual(inboxAfterReply.first { $0.id == parent.id }?.flags.contains(.answered), true)

        reply.id = UUID()
        reply.to = [AccountConfig.demo.address]
        reply.subject = "Note to self"
        let before = await service.messages(in: "INBOX").count
        try await service.send(reply)
        let after = await service.messages(in: "INBOX").count
        XCTAssertEqual(after, before + 1)

        do {
            try await service.send(OutgoingMessage(accountID: "demo", from: AccountConfig.demo.address, to: [EmailAddress(address: "not an address")]))
            XCTFail("expected sendFailed")
        } catch let error as MailError {
            guard case .sendFailed = error else { return XCTFail("\(error)") }
        }
    }

    func testSearchAndBodies() async throws {
        let service = makeService()
        let boxes = try await service.mailboxes()
        let inboxBox = try XCTUnwrap(boxes.first { $0.role == .inbox })
        let hits = try await service.search("lisbon itinerary", in: inboxBox, limit: 10)
        XCTAssertTrue(hits.contains { $0.subject.contains("Lisbon") })
        let blank = try await service.search("   ", in: inboxBox, limit: 10)
        XCTAssertTrue(blank.isEmpty)
        let nothing = try await service.search("zzzz-nothing", in: inboxBox, limit: 10)
        XCTAssertTrue(nothing.isEmpty)

        let message = try XCTUnwrap(hits.first)
        let body = try await service.body(for: message)
        XCTAssertEqual(body.messageID, message.id)
        var ghost = message
        ghost.messageID = "nobody@nowhere.example"
        ghost.uid = 9_999
        do {
            _ = try await service.body(for: ghost)
            XCTFail("expected messageNotFound")
        } catch let error as MailError {
            XCTAssertEqual(error, .messageNotFound)
        }
    }

    func testWatchYieldsWhenMailArrives() async throws {
        let service = makeService()
        let boxes = try await service.mailboxes()
        let inboxBox = try XCTUnwrap(boxes.first { $0.role == .inbox })
        let stream = service.watch(mailbox: inboxBox)
        let heard = ChangeRecorder()
        let listener = Task {
            for await change in stream {
                heard.record(change)
                return
            }
        }
        // The watcher registers asynchronously; keep delivering until it hears something.
        for _ in 0..<150 where heard.first == nil {
            await service.deliverSampleMessage()
            try await Task.sleep(nanoseconds: 20_000_000)
        }
        listener.cancel()
        XCTAssertEqual(heard.first, .changed)
    }

    func testVerifyReportsEveryStep() async throws {
        let steps = StepRecorder()
        try await makeService().verify { steps.append($0) }
        XCTAssertEqual(steps.all, VerificationStep.allCases)
    }
}

final class ChangeRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var changes: [MailboxChange] = []
    func record(_ change: MailboxChange) { lock.withLock { changes.append(change) } }
    var first: MailboxChange? { lock.withLock { changes.first } }
}

final class StepRecorder: @unchecked Sendable {
    private let lock = NSLock()
    private var steps: [VerificationStep] = []
    func append(_ step: VerificationStep) { lock.withLock { steps.append(step) } }
    var all: [VerificationStep] { lock.withLock { steps } }
}

private extension Calendar {
    func isDateInYesterday(_ date: Date, relativeTo now: Date) -> Bool {
        guard let yesterday = self.date(byAdding: .day, value: -1, to: now) else { return false }
        return isDate(date, inSameDayAs: yesterday)
    }
}
