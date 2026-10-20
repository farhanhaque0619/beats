import XCTest
import InkModel
@testable import InkMIME

final class ReplyBuilderTests: XCTestCase {
    private let account = AccountConfig(
        id: "acct", provider: .fastmail, displayName: "Alex Rivera", emailAddress: "alex@ink.example",
        imap: ServerConfig(host: "imap.example", port: 993, security: .tls, username: "alex@ink.example"),
        smtp: ServerConfig(host: "smtp.example", port: 465, security: .tls, username: "alex@ink.example")
    )
    private let ada = EmailAddress(name: "Ada Lovelace", address: "ada@example.com")
    private let grace = EmailAddress(name: "Grace Hopper", address: "grace@example.com")
    private let linus = EmailAddress(name: "Linus", address: "linus@example.org")
    private let me = EmailAddress(name: "Alex Rivera", address: "Alex@Ink.Example")
    private let alias = EmailAddress(name: "Alex", address: "alex.alias@ink.example")
    private let now = Date.utc(2026, 10, 20, 12)

    private func summary(from: [EmailAddress], replyTo: [EmailAddress] = [], to: [EmailAddress], cc: [EmailAddress] = [],
                         subject: String = "Plans", references: [String] = ["root@example.com"], inReplyTo: [String] = [],
                         messageID: String? = "msg-1@example.com") -> MessageSummary {
        MessageSummary(accountID: "acct", mailboxPath: "INBOX", uid: 7, uidValidity: 1, messageID: messageID, inReplyTo: inReplyTo,
                       references: references, subject: subject, from: from, replyTo: replyTo, to: to, cc: cc,
                       date: Date.utc(2026, 10, 20, 9, 15))
    }

    private func draft(_ m: MessageSummary, _ mode: ReplyMode, body: MessageBody? = nil, mine: Set<String> = ["alex.alias@ink.example"]) -> OutgoingMessage {
        ReplyBuilder.draft(replyingTo: m, body: body, mode: mode, from: account, myAddresses: mine, now: now)
    }

    func testReplyGoesToSender() {
        let d = draft(summary(from: [ada], to: [me, grace], cc: [linus]), .reply)
        XCTAssertEqual(d.to.map(\.address), ["ada@example.com"])
        XCTAssertTrue(d.cc.isEmpty)
        XCTAssertTrue(d.bcc.isEmpty)
        XCTAssertEqual(d.from.address, "alex@ink.example")
        XCTAssertEqual(d.from.name, "Alex Rivera")
        XCTAssertEqual(d.accountID, "acct")
        XCTAssertEqual(d.replyMode, .reply)
        XCTAssertEqual(d.createdAt, now)
        XCTAssertEqual(d.body, "")
    }

    func testReplyToHeaderWins() {
        let list = EmailAddress(name: "Ink Dev", address: "ink-dev@lists.example.org")
        let d = draft(summary(from: [ada], replyTo: [list], to: [list]), .reply)
        XCTAssertEqual(d.to.map(\.address), ["ink-dev@lists.example.org"])
    }

    func testReplyAll() {
        let d = draft(summary(from: [ada], to: [me, grace, alias], cc: [linus, ada, EmailAddress(address: "GRACE@example.com")]), .replyAll)
        XCTAssertEqual(d.to.map(\.address), ["ada@example.com", "grace@example.com"])
        XCTAssertEqual(d.cc.map(\.address), ["linus@example.org"])
    }

    func testReplyAllWithReplyToList() {
        let list = EmailAddress(address: "team@example.com")
        let d = draft(summary(from: [ada], replyTo: [list], to: [list, me], cc: [grace]), .replyAll)
        XCTAssertEqual(d.to.map(\.address), ["team@example.com"])
        XCTAssertEqual(d.cc.map(\.address), ["grace@example.com"])
    }

