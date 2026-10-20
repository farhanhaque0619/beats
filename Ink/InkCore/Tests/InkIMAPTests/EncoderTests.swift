import XCTest
import InkModel
@testable import InkIMAP

final class EncoderTests: XCTestCase {
    private func wire(_ command: IMAPCommand) -> String { String(decoding: command.bytes, as: UTF8.self) }

    // MARK: Tags

    func testTagsCountUp() {
        var tags = IMAPTagGenerator()
        XCTAssertEqual(tags.next(), "A001")
        XCTAssertEqual(tags.next(), "A002")
        var late = IMAPTagGenerator(counter: 998)
        XCTAssertEqual(late.next(), "A999")
        XCTAssertEqual(late.next(), "A1000")
    }

    // MARK: Atoms, quoted strings, literals

    func testAtomDetection() {
        XCTAssertTrue(IMAPEncoder.isAtom("INBOX"))
        XCTAssertTrue(IMAPEncoder.isAtom("user@example.com"))
        XCTAssertTrue(IMAPEncoder.isAtom("[Gmail]/Sent"))
        XCTAssertFalse(IMAPEncoder.isAtom(""))
        XCTAssertFalse(IMAPEncoder.isAtom("two words"))
        XCTAssertFalse(IMAPEncoder.isAtom("quote\"d"))
        XCTAssertFalse(IMAPEncoder.isAtom("back\\slash"))
        XCTAssertFalse(IMAPEncoder.isAtom("wild*"))
        XCTAssertFalse(IMAPEncoder.isAtom("wild%"))
        XCTAssertFalse(IMAPEncoder.isAtom("(paren"))
        XCTAssertFalse(IMAPEncoder.isAtom("{brace"))
        XCTAssertFalse(IMAPEncoder.isAtom("ünïcode"))
        XCTAssertFalse(IMAPEncoder.isAtom("tab\there"))
    }

    func testQuotedStrings() {
        XCTAssertEqual(IMAPEncoder.quoted("Sent Items"), "\"Sent Items\"")
        XCTAssertEqual(IMAPEncoder.quoted("say \"hi\""), "\"say \\\"hi\\\"\"")
        XCTAssertEqual(IMAPEncoder.quoted("C:\\path"), "\"C:\\\\path\"")
        XCTAssertEqual(IMAPEncoder.quoted(""), "\"\"")
        XCTAssertNil(IMAPEncoder.quoted("line\r\nbreak"))
        XCTAssertNil(IMAPEncoder.quoted("nul\u{0}byte"))
        XCTAssertNil(IMAPEncoder.quoted("café"))
        XCTAssertEqual(IMAPEncoder.quoted("café", utf8Accepted: true), "\"café\"")
        XCTAssertNil(IMAPEncoder.quoted(String(repeating: "x", count: 2000)))
    }

    func testFlagValidation() {
        XCTAssertTrue(IMAPEncoder.isFlag("\\Seen"))
        XCTAssertTrue(IMAPEncoder.isFlag("$Forwarded"))
        XCTAssertTrue(IMAPEncoder.isFlag("NonJunk"))
        XCTAssertFalse(IMAPEncoder.isFlag("\\"))
        XCTAssertFalse(IMAPEncoder.isFlag("two words"))
        XCTAssertFalse(IMAPEncoder.isFlag("bad)flag"))
        XCTAssertFalse(IMAPEncoder.isFlag("bad]flag"))
    }

    func testBuilderChoosesAtomQuotedOrLiteral() {
        var builder = IMAPCommandBuilder("LOGIN", sensitive: true)
        builder.space()
        builder.astring("ada@example.com")
        builder.space()
        builder.astring("pa ss\"word")
        XCTAssertEqual(wire(builder.build()), "LOGIN ada@example.com \"pa ss\\\"word\"\r\n")

        var nilBuilder = IMAPCommandBuilder("LOGIN")
        nilBuilder.space()
        nilBuilder.astring("NIL")
        XCTAssertEqual(wire(nilBuilder.build()), "LOGIN \"NIL\"\r\n", "a bare NIL would read as NIL")

        var literalBuilder = IMAPCommandBuilder("LOGIN")
        literalBuilder.space()
        literalBuilder.astring("ada")
        literalBuilder.space()
        literalBuilder.astring("pässwörd")
        let command = literalBuilder.build()
        XCTAssertEqual(wire(command), "LOGIN ada {10}\r\npässwörd\r\n")
        XCTAssertTrue(command.hasSynchronizingLiteral)
        XCTAssertEqual(command.parts.count, 3)
    }

