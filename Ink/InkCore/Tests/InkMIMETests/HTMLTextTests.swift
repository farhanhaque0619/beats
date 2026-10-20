import XCTest
@testable import InkMIME

final class HTMLTextTests: XCTestCase {
    func testBlocksAndInline() {
        let html = "<html><head><title>T</title><style>p{color:red}</style><script>alert(1)</script></head><body><h1>Title</h1><p>First <b>bold</b> and <i>italic</i>.</p><p>Second<br>line</p><div>Div</div></body></html>"
        XCTAssertEqual(HTMLText.toPlainText(html), "Title\n\nFirst bold and italic.\n\nSecond\nline\n\nDiv")
    }

    func testWhitespaceCollapsing() {
        XCTAssertEqual(HTMLText.toPlainText("<p>  lots   of\n\n spaces\t here </p>"), "lots of spaces here")
        XCTAssertEqual(HTMLText.toPlainText("a<br><br><br><br>b"), "a\n\nb")
        XCTAssertEqual(HTMLText.toPlainText("<p>a</p>\n\n\n<p>b</p>"), "a\n\nb")
    }

    func testListsAndTables() {
        XCTAssertEqual(HTMLText.toPlainText("<ul><li>one</li><li>two</li></ul><ol><li>first</li><li>second</li></ol>"), "• one\n• two\n\n1. first\n2. second")
        XCTAssertEqual(HTMLText.toPlainText("<table><tr><td>Name</td><td>Qty</td></tr><tr><td>Apple</td><td>3</td></tr></table>"), "Name Qty\nApple 3")
    }

    func testPreformatted() {
        XCTAssertEqual(HTMLText.toPlainText("<pre>  indented\n    code  here</pre><p>after</p>"), "  indented\n    code  here\n\nafter")
    }

    func testEntities() {
        XCTAssertEqual(HTMLText.toPlainText("Fish &amp; Chips &lt;3 &quot;yum&quot; &copy; 2026 &euro;5 &hellip;"), "Fish & Chips <3 \"yum\" © 2026 €5 …")
        XCTAssertEqual(HTMLText.toPlainText("&#8220;quoted&#8221; &#x2014; &#128512;"), "“quoted” — 😀")
        XCTAssertEqual(HTMLText.toPlainText("&unknown; &amp"), "&unknown; &")
        XCTAssertEqual(HTMLText.toPlainText("a&nbsp;b"), "a b")
    }

    func testCommentsAndConditionalComments() {
        let html = "<!--[if mso]><table><tr><td>Outlook only</td></tr></table><![endif]--><p>Everyone</p><!-- a comment -->"
        XCTAssertEqual(HTMLText.toPlainText(html), "Everyone")
    }

    func testHiddenPreheaderIsKeptAndPaddingRemoved() {
        let html = "<div style=\"display:none;max-height:0\">Preview text here&nbsp;&zwnj;&nbsp;&zwnj;&nbsp;&zwnj;&#847;&#8203;</div><p>Body</p>"
        XCTAssertEqual(HTMLText.toPlainText(html), "Preview text here\n\nBody")
    }

    func testOutlookParagraphs() {
        let html = "<p class=MsoNormal>Line one<o:p></o:p></p><p class=MsoNormal>Line two<o:p></o:p></p><p class=MsoNormal><o:p>&nbsp;</o:p></p><p class=MsoNormal>Line three</p>"
        XCTAssertEqual(HTMLText.toPlainText(html), "Line one\nLine two\n\nLine three")
    }

    func testMalformedHTML() {
        XCTAssertEqual(HTMLText.toPlainText("<p>unclosed <b>bold <i>italic"), "unclosed bold italic")
        XCTAssertEqual(HTMLText.toPlainText("a < b and c > d"), "a < b and c > d")
        XCTAssertEqual(HTMLText.toPlainText("text <a href=\"x"), "text")
        XCTAssertEqual(HTMLText.toPlainText("<div title='it>s'>quoted gt</div>"), "quoted gt")
        XCTAssertEqual(HTMLText.toPlainText("<head><meta charset=utf-8><p>no body tag</p>"), "no body tag")
        XCTAssertEqual(HTMLText.toPlainText("<html><head><title>x</title>Text in head</html>"), "Text in head")
        XCTAssertEqual(HTMLText.toPlainText("<head><style>a{}</style></head><body>after head</body>"), "after head")
        XCTAssertEqual(HTMLText.toPlainText(""), "")
        XCTAssertEqual(HTMLText.toPlainText("<style>unterminated"), "")
        XCTAssertEqual(HTMLText.toPlainText("</p></div>stray ends"), "stray ends")
    }

