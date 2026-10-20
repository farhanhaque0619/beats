import XCTest
@testable import InkMIME

final class QuoteSplitterTests: XCTestCase {
    private func split(_ s: String) -> (String, String?) {
        let r = QuoteSplitter.split(s)
        return (r.body, r.quoted)
    }

    func testEnglishAttribution() {
        let (body, quoted) = split("Thanks!\n\nOn Tue, Oct 20, 2026 at 9:15 AM Ada <ada@example.com> wrote:\n> Original\n> text")
        XCTAssertEqual(body, "Thanks!")
        XCTAssertEqual(quoted, "On Tue, Oct 20, 2026 at 9:15 AM Ada <ada@example.com> wrote:\n> Original\n> text")
    }

    func testAttributionWrappedOverLines() {
        let (body, quoted) = split("Thanks!\n\nOn Tue, Oct 20, 2026 at 9:15 AM Ada Lovelace <\nada@example.com> wrote:\n\n> Original")
        XCTAssertEqual(body, "Thanks!")
        XCTAssertEqual(quoted?.hasPrefix("On Tue"), true)
    }

    func testAttributionDirectlyAfterText() {
        let (body, quoted) = split("Thanks.\nOn Tue, Oct 20, 2026, Ada wrote:\n> Original")
        XCTAssertEqual(body, "Thanks.")
        XCTAssertEqual(quoted?.hasPrefix("On Tue"), true)
    }

    func testLocalizedAttributions() {
        let cases = [
            "Am Di., 20. Okt. 2026 um 09:15 Uhr schrieb Ada Lovelace <ada@example.com>:",
            "Am 20.10.2026 um 09:15 schrieb Ada Lovelace:",
            "Le mar. 20 oct. 2026 à 09:15, Ada Lovelace <ada@example.com> a écrit :",
            "El mar, 20 oct 2026 a las 9:15, Ada Lovelace (<ada@example.com>) escribió:",
            "Il giorno mar 20 ott 2026 alle ore 09:15 Ada Lovelace <ada@example.com> ha scritto:",
            "Op di 20 okt 2026 om 09:15 schreef Ada Lovelace <ada@example.com>:",
            "Em ter., 20 de out. de 2026 às 09:15, Ada Lovelace <ada@example.com> escreveu:",
            "Den tis 20 okt. 2026 kl 09:15 skrev Ada Lovelace <ada@example.com>:",
            "tis 20 okt. 2026 kl. 09:15 skrev Ada Lovelace <ada@example.com>:",
        ]
        for attribution in cases {
            let (body, quoted) = split("Antwort oben.\n\n\(attribution)\n\n> Zitat")
            XCTAssertEqual(body, "Antwort oben.", attribution)
            XCTAssertEqual(quoted?.hasPrefix(String(attribution.prefix(10))), true, attribution)
        }
    }

    func testOriginalMessageSeparators() {
        for separator in ["-----Original Message-----", "----- Original Message -----", "-----Ursprüngliche Nachricht-----",
                          "-----Message d'origine-----", "-----Mensaje original-----", "-----Messaggio originale-----",
                          "-----Oorspronkelijk bericht-----", "-----Mensagem original-----", "-----Ursprungligt meddelande-----"] {
            let (body, quoted) = split("See below.\n\n\(separator)\nFrom: Ada\nSent: Tuesday\nSubject: x\n\nOld text")
            XCTAssertEqual(body, "See below.", separator)
            XCTAssertEqual(quoted?.hasPrefix(separator), true, separator)
        }
    }

    func testOutlookHeaderBlocks() {
        let english = "Sounds good.\n\n________________________________\nFrom: Ada Lovelace <ada@example.com>\nSent: Tuesday, October 20, 2026 9:15 AM\nTo: Alex <alex@ink.example>\nSubject: Plans\n\nOld"
        XCTAssertEqual(split(english).0, "Sounds good.")
        XCTAssertEqual(split(english).1?.hasPrefix("________________________________\nFrom:"), true)

        let german = "Passt.\n\nVon: Ada Lovelace <ada@example.com>\nGesendet: Dienstag, 20. Oktober 2026 09:15\nAn: Alex <alex@ink.example>\nBetreff: Pläne\n\nAlt"
        XCTAssertEqual(split(german).0, "Passt.")
        let french = "D'accord.\n\nDe : Ada Lovelace <ada@example.com>\nEnvoyé : mardi 20 octobre 2026 09:15\nÀ : Alex\nObjet : Projets\n\nAncien"
        XCTAssertEqual(split(french).0, "D'accord.")
        let spanish = "Vale.\n\nDe: Ada\nEnviado el: martes, 20 de octubre de 2026 9:15\nPara: Alex\nAsunto: Planes\n\nViejo"
        XCTAssertEqual(split(spanish).0, "Vale.")
        let bold = "Ok.\n\n*From:* Ada\n*Sent:* Tuesday\n*To:* Alex\n*Subject:* x\n\nOld"
        XCTAssertEqual(split(bold).0, "Ok.")
    }

