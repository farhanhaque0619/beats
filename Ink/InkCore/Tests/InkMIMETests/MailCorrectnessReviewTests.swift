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

    func testSnippetSkipsHTMLClientBoilerplateInTextAlternative() {
        let plain = "This message was sent in HTML. Please use an HTML-capable email client to view it.\n\nhttps://news.example.com/view/123"
        XCTAssertEqual(Snippet.make(plain: plain, html: "<p>Autumn deals are here</p>"), "Autumn deals are here")
        XCTAssertEqual(Snippet.make(plain: "Your email client does not support HTML messages.", html: "<p>Hello</p>"), "Hello")
        XCTAssertEqual(Snippet.make(plain: "This is the plain text version of our newsletter.\nBig news today", html: nil), "Big news today")
        // Typographic rules are separators too.
        XCTAssertEqual(Snippet.make(plain: "————————\n━━━━━━━━\n═══ ═══\nWeekly notes", html: nil), "Weekly notes")
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

    // MARK: Charsets

    func testUTF8LabelledAsLatin1IsReadAsUTF8() {
        // PHP mail() and web forms send UTF-8 bodies labelled ISO-8859-1.
        let m = MIMEParser.parse(Raw.bytes("""
        Subject: =?ISO-8859-1?Q?R=C3=A9servation_confirm=C3=A9e?=
        Content-Type: text/plain; charset=ISO-8859-1
        Content-Transfer-Encoding: 8bit

        """, Array("Votre réservation est confirmée – merci !".utf8)))
        XCTAssertEqual(m.subject, "Réservation confirmée")
        XCTAssertEqual(m.plainText, "Votre réservation est confirmée – merci !")
        // Real Latin-1 / Windows-1252 is unaffected, including bytes that only look like a lead byte.
        XCTAssertEqual(Charset.decode(Data([0x52, 0xE9, 0x73, 0x75, 0x6D, 0xE9]), charset: "iso-8859-1"), "Résumé")
        XCTAssertEqual(Charset.decode(Data([0x93, 0x48, 0x69, 0x94, 0x20, 0xC3]), charset: "windows-1252"), "\u{201C}Hi\u{201D} Ã")
        XCTAssertEqual(Charset.decode(Data([0xA4, 0x31, 0x30]), charset: "iso-8859-15"), "€10")
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

    func testEmptyHTMLAlternativeDoesNotHideThePlainText() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: text/plain; charset=utf-8

        The real text.
        --a
        Content-Type: text/html; charset=utf-8

        <html><head><style>p{}</style><title>x</title></head><body><div><br>&nbsp;</div><!-- nothing --></body></html>
        --a--
        """))
        XCTAssertEqual(m.plainText, "The real text.")
        XCTAssertNil(m.html)
        // An HTML part that is only an image still counts.
        let image = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: text/plain

        [image: banner]
        --a
        Content-Type: text/html

        <table><tr><td><img src="https://example.com/banner.png"></td></tr></table>
        --a--
        """))
        XCTAssertEqual(image.html, "<table><tr><td><img src=\"https://example.com/banner.png\"></td></tr></table>")
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

    func testInlineAnswersInAGmailQuoteAreNotCollapsed() {
        // Gmail inline replies put the answers inside div.gmail_quote, between pieces of the quote.
        let html = """
        <div dir="ltr">Answers inline.</div><br><div class="gmail_quote"><div dir="ltr" class="gmail_attr">On Mon, Oct 19, 2026 at 9:00 AM Ada &lt;ada@example.com&gt; wrote:<br></div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex"><div>Can you make Tuesday?</div></blockquote><div>Yes, Tuesday works.</div><blockquote class="gmail_quote" style="margin:0px 0px 0px 0.8ex"><div>Bring the slides?</div></blockquote><div>Will do.</div></div>
        """
        let doc = EmailHTMLDocument.build(html: html, plainText: nil, options: .init())
        XCTAssertFalse(doc.contains("<details"), "the answers would hide behind •••")
        XCTAssertTrue(doc.contains("Yes, Tuesday works."))
        // An ordinary trailing Gmail quote still collapses, and the snippet still drops the quote.
        let plainReply = "<div dir=\"ltr\">Sounds good.</div><br><div class=\"gmail_quote\"><div dir=\"ltr\" class=\"gmail_attr\">On Mon, Ada wrote:<br></div><blockquote class=\"gmail_quote\"><div>Lunch?</div></blockquote></div>"
        XCTAssertTrue(EmailHTMLDocument.build(html: plainReply, plainText: nil, options: .init()).contains("<details class=\"ink-quote\">"))
        XCTAssertEqual(Snippet.make(plain: nil, html: html), "Answers inline.")
    }

    func testInlineAnswersInPlainTextAreNotCollapsed() {
        let text = """
        Answers inline.

        On Mon, Oct 19, 2026 at 9:00 AM Ada <ada@example.com> wrote:
        > Can you make Tuesday?
        Yes, Tuesday works.
        > Bring the slides?
        Will do.
        """
        let doc = EmailHTMLDocument.build(html: nil, plainText: text, options: .init())
        XCTAssertFalse(doc.contains("<details"), "the answers would hide behind •••")
        XCTAssertTrue(doc.contains("Yes, Tuesday works."))
        XCTAssertEqual(Snippet.make(plain: text, html: nil), "Answers inline.")
        // A quote followed only by a list footer still collapses.
        let footer = "Thanks!\n\nOn Mon, Ada wrote:\n> Lunch?\n> Noon?\n\n_______________________\nteam mailing list\nteam@example.com"
        XCTAssertTrue(EmailHTMLDocument.build(html: nil, plainText: footer, options: .init()).contains("<details class=\"ink-quote\">"))
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

    func testChecksDoNotDependOnGraphemeClusters() {
        // "\u{301}" glues onto the ":" before it and "\u{600}" (a prepended mark) onto the
        // character after it, so Character-based hasPrefix/contains miss the match; on Apple
        // platforms String.contains(String) is Character-based, on Linux it isn't.
        XCTAssertTrue(HTMLSanitizer.isDangerousURL("javascript:\u{301}alert(1)"))
        XCTAssertTrue(HTMLSanitizer.isDangerousURL("JaVa\tScRiPt\u{0}:x"))
        XCTAssertFalse(HTMLSanitizer.isDangerousURL("https://example.com/javascript:"))
        XCTAssertTrue(HTMLSanitizer.isDangerousCSS("width: expression(\u{301}alert(1))"))
        XCTAssertEqual(HTMLSanitizer.sanitizeCSS("\u{600}@IMPORT url(x.css); a{b:c}</\u{301}style>"), "\u{600}/*x*/ url(x.css); a{b:c}<\\/\u{301}style>")
        XCTAssertEqual(EncodedWord.decode("\u{600}=?utf-8?Q?caf=C3=A9?="), "\u{600}café")
        XCTAssertEqual(AddressParser.parse("\"=?utf-8?Q?Zo=C3=AB?=\u{301}\" <zoe@example.com>")?.address, "zoe@example.com")
        let ct = ContentType.parse("application/pdf; name=\"\u{600}=?utf-8?Q?r=C3=A9sum=C3=A9?=.pdf\"")
        XCTAssertEqual(ct.parameters["name"], "\u{600}résumé.pdf")
        // A CRLF inside <body background> can't break out of the url('…') it is placed in.
        XCTAssertEqual(HTMLSanitizer.bodyAttributesCSS([HTMLAttribute(name: "background", value: "a\r\nb.png", valueRange: nil, range: 0..<0)]), "")
    }

    func testRemoteImagesCountBackgroundsAndSourceSets() {
        // The reader only offers "Load images" when this is above zero.
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<td background=\"https://cdn.example.com/hero.jpg\">Sale</td>"), 1)
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<div style=\"background-image: url( 'https://cdn.example.com/a.png' )\">x</div>"), 1)
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<style>.hero{background:URL(//cdn.example.com/b.png)}</style><p class=hero>x</p>"), 1)
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<picture><source srcset=\"https://a.example/x.webp 1x, https://a.example/x2.webp 2x\"><img srcset=\"https://a.example/y.png\" alt=\"\"></picture>"), 2)
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<video poster=\"http://a.example/p.jpg\"></video><svg><image href=\"https://a.example/i.png\"/></svg>"), 2)
        // One element is one image, and local sources don't count.
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<img src=\"https://a.example/1.png\" srcset=\"https://a.example/2.png 2x\">"), 1)
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<img src=cid:a srcset=\"data:image/png;base64,AA 2x\"><div style=\"background:url(cid:b)\"></div><a href=\"https://x.example\">x</a>"), 0)
        // A CRLF before a candidate's URL ("\r\n" is one Character) still separates it.
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<img srcset=\"a.png 1x,\r\n https://a.example/b.png 2x\">"), 1)
        XCTAssertEqual(EmailHTMLDocument.srcsetURLs("a.png\r\n1x,\r\n\thttps://a.example/b.png\r\n2x"), ["a.png", "https://a.example/b.png"])
    }

    func testBackgroundShorthandSplitAcrossCRLFIsStillPlain() {
        // "\r\n" is one Character: the shorthand's tokens must still split there.
        XCTAssertFalse(EmailHTMLDocument.cssHasBackground("td {\r\n  background: white\r\nno-repeat\r\n}"))
        XCTAssertTrue(EmailHTMLDocument.cssHasBackground("td {\r\n  background: white\r\n#202124\r\n}"))
    }

    // MARK: Outgoing

    func testReplyToOwnMessageWithOnlyCcGoesToTheCc() {
        let account = AccountConfig(id: "acc", provider: .fastmail, displayName: "Me", emailAddress: "me@example.org",
                                    imap: ServerConfig(host: "i", port: 993, security: .tls, username: "me"),
                                    smtp: ServerConfig(host: "s", port: 465, security: .tls, username: "me"))
        let sent = MessageSummary(accountID: "acc", mailboxPath: "Sent", uid: 1, uidValidity: 1, messageID: "orig@example.org", subject: "Plans",
                                  from: [EmailAddress(address: "Me@Example.org")], replyTo: [], to: [],
                                  cc: [EmailAddress(address: "bob@example.com"), EmailAddress(address: "carol@example.com")], date: Date.utc(2026, 10, 1))
        let all = ReplyBuilder.draft(replyingTo: sent, body: nil, mode: .replyAll, from: account, myAddresses: [])
        XCTAssertEqual(all.to.map(\.address), ["bob@example.com", "carol@example.com"])
        XCTAssertTrue(all.cc.isEmpty)
        let one = ReplyBuilder.draft(replyingTo: sent, body: nil, mode: .reply, from: account, myAddresses: [])
        XCTAssertEqual(one.to.map(\.address), ["bob@example.com", "carol@example.com"])
        // Bcc-only: nobody else is known, so the reply goes to me.
        var bccOnly = sent
        bccOnly.cc = []
        XCTAssertEqual(ReplyBuilder.draft(replyingTo: bccOnly, body: nil, mode: .replyAll, from: account, myAddresses: []).to.map(\.address), ["Me@Example.org"])
    }

    func testForwardKeepsInlinePhotosButNotIcons() {
        // iPhone Mail pastes photos inline (cid:); the forwarded HTML can't carry cid: images, so the
        // photo must travel as an attachment or it is silently lost.
        let account = AccountConfig(id: "acc", provider: .fastmail, displayName: "Me", emailAddress: "me@example.org",
                                    imap: ServerConfig(host: "i", port: 993, security: .tls, username: "me"),
                                    smtp: ServerConfig(host: "s", port: 465, security: .tls, username: "me"))
        let original = MessageSummary(accountID: "acc", mailboxPath: "INBOX", uid: 1, uidValidity: 1, messageID: "p@example.com", subject: "Look",
                                      from: [EmailAddress(address: "ada@example.com")], replyTo: [], to: [EmailAddress(address: "me@example.org")],
                                      cc: [], date: Date.utc(2026, 10, 1))
        let photo = Data(repeating: 0xFF, count: 200_000)
        let body = MessageBody(messageID: "m", plainText: "Look at this", html: "<p>Look at this</p><img src=\"cid:photo\"><img src=\"cid:icon\">", attachments: [
            Attachment(id: "2", filename: "IMG_0042.jpeg", mimeType: "image/jpeg", size: photo.count, contentID: "photo", isInline: true, data: photo),
            Attachment(id: "3", filename: "icon.png", mimeType: "image/png", size: 900, contentID: "icon", isInline: true, data: Data(count: 900)),
        ])
        let forward = ReplyBuilder.draft(replyingTo: original, body: body, mode: .forward, from: account, myAddresses: [])
        XCTAssertEqual(forward.attachments.map(\.filename), ["IMG_0042.jpeg"])
        XCTAssertEqual(forward.attachments.first?.data, photo)
        XCTAssertFalse(forward.quotedHTML?.contains("cid:") ?? false)
        // Replies never carry attachments.
        XCTAssertTrue(ReplyBuilder.draft(replyingTo: original, body: body, mode: .reply, from: account, myAddresses: []).attachments.isEmpty)
    }

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
        // Split on bytes: "\r\n" is a single Character, so String splitting differs across platforms.
        let lines = [UInt8](data).split(separator: 0x0A).map { String(decoding: $0.filter { $0 != 0x0D }, as: UTF8.self) }
        for evil in ["Bcc:", "X-Evil", "X-Injected", "X-File", "X-Type"] {
            XCTAssertFalse(lines.contains { $0.hasPrefix(evil) }, evil)
        }
        XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("secret@"))
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.to.map(\.address), ["bob@example.com"])
        XCTAssertTrue(parsed.bcc.isEmpty)
    }

    func testOverlongDisplayNamesStayWithinTheLineLimit() {
        let longName = String(repeating: "A", count: 1200)
        let quotedName = "Smith, " + String(repeating: "B", count: 1200)
        let message = OutgoingMessage(accountID: "a", from: EmailAddress(name: longName, address: "a@example.com"),
                                      to: [EmailAddress(name: quotedName, address: "b@example.com")], subject: "x", body: "y")
        let (data, _) = MessageBuilder.build(message)
        assertWireFormat(data, limit: 998)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.from.first?.name, longName)
        XCTAssertEqual(parsed.from.first?.address, "a@example.com")
        XCTAssertEqual(parsed.to.first?.name, quotedName)
        XCTAssertEqual(parsed.to.first?.address, "b@example.com")
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
