import XCTest
@testable import InkMIME

final class EmailHTMLDocumentTests: XCTestCase {
    private let light = EmailHTMLDocument.Options()
    private let dark = EmailHTMLDocument.Options(dark: true)

    func testDocumentSkeletonAndCSP() {
        let doc = EmailHTMLDocument.build(html: "<p>Hello</p>", plainText: nil, options: light)
        XCTAssertTrue(doc.hasPrefix("<!DOCTYPE html>"))
        XCTAssertTrue(doc.contains("<meta name=\"viewport\" content=\"width=device-width, initial-scale=1\">"))
        XCTAssertTrue(doc.contains("default-src 'none'; img-src cid: data:; style-src 'unsafe-inline'; font-src data:"))
        XCTAssertFalse(doc.contains("https:"))
        XCTAssertTrue(doc.contains("<p>Hello</p>"))
        XCTAssertTrue(doc.contains("ink-simple"))
        XCTAssertTrue(doc.contains("ink-light"))

        let remote = EmailHTMLDocument.build(html: "<p>x</p>", plainText: nil, options: .init(allowRemoteContent: true))
        XCTAssertTrue(remote.contains("img-src cid: data: https: http:"))
    }

    func testBaseCSS() {
        let doc = EmailHTMLDocument.build(html: "<p>x</p>", plainText: nil, options: .init(accentHex: "#FF2D55", fontFamily: "ui-serif", fontSizePx: 19))
        XCTAssertTrue(doc.contains("font-size: 19px; line-height: 1.5"))
        XCTAssertTrue(doc.contains("ui-serif, \"New York\""))
        XCTAssertTrue(doc.contains("--ink-accent: #FF2D55"))
        XCTAssertTrue(doc.contains("img { max-width: 100% !important; height: auto; }"))
        XCTAssertTrue(doc.contains("white-space: pre-wrap"))
        XCTAssertTrue(doc.contains("border-left: 2px solid var(--ink-rule)"))
        XCTAssertTrue(doc.contains("body.ink-simple a { color: var(--ink-accent); }"))
        XCTAssertTrue(doc.contains("table { max-width: 100% !important; }"))
        XCTAssertTrue(doc.contains("overflow-wrap: break-word"))

        let system = EmailHTMLDocument.build(html: "<p>x</p>", plainText: nil, options: light)
        XCTAssertTrue(system.contains("-apple-system, BlinkMacSystemFont"))
        XCTAssertTrue(system.contains("font-size: 17px"))
    }

    func testOptionSanitizing() {
        let doc = EmailHTMLDocument.build(html: "<p>x</p>", plainText: nil,
                                          options: .init(accentHex: "red;}</style><script>", fontFamily: "Evil\"; } body { x", fontSizePx: 400))
        XCTAssertTrue(doc.contains("--ink-accent: #0A84FF"))
        XCTAssertFalse(doc.contains("<script>"))
        XCTAssertTrue(doc.contains("font-size: 40px"))
        XCTAssertTrue(doc.contains("\"Evil  body  x\""))
    }

    func testDarkModeSimpleVsDesigned() {
        let simple = EmailHTMLDocument.build(html: "<div style=\"color:#000000\">Hi</div>", plainText: nil, options: dark)
        XCTAssertTrue(simple.contains("class=\"ink ink-dark ink-simple"))
        XCTAssertTrue(simple.contains("body.ink-dark.ink-simple #ink-content *"))
        XCTAssertTrue(simple.contains("color-scheme: dark"))
        XCTAssertTrue(simple.contains("--ink-bg: #1C1C1E"))
        XCTAssertTrue(simple.contains("#ink-content img { background-color: #F2F2F7 !important"))   // transparent logos stay legible

        let designedHTML = "<body bgcolor=\"#f4f1ea\"><table width=\"600\" bgcolor=\"#ffffff\"><tr><td>Sale</td></tr></table></body>"
        let designed = EmailHTMLDocument.build(html: designedHTML, plainText: nil, options: dark)
        XCTAssertTrue(designed.contains("ink-designed"))
        XCTAssertTrue(designed.contains("body.ink-dark.ink-designed #ink-content { background-color: #FFFFFF"))
        XCTAssertTrue(designed.contains("style=\"background-color: #f4f1ea\""))

        let lightDoc = EmailHTMLDocument.build(html: "<p>x</p>", plainText: nil, options: light)
        XCTAssertFalse(lightDoc.contains("body.ink-dark.ink-simple #ink-content *"))
    }

