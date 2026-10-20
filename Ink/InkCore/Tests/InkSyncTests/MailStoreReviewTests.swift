import XCTest
import InkModel
@testable import InkSync

/// Regression tests from the adversarial review of `MailStore`: snoozed conversations acted on
/// from the Snoozed list or after new mail arrived in them, paging racing a sync, triage on
/// server-search results, and demo mail across relaunches.
@MainActor
final class MailStoreReviewTests: XCTestCase {
    private func inboxReply(to parent: MessageSummary, id: String, subject: String? = nil) -> MessageSummary {
        let root = parent.messageID ?? "missing@example"
        return summary(account: parent.accountID, uid: 0, messageID: id, inReplyTo: [root], references: parent.references + [root],
                       subject: subject ?? "Re: \(parent.subject)", from: parent.from.first ?? address("Grace", "grace.o@mailbox.example"),
                       date: referenceDate.addingTimeInterval(60), flags: [], snippet: "A new reply")
    }

    // MARK: Snoozed conversations

    func testTrashingASnoozedConversationTrashesItsArchivedCopy() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first { !$0.isBulk })
        let messageID = try XCTUnwrap(target.latest?.messageID)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(86_400))
        await store.flushPendingActions()
        var archive = await fake.messages(in: "Archive")
        XCTAssertTrue(archive.contains { $0.messageID == messageID }, "archived on the server while snoozed")

        store.scope = .unified(.snoozed)
        let snoozed = try XCTUnwrap(store.conversations.first { $0.id == target.id })
        store.trash([snoozed])
        XCTAssertEqual(store.toast?.message, "Moved to Trash")
        XCTAssertTrue(store.conversations.isEmpty)
        await store.flushPendingActions()
        await store.waitUntilIdle()

        let trash = await fake.messages(in: "Trash")
        archive = await fake.messages(in: "Archive")
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertTrue(trash.contains { $0.messageID == messageID }, "the archived copy went to Trash")
        XCTAssertFalse(archive.contains { $0.messageID == messageID })
        XCTAssertFalse(inbox.contains { $0.messageID == messageID })
        XCTAssertNil(store.snoozeDate(for: target))
        XCTAssertNotEqual(store.toast?.style, .error)
    }

    func testMovingASnoozedConversationFindsCopiesOutsideTheArchiveWindow() async throws {
        let (harness, account, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first { !$0.isBulk })
        let messageID = try XCTUnwrap(target.latest?.messageID)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(86_400))
        await store.flushPendingActions()
        // Lots of archiving since: the snoozed message is no longer among the newest in Archive.
        for index in 0..<(MailStore.folderWindow + 10) {
            await fake.deliver(summary(account: account.id, uid: 0, messageID: "filler-\(index)@example.org",
                                       subject: "Filler \(index)", from: address("Dev Mehta", "dev@thebuildlog.example"),
                                       date: referenceDate.addingTimeInterval(Double(index))), to: "Archive")
        }

        store.scope = .unified(.snoozed)
        let snoozed = try XCTUnwrap(store.conversations.first { $0.id == target.id })
        let projects = try XCTUnwrap(store.mailboxes(for: account.id).first { $0.path == "Projects" })
        store.move([snoozed], to: projects)
        XCTAssertEqual(store.toast?.message, "Moved to Projects")
        await store.flushPendingActions()
        await store.waitUntilIdle()

        let filed = await fake.messages(in: "Projects")
        let archive = await fake.messages(in: "Archive")
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertTrue(filed.contains { $0.messageID == messageID }, "filed where asked")
        XCTAssertFalse(archive.contains { $0.messageID == messageID })
        XCTAssertFalse(inbox.contains { $0.messageID == messageID })
        XCTAssertFalse(store.allConversations(for: .allInboxes).contains { $0.messages.contains { $0.messageID == messageID } })
    }

    func testArchivingASnoozedThreadWithNewMailArchivesTheNewMail() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first { !$0.isBulk })
        let latest = try XCTUnwrap(target.latest)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(86_400))
        await store.flushPendingActions()

        // Someone replies while it's snoozed: the thread shows in the inbox again.
        let reply = await fake.deliver(inboxReply(to: latest, id: "reply-1@mailbox.example"))
        await store.refresh()
        let shown = try XCTUnwrap(store.conversations.first { $0.id == target.id }, "the new reply is in the inbox")
        XCTAssertTrue(shown.messages.contains { $0.messageID == reply.messageID })

        store.archive([shown])
        XCTAssertEqual(store.toast?.message, "Archived")
        XCTAssertFalse(store.conversations.contains { $0.id == target.id }, "gone from the list right away")
        await store.flushPendingActions()
        await store.refresh()
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertFalse(inbox.contains { $0.messageID == reply.messageID }, "the new reply was archived too")
        XCTAssertFalse(store.conversations.contains { $0.id == target.id })
        XCTAssertNil(store.snoozeDate(for: target))
    }

    func testSnoozingAgainAfterNewMailSnoozesTheNewMailToo() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first { !$0.isBulk })
        let latest = try XCTUnwrap(target.latest)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(86_400))
        await store.flushPendingActions()

        let reply = await fake.deliver(inboxReply(to: latest, id: "reply-2@mailbox.example"))
        await store.refresh()
        let shown = try XCTUnwrap(store.conversations.first { $0.id == target.id })

        let later = harness.clock.now.addingTimeInterval(2 * 86_400)
        store.snooze([shown], until: later)
        XCTAssertFalse(store.conversations.contains { $0.id == target.id }, "hidden again right away")
        XCTAssertEqual(store.snoozeDate(for: target), later)
        await store.flushPendingActions()
        await store.refresh()
        XCTAssertFalse(store.conversations.contains { $0.id == target.id }, "and stays hidden after a refresh")
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertFalse(inbox.contains { $0.messageID == reply.messageID }, "the reply was archived on the server")
        let record = try XCTUnwrap(store.snoozedConversations.first { $0.id == target.id })
        XCTAssertTrue(record.messages.contains { $0.messageID == reply.messageID }, "and comes back with the rest")

        // Undo puts the first snooze back: the reply shows in the inbox again.
        store.undoWindow = 30
        await fake.deliver(inboxReply(to: latest, id: "reply-3@mailbox.example"))
        await store.refresh()
        let shownAgain = try XCTUnwrap(store.conversations.first { $0.id == target.id })
        store.snooze([shownAgain], until: later.addingTimeInterval(3_600))
        store.undo()
        XCTAssertTrue(store.conversations.contains { $0.id == target.id })
        XCTAssertEqual(store.snoozeDate(for: target), later)
        XCTAssertFalse(store.snoozedConversations.first { $0.id == target.id }?.messages.contains { $0.messageID == "reply-3@mailbox.example" } ?? true)

        harness.clock.advance(3 * 86_400)
        await store.wakeDueSnoozes()
        await store.waitUntilIdle()
        let woken = try XCTUnwrap(store.conversations.first { $0.id == target.id })
        XCTAssertTrue(woken.messages.contains { $0.messageID == reply.messageID })
        XCTAssertTrue(woken.messages.contains { $0.messageID == latest.messageID })
    }

    func testTrashingFromSnoozedTakesNewRepliesInTheInboxToo() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first { !$0.isBulk })
        let latest = try XCTUnwrap(target.latest)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(86_400))
        await store.flushPendingActions()
        let reply = await fake.deliver(inboxReply(to: latest, id: "reply-4@mailbox.example"))
        await store.refresh()
        XCTAssertTrue(store.conversations.contains { $0.id == target.id })

        // Changing the snooze time from the Snoozed list snoozes the reply as well.
        store.scope = .unified(.snoozed)
        store.snooze([try XCTUnwrap(store.conversations.first { $0.id == target.id })], until: harness.clock.now.addingTimeInterval(2 * 86_400))
        await store.flushPendingActions()
        var inbox = await fake.messages(in: "INBOX")
        XCTAssertFalse(inbox.contains { $0.messageID == reply.messageID }, "re-snoozed with the rest")
        XCTAssertFalse(store.allConversations(for: .allInboxes).contains { $0.id == target.id })

        let another = await fake.deliver(inboxReply(to: latest, id: "reply-5@mailbox.example"))
        store.scope = .allInboxes
        await store.refresh()
        XCTAssertTrue(store.conversations.contains { $0.id == target.id })
        store.scope = .unified(.snoozed)
        store.trash([try XCTUnwrap(store.conversations.first { $0.id == target.id })])
        await store.flushPendingActions()
        await store.waitUntilIdle()
        inbox = await fake.messages(in: "INBOX")
        let trash = await fake.messages(in: "Trash")
        XCTAssertFalse(inbox.contains { $0.messageID == another.messageID }, "the new reply was trashed too")
        XCTAssertTrue(trash.contains { $0.messageID == another.messageID })
        XCTAssertTrue(trash.contains { $0.messageID == latest.messageID })
        XCTAssertTrue(trash.contains { $0.messageID == reply.messageID })
        XCTAssertFalse(store.allConversations(for: .allInboxes).contains { $0.id == target.id })
    }

    func testStarringASnoozedConversationStarsItOnTheServer() async throws {
        let (harness, _, fake) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first { !$0.isBulk && !$0.isFlagged })
        let messageID = try XCTUnwrap(target.latest?.messageID)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(3_600))
        await store.flushPendingActions()

        store.scope = .unified(.snoozed)
        let snoozed = try XCTUnwrap(store.conversations.first { $0.id == target.id })
        store.toggleFlag([snoozed])
        XCTAssertEqual(store.toast?.message, "Starred")
        XCTAssertEqual(store.conversations.first { $0.id == target.id }?.isFlagged, true)
        await store.flushPendingActions()
        await store.waitUntilIdle()
        let archived = await fake.messages(in: "Archive").first { $0.messageID == messageID }
        XCTAssertEqual(archived?.isFlagged, true, "the archived copy on the server is starred")
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertFalse(inbox.contains { $0.messageID == messageID }, "starring doesn't unsnooze it")

        harness.clock.advance(7_200)
        await store.wakeDueSnoozes()
        await store.waitUntilIdle()
        store.scope = .allInboxes
        XCTAssertEqual(store.conversations.first { $0.id == target.id }?.isFlagged, true, "still starred after it wakes")
    }

    func testRemovingAnAccountTakesItsUndoToastWithIt() async throws {
        let (harness, account, _) = try await fakeHarness()
        let store = harness.store
        await store.addDemoAccount()
        await store.waitUntilIdle()
        store.undoWindow = 600
        store.undoSendDelay = 600
        store.scope = .account(accountID: "demo", role: .inbox)
        store.inboxFilter = .everything
        let demoThread = try XCTUnwrap(store.conversations.first)
        store.archive([demoThread])
        var message = store.newDraft(accountID: account.id)
        message.to = [address("Grace", "grace.o@mailbox.example")]
        store.send(message)
        XCTAssertEqual(store.toast?.message, "Sending…")

        await store.removeAccount(id: account.id)
        XCTAssertNotEqual(store.toast?.undoable, true, "no Undo button for a message that's gone")
        store.dismissToast()
        store.undo()
        XCTAssertTrue(store.conversations.contains { $0.id == demoThread.id }, "undo still reverts the archive")
    }

    // MARK: Paging vs sync

    func testPagingDuringASyncKeepsPagedMailInTheSyncWindow() async throws {
        let (harness, account, fake) = try await fakeHarness(inboxCount: 130)
        let store = harness.store
        store.inboxFilter = .everything
        XCTAssertEqual(store.conversations.count, MailStore.inboxWindow)

        // A slow sync starts (an IDLE event, say), and older mail is paged in while it runs.
        await fake.delaySync(0.4)
        let syncing = Task { await store.refresh() }
        try await Task.sleep(nanoseconds: 100_000_000)
        await store.loadMore()
        XCTAssertEqual(store.conversations.count, 130)
        await syncing.value
        await fake.delaySync(0)
        XCTAssertEqual(store.conversations.count, 130)

        // The oldest paged message is deleted elsewhere and another is starred: the next sync sees both.
        let paged = await fake.messages(in: "INBOX").sorted { $0.uid < $1.uid }
        let deleted = try XCTUnwrap(paged.first)
        let starred = paged[1]
        try await fake.perform(.deletePermanently, on: [deleted])
        try await fake.perform(.flag, on: [starred])
        harness.clock.advance(120)
        await store.refresh()
        let cached = store.messages(accountID: account.id, path: "INBOX")
        XCTAssertFalse(cached.contains { $0.messageID == deleted.messageID }, "no ghost of a deleted message")
        XCTAssertEqual(cached.first { $0.messageID == starred.messageID }?.isFlagged, true, "flags of paged mail stay in sync")
        XCTAssertEqual(store.conversations.count, 129)
    }

    // MARK: Search results

    func testTriagedSearchResultsLeaveSearchUntilUndone() async throws {
        let (harness, account, fake) = try await fakeHarness()
        let store = harness.store
        store.undoWindow = 30
        let filed = await fake.deliver(summary(account: account.id, uid: 0, messageID: "minutes-7@fieldstone.example",
                                               subject: "Quarterly board minutes", from: address("Hannah Park", "hannah.park@fieldstone.example"),
                                               date: referenceDate.addingTimeInterval(-40 * 86_400)), to: "Archive")
        let results = try await store.searchServer("Quarterly")
        let hit = try XCTUnwrap(results.first { $0.messages.contains { $0.messageID == filed.messageID } })
        XCTAssertFalse(store.searchLocal("quarterly").isEmpty)

        store.trash([hit])
        XCTAssertEqual(store.toast?.message, "Moved to Trash")
        XCTAssertTrue(store.searchLocal("quarterly").isEmpty, "trashed mail leaves search right away")
        XCTAssertNil(store.conversation(id: hit.id), "and the reader lets go of it")

        store.undo()
        XCTAssertFalse(store.searchLocal("quarterly").isEmpty, "undo brings it back")
        XCTAssertNotNil(store.conversation(id: hit.id))

        store.trash([hit])
        await store.flushPendingActions()
        let trash = await fake.messages(in: "Trash")
        XCTAssertTrue(trash.contains { $0.messageID == filed.messageID })
        XCTAssertTrue(store.searchLocal("quarterly").isEmpty)
    }

    // MARK: New-mail notifications

    func testFirstMailToAnEmptyInboxIsNews() async throws {
        let (harness, account, fake) = try await fakeHarness(inboxCount: 0)
        let store = harness.store
        let none = await store.refreshAllInboxes()
        XCTAssertTrue(none.isEmpty)

        let arrived = await fake.deliver(summary(account: account.id, uid: 0, messageID: "hello@mailbox.example", subject: "Hello there",
                                                 from: address("Grace Oyelaran", "grace.o@mailbox.example"),
                                                 date: referenceDate, flags: []))
        harness.clock.advance(120)
        await store.refresh() // seen by a foreground sync first
        let news = await store.refreshAllInboxes()
        XCTAssertEqual(news.map(\.messageID), [arrived.messageID])
    }

    // MARK: Demo

    func testDemoMailIsNotNewsAfterARelaunch() async throws {
        let first = try await demoHarness()
        let baseline = await first.store.refreshAllInboxes()
        XCTAssertTrue(baseline.isEmpty)
        await first.store.flushPendingActions()

        // The next day the app is launched again (in the background, say): a fresh demo session.
        first.clock.advance(86_400)
        let second = try makeHarness(directory: first.directory, clock: first.clock)
        await second.store.load()
        await second.store.waitUntilIdle()
        let news = await second.store.refreshAllInboxes()
        XCTAssertEqual(news.map(\.subject), [], "the sample inbox never brings news")

        // Mail that really arrives in this session still counts.
        let arrived = await second.demo.deliverSampleMessage()
        let fresh = await second.store.refreshAllInboxes()
        XCTAssertEqual(fresh.map(\.messageID), [arrived.messageID])
    }

    func testDemoRelaunchWithinAMinuteStartsAFreshSession() async throws {
        let first = try await demoHarness()
        let count = first.store.allConversations(for: .allInboxes).count
        let dinner = try XCTUnwrap(first.store.conversations.first { $0.subject == "Dinner Saturday?" })
        first.store.archive([dinner])
        await first.store.flushPendingActions()
        first.clock.advance(5)
        await first.store.refresh()
        await first.store.flushPendingActions()

        // Quit and reopened a few seconds later: a new sample session, not a mix of the two.
        first.clock.advance(10)
        let second = try makeHarness(directory: first.directory, clock: first.clock)
        await second.store.load()
        await second.store.waitUntilIdle()
        XCTAssertEqual(second.store.allConversations(for: .allInboxes).count, count)
        XCTAssertTrue(second.store.allConversations(for: .allInboxes).contains { $0.subject == "Dinner Saturday?" })
    }

    func testDemoSearchMatchesPartsOfWordsAcrossLines() async throws {
        let demo = DemoMailService(now: { referenceDate })
        let inbox = MailboxInfo(accountID: "demo", path: "INBOX", role: .inbox)
        let ramen = try await demo.search("RAMEN alder", in: inbox, limit: 10)
        XCTAssertEqual(ramen.map(\.subject), ["Dinner Saturday?"])
        let partial = try await demo.search("tonkots", in: inbox, limit: 10)
        XCTAssertEqual(partial.map(\.subject), ["Dinner Saturday?"], "body text, part of a word")
        let none = try await demo.search("ramen zzqx", in: inbox, limit: 10)
        XCTAssertTrue(none.isEmpty)
        XCTAssertTrue(DemoMailService.bytes(Array("a\r\nb".utf8), contain: Array("\nb".utf8)))
        XCTAssertFalse(DemoMailService.bytes(Array("ab".utf8), contain: Array("abc".utf8)))
    }

    func testDemoCalendarReferencesHoldAllYear() throws {
        var utc = Calendar(identifier: .gregorian)
        utc.timeZone = TimeZone(identifier: "UTC") ?? .current
        func matches(_ pattern: String, in text: String) -> [String] {
            let regex = try? NSRegularExpression(pattern: pattern)
            let range = NSRange(text.startIndex..., in: text)
            return regex?.matches(in: text, range: range).compactMap { match in
                Range(match.range(at: 1), in: text).map { String(text[$0]) }
            } ?? []
        }
        /// True when a day numbered `day` within `days` after `date` falls on `weekday`.
        func isWeekday(_ weekday: Int, day: Int, within days: Int, after date: Date) -> Bool {
            (0...days).contains { offset in
                let candidate = utc.date(byAdding: .day, value: offset, to: date) ?? date
                return utc.component(.day, from: candidate) == day && utc.component(.weekday, from: candidate) == weekday
            }
        }
        for step in 0..<24 {
            let now = referenceDate.addingTimeInterval(Double(step) * 31 * 86_400 + Double(step % 5) * 3_600)
            let snapshot = DemoContent.snapshot(account: .demo, now: now, uidValidity: 1, calendar: utc)
            let inbox = snapshot.messages["INBOX"] ?? []
            func body(_ subjectPrefix: String) throws -> (MessageSummary, String) {
                let message = try XCTUnwrap(inbox.first { $0.subject.hasPrefix(subjectPrefix) }, "\(subjectPrefix) at \(now)")
                return (message, snapshot.bodies[message.messageID?.lowercased() ?? ""]?.plainText ?? "")
            }
            XCTAssertTrue(inbox.allSatisfy { $0.date <= now }, "nothing from the future at \(now)")

            // The roadmap review: this quarter, on a weekday still ahead.
            let roadmap = try XCTUnwrap(inbox.first { $0.subject.contains("roadmap review") })
            let quarter = (utc.component(.month, from: now) - 1) / 3 + 1
            XCTAssertTrue(roadmap.subject.hasPrefix("Q\(quarter) roadmap review"), roadmap.subject)
            let reviewDay = try XCTUnwrap(roadmap.subject.components(separatedBy: "draft for ").last)
            let names = [2: "Monday", 3: "Tuesday", 4: "Wednesday", 5: "Thursday", 6: "Friday"]
            XCTAssertTrue((2...6).contains { offset in
                let day = utc.date(byAdding: .day, value: offset, to: now) ?? now
                return names[utc.component(.weekday, from: day)] == reviewDay
            }, "\(reviewDay) is a workday a few days after \(now)")

            // Named weekdays fall on the days they're paired with.
            let (digest, digestText) = try body("This week near Alder Street")
            let partyDays = matches("Saturday the (\\d+)", in: digestText)
            XCTAssertEqual(partyDays.count, 1)
            for day in partyDays {
                XCTAssertTrue(isWeekday(7, day: Int(day) ?? 0, within: 24, after: digest.date), "block party at \(now)")
            }
            let (club, clubText) = try body("Book club:")
            let clubDays = matches("Sunday the (\\d+)", in: clubText)
            XCTAssertEqual(clubDays.count, 1)
            for day in clubDays {
                XCTAssertTrue(isWeekday(1, day: Int(day) ?? 0, within: 62, after: club.date), "book club at \(now)")
            }
            let (rota, rotaText) = try body("Volunteer schedule for")
            let shiftDays = matches("on the (\\d+)(?:st|nd|rd|th) and", in: rotaText) + matches("and (\\d+)(?:st|nd|rd|th), packing", in: rotaText)
            XCTAssertEqual(shiftDays.count, 2)
            for day in shiftDays {
                XCTAssertTrue(isWeekday(7, day: Int(day) ?? 0, within: 62, after: rota.date), "food bank shift at \(now)")
            }
        }
    }

    func testDemoSnippetsHandleCRLFText() {
        let text = "Sounds good — see you at 7.\r\n\r\n> On Tue, Sam wrote:\r\n> Dinner Saturday?\r\n"
        XCTAssertEqual(DemoBuilder.snippet(from: text), "Sounds good — see you at 7.")
    }
}

