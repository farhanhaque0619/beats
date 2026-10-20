import XCTest
@testable import InkMIME

final class CharsetTests: XCTestCase {
    private func decode(_ bytes: [UInt8], _ charset: String?) -> String {
        Charset.decode(Data(bytes), charset: charset)
    }

    func testUTF8AndASCII() {
        XCTAssertEqual(decode(Array("héllo ✓".utf8), "utf-8"), "héllo ✓")
        XCTAssertEqual(decode(Array("héllo".utf8), "UTF8"), "héllo")
        XCTAssertEqual(decode(Array("plain".utf8), "us-ascii"), "plain")
        XCTAssertEqual(decode([0xEF, 0xBB, 0xBF] + Array("bom".utf8), "utf-8"), "bom")
        XCTAssertEqual(decode([], "utf-8"), "")
    }

    func testLatin1IsDecodedAsWindows1252() {
        // Browsers (and Ink) treat ISO-8859-1 as Windows-1252 so smart quotes survive.
        XCTAssertEqual(decode([0x93, 0x48, 0x69, 0x94, 0x20, 0xE9, 0x80], "iso-8859-1"), "“Hi” é€")
        XCTAssertEqual(decode([0x93, 0x48, 0x69, 0x94, 0x96, 0x85], "windows-1252"), "“Hi”–…")
        XCTAssertEqual(decode([0xE9], "latin1"), "é")
        XCTAssertEqual(decode([0xE9], "CP1252"), "é")
    }

    func testISO8859Variants() {
        XCTAssertEqual(decode([0xA4, 0xBC, 0xBD], "iso-8859-15"), "€Œœ")
        XCTAssertEqual(decode([0x5A, 0x61, 0xBF, 0xF3, 0xB3, 0xE6, 0x20, 0x67, 0xEA, 0xB6, 0x6C, 0xB1, 0x20, 0x6A, 0x61, 0xBC, 0xF1], "ISO-8859-2"),
                       "Zażółć gęślą jaźń")
        XCTAssertEqual(decode([0xCA, 0xE1, 0xEB, 0xE7, 0xEC, 0xDD, 0xF1, 0xE1], "iso-8859-7"), "Καλημέρα")
        XCTAssertEqual(decode([0xBF, 0xE0, 0xD8, 0xD2, 0xD5, 0xE2], "iso-8859-5"), "Привет")
        XCTAssertEqual(decode([0x5A, 0x61, 0xBF, 0xF3, 0xB3, 0xE6], "latin2"), "Zażółć")
    }

    func testWindowsCodePages() {
        XCTAssertEqual(decode([0xC7, 0xE4, 0xF0, 0xE0, 0xE2, 0xF1, 0xF2, 0xE2, 0xF3, 0xE9, 0xF2, 0xE5], "windows-1251"), "Здравствуйте")
        XCTAssertEqual(decode([0x8A, 0x9A], "windows-1250"), "Šš")
        XCTAssertEqual(decode([0xE1], "cp1253"), "α")
        XCTAssertEqual(decode([0xF0, 0xFD], "windows-1254"), "ğı")
    }