    func testDecodeEntities() {
        XCTAssertEqual(HTMLText.decodeEntities("&lt;b&gt; &amp;amp; &Auml;&ouml;&szlig; &mdash; &trade; &rarr; &#39; &#x27; &apos;"), "<b> &amp; Äöß — ™ → ' ' '")
        XCTAssertEqual(HTMLText.decodeEntities("&copy2026 &nbsp;"), "©2026 \u{00A0}")
        XCTAssertEqual(HTMLText.decodeEntities("&#0; &#xD800; &#1114112; &#150;"), "\u{FFFD} \u{FFFD} \u{FFFD} –")
        XCTAssertEqual(HTMLText.decodeEntities("no entities"), "no entities")
        XCTAssertEqual(HTMLText.decodeEntities("&"), "&")
        XCTAssertEqual(HTMLText.decodeEntities("&#"), "&#")
        XCTAssertEqual(HTMLText.decodeEntities("&#x;"), "&#x;")
        XCTAssertGreaterThanOrEqual(HTMLEntities.table.count, 250)
    }

    func testEscape() {
        XCTAssertEqual(HTMLText.escape("<a href=\"x\">Tom & Jerry's</a>"), "&lt;a href=&quot;x&quot;&gt;Tom &amp; Jerry&#39;s&lt;/a&gt;")
        XCTAssertEqual(HTMLText.escape("plain"), "plain")
        XCTAssertEqual(HTMLText.decodeEntities(HTMLText.escape("<&>\"'")), "<&>\"'")
    }

    func testLargeInputIsFast() {
        let chunk = "<tr><td style=\"padding:4px\">Cell &amp; more</td><td><a href=\"https://example.com/\">link</a></td></tr>"
        let html = "<table>" + String(repeating: chunk, count: 20_000) + "</table>"
        let start = Date()
        let text = HTMLText.toPlainText(html)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
        XCTAssertTrue(text.hasPrefix("Cell & more link"))
    }
}

final class FlowedTextTests: XCTestCase {
    func testUnwrap() {
        XCTAssertEqual(FlowedText.decode("This is a \nflowed line.\nFixed line.", delSp: false), "This is a flowed line.\nFixed line.")
    }

    func testDelSp() {
        XCTAssertEqual(FlowedText.decode("Japanese text wraps with\u{20}\nout spaces.", delSp: true), "Japanese text wraps without spaces.")
    }

    func testQuotesAndSpaceStuffing() {
        let text = "> Quoted flowed \n> text continues.\n>> Deeper \n>> line.\n Space-stuffed\nNormal"
        XCTAssertEqual(FlowedText.decode(text, delSp: false), "> Quoted flowed text continues.\n>> Deeper line.\nSpace-stuffed\nNormal")
    }

    func testQuoteDepthChangeEndsParagraph() {
        XCTAssertEqual(FlowedText.decode("> flowed \nnot quoted", delSp: false), "> flowed\nnot quoted")
    }

    func testSignatureSeparatorIsNotFlowed() {
        XCTAssertEqual(FlowedText.decode("Body\n-- \nSig", delSp: false), "Body\n-- \nSig")
    }

    func testFlowedPartInMessage() {
        let parsed = MIMEParser.parse(Raw.data("""
        Content-Type: text/plain; charset=utf-8; format=flowed; delsp=yes

        Hello, this is a long paragraph that a client soft-wrapped at seventy-
        two columns with delsp.\u{20}
        Next.
        """))
        XCTAssertEqual(parsed.plainText, "Hello, this is a long paragraph that a client soft-wrapped at seventy-\ntwo columns with delsp.Next.")
    }
}