    func testFromLineAloneIsNotAQuote() {
        let text = "From: the team at Ink\nWe hope you like it.\nCheers"
        XCTAssertNil(split(text).1)
    }

    func testSignature() {
        let (body, quoted) = split("Hi there\n\n-- \nAda Lovelace\nAnalytical Engines Ltd")
        XCTAssertEqual(body, "Hi there")
        XCTAssertEqual(quoted, "-- \nAda Lovelace\nAnalytical Engines Ltd")
        XCTAssertEqual(split("Hi\n--\nAda").0, "Hi")
    }

    func testTrailingQuoteRun() {
        let (body, quoted) = split("Agreed, ship it.\n\n> Should we ship?\n>\n> > Earlier question\n")
        XCTAssertEqual(body, "Agreed, ship it.")
        XCTAssertEqual(quoted, "> Should we ship?\n>\n> > Earlier question")
    }

    func testInterleavedRepliesAreNotSplit() {
        let text = "> Question one?\nAnswer one.\n> Question two?\nAnswer two."
        XCTAssertNil(split(text).1)
        XCTAssertEqual(split(text).0, text)
    }

    func testBottomPostingIsNotSplit() {
        let text = "On Tue, Oct 20, 2026 at 9:15 AM Ada wrote:\n> Question?\n\nMy answer below the quote."
        XCTAssertNil(split(text).1)
    }

    func testNoMarkers() {
        XCTAssertNil(split("Just a message.\nTwo lines.").1)
        XCTAssertNil(split("").1)
        XCTAssertNil(split("I wrote: something").1)
        XCTAssertNil(split("As I wrote last week:\n- item one\n- item two").1)
    }

    func testCRLFInput() {
        let (body, quoted) = split("Yes.\r\n\r\nOn Tue, Oct 20, 2026, Ada wrote:\r\n> Q?\r\n")
        XCTAssertEqual(body, "Yes.")
        XCTAssertEqual(quoted, "On Tue, Oct 20, 2026, Ada wrote:\n> Q?")
    }

    // MARK: HTML

