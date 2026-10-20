import XCTest
import InkModel
@testable import InkMIME

/// Regression tests from an adversarial review of real-world mail handling: snippets, lost or
/// hidden attachments, filename spoofing, the reader document's isolation and outgoing headers.
final class MailCorrectnessReviewTests: XCTestCase {
    // MARK: Snippets

    func testSnippetDropsPreheaderPaddingInPlainText() {
        // Newsletters pad the text/plain preheader with CGJ / ZWNJ / BOM runs, not only the HTML.
        let plain = "Big autumn sale \u{034F} \u{200C} \u{034F} \u{200C} \u{034F} \u{200C}\u{FEFF}\u{200B}\u{00AD}\u{2060}\nHello there"
        XCTAssertEqual(Snippet.make(plain: plain, html: nil), "Big autumn sale Hello there")
        // Padding glued to the last word, and a line of nothing but padding.
        XCTAssertEqual(Snippet.make(plain: "Deals inside\u{034F}\u{200C}\u{034F}\u{200C}\n\u{200C}\u{034F}\u{00A0}\u{200B}\nShop now", html: nil),
                       "Deals inside Shop now")
        // A plain part that is only padding falls through to the HTML.
        XCTAssertEqual(Snippet.make(plain: "\u{034F}\u{200C}\u{200B}", html: "<p>From HTML</p>"), "From HTML")
    }

    func testSnippetKeepsMeaningfulJoiners() {
        // ZWNJ inside a Persian word and ZWJ inside an emoji sequence are part of the text.
        XCTAssertEqual(Snippet.make(plain: "می\u{200C}خواهم", html: nil), "می\u{200C}خواهم")
        XCTAssertEqual(Snippet.make(plain: "Family 👨\u{200D}👩\u{200D}👧 photo", html: nil), "Family 👨\u{200D}👩\u{200D}👧 photo")
    }

    func testSnippetDropsZWNJNextToNoBreakSpacesInHTML() {
        let html = "<div style=\"display:none;max-height:0\">Your weekly digest&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;\u{034F}\u{200C}\u{00A0}\u{200C}</div><p>Hi Ada,</p>"
        XCTAssertEqual(Snippet.make(plain: nil, html: html), "Your weekly digest Hi Ada,")
        XCTAssertFalse(HTMLText.toPlainText(html).unicodeScalars.contains("\u{200C}"))
        // Between letters it stays.
        XCTAssertEqual(HTMLText.toPlainText("<p>می&zwnj;خواهم</p>"), "می\u{200C}خواهم")
        XCTAssertEqual(HTMLText.toPlainText("<p>می\u{200C}خواهم</p>"), "می\u{200C}خواهم")
    }

    func testEmptyCommentsDoNotSwallowContent() {
        XCTAssertEqual(HTMLText.toPlainText("<p>a</p><!---><p>visible</p><!-- c --><p>b</p>"), "a\n\nvisible\n\nb")
        XCTAssertEqual(HTMLText.toPlainText("<p>a</p><!--><p>visible</p><!-- c --><p>b</p>"), "a\n\nvisible\n\nb")
        // Outlook's "downlevel-revealed" pattern still works.
        XCTAssertEqual(HTMLText.toPlainText("<!--[if !mso]><!--><p>Web</p><!--<![endif]--><!--[if mso]><p>Outlook</p><![endif]-->"), "Web")
    }

    // MARK: Attachments

    func testFilenameBidiOverridesAreRemoved() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: text/plain

        Body
        --b
        Content-Type: application/octet-stream; name="=?UTF-8?Q?report=E2=80=AEcod.scr?="
        Content-Disposition: attachment; filename*=UTF-8''invoice%E2%80%AEfdp.exe

        x
        --b
        Content-Type: application/octet-stream; name="=?UTF-8?Q?report=E2=81=A7cod.scr?="