// MARK: Surviving the app being killed

@MainActor
final class MailStoreRelaunchTests: XCTestCase {
    func testSnoozeWokenWhenTheAppWasKilledWakesAgainNextLaunch() async throws {
        let (account, fake) = fastmailFixture()
        let directory = try makeTemporaryDirectory()
        let first = try makeHarness(directory: directory, services: [account.id: fake])
        try await first.store.addAccount(account, credential: .password("pw"))
        await first.store.waitUntilIdle()
        first.store.inboxFilter = .everything
        let target = try XCTUnwrap(first.store.conversations.first { !$0.isBulk })
        let messageID = try XCTUnwrap(target.latest?.messageID)
        first.store.snooze([target], until: first.clock.now.addingTimeInterval(3_600))
        await first.store.flushPendingActions()

        // Time's up, but the app is suspended (and then killed) while the wake talks to the server.
        first.clock.advance(7_200)
        await fake.delayPerform(1)
        let waking = Task { await first.store.wakeDueSnoozes() }
        try await Task.sleep(nanoseconds: 150_000_000)
        await first.store.cache?.flush()

        await fake.delayPerform(0)
        let second = try makeHarness(directory: directory, clock: first.clock, services: [account.id: fake])
        await second.store.load()
        await second.store.waitUntilIdle()
        await second.store.wakeDueSnoozes()
        await second.store.waitUntilIdle()
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertTrue(inbox.contains { $0.messageID == messageID }, "back in the inbox on the server")
        let shown = second.store.allConversations(for: .allInboxes).first { $0.messages.contains { $0.messageID == messageID } }
        XCTAssertEqual(shown?.isUnread, true, "and on screen, unread")
        XCTAssertTrue(second.store.snoozedConversations.isEmpty)

        await waking.value
        await first.store.waitUntilIdle()
        await first.store.cache?.flush()
        let third = try makeHarness(directory: directory, clock: first.clock, services: [account.id: fake])
        await third.store.load()
        XCTAssertTrue(third.store.snoozedConversations.isEmpty, "a finished wake leaves nothing behind")
        await third.store.waitUntilIdle()
    }

