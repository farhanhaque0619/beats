import XCTest
@testable import InkMIME

final class EncodedWordTests: XCTestCase {
    func testBase64AndQ() {
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?Q2Fmw6kg4piVIG1lZXRpbmcg4oCUIDEwOjAw?="), "Café ☕ meeting — 10:00")
        XCTAssertEqual(EncodedWord.decode("=?utf-8?q?Gr=C3=BC=C3=9Fe_aus_M=C3=BCnchen?="), "Grüße aus München")
        XCTAssertEqual(EncodedWord.decode("=?ISO-8859-1?Q?Andr=E9?= Pirard"), "André Pirard")
    }

    func testAdjacentWordsSeparatedByWhitespaceAreJoined() {
        // RFC 2047 §8 examples.
        XCTAssertEqual(EncodedWord.decode("(=?ISO-8859-1?Q?a?= =?ISO-8859-1?Q?b?=)"), "(ab)")
        XCTAssertEqual(EncodedWord.decode("(=?ISO-8859-1?Q?a?=  \r\n  =?ISO-8859-1?Q?b?=)"), "(ab)")
        XCTAssertEqual(EncodedWord.decode("(=?ISO-8859-1?Q?a?= b)"), "(a b)")
        XCTAssertEqual(EncodedWord.decode("(=?ISO-8859-1?Q?a_b?=)"), "(a b)")
        XCTAssertEqual(EncodedWord.decode("(=?ISO-8859-1?Q?a?= =?ISO-8859-2?Q?_b?=)"), "(a b)")
    }

    func testMixedCharsets() {
        let s = "=?ISO-2022-JP?B?GyRCOzNFRBsoQg==?= =?UTF-8?Q?_&_?= =?KOI8-R?B?8NLJ18XU?="
        XCTAssertEqual(EncodedWord.decode(s), "山田 & Привет")
    }

    func testMultibyteCharacterSplitAcrossWords() {
        // "é" (C3 A9) split between two words by a careless encoder.
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?Q?Caf=C3?= =?UTF-8?Q?=A9?="), "Café")
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?w6nD?= =?UTF-8?B?qQ==?="), "éé")
    }

    func testMalformedWordsAreLeftAsIs() {
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?X?abc?="), "=?UTF-8?X?abc?=")
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?Q?unterminated"), "=?UTF-8?Q?unterminated")
        XCTAssertEqual(EncodedWord.decode("=??Q?no-charset?="), "=??Q?no-charset?=")
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?not*base64!?="), "=?UTF-8?B?not*base64!?=")
        XCTAssertEqual(EncodedWord.decode("Price =? 10"), "Price =? 10")
        XCTAssertEqual(EncodedWord.decode("plain text"), "plain text")
    }

    func testWordsGluedToText() {
        XCTAssertEqual(EncodedWord.decode("Re:=?UTF-8?Q?_Caf=C3=A9?=!"), "Re: Café!")
    }

    func testLanguageSuffixAndLowercaseEncoding() {
        XCTAssertEqual(EncodedWord.decode("=?US-ASCII*EN?Q?Keith_Moore?="), "Keith Moore")
        XCTAssertEqual(EncodedWord.decode("=?utf-8?b?w6k=?="), "é")
    }

    func testQuestionMarkInsideQText() {
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?Q?Ready??="), "Ready?")
    }

    func testUnknownCharsetFallsBack() {
        XCTAssertEqual(EncodedWord.decode("=?x-unknown?Q?hello?="), "hello")
        XCTAssertEqual(EncodedWord.decode("=?x-made-up?B?w6k=?="), "é")
    }

    func testEncodeLeavesASCIIAlone() {
        XCTAssertEqual(EncodedWord.encode("Hello world"), "Hello world")
    }

    func testEncodeRoundTripAndLimits() {
        let samples = [
            "Café", "Grüße aus München", "山田 太郎のレポート", "Привет, мир", "🎉 Launch day! 🚀",
            String(repeating: "Ünïcödé ", count: 30), "=?looks like a word?=", "a\u{00A0}b",
        ]
        for sample in samples {
            let encoded = EncodedWord.encode(sample)
            XCTAssertNotEqual(encoded, sample)
            for word in encoded.split(separator: " ") {
                XCTAssertLessThanOrEqual(word.count, 75, "word too long: \(word)")
                XCTAssertTrue(word.hasPrefix("=?UTF-8?") && word.hasSuffix("?="))
            }
            XCTAssertTrue(encoded.utf8.allSatisfy { $0 < 0x80 })
            XCTAssertEqual(EncodedWord.decode(encoded), sample)
        }
    }

    func testEncodePicksShorterEncoding() {
        XCTAssertTrue(EncodedWord.encode("Café au lait").hasPrefix("=?UTF-8?Q?"))
        XCTAssertTrue(EncodedWord.encode("日本語のテキスト").hasPrefix("=?UTF-8?B?"))
    }
}