        y
        --b--
        """))
        XCTAssertEqual(m.attachments.map(\.filename), ["invoicefdp.exe", "reportcod.scr"])
        XCTAssertEqual(HeaderParameters.sanitizeFilename("\u{200F}\u{202B}name\u{202C}.pdf"), "name.pdf")
        XCTAssertNil(HeaderParameters.sanitizeFilename("\u{202E}\u{2066}"))
    }

    func testContentIDPrefixDoesNotHideAnotherAttachment() {
        // "cid:10" in the HTML must not mark the part with Content-ID <1> as inline (hidden).
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/related; boundary=r

        --r
        Content-Type: text/html

        <p><img src="cid:10"></p>
        --r
        Content-Type: image/png
        Content-ID: <10>

        png10
        --r
        Content-Type: image/png; name=chart.png
        Content-ID: <1>

        png1
        --r--
        """))
        XCTAssertEqual(m.attachments.map(\.contentID), ["10", "1"])
        XCTAssertEqual(m.attachments.map(\.isInline), [true, false])
    }

    func testContentIDReferencesAreMatchedWhole() {
        let html = """
        <img src='CID:Logo@Example.COM'><img src="cid:a%40b"><div style="background:url(cid:bg.png)"></div><img src=cid:x&amp;y>
        """
        XCTAssertEqual(BodySelector.referencedContentIDs(html), ["logo@example.com", "a%40b", "a@b", "bg.png", "x&y"])
    }

    func testNamedInlineTextAttachmentIsListed() {
        // Apple Mail attaches text files with `Content-Disposition: inline`.
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary="Apple-Mail=_1"

        --Apple-Mail=_1
        Content-Type: text/plain; charset=us-ascii

        See the notes.
        --Apple-Mail=_1
        Content-Disposition: inline; filename=notes.txt
        Content-Type: text/plain; x-unix-mode=0644; name="notes.txt"

        line 1
        --Apple-Mail=_1--
        """))
        XCTAssertEqual(m.plainText, "See the notes.\nline 1")
        XCTAssertEqual(m.attachments.map(\.filename), ["notes.txt"])
        XCTAssertEqual(m.attachments.first?.data, Data("line 1".utf8))
        XCTAssertEqual(m.attachments.first?.isInline, false)
    }

    func testAttachmentOnlyInPlainAlternativeIsKept() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain

        Plain
        --m
        Content-Type: application/pdf; name=x.pdf
        Content-Disposition: attachment; filename=x.pdf

        pdf
        --m--
        --a
        Content-Type: text/html

        <p>HTML</p>
        --a--
        """))
        XCTAssertEqual(m.html, "<p>HTML</p>")
        XCTAssertEqual(m.plainText, "Plain")
        XCTAssertEqual(m.attachments.map(\.filename), ["x.pdf"])
    }

    func testAttachmentInBothAlternativesIsListedOnce() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: multipart/mixed; boundary=m1

        --m1
        Content-Type: text/plain

        Plain
        --m1
        Content-Type: application/pdf; name=x.pdf
        Content-Transfer-Encoding: base64

        cGRm
        --m1--
        --a
        Content-Type: multipart/mixed; boundary=m2

        --m2
        Content-Type: text/html

        <p>HTML</p>
        --m2
        Content-Type: application/pdf; name=x.pdf
        Content-Transfer-Encoding: base64

        cGRm
        --m2--
        --a--
        """))
        XCTAssertEqual(m.attachments.map(\.filename), ["x.pdf"])
        XCTAssertEqual(m.attachments.map(\.id), ["2.2"])
    }

    // MARK: Reader document

    func testStrayEndTagsCannotCloseInksWrapper() {
        // A stray `</div>` would close #ink-content, and what follows would miss the dark-mode
        // recolouring (black text on a black page).
        let html = "<div>Hi</div></div></div><p style=\"color:#000000\">After the stray tags</p>"
        let sanitized = HTMLSanitizer.sanitize(html).body
        XCTAssertEqual(sanitized, "<div>Hi</div><p style=\"color:#000000\">After the stray tags</p>")
        let doc = EmailHTMLDocument.build(html: html, plainText: nil, options: .init(dark: true))
        XCTAssertTrue(doc.contains("<div>Hi</div><p style=\"color:#000000\">After the stray tags</p>\n</div>\n</body>"))
    }

    func testListItemsCloseTheirDivsLikeABrowser() {
        // The second <li> closes the first one *and* the div inside it; the email's later </div>
        // has nothing left to close and must not reach Ink's wrapper.
        let sanitized = HTMLSanitizer.sanitize("<ul><li><div>one<li>two</div></ul><p>after</p>").body
        XCTAssertEqual(sanitized, "<ul><li><div>one<li>two</ul><p>after</p>")
        XCTAssertEqual(HTMLSanitizer.sanitize("<dl><dt><div>term<dd>def</div></dl>").body, "<dl><dt><div>term<dd>def</dl>")
        // Matching end tags, </p> and </br> are kept.
        XCTAssertEqual(HTMLSanitizer.sanitize("<div><b>x</b></div></p>a</br>b").body, "<div><b>x</b></div></p>a</br>b")
    }

    func testStrayBlockquoteEndDoesNotEndAReplysQuote() {
        // The original's broken markup must not make the rest of the quote look like the reply.
        let message = OutgoingMessage(accountID: "a", from: EmailAddress(address: "me@example.com"),
                                      to: [EmailAddress(address: "you@example.com")], subject: "Re: x", body: "Reply",
                                      quotedText: "On Tue, you wrote:\n> Hello", quotedHTML: "<p>Hello</p></blockquote></div><p>Still quoted</p>",
                                      replyMode: .reply)
        let html = MessageBuilder.htmlBody(for: message)
        XCTAssertTrue(html.contains("<p>Hello</p><p>Still quoted</p>\n</blockquote>"), html)
    }

    func testPlaintextElementCannotSwallowTheDocument() {
        let doc = EmailHTMLDocument.build(html: "<p>a</p><plaintext><b>raw</b>", plainText: nil, options: .init())
        XCTAssertFalse(doc.contains("<plaintext"))
        XCTAssertTrue(doc.contains("&lt;b&gt;raw&lt;/b&gt;"))
    }

    func testDocumentPolicyCoversNavigationDirectives() {
        for allow in [false, true] {
            let doc = EmailHTMLDocument.build(html: "<p>x</p>", plainText: nil, options: .init(allowRemoteContent: allow))
            let policy = EmailHTMLDocument.contentSecurityPolicy(allowRemoteContent: allow)
            XCTAssertTrue(policy.hasPrefix("default-src 'none'; img-src cid: data:"))
            XCTAssertTrue(policy.contains("base-uri 'none'"))
            XCTAssertTrue(policy.contains("form-action 'none'"))
            XCTAssertTrue(doc.contains("content=\"\(policy)\""))
            XCTAssertTrue(doc.contains("<meta name=\"referrer\" content=\"no-referrer\">"))
        }
    }

    func testRemoteLoadVectorsAreRemovedOrLeftToThePolicy() {
        let html = """
        <html><head><base href="https://evil.example/"><meta http-equiv="refresh" content="0;url=https://evil.example">
        <link rel=stylesheet href="https://evil.example/a.css"><link rel=dns-prefetch href="//evil.example">
        <style>@import url(https://evil.example/b.css); @IMPORT "https://evil.example/c.css"; .x{background:url(https://evil.example/d.png)}</style></head>
        <body background="https://evil.example/bg.png"><img srcset="https://evil.example/e.png 2x" src="cid:x">
        <svg><image href="https://evil.example/f.png"/><a xlink:href="javascript:alert(1)"><text>t</text></a></svg>
        <a href="javascript:alert(1)">x</a><a href=" jav&#x09;ascript:alert(1)">y</a><a href="data:text/html,<b>">z</a>
        <iframe src="https://evil.example"></iframe><form action="https://evil.example"><input name=q><button formaction="https://evil.example">b</button></form>
        <object data="https://evil.example/o"></object><embed src="https://evil.example/e"><video poster="https://evil.example/p.png"></video>
        <a href="https://example.com/ok" ping="https://evil.example/ping" onclick="x()">ok</a></body></html>
        """
        let doc = EmailHTMLDocument.build(html: html, plainText: nil, options: .init())
        for banned in ["<base", "refresh", "<link", "@import", "@IMPORT", "javascript", "<iframe", "<form", "<input", "<button", "formaction",
                       "<object", "<embed", "ping=", "onclick", "data:text/html"] {
            XCTAssertFalse(doc.contains(banned), banned)
        }
        XCTAssertTrue(doc.contains("<a href=\"https://example.com/ok\">ok</a>"))
        // Remaining remote URLs (srcset, poster, SVG image, CSS url(), body background) are blocked by the policy.
        XCTAssertTrue(doc.contains("img-src cid: data:;"))
        XCTAssertFalse(doc.contains("img-src cid: data: https:"))
    }

    // MARK: Outgoing

    func testHeaderInjectionThroughEveryField() {
        var message = OutgoingMessage(accountID: "a",
                                      from: EmailAddress(name: "Ada\r\nBcc: x@evil.example", address: "ada@example.com\r\nBcc: y@evil.example"),
                                      to: [EmailAddress(name: "Bob\nX-Evil: 1", address: "bob@example.com")],
                                      bcc: [EmailAddress(address: "secret@example.com")],
                                      subject: "Hi\r\nBcc: z@evil.example\rX-Evil-CR: 1", body: "x")
        message.inReplyTo = "abc@x\r\nBcc: q@evil.example"
        message.references = ["r1@x\r\nX-Injected: 1"]
        message.attachments = [OutgoingAttachment(filename: "a\r\nX-File: 1.pdf", mimeType: "application/pdf\r\nX-Type: 1", data: Data("x".utf8))]
        let (data, _) = MessageBuilder.build(message)
        assertWireFormat(data)
        let lines = String(decoding: data, as: UTF8.self).components(separatedBy: "\r\n")
        for evil in ["Bcc:", "X-Evil", "X-Injected", "X-File", "X-Type"] {
            XCTAssertFalse(lines.contains { $0.hasPrefix(evil) }, evil)
        }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret@"))
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.to.map(\.address), ["bob@example.com"])
        XCTAssertTrue(parsed.bcc.isEmpty)
    }

    func testBuiltMessageRoundTripsNamesSubjectsAndLongLines() {
        let subject = String(repeating: "Ünïcödé subject words ", count: 8) + "🎉 end"
        let body = "Hello\n.\nFrom here\n" + String(repeating: "long ", count: 300) + "\n" + String(repeating: "x", count: 1200)
        let message = OutgoingMessage(accountID: "a", from: EmailAddress(name: "Zoë Ångström", address: "zoe@example.com"),
                                      to: [EmailAddress(name: "Bob, Jr.", address: "bob@example.com")], subject: subject, body: body,
                                      attachments: [OutgoingAttachment(filename: "Résumé – final version with a very long name indeed 2026.pdf",
                                                                       mimeType: "application/pdf", data: Data(repeating: 7, count: 100))])
        let (data, _) = MessageBuilder.build(message)
        assertWireFormat(data)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.subject, subject)
        XCTAssertEqual(parsed.from.first?.name, "Zoë Ångström")
        XCTAssertEqual(parsed.to.first?.name, "Bob, Jr.")
        XCTAssertEqual(parsed.plainText, body)
        XCTAssertEqual(parsed.attachments.map(\.filename), ["Résumé – final version with a very long name indeed 2026.pdf"])
        XCTAssertEqual(parsed.attachments.first?.data, Data(repeating: 7, count: 100))
    }
}
