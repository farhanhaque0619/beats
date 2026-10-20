import XCTest
import InkModel
@testable import InkMIME

final class MIMEParserTests: XCTestCase {
    func testSinglePartDefaults() {
        let parsed = MIMEParser.parse(Raw.data("""
        Subject: hello

        Just text.
        """))
        XCTAssertEqual(parsed.root.partID, "1")
        XCTAssertEqual(parsed.root.contentType.mimeType, "text/plain")
        XCTAssertEqual(parsed.root.contentType.charset, "us-ascii")
        XCTAssertEqual(parsed.root.transferEncoding, "7bit")
        XCTAssertEqual(parsed.plainText, "Just text.")
        XCTAssertNil(parsed.html)
        XCTAssertTrue(parsed.attachments.isEmpty)
    }

    func testIMAPPartNumbering() {
        let raw = """
        Content-Type: multipart/mixed; boundary=outer

        --outer
        Content-Type: text/plain

        one
        --outer
        Content-Type: application/octet-stream

        two
        --outer
        Content-Type: message/rfc822

        Subject: inner
        Content-Type: multipart/mixed; boundary=inner

        --inner
        Content-Type: text/plain

        three-one
        --inner
        Content-Type: application/octet-stream

        three-two
        --inner--
        --outer
        Content-Type: multipart/mixed; boundary=four

        --four
        Content-Type: image/gif

        four-one
        --four
        Content-Type: message/rfc822

        Subject: deep
        Content-Type: multipart/mixed; boundary=deep

        --deep
        Content-Type: text/plain

        four-two-one
        --deep
        Content-Type: multipart/alternative; boundary=alt

        --alt
        Content-Type: text/plain

        four-two-two-one
        --alt
        Content-Type: text/richtext

        four-two-two-two
        --alt--
        --deep--
        --four--
        --outer
        Content-Type: message/rfc822

        Subject: simple inner

        five-one
        --outer--
        """
        let root = MIMEParser.parse(Raw.data(raw)).root
        XCTAssertEqual(root.partID, "")
        XCTAssertEqual(root.children.map(\.partID), ["1", "2", "3", "4", "5"])
        XCTAssertEqual(root.part(withID: "1")?.text(), "one")
        XCTAssertEqual(root.part(withID: "3")?.contentType.mimeType, "message/rfc822")
        XCTAssertEqual(root.part(withID: "3.1")?.text(), "three-one")
        XCTAssertEqual(String(decoding: root.part(withID: "3.2")?.body ?? Data(), as: UTF8.self), "three-two")
        XCTAssertEqual(root.part(withID: "4.1")?.contentType.mimeType, "image/gif")
        XCTAssertEqual(root.part(withID: "4.2")?.contentType.mimeType, "message/rfc822")
        XCTAssertEqual(root.part(withID: "4.2.1")?.text(), "four-two-one")
        XCTAssertEqual(root.part(withID: "4.2.2")?.contentType.mimeType, "multipart/alternative")
        XCTAssertEqual(root.part(withID: "4.2.2.1")?.text(), "four-two-two-one")
        XCTAssertEqual(root.part(withID: "4.2.2.2")?.contentType.mimeType, "text/richtext")
        XCTAssertEqual(root.part(withID: "5.1")?.text(), "five-one")
        XCTAssertEqual(root.part(withID: "3")?.embeddedMessage?.subject, "inner")
        XCTAssertNil(root.part(withID: "9"))
        XCTAssertEqual(root.leafParts.count, 6)   // encapsulated messages are leaves
    }

