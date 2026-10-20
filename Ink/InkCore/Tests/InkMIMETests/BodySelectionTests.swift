import XCTest
import InkModel
@testable import InkMIME

final class BodySelectionTests: XCTestCase {
    func testAlternativePrefersLastHTMLAndKeepsPlain() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: text/plain

        plain version
        --a
        Content-Type: text/enriched

        <bold>enriched</bold>
        --a
        Content-Type: text/html

        <p>html version</p>
        --a
        Content-Type: text/x-amp-html

        <html ⚡4email>amp</html>
        --a--
        """))
        XCTAssertEqual(m.plainText, "plain version")
        XCTAssertEqual(m.html, "<p>html version</p>")
        XCTAssertTrue(m.attachments.isEmpty)
    }

    func testRelatedUsesStartParameter() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/related; boundary=r; start="<root@x>"; type="text/html"

        --r
        Content-Type: image/png
        Content-ID: <img1@x>
        Content-Transfer-Encoding: base64

        iVBORw0KGgo=
        --r
        Content-Type: text/html
        Content-ID: <root@x>

        <img src="CID:img1@x"> and <img src="cid:missing@x">
        --r
        Content-Type: image/gif
        Content-ID: <unused@x>

        GIF89a
        --r--
        """))
        XCTAssertEqual(m.html?.hasPrefix("<img src=\"CID:img1@x\">"), true)
        XCTAssertEqual(m.attachments.map(\.contentID), ["img1@x", "unused@x"])
        XCTAssertEqual(m.attachments.map(\.isInline), [true, false])
        XCTAssertEqual(m.attachments.map(\.filename), ["Image 1.png", "Image 3.gif"])
    }

    func testMixedWithInterleavedTextAndImages() {
        // Apple Mail: text, inline image, more text.
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain; charset=utf-8

        Look at this:
        --m
        Content-Type: image/jpeg; name=photo.jpg
        Content-Disposition: inline; filename=photo.jpg
        Content-Transfer-Encoding: base64

        /9j/4AAQ
        --m
        Content-Type: text/plain; charset=utf-8

        Isn't it nice?
        --m--
        """))
        XCTAssertEqual(m.plainText, "Look at this:\nIsn't it nice?")
        XCTAssertNil(m.html)
        XCTAssertEqual(m.attachments.map(\.filename), ["photo.jpg"])
        XCTAssertFalse(m.attachments[0].isInline)   // nothing references it: show it as a file
    }

    func testMixedPlainAndHTMLPartsAreJoined() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/html

        <p>First <b>html</b></p>
        --m
        Content-Type: text/plain

        then <plain> & text
        --m--
        """))
        XCTAssertEqual(m.html, "<p>First <b>html</b></p>\n<div class=\"ink-plain-part\" style=\"white-space: pre-wrap\">then &lt;plain&gt; &amp; text</div>")
        XCTAssertEqual(m.plainText, "First html\nthen <plain> & text")
    }

    func testTextAttachmentsAreNotBody() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain

        Body text
        --m
        Content-Type: text/plain; name="log.txt"

        log line 1
        --m
        Content-Type: text/html
        Content-Disposition: attachment; filename="page.html"

        <p>saved page</p>
        --m
        Content-Type: text/csv
        Content-Disposition: inline

        a,b,c
        --m--
        """))
        XCTAssertEqual(m.plainText, "Body text")
        XCTAssertNil(m.html)
        XCTAssertEqual(m.attachments.map(\.filename), ["log.txt", "page.html", "Attachment 4.csv"])
        XCTAssertEqual(m.attachments[0].data, Data("log line 1".utf8))
    }

    func testInlineNamedTextPartIsBody() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: text/plain; name="message.txt"
        Content-Disposition: inline; filename="message.txt"

        Named but inline
        """))
        XCTAssertEqual(m.plainText, "Named but inline")
        XCTAssertTrue(m.attachments.isEmpty)
    }

    func testSinglePartAttachmentMessage() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: application/pdf; name=scan.pdf
        Content-Transfer-Encoding: base64

        JVBERi0xLjQKJSVFT0YK
        """))
        XCTAssertNil(m.plainText)
        XCTAssertNil(m.html)
        XCTAssertEqual(m.attachments.map(\.filename), ["scan.pdf"])
        XCTAssertEqual(m.attachments.first?.id, "1")
    }

    func testUUEncodedAttachment() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain

        see file
        --m
        Content-Type: application/octet-stream
        Content-Transfer-Encoding: x-uuencode

        begin 644 hello.txt
        12&5L;&\\L('5U96YC;V1E(0H
        `
        end
        --m--
        """))
        XCTAssertEqual(m.attachments.first?.filename, "hello.txt")
        XCTAssertEqual(m.attachments.first?.data, Data("Hello, uuencode!\n".utf8))
    }

    func testEmptyAndWhitespaceTextParts() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain

        \u{20}\u{20}
        --m
        Content-Type: text/plain

        Real text
        --m--
        """))
        XCTAssertEqual(m.plainText, "Real text")
    }

    func testMissingCharsetFallsBack() {
        let utf8 = MIMEParser.parse(Raw.bytes("Content-Type: text/plain\n\n", Array("Grüße".utf8)))
        XCTAssertEqual(utf8.plainText, "Grüße")
        let latin1 = MIMEParser.parse(Raw.bytes("Content-Type: text/plain\n\nGr", [0xFC, 0xDF], "e"))
        XCTAssertEqual(latin1.plainText, "Grüße")
        let html = MIMEParser.parse(Raw.bytes("Content-Type: text/html\n\n<meta http-equiv=\"Content-Type\" content=\"text/html; charset=windows-1251\"><p>", [0xCF, 0xF0, 0xE8], "</p>"))
        XCTAssertEqual(html.html?.hasSuffix("<p>При</p>"), true)
    }

    func testInlineImageReferencedCaseInsensitively() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/related; boundary=r

        --r
        Content-Type: text/html

        <img src="cid:Logo.PNG@01D9">
        --r
        Content-Type: image/png
        Content-ID: <logo.png@01d9>

        x
        --r--
        """))
        XCTAssertEqual(m.attachments.first?.isInline, true)
    }
}