    func testTriageTakenJustBeforeQuittingIsSentNextLaunch() async throws {
        let (account, fake) = fastmailFixture()
        let directory = try makeTemporaryDirectory()
        let first = try makeHarness(directory: directory, services: [account.id: fake])
        try await first.store.addAccount(account, credential: .password("pw"))
        await first.store.waitUntilIdle()
        first.store.undoWindow = 600
        first.store.inboxFilter = .everything
        let archived = try XCTUnwrap(first.store.conversations.first { !$0.isBulk })
        let starred = try XCTUnwrap(first.store.conversations.first { $0.id != archived.id && !$0.isFlagged })
        let archivedID = try XCTUnwrap(archived.latest?.messageID)
        let starredID = try XCTUnwrap(starred.latest?.messageID)

        // The archive is committed (starring commits it) but the server is slow; the star is still
        // in its undo window. Then the app quits without a flush (Cmd-Q on the Mac, a crash).
        await fake.delayPerform(1)
        first.store.archive([archived])
        first.store.setFlagged(true, [starred])
        try await Task.sleep(nanoseconds: 100_000_000)
        await first.store.cache?.flush()

        await fake.delayPerform(0)
        let second = try makeHarness(directory: directory, clock: first.clock, services: [account.id: fake])
        await second.store.load()
        second.store.inboxFilter = .everything
        XCTAssertFalse(second.store.conversations.contains { $0.id == archived.id }, "still archived on screen")
        XCTAssertEqual(second.store.conversations.first { $0.id == starred.id }?.isFlagged, true, "still starred on screen")
        await second.store.waitUntilIdle()
        let inbox = await fake.messages(in: "INBOX")
        XCTAssertFalse(inbox.contains { $0.messageID == archivedID }, "the archive reached the server")
        XCTAssertEqual(inbox.first { $0.messageID == starredID }?.isFlagged, true, "and so did the star")
        XCTAssertFalse(second.store.conversations.contains { $0.id == archived.id })
        XCTAssertEqual(second.store.conversations.first { $0.id == starred.id }?.isFlagged, true)

        // Nothing is sent twice by later launches.
        await first.store.waitUntilIdle()
        await second.store.flushPendingActions()
        let performed = await fake.performed.count
        let third = try makeHarness(directory: directory, clock: first.clock, services: [account.id: fake])
        await third.store.load()
        await third.store.waitUntilIdle()
        let after = await fake.performed.count
        XCTAssertEqual(after, performed)
    }