    func testGmailQuote() {
        let html = #"<div dir="ltr">Reply</div><br><div class="gmail_quote"><div class="gmail_attr">On Tue, Ada wrote:<br></div><blockquote class="gmail_quote">Original</blockquote></div>"#
        let r = QuoteSplitter.stripQuotedHTML(html)
        XCTAssertTrue(r.hadQuote)
        XCTAssertEqual(r.html, #"<div dir="ltr">Reply</div><br>"#)
    }

    func testAppleMailBlockquoteWithAttributionBefore() {
        let html = #"<html><body><div>Sounds good</div><div><br><div>On Oct 20, 2026, at 9:15 AM, Ada Lovelace &lt;ada@example.com&gt; wrote:</div><br class="Apple-interchange-newline"><blockquote type="cite"><div>Original</div></blockquote></div></body></html>"#
        let r = QuoteSplitter.stripQuotedHTML(html)
        XCTAssertTrue(r.hadQuote)
        XCTAssertFalse(r.html.contains("Original"))
        XCTAssertFalse(r.html.contains("wrote:"))
        XCTAssertTrue(r.html.contains("Sounds good"))
    }

    func testThunderbirdCitePrefix() {
        let html = #"<p>Fine by me.</p><div class="moz-cite-prefix">On 10/20/26 9:15 AM, Ada wrote:<br></div><blockquote type="cite" cite="mid:abc@example.com">Original</blockquote><br>"#
        let r = QuoteSplitter.stripQuotedHTML(html)
        XCTAssertTrue(r.hadQuote)
        XCTAssertEqual(r.html, "<p>Fine by me.</p><br>")
    }

    func testInterleavedHTMLQuotesAreKept() {
        let html = #"<blockquote type="cite">Question?</blockquote><p>Answer.</p><blockquote type="cite">Second?</blockquote><p>Second answer.</p>"#
        let r = QuoteSplitter.stripQuotedHTML(html)
        XCTAssertFalse(r.hadQuote)
        XCTAssertEqual(r.html, html)
    }

    func testOnlyTrailingQuoteIsRemoved() {
        let html = #"<blockquote type="cite">Question?</blockquote><p>Answer.</p><blockquote type="cite">Full original</blockquote>"#
        let r = QuoteSplitter.stripQuotedHTML(html)
        XCTAssertTrue(r.hadQuote)
        XCTAssertEqual(r.html, #"<blockquote type="cite">Question?</blockquote><p>Answer.</p>"#)
    }

    func testUnclosedQuoteRunsToEnd() {
        let html = #"<p>Top</p><div class="gmail_quote">Original <b>never closed</body></html>"#
        let r = QuoteSplitter.stripQuotedHTML(html)
        XCTAssertTrue(r.hadQuote)
        XCTAssertEqual(r.html, "<p>Top</p></body></html>")
    }

    func testNewOutlookReferenceContainer() {
        let html = #"<div>Reply text</div><div id="mail-editor-reference-message-container"><div>From: Ada</div><div>Old</div></div>"#
        let r = QuoteSplitter.stripQuotedHTML(html)
        XCTAssertTrue(r.hadQuote)
        XCTAssertEqual(r.html, "<div>Reply text</div>")
    }

    func testNoQuote() {
        let html = "<p>Nothing quoted here.</p><blockquote>Just a blockquote</blockquote>"
        XCTAssertFalse(QuoteSplitter.stripQuotedHTML(html).hadQuote)
        XCTAssertFalse(QuoteSplitter.stripQuotedHTML("").hadQuote)
    }
}

final class SnippetTests: XCTestCase {
    func testBasic() {
        XCTAssertEqual(Snippet.make(plain: "Hello there,\n\n  how are   you?", html: nil), "Hello there, how are you?")
        XCTAssertEqual(Snippet.make(plain: nil, html: "<p>Hello <b>there</b></p><p>Second</p>"), "Hello there Second")
        XCTAssertEqual(Snippet.make(plain: "   ", html: "<p>From HTML</p>"), "From HTML")
        XCTAssertEqual(Snippet.make(plain: nil, html: nil), "")
    }

    func testStripsQuotesSignaturesAndNoise() {
        let plain = """
        Sounds good, see you then.
        https://example.com/only-a-link
        [image: logo.png]
        ----------------------------
        Sent from my iPhone

        --
        Ada Lovelace

        On Tue, Oct 20, 2026 at 9:15 AM Grace <grace@example.com> wrote:
        > Lunch?
        """
        XCTAssertEqual(Snippet.make(plain: plain, html: nil), "Sounds good, see you then.")
    }

    func testRemovesLinkTargets() {
        XCTAssertEqual(Snippet.make(plain: "Read the docs <https://docs.example.com/start> and reply <mailto:a@b.example>.", html: nil),
                       "Read the docs and reply .")
    }

    func testTruncation() {
        let long = String(repeating: "word ", count: 100)
        let snippet = Snippet.make(plain: long, html: nil, maxLength: 50)
        XCTAssertLessThanOrEqual(snippet.count, 50)
        XCTAssertTrue(snippet.hasSuffix("…"))
        XCTAssertFalse(snippet.contains("  "))
        XCTAssertEqual(Snippet.make(plain: "short", html: nil, maxLength: 50), "short")
        XCTAssertEqual(Snippet.make(plain: String(repeating: "x", count: 80), html: nil, maxLength: 10), String(repeating: "x", count: 9) + "…")
        XCTAssertEqual(Snippet.make(plain: "anything", html: nil, maxLength: 0), "")
    }

    func testOnlyQuotedFallsBack() {
        XCTAssertEqual(Snippet.make(plain: "> only a quote\n> nothing else", html: nil), "> only a quote > nothing else")
    }

    func testHTMLQuoteIsStripped() {
        let html = #"<div>New text</div><div class="gmail_quote">On Tue, Ada wrote:<blockquote>Old text</blockquote></div>"#
        XCTAssertEqual(Snippet.make(plain: nil, html: html), "New text")
    }

    func testBoilerplatePlainFallsBackToHTML() {
        let plain = "View this email in your browser: https://news.example/v/1\n\nhttps://news.example/c/2\n"
        let html = "<p>View in browser</p><h1>Autumn collection</h1><p>New arrivals are here.</p>"
        XCTAssertEqual(Snippet.make(plain: plain, html: html), "Autumn collection New arrivals are here.")
        XCTAssertEqual(Snippet.make(plain: plain, html: nil), "View this email in your browser: https://news.example/v/1 https://news.example/c/2")
    }

    func testEmojiAndCJKTruncateOnCharacters() {
        let text = String(repeating: "👍🏽日本", count: 100)
        let snippet = Snippet.make(plain: text, html: nil, maxLength: 20)
        XCTAssertEqual(snippet.count, 20)
    }
}