    func testLiteralModes() {
        var plus = IMAPCommandBuilder("APPEND", literalMode: .nonSynchronizing)
        plus.space()
        plus.literal(Data("hello".utf8))
        let plusCommand = plus.build()
        XCTAssertEqual(wire(plusCommand), "APPEND {5+}\r\nhello\r\n")
        XCTAssertFalse(plusCommand.hasSynchronizingLiteral)

        var minus = IMAPCommandBuilder("APPEND", literalMode: .nonSynchronizingUpTo4096)
        minus.space()
        minus.literal(Data(repeating: 0x41, count: 4096))
        XCTAssertFalse(minus.build().hasSynchronizingLiteral)
        var minusLarge = IMAPCommandBuilder("APPEND", literalMode: .nonSynchronizingUpTo4096)
        minusLarge.space()
        minusLarge.literal(Data(repeating: 0x41, count: 4097))
        XCTAssertTrue(minusLarge.build().hasSynchronizingLiteral)
        XCTAssertTrue(wire(minusLarge.build()).hasPrefix("APPEND {4097}\r\n"))
    }

    func testLiteralModeFromCapabilities() {
        XCTAssertEqual(IMAPLiteralMode(capabilities: ["IMAP4REV1", "LITERAL+"]), .nonSynchronizing)
        XCTAssertEqual(IMAPLiteralMode(capabilities: ["IMAP4REV1", "LITERAL-"]), .nonSynchronizingUpTo4096)
        XCTAssertEqual(IMAPLiteralMode(capabilities: ["IMAP4REV2"]), .nonSynchronizingUpTo4096)
        XCTAssertEqual(IMAPLiteralMode(capabilities: ["IMAP4REV1"]), .synchronizing)
    }

    func testSensitiveCommandsAreRedactedInLogs() {
        var builder = IMAPCommandBuilder("LOGIN", sensitive: true)
        builder.raw(" ada hunter2")
        let command = builder.build()
        XCTAssertEqual(command.logDescription, "LOGIN [redacted]")
        XCTAssertFalse(command.logDescription.contains("hunter2"))
    }

    func testLiteralContentsAreElidedInLogs() {
        var builder = IMAPCommandBuilder("APPEND", literalMode: .nonSynchronizing)
        builder.raw(" Sent ")
        let message = Data("Subject: secret plans\r\n\r\nbody".utf8)
        builder.literal(message)
        let command = builder.build()
        XCTAssertFalse(command.logDescription.contains("secret"))
        XCTAssertTrue(command.logDescription.contains("<\(message.count) bytes>"), command.logDescription)
    }

    func testMailboxNames() {
        var builder = IMAPCommandBuilder("SELECT")
        builder.space()
        builder.mailbox("inbox")
        XCTAssertEqual(wire(builder.build()), "SELECT INBOX\r\n")

        var encoded = IMAPCommandBuilder("SELECT")
        encoded.space()
        encoded.mailbox("Entwürfe")
        XCTAssertEqual(wire(encoded.build()), "SELECT \"Entw&APw-rfe\"\r\n")

        var raw = IMAPCommandBuilder("SELECT")
        raw.space()
        raw.mailbox("[Gmail]/All Mail")
        XCTAssertEqual(wire(raw.build()), "SELECT \"[Gmail]/All Mail\"\r\n")

        var utf8 = IMAPCommandBuilder("SELECT", utf8Accepted: true)
        utf8.space()
        utf8.mailbox("Entwürfe")
        XCTAssertEqual(wire(utf8.build()), "SELECT \"Entwürfe\"\r\n")

        var alreadyEncoded = IMAPCommandBuilder("SELECT")
        alreadyEncoded.space()
        alreadyEncoded.mailbox("&U9dP4TDIMOwwpA-")
        XCTAssertEqual(wire(alreadyEncoded.build()), "SELECT \"&U9dP4TDIMOwwpA-\"\r\n", "wire names pass through")
    }