    func testBuiltInSingleByteTables() {
        XCTAssertEqual(decode([0xF9, 0xEC, 0xE5, 0xED, 0x20, 0xF2, 0xE5, 0xEC, 0xED], "windows-1255"), "שלום עולם")
        XCTAssertEqual(decode([0xF9, 0xEC, 0xE5, 0xED], "iso-8859-8"), "שלום")
        XCTAssertEqual(decode([0xF9, 0xEC, 0xE5, 0xED], "iso-8859-8-i"), "שלום")
        XCTAssertEqual(decode([0xE3, 0xD1, 0xCD, 0xC8, 0xC7], "windows-1256"), "مرحبا")
        XCTAssertEqual(decode([0xE5, 0xD1, 0xCD, 0xC8, 0xC7], "iso-8859-6"), "مرحبا")
        XCTAssertEqual(decode([0xCA, 0xC7, 0xD1, 0xCA, 0xB4, 0xD5], "tis-620"), "สวัสดี")
        XCTAssertEqual(decode([0x85, 0x93, 0x94], "windows-874"), "…“”")
        XCTAssertEqual(decode([0x41, 0xE8, 0x69, 0xFB], "windows-1257"), "Ačiū")
        XCTAssertEqual(decode([0x54, 0x69, 0xEA, 0xEC, 0x6E, 0x67], "windows-1258"), "Tiếng")   // combining acute
        XCTAssertEqual(decode([0x8F, 0xE0, 0xA8, 0xA2, 0xA5, 0xE2], "cp866"), "Привет")
        XCTAssertEqual(decode([0xC5, 0xEB, 0xEB, 0xDC, 0xE4, 0xE1], "windows-1253"), "Ελλάδα")
        XCTAssertEqual(decode([0xDD, 0x73, 0x74, 0x61, 0x6E, 0x62, 0x75, 0x6C], "iso-8859-9"), "İstanbul")
        XCTAssertEqual(decode([0xDE, 0xF3, 0x72, 0x72], "iso-8859-10"), "Þórr")
        XCTAssertEqual(decode([0xD9, 0xF3, 0x64, 0xEA], "iso-8859-13"), "Łódź")
        XCTAssertEqual(decode([0xD0, 0x61, 0x6C, 0x65, 0x73], "iso-8859-14"), "Ŵales")
        XCTAssertEqual(decode([0xAA, 0xFE, 0x61, 0x72, 0xE3], "iso-8859-16"), "Șțară")
        XCTAssertEqual(decode([0x41, 0x98], "koi8-r").unicodeScalars.count, 2)
        // Undefined bytes become U+FFFD instead of failing the whole text.
        XCTAssertEqual(decode([0x41, 0xAA, 0x42], "windows-1253"), "A\u{FFFD}B")
        XCTAssertEqual(decode([0x41, 0xA1, 0x42], "iso-8859-6"), "A\u{FFFD}B")
        // Every table is complete.
        for n in [2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 13, 14, 16] {
            XCTAssertEqual(SingleByteTables.iso(n)?.count, 128, "iso-8859-\(n)")
        }
        for name in ["windows-1250", "windows-1251", "windows-1253", "windows-1254", "windows-1255", "windows-1256",
                     "windows-1257", "windows-1258", "windows-874", "koi8-r", "koi8-u", "ibm866"] {
            XCTAssertEqual(SingleByteTables.named(name)?.count, 128, name)
        }
        XCTAssertEqual(Charset.canonicalName("cp1251"), "windows-1251")
        XCTAssertEqual(Charset.canonicalName("ISO_8859-5:1988"), "iso-8859-5")
        XCTAssertEqual(Charset.canonicalName("KOI8R"), "koi8-r")
    }

    func testKOI8() {
        XCTAssertEqual(decode([0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4, 0x2C, 0x20, 0xCD, 0xC9, 0xD2], "koi8-r"), "Привет, мир")
        XCTAssertEqual(decode([0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4], "KOI8-U"), "Привет")
    }

    func testJapanese() {
        XCTAssertEqual(decode([0x82, 0xB1, 0x82, 0xF1, 0x82, 0xC9, 0x82, 0xBF, 0x82, 0xCD, 0x90, 0xA2, 0x8A, 0x45], "shift_jis"), "こんにちは世界")
        XCTAssertEqual(decode([0x82, 0xB1, 0x82, 0xF1], "x-sjis"), "こん")
        XCTAssertEqual(decode([0x87, 0x40], "cp932"), "①")
        XCTAssertEqual(decode([0xA4, 0xB3, 0xA4, 0xF3, 0xA4, 0xCB, 0xA4, 0xC1, 0xA4, 0xCF, 0xC0, 0xA4, 0xB3, 0xA6], "euc-jp"), "こんにちは世界")
        XCTAssertEqual(decode([0x8E, 0xB6, 0x8E, 0xC0, 0x8E, 0xB6, 0x8E, 0xC5], "EUC-JP"), "ｶﾀｶﾅ")
        let jis: [UInt8] = [0x1B, 0x24, 0x42, 0x24, 0x33, 0x24, 0x73, 0x24, 0x4B, 0x24, 0x41, 0x24, 0x4F, 0x1B, 0x28, 0x42]
        XCTAssertEqual(decode(jis, "iso-2022-jp"), "こんにちは")
    }

    func testISO2022JPMissingResetAndTruncation() {
        // No ESC ( B at the end of the line, as some mobile mailers do.
        let noReset: [UInt8] = [0x1B, 0x24, 0x42, 0x24, 0x33, 0x24, 0x73]
        XCTAssertEqual(decode(noReset, "iso-2022-jp"), "こん")
        let truncated: [UInt8] = [0x1B, 0x24, 0x42, 0x24, 0x33, 0x24]
        let text = decode(truncated, "iso-2022-jp")
        XCTAssertTrue(text.hasPrefix("こ"), text)   // the dangling half character is dropped or replaced
        XCTAssertLessThanOrEqual(text.count, 2)
    }

    func testChinese() {
        XCTAssertEqual(decode([0xC4, 0xE3, 0xBA, 0xC3], "gb2312"), "你好")
        XCTAssertEqual(decode([0xC4, 0xE3, 0xBA, 0xC3, 0xA3, 0xAC, 0xCA, 0xC0, 0xBD, 0xE7], "GBK"), "你好，世界")
        XCTAssertEqual(decode([0xC4, 0xE3, 0x95, 0x32, 0x82, 0x36], "gb18030"), "你𠀀")
        XCTAssertEqual(decode([0xA4, 0xA4, 0xA4, 0xE5, 0xB6, 0x6C, 0xA5, 0xF3], "big5"), "中文郵件")
        XCTAssertEqual(decode(Array("~{Dc:C~}".utf8), "hz-gb-2312"), "你好")
    }