    func testUndoneTriageIsNotSentNextLaunch() async throws {
        let (account, fake) = fastmailFixture()
        let directory = try makeTemporaryDirectory()
        let first = try makeHarness(directory: directory, services: [account.id: fake])
        try await first.store.addAccount(account, credential: .password("pw"))
        await first.store.waitUntilIdle()
        first.store.undoWindow = 600
        let target = try XCTUnwrap(first.store.conversations.first)
        first.store.trash([target])
        first.store.undo()
        await first.store.cache?.flush()

        let second = try makeHarness(directory: directory, clock: first.clock, services: [account.id: fake])
        await second.store.load()
        await second.store.waitUntilIdle()
        let performed = await fake.performed
        XCTAssertTrue(performed.isEmpty)
        XCTAssertTrue(second.store.conversations.contains { $0.id == target.id })
    }

    func testUndoAfterRemovingTheAccountDoesNotBringBackItsSnooze() async throws {
        let (harness, account, _) = try await fakeHarness()
        let store = harness.store
        store.inboxFilter = .everything
        let target = try XCTUnwrap(store.conversations.first)
        store.snooze([target], until: harness.clock.now.addingTimeInterval(86_400))
        await store.flushPendingActions()
        store.undoWindow = 600
        store.archive(store.snoozedConversations)
        XCTAssertTrue(store.snoozedConversations.isEmpty)
        await store.removeAccount(id: account.id)
        store.undo()
        XCTAssertTrue(store.snoozedConversations.isEmpty, "nothing comes back for an account that's gone")
    }

