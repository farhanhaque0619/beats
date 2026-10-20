import XCTest
import InkModel
@testable import InkSync

final class MailCacheTests: XCTestCase {
    private func sampleMailbox(account: String = "acct", path: String = "INBOX", count: Int = 3) -> CachedMailbox {
        let messages = (0..<count).map { index in
            summary(account: account, mailbox: path, uid: UInt32(100 + index), messageID: "m\(index)@x.example", subject: "Subject \(index) — ünïcödé",
                    from: address("Priya", "priya@fieldstone.example"), date: referenceDate - Double(index) * 60)
        }
        return CachedMailbox(accountID: account, path: path,
                             state: MailboxSyncState(uidValidity: 1, uidNext: 200, highestModSeq: 9_876_543_210, knownUIDs: messages.map(\.uid), lastSync: referenceDate),
                             messages: messages, savedAt: referenceDate)
    }

    func testRoundTripMailboxesStateAndSummaries() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0.01)
        let folders = [MailboxInfo(accountID: "acct", path: "INBOX", role: .inbox),
                       MailboxInfo(accountID: "acct", path: "Projects/Ink & Co", rawPath: "Projects/Ink &- Co", role: .custom)]
        cache.saveMailboxes(folders, accountID: "acct")
        cache.saveMailbox(sampleMailbox())
        cache.saveMailbox(sampleMailbox(path: "Projects/Ink & Co", count: 1))
        await cache.flush()

        let reread = await MailCache(storageDirectory: directory).loadAccount("acct")
        XCTAssertEqual(reread.mailboxes, folders)
        XCTAssertEqual(reread.mailboxContents.count, 2)
        let inbox = reread.mailboxContents.first { $0.path == "INBOX" }
        XCTAssertEqual(inbox, sampleMailbox())
        XCTAssertEqual(inbox?.state?.highestModSeq, 9_876_543_210)
    }

    func testFilesLiveUnderCacheAccountFolderWithHashedNames() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0)
        cache.saveMailbox(sampleMailbox(path: "../../etc/passwd"))
        await cache.flush()
        let folder = directory.appendingPathComponent("cache/acct")
        let files = try FileManager.default.contentsOfDirectory(atPath: folder.path)
        XCTAssertEqual(files.count, 1)
        XCTAssertTrue(files[0].hasPrefix("mailbox-") && files[0].hasSuffix(".json"))
        XCTAssertFalse(files[0].contains("/"))
        // Weird account IDs become safe folder names.
        XCTAssertEqual(MailCache.safeComponent("demo"), "demo")
        XCTAssertTrue(MailCache.safeComponent("../x").hasPrefix("a-"))
        XCTAssertTrue(MailCache.safeComponent("").hasPrefix("a-"))
        XCTAssertTrue(MailCache.safeComponent("Ünï/cödé").hasPrefix("a-"))
    }

    func testWritesAreCoalescedLastOneWins() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0.2)
        for count in 1...20 { cache.saveMailbox(sampleMailbox(count: count)) }
        let file = cache.mailboxURL(accountID: "acct", path: "INBOX")
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "debounced: nothing written yet")
        await cache.flush()
        let reread = await cache.loadAccount("acct")
        XCTAssertEqual(reread.mailboxContents.first?.messages.count, 20)
    }

    func testDebounceWritesEventuallyWithoutFlush() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0.05)
        cache.saveMailbox(sampleMailbox())
        let file = cache.mailboxURL(accountID: "acct", path: "INBOX")
        let written = await waitFor(3) { FileManager.default.fileExists(atPath: file.path) }
        XCTAssertTrue(written)
    }

    func testCorruptAndForeignFilesAreIgnored() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0)
        cache.saveMailbox(sampleMailbox())
        await cache.flush()
        let folder = directory.appendingPathComponent("cache/acct", isDirectory: true)
        try Data("{\"accountID\": \"acct\", \"path\": tru".utf8).write(to: folder.appendingPathComponent("mailbox-broken.json"))
        try Data([0xFF, 0x00, 0x13]).write(to: folder.appendingPathComponent("mailboxes.json"))
        // A file copied from another account must not be adopted.
        let foreign = sampleMailbox(account: "other")
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .secondsSince1970
        try encoder.encode(foreign).write(to: folder.appendingPathComponent("mailbox-foreign.json"))

        let reread = await cache.loadAccount("acct")
        XCTAssertNil(reread.mailboxes)
        XCTAssertEqual(reread.mailboxContents.count, 1)
        XCTAssertEqual(reread.mailboxContents.first?.accountID, "acct")
        let missing = await cache.loadJSON([String].self, from: directory.appendingPathComponent("nope.json"))
        XCTAssertNil(missing)
    }

    func testBodiesStoreSmallAttachmentsAndDropHugeOnes() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0)
        let small = Attachment(id: "2", filename: "invite.ics", mimeType: "text/calendar", size: 12, data: Data("BEGIN:VCALENDAR".utf8))
        let huge = Attachment(id: "3", filename: "video.mov", mimeType: "video/quicktime", size: MailCache.maxStoredAttachmentBytes + 1,
                              data: Data(count: MailCache.maxStoredAttachmentBytes + 1))
        let body = MessageBody(messageID: "acct|INBOX|1|5", plainText: "Hello", html: "<p>Hello</p>", attachments: [small, huge], fetchedAt: referenceDate)
        cache.saveBody(body, key: "acct|mid:x@y", accountID: "acct")
        // Readable before the write lands (served from the pending queue)…
        XCTAssertEqual(cache.loadBody(key: "acct|mid:x@y", accountID: "acct")?.plainText, "Hello")
        await cache.flush()
        // …and after, from disk.
        let reread = MailCache(storageDirectory: directory).loadBody(key: "acct|mid:x@y", accountID: "acct")
        XCTAssertEqual(reread?.html, "<p>Hello</p>")
        XCTAssertEqual(reread?.attachments.first?.data, small.data)
        XCTAssertNil(reread?.attachments.last?.data, "big attachments are re-downloaded instead")
        XCTAssertEqual(reread?.attachments.last?.size, huge.size)
        XCTAssertNil(cache.loadBody(key: "missing", accountID: "acct"))
    }

    func testRemoveAccountDropsFilesAndPendingWrites() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0)
        cache.saveMailbox(sampleMailbox())
        await cache.flush()
        cache.saveMailbox(sampleMailbox(count: 5))
        cache.removeAccount("acct")
        await cache.flush()
        XCTAssertFalse(FileManager.default.fileExists(atPath: directory.appendingPathComponent("cache/acct").path))
        let reread = await cache.loadAccount("acct")
        XCTAssertTrue(reread.mailboxContents.isEmpty)
    }

    func testRemoveMailboxAndScheduleJSONElsewhere() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0)
        cache.saveMailbox(sampleMailbox())
        cache.scheduleJSON(["a", "b"], to: directory.appendingPathComponent("state.json"))
        await cache.flush()
        cache.removeMailbox(accountID: "acct", path: "INBOX")
        await cache.flush()
        let reread = await cache.loadAccount("acct")
        XCTAssertTrue(reread.mailboxContents.isEmpty)
        let state = await cache.loadJSON([String].self, from: directory.appendingPathComponent("state.json"))
        XCTAssertEqual(state, ["a", "b"])
    }

    func testAtomicWriteLeavesNoTemporaryFiles() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0)
        for round in 0..<5 {
            cache.saveMailbox(sampleMailbox(count: round + 1))
            await cache.flush()
        }
        let files = try FileManager.default.contentsOfDirectory(atPath: directory.appendingPathComponent("cache/acct").path)
        XCTAssertEqual(files, files.filter { $0.hasSuffix(".json") })
        XCTAssertEqual(files.count, 1)
    }

    func testConcurrentSchedulingFromManyThreads() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0.01)
        await withTaskGroup(of: Void.self) { group in
            for index in 0..<50 {
                let box = sampleMailbox(path: "Folder \(index % 10)", count: index % 4 + 1)
                group.addTask { cache.saveMailbox(box) }
            }
        }
        await cache.flush()
        let reread = await cache.loadAccount("acct")
        XCTAssertEqual(reread.mailboxContents.count, 10)
    }

    func testPruningKeepsTheNewestBodiesWithinTheLimit() async throws {
        let directory = try makeTemporaryDirectory()
        let cache = MailCache(storageDirectory: directory, debounceInterval: 0)
        let text = String(repeating: "Lorem ipsum dolor sit amet. ", count: 40)
        for index in 0..<6 { cache.saveBody(MessageBody(messageID: "m\(index)", plainText: text), key: "k\(index)", accountID: "acct") }
        cache.saveBody(MessageBody(messageID: "other", plainText: text), key: "k0", accountID: "other")
        await cache.flush()
        // Written an hour apart, k5 most recently.
        for index in 0..<6 {
            try FileManager.default.setAttributes([.modificationDate: referenceDate.addingTimeInterval(Double(index) * 3_600)],
                                                  ofItemAtPath: cache.bodyURL(accountID: "acct", key: "k\(index)").path)
        }
        let size = try XCTUnwrap(FileManager.default.attributesOfItem(atPath: cache.bodyURL(accountID: "acct", key: "k0").path)[.size] as? Int)

        await cache.pruneBodies(accountID: "acct", maxBytes: size * 2 + size / 2)
        let kept = (0..<6).filter { cache.loadBody(key: "k\($0)", accountID: "acct") != nil }
        XCTAssertEqual(kept, [4, 5], "the two most recent fit")
        XCTAssertNotNil(cache.loadBody(key: "k0", accountID: "other"), "other accounts are untouched")

        await cache.pruneBodies(accountID: "acct", maxBytes: 0)
        XCTAssertNil(cache.loadBody(key: "k5", accountID: "acct"))
        await cache.pruneBodies(accountID: "missing", maxBytes: 0)
    }
}