final class RobustnessTests: XCTestCase {
    /// Random mutations of real messages: nothing may crash, and parsing must terminate quickly.
    func testMutatedFixturesNeverCrash() {
        let seeds = [Fixtures.gmailReply, Fixtures.appleMailInlineImage, Fixtures.outlookWinmail, Fixtures.encodedFilenames,
                     Fixtures.calendarInvite, Fixtures.thunderbirdForwardAttachment, Fixtures.iso2022jp, Fixtures.windows1252Newsletter]
        var rng = SplitMix64(seed: 2026)
        let interesting: [UInt8] = Array("=?\r\n\t-<>\"'();:,@&#%*\\/[]{}".utf8) + [0x00, 0x1B, 0x80, 0xC3, 0xE2, 0xFF, 0xFE]
        let start = Date()
        for seed in seeds {
            let original = [UInt8](Raw.data(seed))
            for _ in 0..<40 {
                var bytes = original
                let edits = Int.random(in: 1...30, using: &rng)
                for _ in 0..<edits {
                    guard !bytes.isEmpty else { break }
                    let i = Int.random(in: 0..<bytes.count, using: &rng)
                    switch Int.random(in: 0..<4, using: &rng) {
                    case 0: bytes[i] = interesting.randomElement(using: &rng) ?? 0
                    case 1: bytes.remove(at: i)
                    case 2: bytes.insert(interesting.randomElement(using: &rng) ?? 0, at: i)
                    default:
                        let end = min(bytes.count, i + Int.random(in: 1...200, using: &rng))
                        bytes.insert(contentsOf: bytes[i..<end], at: i)
                    }
                }
                let parsed = MIMEParser.parse(Data(bytes))
                _ = parsed.root.allParts.count
                _ = Snippet.make(plain: parsed.plainText, html: parsed.html)
                if let html = parsed.html {
                    _ = EmailHTMLDocument.build(html: html, plainText: parsed.plainText, options: .init(dark: true))
                    _ = QuoteSplitter.stripQuotedHTML(html)
                    _ = HTMLText.toPlainText(html)
                }
                if let plain = parsed.plainText { _ = QuoteSplitter.split(plain) }
            }
        }
        XCTAssertLessThan(Date().timeIntervalSince(start), 60)
    }