    func testIsDesigned() {
        XCTAssertFalse(EmailHTMLDocument.isDesigned("<div dir=\"ltr\">Hi<br></div>"))
        XCTAssertFalse(EmailHTMLDocument.isDesigned("<body style=\"word-wrap:break-word\"><p class=MsoNormal>Hi</p></body>"))
        XCTAssertFalse(EmailHTMLDocument.isDesigned("<div style=\"background-color: rgb(255, 255, 255)\">pasted</div>"))
        XCTAssertFalse(EmailHTMLDocument.isDesigned("<div style=\"background: transparent\">x</div>"))
        XCTAssertFalse(EmailHTMLDocument.isDesigned("<div style=\"background-position: center\">x</div>"))
        XCTAssertTrue(EmailHTMLDocument.isDesigned("<table bgcolor=\"#123456\"><tr><td>x</td></tr></table>"))
        XCTAssertTrue(EmailHTMLDocument.isDesigned("<td background=\"https://x.example/bg.png\">x</td>"))
        XCTAssertTrue(EmailHTMLDocument.isDesigned("<div style=\"background:#222 url(x.png)\">x</div>"))
        XCTAssertTrue(EmailHTMLDocument.isDesigned("<div style=\"background-image: linear-gradient(red, blue)\">x</div>"))
        XCTAssertTrue(EmailHTMLDocument.isDesigned("<style>.hero { background-color: #0a2540; }</style><div class=hero>x</div>"))
        XCTAssertTrue(EmailHTMLDocument.isDesigned("<table width=\"600\"><tr><td><img src=a.png><img src=b.png></td></tr></table>"))
    }

