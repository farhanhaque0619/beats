import XCTest
import InkModel
@testable import InkSync

final class ThreaderTests: XCTestCase {
    let me = address("Alex Rivera", "alex@ink.example")
    let priya = address("Priya Natarajan", "priya@fieldstone.example")
    let marcus = address("Marcus Bell", "marcus.bell@fieldstone.example")
    let day: TimeInterval = 86_400
    let base = referenceDate

    // MARK: Gmail

    func testGmailThreadIDsGroupEvenWithoutHeaders() {
        // Gmail threads by X-GM-THRID even when a client dropped In-Reply-To / References.
        let messages = [
            summary(uid: 10, messageID: "CAF=abc@mail.gmail.com", gmailThread: 1_780_000_000_000_000_001, gmailMessage: 1,
                    subject: "Weekend plans", from: priya, date: base),
            summary(uid: 11, messageID: "CAF=def@mail.gmail.com", gmailThread: 1_780_000_000_000_000_001, gmailMessage: 2,
                    subject: "Totally different subject", from: marcus, date: base + 60),
            summary(uid: 12, messageID: "CAF=ghi@mail.gmail.com", gmailThread: 1_780_000_000_000_000_002, gmailMessage: 3,
                    subject: "Weekend plans", from: priya, date: base + 120),
        ]
        let conversations = Threader.thread(messages)
        XCTAssertEqual(conversations.count, 2)
        let joined = conversations.first { $0.count == 2 }
        XCTAssertEqual(joined?.id, "acct|gm:1780000000000000001")
        XCTAssertEqual(joined?.messages.map(\.uid), [10, 11])
        XCTAssertTrue(joined?.messages.allSatisfy { $0.threadKey == "acct|gm:1780000000000000001" } ?? false)
    }