    func testRandomBytesEverywhere() {
        var rng = SplitMix64(seed: 7)
        for _ in 0..<300 {
            let count = Int.random(in: 0...600, using: &rng)
            let bytes = (0..<count).map { _ in UInt8.random(in: 0...255, using: &rng) }
            let text = String(decoding: bytes, as: UTF8.self)
            _ = MIMEParser.parse(Data(bytes))
            _ = EncodedWord.decode(text)
            _ = AddressParser.parseList(text)
            _ = MessageIDParser.parseList(text)
            _ = RFC5322Date.parse(text)
            _ = ContentType.parse(text)
            _ = ContentDisposition.parse(text)
            _ = HTMLText.toPlainText(text)
            _ = HTMLText.decodeEntities(text)
            _ = QuoteSplitter.split(text)
            _ = QuoteSplitter.stripQuotedHTML(text)
            _ = Snippet.make(plain: text, html: text)
            _ = EmailHTMLDocument.isDesigned(text)
            _ = EmailHTMLDocument.countTrackingPixels(text)
            _ = QuotedPrintable.decode(Data(bytes))
            _ = Base64Lenient.decode(Data(bytes))
            _ = UUEncode.decode(Data(bytes))
            for charset in ["utf-8", "gb2312", "shift_jis", "euc-jp", "iso-2022-jp", "big5", "euc-kr", "utf-16", "utf-32", "koi8-r", "x-junk", "utf-7"] {
                _ = Charset.decode(Data(bytes), charset: charset)
            }
        }
    }

    func testPathologicalInputsStayFast() {
        let start = Date()
        _ = EncodedWord.decode(String(repeating: "=?utf-8?q?", count: 5000))
        _ = AddressParser.parseList(String(repeating: "a, ", count: 20_000))
        _ = AddressParser.parseList(String(repeating: "(", count: 20_000))
        _ = HTMLText.toPlainText(String(repeating: "<div>", count: 50_000))
        _ = HTMLText.toPlainText(String(repeating: "<a href=\"", count: 5000))
        _ = QuoteSplitter.stripQuotedHTML(String(repeating: "<blockquote type=\"cite\">", count: 5000))
        let siblings = String(repeating: "<blockquote type=\"cite\">q</blockquote>", count: 5000)
        XCTAssertTrue(QuoteSplitter.stripQuotedHTML("<p>top</p>" + siblings).hadQuote)
        XCTAssertFalse(QuoteSplitter.stripQuotedHTML(siblings + "<p>bottom</p>").hadQuote)
        _ = QuoteSplitter.split(String(repeating: "> quote\n", count: 50_000))
        _ = MIMEParser.parse(Data(("Content-Type: multipart/mixed; boundary=b\r\n\r\n" + String(repeating: "--b\r\n", count: 20_000)).utf8))
        _ = MIMEParser.parse(Data(("Subject: x\r\n" + String(repeating: " folded\r\n", count: 50_000) + "\r\nbody").utf8))
        _ = Charset.decode(Data(Array(repeating: 0xFF, count: 100_000)), charset: "gb2312")
        _ = RFC5322Date.parse(String(repeating: "1 ", count: 10_000))
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }

    func testLargeMessageWithAttachment() {
        let payload = Data((0..<3_000_000).map { UInt8(truncatingIfNeeded: $0 &* 2_654_435_761 >> 13) })
        let message = OutgoingMessage(accountID: "a", from: EmailAddress(address: "a@example.com"), to: [EmailAddress(address: "b@example.com")],
                                      subject: "Big", body: "Large file attached",
                                      attachments: [OutgoingAttachment(filename: "big.bin", mimeType: "application/octet-stream", data: payload)])
        let start = Date()
        let (data, _) = MessageBuilder.build(message)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.attachments.first?.data, payload)
        XCTAssertLessThan(Date().timeIntervalSince(start), 30)
    }
}