    func testOldBodiesArePrunedAtLaunch() async throws {
        let first = try await demoHarness()
        let dinner = try XCTUnwrap(first.store.conversations.first { $0.subject == "Dinner Saturday?" }?.latest)
        _ = try await first.store.body(for: dinner)
        await first.store.flushPendingActions()
        let file = try XCTUnwrap(first.store.cache?.bodyURL(accountID: "demo", key: dinner.dedupeKey))
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path))

        let roomy = try makeHarness(directory: first.directory, clock: first.clock)
        await roomy.store.load()
        await roomy.store.waitUntilIdle()
        XCTAssertTrue(FileManager.default.fileExists(atPath: file.path), "within the limit: kept")

        let tight = try makeHarness(directory: first.directory, clock: first.clock)
        tight.store.bodyCacheLimit = 0
        await tight.store.load()
        await tight.store.waitUntilIdle()
        XCTAssertFalse(FileManager.default.fileExists(atPath: file.path), "over the limit: pruned")
    }

    func testLargeCachedBodiesAreReadOffTheMainThread() async throws {
        let (account, fake) = fastmailFixture()
        let directory = try makeTemporaryDirectory()
        let first = try makeHarness(directory: directory, services: [account.id: fake])
        try await first.store.addAccount(account, credential: .password("pw"))
        await first.store.waitUntilIdle()
        let small = try XCTUnwrap(first.store.conversations.first?.latest)
        let large = try XCTUnwrap(first.store.conversations.last?.latest)
        let photo = Attachment(id: "2", filename: "site-photo.jpg", mimeType: "image/jpeg", size: 2_000_000,
                               data: Data(repeating: 0xA5, count: 2_000_000))
        first.store.rememberBody(MessageBody(messageID: small.id, plainText: "Short note"), key: small.dedupeKey, accountID: account.id, persist: true)
        first.store.rememberBody(MessageBody(messageID: large.id, plainText: "Photos attached", attachments: [photo]),
                                 key: large.dedupeKey, accountID: account.id, persist: true)
        await first.store.flushPendingActions()

        let second = try makeHarness(directory: directory, clock: first.clock, services: [account.id: fake])
        await second.store.load()
        XCTAssertEqual(second.store.cachedBody(for: small)?.plainText, "Short note", "small bodies come straight from disk")
        XCTAssertNil(second.store.cachedBody(for: large), "a big file isn't decoded on the main thread")
        // Gone from the server, so this can only come from the cache.
        try await fake.perform(.deletePermanently, on: [large])
        let body = try await second.store.body(for: large)
        XCTAssertEqual(body.attachments.first?.data?.count, 2_000_000)
        XCTAssertEqual(body.messageID, large.id)
        XCTAssertEqual(second.store.cachedBody(for: large)?.plainText, "Photos attached", "then kept in memory")
        await second.store.waitUntilIdle()
    }
}