    func testFlagListFiltersInvalidFlags() {
        var builder = IMAPCommandBuilder("UID STORE")
        builder.raw(" 1 +FLAGS ")
        builder.flagList(["\\Seen", "bad flag", "$Forwarded", ""])
        XCTAssertEqual(wire(builder.build()), "UID STORE 1 +FLAGS (\\Seen $Forwarded)\r\n")
    }

    // MARK: Fetch items

    func testFetchItemWireForms() {
        XCTAssertEqual(IMAPFetchItem.uid.wire, "UID")
        XCTAssertEqual(IMAPFetchItem.rfc822Size.wire, "RFC822.SIZE")
        XCTAssertEqual(IMAPFetchItem.bodyPeek(section: "", partial: nil).wire, "BODY.PEEK[]")
        XCTAssertEqual(IMAPFetchItem.bodyPeek(section: "1.2", partial: (0, 2048)).wire, "BODY.PEEK[1.2]<0.2048>")
        XCTAssertEqual(IMAPFetchItem.body(section: "TEXT", partial: nil).wire, "BODY[TEXT]")
        XCTAssertEqual(IMAPFetchItem.headerFields(["References", "In-Reply-To", "List-Unsubscribe"]).wire,
                       "BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE)]")
        XCTAssertEqual(IMAPFetchItem.headerFieldsNot(["Received"]).wire, "BODY.PEEK[HEADER.FIELDS.NOT (RECEIVED)]")
        XCTAssertEqual(IMAPFetchItem.gmailThreadID.wire, "X-GM-THRID")
        XCTAssertEqual(IMAPFetchItem.gmailMessageID.wire, "X-GM-MSGID")
        XCTAssertEqual(IMAPFetchItem.gmailLabels.wire, "X-GM-LABELS")
        XCTAssertEqual(IMAPFetchItem.modSeq.wire, "MODSEQ")
        XCTAssertEqual(IMAPFetchItem.bodyPeek(section: "1", partial: (0, 2048)), IMAPFetchItem.bodyPeek(section: "1", partial: (0, 2048)))
        XCTAssertNotEqual(IMAPFetchItem.bodyPeek(section: "1", partial: nil), IMAPFetchItem.bodyPeek(section: "2", partial: nil))
    }

    func testSectionKeysNormalize() {
        XCTAssertEqual(IMAPFetchResponse.sectionKey("header.fields ( \"From\"  To )"), "HEADER.FIELDS (FROM TO)")
        XCTAssertEqual(IMAPFetchResponse.sectionKey("1.2"), "1.2")
        XCTAssertEqual(IMAPFetchResponse.sectionKey(""), "")
        XCTAssertEqual(IMAPFetchItem.headerFields(["references"]).sectionKey, "HEADER.FIELDS (REFERENCES)")
        XCTAssertNil(IMAPFetchItem.envelope.sectionKey)
    }

    // MARK: Dates

    func testInternalDateParsing() {
        let date = IMAPDate.parseInternalDate("17-Jul-1996 02:44:25 -0700")
        XCTAssertEqual(date?.timeIntervalSince1970, 837_596_665)
        XCTAssertEqual(IMAPDate.parseInternalDate(" 7-Oct-2026 09:05:00 +0000")?.timeIntervalSince1970, 1_791_363_900)
        XCTAssertEqual(IMAPDate.parseInternalDate("20-OCT-2026 10:00:00 +0530")?.timeIntervalSince1970, 1_792_470_600)
        XCTAssertNil(IMAPDate.parseInternalDate("garbage"))
        XCTAssertNil(IMAPDate.parseInternalDate("32-Jan-2026 00:00:00 +0000"))
        XCTAssertNil(IMAPDate.parseInternalDate("01-Foo-2026 00:00:00 +0000"))
        XCTAssertNil(IMAPDate.parseInternalDate(""))
    }