    func testGmailDedupePrefersInboxCopyOverAllMail() {
        // The same Gmail message shows up in INBOX and in [Gmail]/All Mail with different UIDs.
        let inbox = summary(mailbox: "INBOX", uid: 4_412, messageID: "CAE+x7@mail.gmail.com", gmailThread: 99, gmailMessage: 555,
                            subject: "Lease renewal", from: priya, date: base, flags: [])
        let allMail = summary(mailbox: "[Gmail]/All Mail", uid: 80_113, messageID: "CAE+x7@mail.gmail.com", gmailThread: 99, gmailMessage: 555,
                              subject: "Lease renewal", from: priya, date: base, flags: [])
        let sent = summary(mailbox: "[Gmail]/Sent Mail", uid: 301, messageID: "CAB+me@mail.gmail.com", gmailThread: 99, gmailMessage: 556,
                           subject: "Re: Lease renewal", from: me, date: base + 300)
        let sentInAllMail = summary(mailbox: "[Gmail]/All Mail", uid: 80_114, messageID: "CAB+me@mail.gmail.com", gmailThread: 99, gmailMessage: 556,
                                    subject: "Re: Lease renewal", from: me, date: base + 300)
        let conversations = Threader.thread([allMail, sentInAllMail, inbox, sent])
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].count, 2, "copies collapse to one per message")
        XCTAssertEqual(conversations[0].messages.first?.mailboxPath, "INBOX", "the inbox copy wins")
        XCTAssertEqual(conversations[0].unreadCount, 1)
    }

    func testDedupeByMessageIDWithCustomRank() {
        let a = summary(mailbox: "Archive", uid: 1, messageID: "<Same@Host.example>", subject: "Hi", from: priya, date: base)
        let b = summary(mailbox: "INBOX", uid: 2, messageID: "same@host.example", subject: "Hi", from: priya, date: base)
        // Message-IDs compare case-insensitively through dedupeKey only when spelled the same; here they differ by brackets,
        // so both copies survive dedupe but thread together by normalized ID.
        let threads = Threader.thread([a, b])
        XCTAssertEqual(threads.count, 1)
        let deduped = Threader.dedupe([
            summary(mailbox: "Archive", uid: 1, messageID: "m1@x.example", subject: "Hi", from: priya, date: base),
            summary(mailbox: "INBOX", uid: 2, messageID: "M1@X.example", subject: "Hi", from: priya, date: base),
        ]) { $0.mailboxPath == "Archive" ? 0 : 1 }
        XCTAssertEqual(deduped.count, 1)
        XCTAssertEqual(deduped.first?.mailboxPath, "Archive", "custom rank decides which copy stays")
    }

    // MARK: References

    func testReferencesChainAcrossFoldersAndOutOfOrderArrival() {
        // Thunderbird-style chain: each reply carries the full References list.
        let root = summary(mailbox: "INBOX", uid: 1, messageID: "root.1@fieldstone.example", subject: "Q4 roadmap review", from: priya, date: base)
        let reply = summary(mailbox: "Sent", uid: 7, messageID: "reply.2@ink.example", inReplyTo: ["root.1@fieldstone.example"],
                            references: ["root.1@fieldstone.example"], subject: "Re: Q4 roadmap review", from: me, date: base + 3_600)
        let third = summary(mailbox: "INBOX", uid: 3, messageID: "third.3@fieldstone.example", inReplyTo: ["reply.2@ink.example"],
                            references: ["root.1@fieldstone.example", "reply.2@ink.example"], subject: "RE: Q4 roadmap review", from: marcus,
                            date: base + 7_200)
        // Arrival order scrambled; the thread is still one conversation keyed by the root.
        let conversations = Threader.thread([third, root, reply])
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].id, "acct|root.1@fieldstone.example")
        XCTAssertEqual(conversations[0].messages.map(\.uid), [1, 7, 3])
        XCTAssertEqual(conversations[0].subject, "Q4 roadmap review")
    }

    func testMissingParentStillJoinsSiblingsThroughSharedReference() {
        // The root was deleted; two replies reference it (Outlook only sets In-Reply-To).
        let a = summary(uid: 5, messageID: "AM6PR01MB1@eurprd01.prod.outlook.example", inReplyTo: ["<gone@fieldstone.example>"],
                        subject: "RE: Budget", from: marcus, date: base)
        let b = summary(uid: 6, messageID: "AM6PR01MB2@eurprd01.prod.outlook.example", inReplyTo: ["<gone@fieldstone.example>"],
                        subject: "RE: Budget", from: priya, date: base + 60)
        let conversations = Threader.thread([a, b])
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].id, "acct|gone@fieldstone.example", "keyed by the missing root, stable when it shows up")
    }

    func testConversationIDIsStableWhenOlderMessagesArrive() {
        let reply = summary(uid: 9, messageID: "r@x.example", inReplyTo: ["root@x.example"], references: ["root@x.example"],
                            subject: "Re: Plans", from: priya, date: base + 100)
        let before = Threader.thread([reply])[0].id
        let root = summary(uid: 2, messageID: "root@x.example", subject: "Plans", from: me, to: [priya], date: base)
        let after = Threader.thread([reply, root])[0].id
        XCTAssertEqual(before, after)
    }

    func testUnrelatedMessagesStayApart() {
        let conversations = Threader.thread([
            summary(uid: 1, messageID: "a@x.example", subject: "One", from: priya, date: base),
            summary(uid: 2, messageID: "b@x.example", subject: "Two", from: priya, date: base + 1),
            summary(uid: 3, messageID: nil, subject: "", from: marcus, date: base + 2),
        ])
        XCTAssertEqual(conversations.count, 3)
        XCTAssertEqual(conversations.first?.subject, "(no subject)", "newest first")
    }

    func testAccountsNeverMixEvenWithSameMessageID() {
        let a = summary(account: "one", uid: 1, messageID: "dup@x.example", subject: "Hi", from: priya, date: base)
        let b = summary(account: "two", uid: 1, messageID: "dup@x.example", subject: "Hi", from: priya, date: base)
        let conversations = Threader.thread([a, b])
        XCTAssertEqual(conversations.count, 2)
        XCTAssertEqual(Set(conversations.map(\.accountID)), ["one", "two"])
    }

    // MARK: Subject fallback

    func testSubjectFallbackJoinsHeaderlessRepliesWithSharedParticipant() {
        // Some webmail and phone clients drop In-Reply-To / References entirely.
        let original = summary(uid: 1, messageID: "m1@mailbox.example", subject: "Dinner Saturday?", from: priya, to: [me], date: base)
        let reply = summary(mailbox: "Sent", uid: 2, messageID: "m2@ink.example", subject: "Re: Dinner Saturday?", from: me, to: [priya],
                            date: base + 2 * 3_600)
        let conversations = Threader.thread([original, reply], myAddresses: ["ALEX@ink.example"])
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].count, 2)
    }

    func testSubjectFallbackNeedsAParticipantOtherThanMe() {
        // Two different people writing "Hello" to me: the only shared address is mine.
        let a = summary(uid: 1, messageID: "a@x.example", subject: "Hello", from: priya, to: [me], date: base)
        let b = summary(uid: 2, messageID: "b@y.example", subject: "Hello", from: marcus, to: [me], date: base + 600)
        XCTAssertEqual(Threader.thread([a, b], myAddresses: ["alex@ink.example"]).count, 2)
    }

    func testSubjectFallbackRespectsThirtyDayWindow() {
        let a = summary(uid: 1, messageID: "a@x.example", subject: "Monthly sync", from: priya, to: [me], date: base)
        let b = summary(uid: 2, messageID: "b@x.example", subject: "Re: Monthly sync", from: priya, to: [me], date: base + 31 * day)
        XCTAssertEqual(Threader.thread([a, b], myAddresses: ["alex@ink.example"]).count, 2)
        let c = summary(uid: 3, messageID: "c@x.example", subject: "Re: Monthly sync", from: priya, to: [me], date: base + 29 * day)
        XCTAssertEqual(Threader.thread([a, c], myAddresses: ["alex@ink.example"]).count, 1)
    }

    func testSubjectFallbackSkipsBulkAndMessagesWithReferences() {
        let newsletter = address("The Margin", "newsletter@themargin.example")
        let issues = (0..<4).map { index in
            summary(uid: UInt32(index + 1), messageID: "issue\(index)@themargin.example", subject: "This week at The Margin",
                    from: newsletter, date: base + Double(index) * 7 * day / 2, bulk: true)
        }
        XCTAssertEqual(Threader.thread(issues).count, 4, "weekly newsletters with a fixed subject stay apart")

        let referenced = summary(uid: 9, messageID: "x@x.example", inReplyTo: ["other@x.example"], subject: "Lunch", from: priya, date: base)
        let plain = summary(uid: 10, messageID: "y@x.example", subject: "Lunch", from: priya, date: base + 60)
        XCTAssertEqual(Threader.thread([referenced, plain]).count, 2, "only header-less messages use the fallback")
    }

    func testSubjectNormalizationAcrossLanguagesAndListTags() {
        let a = summary(uid: 1, messageID: "a@x.example", subject: "[team] Offsite agenda", from: priya, to: [me, marcus], date: base)
        let b = summary(uid: 2, messageID: "b@x.example", subject: "AW: [team] Offsite agenda", from: marcus, to: [priya], date: base + 60)
        let c = summary(uid: 3, messageID: "c@x.example", subject: "SV: Re: Offsite agenda", from: priya, to: [marcus], date: base + 120)
        let conversations = Threader.thread([a, b, c], myAddresses: ["alex@ink.example"])
        XCTAssertEqual(conversations.count, 1)
    }

    func testLargeSameSubjectBucketIsFast() {
        // 3,000 header-less "Daily report" mails from the same sender; must not go quadratic.
        let sender = address("Build Bot", "ci@builds.example")
        let messages = (0..<3_000).map { index in
            summary(uid: UInt32(index + 1), messageID: "r\(index)@builds.example", subject: "Daily report", from: sender,
                    to: [address("Ops", "ops@fieldstone.example")], date: base + Double(index) * 60)
        }
        let start = Date()
        let conversations = Threader.thread(messages)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertEqual(conversations.count, 1)
        XCTAssertEqual(conversations[0].count, 3_000)
    }

    func testMalformedIDsAreIgnored() {
        let conversations = Threader.thread([
            summary(uid: 1, messageID: "   ", inReplyTo: ["<>", ""], references: ["  ", "<>"], subject: "A", from: priya, date: base),
            summary(uid: 2, messageID: "<>", inReplyTo: [], references: ["<>"], subject: "B", from: marcus, date: base + 1),
        ])
        XCTAssertEqual(conversations.count, 2, "empty IDs must not glue unrelated mail together")
        for conversation in conversations { XCTAssertFalse(conversation.id.isEmpty) }
    }

    func testEmptyInput() {
        XCTAssertTrue(Threader.thread([]).isEmpty)
        XCTAssertTrue(Threader.dedupe([]).isEmpty)
    }
}