    func testRemoteImagesAndTrackers() {
        let html = """
        <img src="cid:logo"><img src="data:image/png;base64,AAAA">
        <img src="https://cdn.example.com/hero.jpg" width="600">
        <img src="//cdn.example.com/proto-relative.png">
        <img src="https://t.example.com/o.gif" width="1" height="1">
        <img src="https://img.example.com/x.png" style="display:none">
        <img src="https://mailtrack.io/trace/mail/abc.png">
        <img src="https://example.com/spacer.gif" width="1" height="40">
        <img src="http://u123.ct.sendgrid.net/wf/open?upn=abc" alt="">
        <img src="https://example.com/tiny.png" style="width:1px;height:1px">
        """
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages(html), 8)
        XCTAssertEqual(EmailHTMLDocument.countTrackingPixels(html), 5)
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages("<p>no images</p>"), 0)
        XCTAssertEqual(EmailHTMLDocument.countTrackingPixels("<img src=cid:a width=1 height=1>"), 0)
    }

    func testSanitizing() {
        let html = """
        <html><head><title>Hidden title</title><meta http-equiv="refresh" content="0;url=https://evil.example"><base href="https://evil.example/"><script>alert(1)</script><style>p { color: red; } @import url(https://evil.example/x.css); .x { width: expression(alert(1)); }</style></head>
        <body onload="alert(1)" bgcolor="#ffffff">
        <p onclick="alert(1)" style="color:blue">Text</p>
        <a href="javascript:alert(1)">bad link</a> <a href=" JaVaScRiPt:alert(1)">bad link 2</a> <a href="https://ok.example/">good link</a>
        <iframe src="https://evil.example"></iframe><object data="x.swf"></object><embed src="x.swf">
        <form action="https://evil.example/login"><input type="password" name="p"><button>Send</button></form>
        <img src="data:image/svg+xml;base64,PHN2Zz4=" onerror="alert(1)"><img src="cid:logo">
        <div style="behavior: url(x.htc)">b</div><svg><a xlink:href="javascript:alert(1)">s</a></svg>
        <a href="data:text/html;base64,PHNjcmlwdD4=">data link</a> <a href="data:image/svg+xml,&lt;svg onload=alert(1)&gt;">svg link</a>
        </body></html>
        """
        let doc = EmailHTMLDocument.build(html: html, plainText: nil, options: light)
        XCTAssertFalse(doc.lowercased().contains("javascript:"))
        XCTAssertFalse(doc.contains("onload"))
        XCTAssertFalse(doc.contains("onclick"))
        XCTAssertFalse(doc.contains("onerror"))
        XCTAssertFalse(doc.contains("<script"))
        XCTAssertFalse(doc.contains("alert(1)</script>"))
        XCTAssertFalse(doc.contains("<iframe"))
        XCTAssertFalse(doc.contains("<object"))
        XCTAssertFalse(doc.contains("<embed"))
        XCTAssertFalse(doc.contains("<form"))
        XCTAssertFalse(doc.contains("<input"))
        XCTAssertFalse(doc.contains("refresh"))
        XCTAssertFalse(doc.contains("<base"))
        XCTAssertFalse(doc.contains("Hidden title"))
        XCTAssertFalse(doc.contains("expression("))
        XCTAssertFalse(doc.contains("@import"))
        XCTAssertFalse(doc.contains("behavior:"))
        XCTAssertTrue(doc.contains("<img src=\"data:image/svg+xml;base64,PHN2Zz4=\">"))   // inert inside <img>
        XCTAssertFalse(doc.contains("href=\"data:"))
        XCTAssertTrue(doc.contains("<p style=\"color:blue\">Text</p>"))
        XCTAssertTrue(doc.contains("<a href=\"https://ok.example/\">good link</a>"))
        XCTAssertTrue(doc.contains("<img src=\"cid:logo\">"))
        XCTAssertTrue(doc.contains("p { color: red; }"))
        XCTAssertTrue(doc.contains("Send"))
    }

    func testBrokenAttributeQuotesCannotEscape() {
        let doc = EmailHTMLDocument.build(html: "<a title=\"unterminated href=x>Text</a><p>after</p>", plainText: nil, options: light)
        XCTAssertTrue(doc.contains("after"))
        let tagCount = doc.components(separatedBy: "<p>").count
        XCTAssertGreaterThanOrEqual(tagCount, 2)
    }

    func testStyleBlockCannotCloseItself() {
        let doc = EmailHTMLDocument.build(html: "<style>p{} </style ><p>after</p>", plainText: nil, options: light)
        XCTAssertTrue(doc.contains("<p>after</p>"))
        let injected = EmailHTMLDocument.build(html: "<style>a{content:'</style><script>x</script>'}</style>", plainText: nil, options: light)
        XCTAssertFalse(injected.contains("<script>"))
    }

    func testPlainTextRendering() {
        let text = "Hello <world> & friends,\nsee https://example.com/path?a=1&b=2. Or www.example.org!\nMail me: ada@example.com\n\n> quoted line\n> > nested\n\n-- \nAda"
        let doc = EmailHTMLDocument.build(html: nil, plainText: text, options: .init(collapseQuotes: false))
        XCTAssertTrue(doc.contains("Hello &lt;world&gt; &amp; friends,"))
        XCTAssertTrue(doc.contains("<a href=\"https://example.com/path?a=1&amp;b=2\">https://example.com/path?a=1&amp;b=2</a>."))
        XCTAssertTrue(doc.contains("<a href=\"http://www.example.org\">www.example.org</a>!"))
        XCTAssertTrue(doc.contains("<a href=\"mailto:ada@example.com\">ada@example.com</a>"))
        XCTAssertTrue(doc.contains("<blockquote>quoted line<blockquote>nested</blockquote></blockquote>"))
        XCTAssertTrue(doc.contains("<div class=\"ink-signature\">-- \nAda</div>"))
        XCTAssertTrue(doc.contains("class=\"ink-plain\""))
        XCTAssertTrue(doc.contains("ink-plain-doc"))
    }

    func testCollapsedQuotesPlain() {
        let text = "Sure!\n\nOn Tue, Oct 20, 2026, Ada wrote:\n> Lunch?"
        let doc = EmailHTMLDocument.build(html: nil, plainText: text, options: light)
        XCTAssertTrue(doc.contains("Sure!<details class=\"ink-quote\"><summary class=\"ink-quote-toggle\""))
        XCTAssertTrue(doc.contains("On Tue, Oct 20, 2026, Ada wrote:<blockquote>Lunch?</blockquote>"))
    }

    func testCollapsedQuotesHTML() {
        let html = #"<div dir="ltr">Sure!</div><div class="gmail_quote">On Tue, Ada wrote:<blockquote class="gmail_quote">Lunch?</blockquote></div>"#
        let doc = EmailHTMLDocument.build(html: html, plainText: nil, options: light)
        XCTAssertTrue(doc.contains(#"<div dir="ltr">Sure!</div><details class="ink-quote"><summary class="ink-quote-toggle" aria-label="Show quoted text">•••</summary><div class="gmail_quote">"#))
        XCTAssertTrue(doc.contains("</blockquote></div></details>"))
        let expanded = EmailHTMLDocument.build(html: html, plainText: nil, options: .init(collapseQuotes: false))
        XCTAssertFalse(expanded.contains("<details"))
    }

    func testEmptyInputs() {
        let doc = EmailHTMLDocument.build(html: nil, plainText: nil, options: light)
        XCTAssertTrue(doc.contains("<div id=\"ink-content\""))
        let whitespaceHTML = EmailHTMLDocument.build(html: "   ", plainText: "fallback text", options: light)
        XCTAssertTrue(whitespaceHTML.contains("fallback text"))
    }

    func testRealNewsletterEndToEnd() {
        let m = MIMEParser.parse(Raw.data(Fixtures.windows1252Newsletter))
        let doc = EmailHTMLDocument.build(html: m.html, plainText: m.plainText, options: dark)
        XCTAssertTrue(doc.contains("ink-designed"))
        XCTAssertTrue(doc.contains("“Fall Sale”"))
        XCTAssertTrue(doc.contains("body{background-color:#f4f1ea}"))
        XCTAssertFalse(doc.contains("<title>"))
    }
}