    func testReplyToMyOwnSentMessage() {
        let sent = summary(from: [me], to: [ada, grace], cc: [linus])
        let reply = draft(sent, .reply)
        XCTAssertEqual(reply.to.map(\.address), ["ada@example.com", "grace@example.com"])
        XCTAssertTrue(reply.cc.isEmpty)
        let all = draft(sent, .replyAll)
        XCTAssertEqual(all.to.map(\.address), ["ada@example.com", "grace@example.com"])
        XCTAssertEqual(all.cc.map(\.address), ["linus@example.org"])
    }

    func testReplyToNoteToSelf() {
        let selfSent = summary(from: [me], to: [me])
        XCTAssertEqual(draft(selfSent, .reply).to.map(\.normalized), ["alex@ink.example"])
        XCTAssertEqual(draft(selfSent, .replyAll).to.map(\.normalized), ["alex@ink.example"])
    }

    func testForwardHasNoRecipientsAndCarriesAttachments() {
        let body = MessageBody(messageID: "x", plainText: "Original text", html: nil, attachments: [
            Attachment(id: "2", filename: "report.pdf", mimeType: "application/pdf", size: 3, data: Data("pdf".utf8)),
            Attachment(id: "3", filename: "logo.png", mimeType: "image/png", size: 3, contentID: "logo", isInline: true, data: Data("png".utf8)),
            Attachment(id: "4", filename: "big.mov", mimeType: "video/quicktime", size: 99_000_000, data: nil),
        ])
        let d = draft(summary(from: [ada], to: [me], cc: [grace]), .forward, body: body)
        XCTAssertTrue(d.to.isEmpty)
        XCTAssertTrue(d.cc.isEmpty)
        XCTAssertEqual(d.subject, "Fwd: Plans")
        XCTAssertEqual(d.attachments.map(\.filename), ["report.pdf"])
        XCTAssertEqual(d.attachments.first?.data, Data("pdf".utf8))
        let quoted = d.quotedText ?? ""
        XCTAssertTrue(quoted.hasPrefix("---------- Forwarded message ---------\nFrom: Ada Lovelace <ada@example.com>\nDate: "))
        XCTAssertTrue(quoted.contains("\nSubject: Plans\nTo: Alex Rivera <Alex@Ink.Example>"))
        XCTAssertTrue(quoted.contains("\nCc: Grace Hopper <grace@example.com>"))
        XCTAssertTrue(quoted.hasSuffix("\n\nOriginal text"))
        XCTAssertEqual(d.inReplyTo, "msg-1@example.com")
    }

