import XCTest
import InkModel
@testable import InkMIME

final class MessageBuilderTests: XCTestCase {
    private let date = Date.utc(2026, 10, 20, 9, 15, 30)
    private let ada = EmailAddress(name: "Ada Lovelace", address: "ada@example.com")
    private let alex = EmailAddress(name: "Alex Rivera", address: "alex@ink.example")

    private func headerBlock(_ data: Data) -> String {
        let text = String(decoding: data, as: UTF8.self)
        return text.components(separatedBy: "\r\n\r\n").first ?? ""
    }

    /// The header block with folding undone, for substring checks.
    private func unfoldedHeaders(_ data: Data) -> String {
        headerBlock(data).replacingOccurrences(of: "\r\n ", with: " ")
    }

    func testSimpleMessageRoundTrip() {
        let message = OutgoingMessage(accountID: "a", from: alex, to: [ada], cc: [EmailAddress(address: "grace@example.com")],
                                      bcc: [EmailAddress(address: "secret@example.com")], subject: "Hello there",
                                      body: "Hi Ada,\n\nSee https://example.com for details.\n\nAlex")
        let (data, id) = MessageBuilder.build(message, date: date, messageID: "fixed-id@ink.example")
        XCTAssertEqual(id, "fixed-id@ink.example")
        assertWireFormat(data)

        let headers = unfoldedHeaders(data)
        XCTAssertFalse(headers.lowercased().contains("bcc"))
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret@example.com"))
        XCTAssertTrue(headers.contains("MIME-Version: 1.0"))
        XCTAssertTrue(headers.contains("User-Agent: Ink"))
        XCTAssertTrue(headers.contains("Message-ID: <fixed-id@ink.example>"))
        XCTAssertTrue(headers.contains("Content-Type: multipart/alternative; boundary=\"=_Ink_alt_"))

        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.subject, "Hello there")
        XCTAssertEqual(parsed.from.first?.name, "Alex Rivera")
        XCTAssertEqual(parsed.from.first?.address, "alex@ink.example")
        XCTAssertEqual(parsed.to.map(\.address), ["ada@example.com"])
        XCTAssertEqual(parsed.cc.map(\.address), ["grace@example.com"])
        XCTAssertTrue(parsed.bcc.isEmpty)
        XCTAssertEqual(parsed.date, date)
        XCTAssertEqual(parsed.messageID, "fixed-id@ink.example")
        XCTAssertEqual(parsed.plainText, "Hi Ada,\n\nSee https://example.com for details.\n\nAlex")
        XCTAssertEqual(parsed.html?.contains("<a href=\"https://example.com\">https://example.com</a>"), true)
        XCTAssertEqual(parsed.root.children.map(\.contentType.mimeType), ["text/plain", "text/html"])
        XCTAssertEqual(parsed.root.children.map(\.transferEncoding), ["quoted-printable", "quoted-printable"])
        XCTAssertEqual(parsed.root.children.first?.contentType.charset, "utf-8")
    }

    func testGeneratedMessageIDUsesSenderDomain() {
        let message = OutgoingMessage(accountID: "a", from: alex, to: [ada], subject: "x", body: "y")
        let (data, id) = MessageBuilder.build(message, date: date)
        XCTAssertTrue(id.hasSuffix("@ink.example"))
        XCTAssertEqual(id.count, 36 + 1 + "ink.example".count)
        XCTAssertEqual(MIMEParser.parse(data).messageID, id)
        let (_, other) = MessageBuilder.build(message, date: date)
        XCTAssertNotEqual(id, other)
        let noDomain = OutgoingMessage(accountID: "a", from: EmailAddress(address: "weird"), to: [ada], subject: "x", body: "y")
        XCTAssertTrue(MessageBuilder.build(noDomain).messageID.hasSuffix("@ink.local"))
    }

    func testNonASCIIHeadersAreEncoded() {
        let message = OutgoingMessage(
            accountID: "a",
            from: EmailAddress(name: "Zoë Müller", address: "zoe@example.de"),
            to: [EmailAddress(name: "山田 太郎", address: "yamada@example.co.jp"), EmailAddress(name: "Doe, Jane", address: "jane@example.com")],
            subject: "Grüße aus München — Planung für Q4 🎉 mit einem sehr langen Betreff, der gefaltet werden muss",
            body: "Hallo!"
        )
        let (data, _) = MessageBuilder.build(message, date: date)
        assertWireFormat(data, limit: 998)
        let headers = headerBlock(data)
        XCTAssertTrue(headers.utf8.allSatisfy { $0 < 0x80 })
        XCTAssertTrue(headers.contains("=?UTF-8?"))
        XCTAssertTrue(unfoldedHeaders(data).contains("\"Doe, Jane\" <jane@example.com>"))
        for line in headers.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 78, line)
        }
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.subject, message.subject)
        XCTAssertEqual(parsed.from.first?.name, "Zoë Müller")
        XCTAssertEqual(parsed.to.map { $0.name ?? "" }, ["山田 太郎", "Doe, Jane"])
    }

    func testHeaderInjectionIsNeutralised() {
        let message = OutgoingMessage(accountID: "a", from: alex, to: [EmailAddress(name: "Evil\r\nBcc: victim@example.com", address: "ada@example.com")],
                                      subject: "Hi\r\nBcc: victim@example.com\r\n\r\nInjected body", body: "Real body")
        let (data, _) = MessageBuilder.build(message, date: date)
        let headers = headerBlock(data)
        XCTAssertFalse(headers.contains("\r\nBcc:"))
        let parsed = MIMEParser.parse(data)
        XCTAssertNil(parsed.headers["Bcc"])
        XCTAssertEqual(parsed.plainText, "Real body")
        XCTAssertEqual(parsed.subject, "Hi Bcc: victim@example.com Injected body")
    }

    func testThreadingHeaders() {
        let refs = (1...30).map { "ref\($0)@example.com" }
        let message = OutgoingMessage(accountID: "a", from: alex, to: [ada], subject: "Re: x", body: "y",
                                      inReplyTo: "parent@example.com", references: refs)
        let (data, _) = MessageBuilder.build(message, date: date)
        assertWireFormat(data)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.inReplyTo, ["parent@example.com"])
        XCTAssertEqual(parsed.references, refs + ["parent@example.com"])
        XCTAssertTrue(headerBlock(data).contains("References: <ref1@example.com>"))
    }

    func testUndisclosedRecipients() {
        let message = OutgoingMessage(accountID: "a", from: alex, bcc: [ada], subject: "Blind", body: "x")
        let (data, _) = MessageBuilder.build(message, date: date)
        XCTAssertTrue(headerBlock(data).contains("To: undisclosed-recipients:;"))
        XCTAssertTrue(MIMEParser.parse(data).to.isEmpty)
    }

    func testAttachments() {
        let pdf = Data((0..<5000).map { UInt8(truncatingIfNeeded: $0 &* 7) })
        let message = OutgoingMessage(
            accountID: "a", from: alex, to: [ada], subject: "Files", body: "See attached.",
            attachments: [
                OutgoingAttachment(filename: "report.pdf", mimeType: "application/pdf", data: pdf),
                OutgoingAttachment(filename: "Präsentation Q3 – final mit einem wirklich sehr langen Dateinamen.pptx",
                                   mimeType: "application/vnd.openxmlformats-officedocument.presentationml.presentation", data: Data("pptx".utf8)),
                OutgoingAttachment(filename: "報告書.docx", mimeType: "bogus type", data: Data()),
                OutgoingAttachment(filename: "../evil\r\nname.txt", mimeType: "text/plain", data: Data("plain attachment".utf8)),
            ]
        )
        let (data, _) = MessageBuilder.build(message, date: date)
        assertWireFormat(data)
        let text = String(decoding: data, as: UTF8.self)
        XCTAssertTrue(unfoldedHeaders(data).contains("Content-Type: multipart/mixed; boundary=\"=_Ink_mix_"))
        XCTAssertTrue(text.contains("filename*0*=utf-8''Pr%C3%A4sentation"))
        XCTAssertTrue(text.contains("filename*=utf-8''%E5%A0%B1%E5%91%8A%E6%9B%B8.docx"))
        for line in text.components(separatedBy: "\r\n") where line.count > 0 && !line.contains(":") && !line.hasPrefix("--") && !line.hasPrefix(" ") {
            XCTAssertLessThanOrEqual(line.count, 76)
        }

        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.plainText, "See attached.")
        XCTAssertEqual(parsed.attachments.map(\.filename), [
            "report.pdf", "Präsentation Q3 – final mit einem wirklich sehr langen Dateinamen.pptx", "報告書.docx", "evil name.txt",
        ])
        XCTAssertEqual(parsed.attachments.map(\.mimeType), [
            "application/pdf", "application/vnd.openxmlformats-officedocument.presentationml.presentation", "application/octet-stream", "text/plain",
        ])
        XCTAssertEqual(parsed.attachments[0].data, pdf)
        XCTAssertEqual(parsed.attachments[1].data, Data("pptx".utf8))
        XCTAssertEqual(parsed.attachments[2].size, 0)
        XCTAssertEqual(parsed.attachments[3].data, Data("plain attachment".utf8))
        XCTAssertEqual(parsed.attachments.map(\.id), ["2", "3", "4", "5"])
        XCTAssertEqual(parsed.root.children.first?.contentType.mimeType, "multipart/alternative")
    }

    func testReplyWithQuotedHTML() {
        let message = OutgoingMessage(
            accountID: "a", from: alex, to: [ada], subject: "Re: Plans", body: "Sounds good!",
            quotedText: "On Tue, Oct 20, 2026 at 9:15 AM, Ada Lovelace <ada@example.com> wrote:\n> Lunch on Friday?\n> > Earlier",
            quotedHTML: "<html><head><style>p{color:red}</style></head><body><p onclick=\"x()\">Lunch on <b>Friday</b>?</p><img src=\"cid:logo\"><script>alert(1)</script></body></html>",
            inReplyTo: "parent@example.com", references: ["parent@example.com"], replyMode: .reply
        )
        let (data, _) = MessageBuilder.build(message, date: date)
        assertWireFormat(data)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.plainText, "Sounds good!\n\nOn Tue, Oct 20, 2026 at 9:15 AM, Ada Lovelace <ada@example.com> wrote:\n> Lunch on Friday?\n> > Earlier")
        let html = parsed.html ?? ""
        XCTAssertTrue(html.contains("Sounds good!"))
        XCTAssertTrue(html.contains("<div>On Tue, Oct 20, 2026 at 9:15 AM, Ada Lovelace &lt;<a href=\"mailto:ada@example.com\">ada@example.com</a>&gt; wrote:</div>"))
        XCTAssertTrue(html.contains("<blockquote type=\"cite\""))
        XCTAssertTrue(html.contains("<p>Lunch on <b>Friday</b>?</p>"))
        XCTAssertFalse(html.contains("onclick"))
        XCTAssertFalse(html.contains("<script"))
        XCTAssertFalse(html.contains("cid:logo"))
        XCTAssertFalse(html.contains("color:red"))
        // Our own quote detection sees it as a quote.
        XCTAssertTrue(QuoteSplitter.stripQuotedHTML(html).hadQuote)
        XCTAssertEqual(QuoteSplitter.split(parsed.plainText ?? "").body, "Sounds good!")
    }

    func testReplyWithPlainQuoteOnly() {
        let message = OutgoingMessage(accountID: "a", from: alex, to: [ada], subject: "Re: Plans", body: "Yes",
                                      quotedText: "On Tue, Ada wrote:\n> Lunch?\n> > Earlier?", replyMode: .reply)
        let html = MIMEParser.parse(MessageBuilder.build(message, date: date).data).html ?? ""
        XCTAssertTrue(html.contains("<div>On Tue, Ada wrote:</div>"))
        XCTAssertTrue(html.contains(">\nLunch?<blockquote type=\"cite\" style=\"margin: 0 0 0 0.8ex; border-left: 1px solid #ccc; padding-left: 1ex;\">Earlier?</blockquote>"))
    }

    func testForwardHTML() {
        let message = OutgoingMessage(accountID: "a", from: alex, to: [ada], subject: "Fwd: Plans", body: "FYI",
                                      quotedText: "---------- Forwarded message ---------\nFrom: Grace <grace@example.com>\nSubject: Plans\n\nOriginal body",
                                      replyMode: .forward)
        let parsed = MIMEParser.parse(MessageBuilder.build(message, date: date).data)
        let html = parsed.html ?? ""
        XCTAssertTrue(html.contains("<div>---------- Forwarded message ---------<br>\nFrom: Grace &lt;<a href=\"mailto:grace@example.com\">grace@example.com</a>&gt;<br>\nSubject: Plans</div>"))
        XCTAssertTrue(html.contains("Original body"))
        XCTAssertEqual(parsed.plainText?.hasSuffix("Original body"), true)
    }

    func testLongLinesAndSpecialBodies() {
        let longLine = String(repeating: "abcdefghij", count: 300)
        let body = "\(longLine)\n.\nFrom the start\nTrailing spaces   \nCRLF\r\nmixed\rlines\n" + String(repeating: "Ü", count: 2000)
        let message = OutgoingMessage(accountID: "a", from: alex, to: [ada], subject: String(repeating: "x", count: 1200), body: body)
        let (data, _) = MessageBuilder.build(message, date: date)
        assertWireFormat(data, limit: 998)
        for line in String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n") {
            XCTAssertNotEqual(line, ".")
            XCTAssertFalse(line.hasPrefix("From "))
        }
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.plainText, body.replacingOccurrences(of: "\r\n", with: "\n").replacingOccurrences(of: "\r", with: "\n"))
        XCTAssertEqual(parsed.subject, String(repeating: "x", count: 1200))
    }

    func testPathologicalHeaderValuesStayWithinLimits() {
        let huge = EmailAddress(name: "Huge", address: String(repeating: "a", count: 1500) + "@example.com")
        let message = OutgoingMessage(accountID: "a", from: alex, to: [huge, ada], subject: "x", body: "y",
                                      attachments: [OutgoingAttachment(filename: "f.bin", mimeType: "application/" + String(repeating: "x", count: 500), data: Data([1]))],
                                      inReplyTo: String(repeating: "i", count: 1200) + "@example.com")
        let (data, _) = MessageBuilder.build(message, date: date)
        assertWireFormat(data, limit: 998)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.to.map(\.address), ["ada@example.com"])
        XCTAssertEqual(parsed.attachments.first?.mimeType, "application/octet-stream")
        XCTAssertTrue(parsed.inReplyTo.isEmpty)
    }

    func testEmptyMessage() {
        let message = OutgoingMessage(accountID: "a", from: alex)
        let (data, _) = MessageBuilder.build(message, date: date)
        assertWireFormat(data)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.subject, "")
        XCTAssertEqual(parsed.plainText ?? "", "")
        XCTAssertNotNil(parsed.html)
    }

    func testDateHeaderIsCurrentZoneAndParses() {
        let (data, _) = MessageBuilder.build(OutgoingMessage(accountID: "a", from: alex, to: [ada], subject: "x", body: "y"), date: date)
        XCTAssertTrue(headerBlock(data).contains("Date: \(RFC5322Date.format(date))"))
    }
}