    func testKorean() {
        XCTAssertEqual(decode([0xBE, 0xC8, 0xB3, 0xE7, 0xC7, 0xCF, 0xBC, 0xBC, 0xBF, 0xE4], "euc-kr"), "안녕하세요")
        XCTAssertEqual(decode([0xBE, 0xC8, 0xB3, 0xE7], "ks_c_5601-1987"), "안녕")
    }

    func testUTF16And32() {
        XCTAssertEqual(decode([0xFF, 0xFE, 0x48, 0x00, 0x69, 0x00], "utf-16"), "Hi")
        XCTAssertEqual(decode([0xFE, 0xFF, 0x00, 0x48, 0x00, 0x69], "utf-16"), "Hi")
        XCTAssertEqual(decode([0x48, 0x00, 0x69, 0x00], "utf-16le"), "Hi")
        XCTAssertEqual(decode([0x00, 0x48, 0x00, 0x69], "UTF-16BE"), "Hi")
        XCTAssertEqual(decode([0x48, 0x00, 0x69, 0x00], "utf-16"), "Hi")   // no BOM: guessed
        XCTAssertEqual(decode([0x3D, 0xD8, 0x00, 0xDE], "utf-16le"), "😀")
        XCTAssertEqual(decode([0x48, 0x00, 0x3D, 0xD8], "utf-16le"), "H")   // truncated surrogate pair
        XCTAssertEqual(decode([0x00, 0x00, 0x00, 0x48], "utf-32be"), "H")
        XCTAssertEqual(decode([0x48, 0x00, 0x00, 0x00], "utf-32le"), "H")
    }

    func testMislabelledAndUnknown() {
        // Labelled UTF-8 but actually Latin-1.
        XCTAssertEqual(decode([0x43, 0x61, 0x66, 0xE9, 0x20, 0x6F, 0x6B], "utf-8"), "Café ok")
        // ...but a lone lead byte at the very end of UTF-8-labelled text reads as a truncated fetch.
        XCTAssertEqual(decode([0x43, 0x61, 0x66, 0xE9], "utf-8"), "Caf")
        // Labelled ASCII but UTF-8.
        XCTAssertEqual(decode(Array("Café".utf8), "us-ascii"), "Café")
        // Unknown labels: UTF-8 if valid, else Windows-1252.
        XCTAssertEqual(decode(Array("Café".utf8), "x-klingon"), "Café")
        XCTAssertEqual(decode([0x43, 0x61, 0x66, 0xE9], "x-klingon"), "Café")
        XCTAssertEqual(decode([0x43, 0x61, 0x66, 0xE9], nil), "Café")
        XCTAssertEqual(decode(Array("ok".utf8), "\"utf-8\""), "ok")
    }

    func testTruncatedMultibyteTailIsDropped() {
        let bytes = Array("Grüße".utf8)
        XCTAssertEqual(decode(Array(bytes.dropLast()), "utf-8"), "Grüß")   // "e" is ASCII, drop 1 still valid
        XCTAssertEqual(decode(Array(bytes.prefix(5)), "utf-8"), "Grü")      // cuts "ß" in half
        XCTAssertEqual(decode([0xC4, 0xE3, 0xBA], "gb2312"), "你")
        XCTAssertEqual(decode([0x82, 0xB1, 0x82], "shift_jis"), "こ")
    }

    func testInvalidBytesInsideMultibyteText() {
        // One broken sequence in otherwise valid GB2312 text stays local.
        let text = decode([0xC4, 0xE3, 0xFF, 0xBA, 0xC3, 0x21], "gb2312")
        XCTAssertTrue(text.hasPrefix("你"))
        XCTAssertTrue(text.hasSuffix("!"))
        // Mostly-garbage "Shift_JIS" falls back to something readable rather than nothing.
        XCTAssertFalse(decode(Array(repeating: 0xFF, count: 40), "shift_jis").isEmpty)
    }

    func testCanonicalNames() {
        XCTAssertEqual(Charset.canonicalName("Latin1"), "windows-1252")
        XCTAssertEqual(Charset.canonicalName("UTF8"), "utf-8")
        XCTAssertEqual(Charset.canonicalName(" us-ascii "), "us-ascii")
        XCTAssertTrue(Charset.isSame("utf-8", "UTF8"))
        XCTAssertFalse(Charset.isSame("utf-8", "koi8-r"))
    }

    func testMacRomanAndUTF7() {
        XCTAssertEqual(decode([0x8E], "macintosh"), "é")
        XCTAssertEqual(decode([0x43, 0x61, 0x66, 0x8E, 0xD2, 0xD3, 0xDB], "x-mac-roman"), "Café“”€")
        XCTAssertEqual(decode(Array("Hi Mom -+Jjo--!".utf8), "utf-7"), "Hi Mom -☺-!")
    }
}