    func testSubjects() {
        XCTAssertEqual(ReplyBuilder.replySubject("Plans"), "Re: Plans")
        XCTAssertEqual(ReplyBuilder.replySubject("Re: Plans"), "Re: Plans")
        XCTAssertEqual(ReplyBuilder.replySubject("RE: Re: re: Plans"), "Re: Plans")
        XCTAssertEqual(ReplyBuilder.replySubject("Re[2]: Plans"), "Re: Plans")
        XCTAssertEqual(ReplyBuilder.replySubject("AW: Projekt"), "Re: Projekt")
        XCTAssertEqual(ReplyBuilder.replySubject("SV: Möte"), "Re: Möte")
        XCTAssertEqual(ReplyBuilder.replySubject("Antw: Vergadering"), "Re: Vergadering")
        XCTAssertEqual(ReplyBuilder.replySubject("VS: Kokous"), "Re: Kokous")
        XCTAssertEqual(ReplyBuilder.replySubject("RIF: Riunione"), "Re: Riunione")
        XCTAssertEqual(ReplyBuilder.replySubject("Réf : Réunion"), "Re: Réunion")
        XCTAssertEqual(ReplyBuilder.replySubject("Odp: Spotkanie"), "Re: Spotkanie")
        XCTAssertEqual(ReplyBuilder.replySubject("Re：会議"), "Re: 会議")
        XCTAssertEqual(ReplyBuilder.replySubject("Fwd: Plans"), "Re: Fwd: Plans")
        XCTAssertEqual(ReplyBuilder.replySubject("[ink-dev] Release"), "Re: [ink-dev] Release")
        XCTAssertEqual(ReplyBuilder.replySubject("[ink-dev] Re: Release"), "Re: [ink-dev] Release")
        XCTAssertEqual(ReplyBuilder.replySubject("Re: [ink-dev] Re: Release"), "Re: [ink-dev] Release")
        XCTAssertEqual(ReplyBuilder.replySubject("Meeting notes: Q3"), "Re: Meeting notes: Q3")
        XCTAssertEqual(ReplyBuilder.replySubject("Reminder: dentist"), "Re: Reminder: dentist")
        XCTAssertEqual(ReplyBuilder.replySubject(""), "Re:")
        XCTAssertEqual(ReplyBuilder.replySubject("   Re:   spaced  "), "Re: spaced")

        XCTAssertEqual(ReplyBuilder.forwardSubject("Plans"), "Fwd: Plans")
        XCTAssertEqual(ReplyBuilder.forwardSubject("Fwd: Plans"), "Fwd: Plans")
        XCTAssertEqual(ReplyBuilder.forwardSubject("FW: Fwd: Plans"), "Fwd: Plans")
        XCTAssertEqual(ReplyBuilder.forwardSubject("WG: Projekt"), "Fwd: Projekt")
        XCTAssertEqual(ReplyBuilder.forwardSubject("TR: Réunion"), "Fwd: Réunion")
        XCTAssertEqual(ReplyBuilder.forwardSubject("Re: Plans"), "Fwd: Re: Plans")
        XCTAssertEqual(ReplyBuilder.forwardSubject(""), "Fwd:")

        // Normalizing the result gives back the thread subject.
        for subject in ["Plans", "Re: Plans", "AW: Plans", "Fwd: Plans", "Re[3]: Plans"] {
            XCTAssertEqual(SubjectNormalizer.normalize(ReplyBuilder.replySubject(subject)), "Plans")
            XCTAssertEqual(SubjectNormalizer.normalize(ReplyBuilder.forwardSubject(subject)), "Plans")
        }
    }

    func testThreadingReferences() {
        let d = draft(summary(from: [ada], to: [me], references: ["a@x", "b@x"], messageID: "c@x"), .reply)
        XCTAssertEqual(d.inReplyTo, "c@x")
        XCTAssertEqual(d.references, ["a@x", "b@x", "c@x"])

        let noRefs = draft(summary(from: [ada], to: [me], references: [], inReplyTo: ["parent@x"], messageID: "c@x"), .reply)
        XCTAssertEqual(noRefs.references, ["parent@x", "c@x"])

        let many = (1...40).map { "r\($0)@x" }
        let capped = draft(summary(from: [ada], to: [me], references: many, messageID: "last@x"), .reply)
        XCTAssertEqual(capped.references.count, 20)
        XCTAssertEqual(capped.references.last, "last@x")
        XCTAssertEqual(capped.references.first, "r22@x")

        let dup = draft(summary(from: [ada], to: [me], references: ["a@x", "c@x"], messageID: "c@x"), .reply)
        XCTAssertEqual(dup.references, ["a@x", "c@x"])

        let noID = draft(summary(from: [ada], to: [me], references: [], messageID: nil), .reply)
        XCTAssertNil(noID.inReplyTo)
        XCTAssertTrue(noID.references.isEmpty)
    }

    func testQuotedTextAndHTML() {
        let body = MessageBody(messageID: "x", plainText: "Lunch on Friday?\n\n> Earlier line\n\n", html: "<html><body><p>Lunch on <b>Friday</b>?</p><img src=\"cid:sig\"><script>x</script></body></html>")
        let d = draft(summary(from: [ada], to: [me]), .reply, body: body)
        let quoted = d.quotedText ?? ""
        let lines = quoted.components(separatedBy: "\n")
        XCTAssertTrue(lines[0].hasPrefix("On "))
        XCTAssertTrue(lines[0].hasSuffix(", Ada Lovelace <ada@example.com> wrote:"))
        XCTAssertEqual(Array(lines.dropFirst()), ["> Lunch on Friday?", ">", "> > Earlier line"])
        XCTAssertEqual(d.quotedHTML, "<p>Lunch on <b>Friday</b>?</p>")
        // Recognised by our own quote splitter.
        XCTAssertEqual(QuoteSplitter.split("Sure!\n\n" + quoted).body, "Sure!")
    }

