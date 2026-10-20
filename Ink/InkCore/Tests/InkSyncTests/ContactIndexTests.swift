import XCTest
import InkModel
@testable import InkSync

final class ContactIndexTests: XCTestCase {
    let me = address("Alex Rivera", "alex@ink.example")
    let base = referenceDate

    private func index(_ messages: [MessageSummary]) -> ContactIndex {
        ContactIndex(messages: messages, myAddresses: ["Alex@Ink.example"], now: base)
    }

    func testPeopleYouWriteToRankAboveSenders() {
        let jose = address("José Álvarez", "jose@tinkerbit.example")
        let priya = address("Priya Natarajan", "priya@fieldstone.example")
        var messages: [MessageSummary] = []
        // Priya writes twice; Alex writes to José once (sent weighs 3x).
        messages.append(summary(uid: 1, messageID: "p1@x", subject: "a", from: priya, date: base - 3_600))
        messages.append(summary(uid: 2, messageID: "p2@x", subject: "b", from: priya, date: base - 7_200))
        messages.append(summary(mailbox: "Sent", uid: 3, messageID: "s1@x", subject: "c", from: me, to: [jose], date: base - 3_600))
        let contacts = index(messages)
        XCTAssertEqual(contacts.suggestions(matching: "", limit: 2).map(\.address), ["jose@tinkerbit.example", "priya@fieldstone.example"])
    }

    func testPrefixMatchesNameWordsAddressAndDomainIgnoringAccents() {
        let jose = address("José Álvarez", "jose.alvarez@tinkerbit.example")
        let contacts = index([summary(uid: 1, messageID: "a@x", subject: "s", from: jose, date: base)])
        for query in ["jos", "JOSÉ", "alv", "álv", "jose.al", "tinker", "Jose Al"] {
            XCTAssertEqual(contacts.suggestions(matching: query).first?.address, "jose.alvarez@tinkerbit.example", query)
        }
        XCTAssertTrue(contacts.suggestions(matching: "xyz").isEmpty)
        XCTAssertTrue(contacts.suggestions(matching: "lvarez").isEmpty, "prefix of a word, not any substring")
    }

    func testExcludesMeAndAutomatedSendersUnlessIWroteToThem() {
        let noreply = address("Kestrel Air", "no-reply@kestrelair.example")
        let support = address("Harbor & Pine", "support@harborandpine.example")
        let messages = [
            summary(uid: 1, messageID: "a@x", subject: "Your trip", from: noreply, to: [me], date: base),
            summary(uid: 2, messageID: "b@x", subject: "Order", from: support, to: [me], date: base),
            summary(mailbox: "Sent", uid: 3, messageID: "c@x", subject: "Re: Order", from: me, to: [support], date: base),
        ]
        let all = index(messages).suggestions(matching: "", limit: 10).map(\.address)
        XCTAssertFalse(all.contains("no-reply@kestrelair.example"))
        XCTAssertFalse(all.contains("alex@ink.example"))
        XCTAssertTrue(all.contains("support@harborandpine.example"), "you wrote to them, so they count")
    }

    func testRecencyAndLatestDisplayName() {
        let old = address("Sam", "sam.chen@mailbox.example")
        let renamed = address("Sam Chen", "SAM.CHEN@mailbox.example")
        let other = address("Theo Lindqvist", "theo@lindqvist.example")
        let messages = [
            summary(uid: 1, messageID: "a@x", subject: "s", from: old, date: base - 200 * 86_400),
            summary(uid: 2, messageID: "b@x", subject: "s", from: renamed, date: base - 86_400),
            summary(uid: 3, messageID: "c@x", subject: "s", from: other, date: base - 300 * 86_400),
        ]
        let contacts = index(messages)
        let top = contacts.suggestions(matching: "", limit: 3)
        XCTAssertEqual(top.first?.address.lowercased(), "sam.chen@mailbox.example")
        XCTAssertEqual(top.first?.name, "Sam Chen", "most recent name wins")
        XCTAssertEqual(contacts.entries.first?.count, 2, "case-insensitive addresses merge")
    }

    func testCopiesOfOneMessageCountOnceAndInvalidAddressesAreSkipped() {
        let priya = address("Priya", "priya@fieldstone.example")
        let bad = EmailAddress(name: "Undisclosed", address: "undisclosed-recipients:;")
        let inbox = summary(mailbox: "INBOX", uid: 1, messageID: "same@x", subject: "s", from: priya, to: [me, bad], date: base)
        var allMail = inbox
        allMail.mailboxPath = "[Gmail]/All Mail"
        allMail.uid = 99
        let contacts = index([inbox, allMail])
        XCTAssertEqual(contacts.entries.count, 1)
        XCTAssertEqual(contacts.entries.first?.count, 1)
    }

    func testLimitAndExclusions() {
        let people = (0..<20).map { address("Person \($0)", "person\($0)@example.example") }
        let messages = people.enumerated().map { index, person in
            summary(uid: UInt32(index + 1), messageID: "m\(index)@x", subject: "s", from: person, date: base - Double(index) * 3_600)
        }
        let contacts = index(messages)
        XCTAssertEqual(contacts.suggestions(matching: "person", limit: 6).count, 6)
        XCTAssertEqual(contacts.suggestions(matching: "person", limit: 0).count, 0)
        let excluded = contacts.suggestions(matching: "person", limit: 3, excluding: ["person0@example.example"])
        XCTAssertFalse(excluded.map(\.address).contains("person0@example.example"))
    }
}