    func testInternalDateFormatting() {
        XCTAssertEqual(IMAPDate.formatInternalDate(Date(timeIntervalSince1970: 837_596_665)), "17-Jul-1996 09:44:25 +0000")
        XCTAssertEqual(IMAPDate.formatInternalDate(Date(timeIntervalSince1970: 0)), "01-Jan-1970 00:00:00 +0000")
        XCTAssertEqual(IMAPDate.formatSearchDate(Date(timeIntervalSince1970: 1_792_454_400)), "20-Oct-2026")
        let now = Date(timeIntervalSince1970: 1_792_470_123)
        XCTAssertEqual(IMAPDate.parseInternalDate(IMAPDate.formatInternalDate(now))?.timeIntervalSince1970, 1_792_470_123)
    }

    // MARK: Search

    private func searchWire(_ criteria: IMAPSearchCriteria, literalMode: IMAPLiteralMode = .synchronizing) -> String {
        var builder = IMAPCommandBuilder("UID SEARCH", literalMode: literalMode)
        builder.space()
        criteria.encode(into: &builder)
        return wire(builder.build())
    }

    func testSearchEncoding() {
        let since = Date(timeIntervalSince1970: 1_792_454_400)
        XCTAssertEqual(searchWire(.all), "UID SEARCH ALL\r\n")
        XCTAssertEqual(searchWire(.and([.since(since), .unseen, .or(.from("ada"), .subject("ada lovelace"))])),
                       "UID SEARCH SINCE 20-Oct-2026 UNSEEN OR FROM \"ada\" SUBJECT \"ada lovelace\"\r\n")
        XCTAssertEqual(searchWire(.uid(IMAPSequenceSet([1, 2, 3, 7]))), "UID SEARCH UID 1:3,7\r\n")
        XCTAssertEqual(searchWire(.header("Message-ID", "<abc@example.com>")), "UID SEARCH HEADER Message-ID \"<abc@example.com>\"\r\n")
        XCTAssertEqual(searchWire(.not(.and([.seen, .flagged]))), "UID SEARCH NOT (SEEN FLAGGED)\r\n")
        XCTAssertEqual(searchWire(.gmailRaw("has:attachment from:ada")), "UID SEARCH X-GM-RAW \"has:attachment from:ada\"\r\n")
        XCTAssertEqual(searchWire(.gmailMessageID(1_278_455_344_230_334_865)), "UID SEARCH X-GM-MSGID 1278455344230334865\r\n")
        XCTAssertEqual(searchWire(.anyOf([.from("q"), .subject("q"), .body("q")])), "UID SEARCH OR FROM \"q\" OR SUBJECT \"q\" BODY \"q\"\r\n")
        XCTAssertEqual(searchWire(.anyOf([])), "UID SEARCH ALL\r\n")
        XCTAssertEqual(searchWire(.and([.larger(1000), .smaller(-5), .keyword("$Forwarded")])), "UID SEARCH LARGER 1000 SMALLER 0 KEYWORD $Forwarded\r\n")
    }

    func testSearchWithNonASCIIUsesLiterals() {
        let criteria = IMAPSearchCriteria.subject("Grüße")
        XCTAssertTrue(criteria.requiresUTF8)
        XCTAssertEqual(searchWire(criteria), "UID SEARCH SUBJECT {7}\r\nGrüße\r\n")
        XCTAssertEqual(searchWire(criteria, literalMode: .nonSynchronizing), "UID SEARCH SUBJECT {7+}\r\nGrüße\r\n")
        XCTAssertFalse(IMAPSearchCriteria.subject("Hello").requiresUTF8)
        XCTAssertTrue(IMAPSearchCriteria.or(.from("a"), .not(.text("日本"))).requiresUTF8)
        XCTAssertTrue(IMAPSearchCriteria.and([.unseen, .gmailRaw("x")]).requiresGmail)
        XCTAssertFalse(IMAPSearchCriteria.unseen.requiresGmail)
    }
}