    func testQuoteFromHTMLOnlyBody() {
        let body = MessageBody(messageID: "x", plainText: nil, html: "<p>Only <i>HTML</i> here</p><p>Second</p>")
        let d = draft(summary(from: [ada], to: [me]), .replyAll, body: body)
        XCTAssertEqual(d.quotedText?.components(separatedBy: "\n").dropFirst().joined(separator: "\n"), "> Only HTML here\n>\n> Second")
    }

    func testNoBodyMeansNoQuote() {
        let d = draft(summary(from: [ada], to: [me]), .reply, body: nil)
        XCTAssertNil(d.quotedText)
        XCTAssertNil(d.quotedHTML)
        let f = draft(summary(from: [ada], to: [me]), .forward, body: nil)
        XCTAssertEqual(f.quotedText?.hasPrefix("---------- Forwarded message ---------"), true)
    }

    func testAttributionFormat() {
        let m = summary(from: [ada], to: [me])
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(ReplyBuilder.attribution(for: m, timeZone: utc), "On Tue, Oct 20, 2026 at 9:15 AM, Ada Lovelace <ada@example.com> wrote:")
        let pm = MessageSummary(accountID: "a", mailboxPath: "INBOX", uid: 1, uidValidity: 1, subject: "x",
                                from: [EmailAddress(address: "bare@example.com")], date: Date.utc(2026, 1, 5, 0, 7))
        XCTAssertEqual(ReplyBuilder.attribution(for: pm, timeZone: utc), "On Mon, Jan 5, 2026 at 12:07 AM, bare@example.com wrote:")
        let noSender = MessageSummary(accountID: "a", mailboxPath: "INBOX", uid: 1, uidValidity: 1, subject: "x", from: [], date: Date.utc(2026, 6, 1, 13, 30))
        XCTAssertEqual(ReplyBuilder.attribution(for: noSender, timeZone: utc), "On Mon, Jun 1, 2026 at 1:30 PM, Unknown sender wrote:")
    }

    func testEndToEndReplyBuildsAndParses() {
        let original = MIMEParser.parse(Raw.data(Fixtures.gmailAlternative))
        let summary = MessageSummary(accountID: "acct", mailboxPath: "INBOX", uid: 1, uidValidity: 1, messageID: original.messageID,
                                     inReplyTo: original.inReplyTo, references: original.references, subject: original.subject,
                                     from: original.from, replyTo: original.replyTo, to: original.to, cc: original.cc,
                                     date: original.date ?? now)
        var reply = draft(summary, .replyAll, body: original.body(messageID: summary.id))
        reply.body = "Yes! 10 works."
        XCTAssertEqual(reply.subject, "Re: Café tomorrow?")
        XCTAssertEqual(reply.to.map(\.address), ["ada.lovelace@gmail.com"])
        XCTAssertTrue(reply.cc.isEmpty)
        let (data, id) = MessageBuilder.build(reply, date: now)
        assertWireFormat(data)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.messageID, id)
        XCTAssertEqual(parsed.subject, "Re: Café tomorrow?")
        XCTAssertEqual(parsed.inReplyTo, ["CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com"])
        XCTAssertEqual(parsed.references, ["CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com"])
        XCTAssertEqual(QuoteSplitter.split(parsed.plainText ?? "").body, "Yes! 10 works.")
        XCTAssertEqual(QuoteSplitter.split(parsed.plainText ?? "").quoted?.contains("> Are you free for a coffee at Café Central"), true)
        let stripped = QuoteSplitter.stripQuotedHTML(parsed.html ?? "")
        XCTAssertTrue(stripped.hadQuote)
        XCTAssertFalse(stripped.html.contains("Are you free"))
        XCTAssertEqual(Snippet.make(plain: parsed.plainText, html: parsed.html), "Yes! 10 works.")
    }
}