    func testPreambleEpilogueAndTransportPadding() {
        let parsed = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary="b"

        This is the preamble. It should be ignored.
        --b\u{20}\u{20}\u{09}
        Content-Type: text/plain

        body
        --b--\u{20}\u{20}
        This is the epilogue. It should also be ignored.
        """))
        XCTAssertEqual(parsed.root.children.count, 1)
        XCTAssertEqual(parsed.plainText, "body")
    }

    func testBoundaryPrefixOfAnotherIsNotConfused() {
        // The inner boundary starts with the outer one.
        let parsed = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary="abc"

        --abc
        Content-Type: multipart/alternative; boundary="abc-inner"

        --abc-inner
        Content-Type: text/plain

        plain
        --abc-inner
        Content-Type: text/html

        <p>html</p>
        --abc-inner--
        --abc
        Content-Type: text/plain; name=notes.txt
        Content-Disposition: attachment

        notes
        --abc--
        """))
        XCTAssertEqual(parsed.root.children.count, 2)
        XCTAssertEqual(parsed.root.children[0].children.count, 2)
        XCTAssertEqual(parsed.plainText, "plain")
        XCTAssertEqual(parsed.html, "<p>html</p>")
        XCTAssertEqual(parsed.attachments.map(\.filename), ["notes.txt"])
    }

    func testEmptyPartsAndPartsWithoutHeaders() {
        let parsed = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=b

        --b
        --b

        no headers here
        --b
        This part has no blank line and no headers
        --b--
        """))
        XCTAssertEqual(parsed.root.children.count, 3)
        XCTAssertEqual(parsed.root.children[1].text(), "no headers here")
        XCTAssertEqual(parsed.root.children[2].text(), "This part has no blank line and no headers")
        XCTAssertEqual(parsed.plainText, "no headers here\nThis part has no blank line and no headers")
    }

    func testMissingBoundaryParameterIsDetected() {
        let parsed = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/alternative

        --detected
        Content-Type: text/plain

        found me
        --detected
        Content-Type: text/html

        <b>found me</b>
        --detected--
        """))
        XCTAssertEqual(parsed.plainText, "found me")
        XCTAssertEqual(parsed.html, "<b>found me</b>")
    }

    func testWrongBoundaryFallsBackToText() {
        let parsed = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary="nope"

        There are no parts here at all.
        """))
        XCTAssertEqual(parsed.root.contentType.mimeType, "text/plain")
        XCTAssertEqual(parsed.root.partID, "1")
        XCTAssertEqual(parsed.plainText, "There are no parts here at all.")
    }

    func testDigestDefaultsToMessages() {
        let parsed = MIMEParser.parse(Raw.data("""
        Subject: Digest
        Content-Type: multipart/digest; boundary=d

        --d

        Subject: First
        From: a@example.com

        First body
        --d

        Subject: Second
        From: b@example.com

        Second body
        --d--
        """))
        XCTAssertEqual(parsed.root.children.map(\.contentType.mimeType), ["message/rfc822", "message/rfc822"])
        XCTAssertEqual(parsed.root.children[1].embeddedMessage?.subject, "Second")
        XCTAssertEqual(parsed.root.children[1].embeddedMessage?.plainText, "Second body")
        XCTAssertEqual(parsed.attachments.count, 2)
        XCTAssertEqual(parsed.attachments.first?.filename, "First.eml")
    }

    func testBase64EncodedMessageRFC822() {
        let inner = "Subject: Wrapped\r\nContent-Type: text/plain\r\n\r\nInside base64"
        let parsed = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: message/rfc822
        Content-Transfer-Encoding: base64
        Content-Disposition: attachment

        \(Data(inner.utf8).base64EncodedString())
        --b--
        """))
        let part = parsed.root.children[0]
        XCTAssertEqual(part.embeddedMessage?.subject, "Wrapped")
        XCTAssertEqual(part.embeddedMessage?.plainText, "Inside base64")
        XCTAssertEqual(parsed.attachments.first?.mimeType, "message/rfc822")
        XCTAssertEqual(parsed.attachments.first?.data, Data(inner.utf8))
    }

    func testEnvelopeFields() {
        let parsed = MIMEParser.parse(Raw.data("""
        From: Ada <ada@example.com>
        Reply-To: list@example.com
        To: alex@ink.example, Bob <bob@example.org>
        To: second-to@example.org
        Cc: carol@example.net
        Bcc: secret@example.com
        Subject:   =?UTF-8?Q?Hello?=   there
        Date: Tue, 20 Oct 2026 09:15:30 +0000
        Message-ID: <id-1@example.com>
        In-Reply-To: <parent@example.com>
        References: <root@example.com>
         <parent@example.com>

        x
        """))
        XCTAssertEqual(parsed.from.map(\.address), ["ada@example.com"])
        XCTAssertEqual(parsed.replyTo.map(\.address), ["list@example.com"])
        XCTAssertEqual(parsed.to.map(\.address), ["alex@ink.example", "bob@example.org", "second-to@example.org"])
        XCTAssertEqual(parsed.cc.map(\.address), ["carol@example.net"])
        XCTAssertEqual(parsed.bcc.map(\.address), ["secret@example.com"])
        XCTAssertEqual(parsed.subject, "Hello there")
        XCTAssertEqual(parsed.date, Date.utc(2026, 10, 20, 9, 15, 30))
        XCTAssertEqual(parsed.messageID, "id-1@example.com")
        XCTAssertEqual(parsed.inReplyTo, ["parent@example.com"])
        XCTAssertEqual(parsed.references, ["root@example.com", "parent@example.com"])
    }

    func testDateFallsBackToReceived() {
        let parsed = MIMEParser.parse(Raw.data("""
        Received: from mx.example.com by mail.ink.example; Tue, 20 Oct 2026 09:15:30 +0000
        Subject: no date

        x
        """))
        XCTAssertEqual(parsed.date, Date.utc(2026, 10, 20, 9, 15, 30))
    }

    func testBodyConvenience() {
        let parsed = MIMEParser.parse(Raw.data(Fixtures.gmailInlineImage))
        let body = parsed.body(messageID: "acct|INBOX|1|42")
        XCTAssertEqual(body.messageID, "acct|INBOX|1|42")
        XCTAssertEqual(body.html, parsed.html)
        XCTAssertEqual(body.plainText, parsed.plainText)
        XCTAssertEqual(body.attachments.count, 1)
        XCTAssertTrue(body.visibleAttachments.isEmpty)
    }

    func testParsePartAndDecodeText() {
        let part = MIMEParser.parsePart(Raw.data("""
        Content-Type: text/html; charset=windows-1252
        Content-Transfer-Encoding: quoted-printable

        <p>=93Hi=94</p>
        """), partID: "1.2")
        XCTAssertEqual(part.partID, "1.2")
        XCTAssertEqual(part.text(), "<p>“Hi”</p>")

        // A truncated snippet fetch: base64 cut mid-quantum, charset multibyte cut mid-character.
        let full = Data("Grüße aus München und viele Grüße zurück".utf8).base64EncodedString()
        let cut = Data(full.prefix(30).utf8)
        let text = MIMEParser.decodeText(cut, transferEncoding: "base64", contentType: ContentType.parse("text/plain; charset=utf-8"))
        XCTAssertTrue("Grüße aus München und viele Grüße zurück".hasPrefix(text))
        XCTAssertFalse(text.isEmpty)

        let flowed = MIMEParser.decodeText(Data("one \r\ntwo\r\n".utf8), transferEncoding: "7bit", contentType: ContentType.parse("text/plain; format=flowed"))
        XCTAssertEqual(flowed, "one two\n")

        let sniffed = MIMEParser.decodeText(Data("<meta charset=\"koi8-r\"><p>\u{0}".utf8) + Data([0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4]),
                                            transferEncoding: nil, contentType: ContentType.parse("text/html"))
        XCTAssertTrue(sniffed.hasSuffix("Привет"))
    }

    func testEmptyAndGarbageInput() {
        let empty = MIMEParser.parse(Data())
        XCTAssertEqual(empty.subject, "")
        XCTAssertTrue(empty.from.isEmpty)
        XCTAssertNil(empty.date)
        XCTAssertNil(empty.html)

        let binary = MIMEParser.parse(Data((0..<4096).map { UInt8(truncatingIfNeeded: $0 &* 31 &+ 7) }))
        XCTAssertNotNil(binary.root)

        let onlyHeaders = MIMEParser.parse(Data("Subject: only headers".utf8))
        XCTAssertEqual(onlyHeaders.subject, "only headers")
    }

    func testDeepNestingIsBounded() {
        var raw = "Subject: deep\r\n"
        for level in 0..<200 {
            raw += "Content-Type: multipart/mixed; boundary=\"b\(level)\"\r\n\r\n--b\(level)\r\n"
        }
        raw += "Content-Type: text/plain\r\n\r\nbottom\r\n"
        let parsed = MIMEParser.parse(Data(raw.utf8))
        XCTAssertNotNil(parsed.root)
        var depth = 0
        var node = parsed.root
        while let child = node.children.first { node = child; depth += 1 }
        XCTAssertLessThanOrEqual(depth, MIMEParser.maxDepth + 1)
    }
}
