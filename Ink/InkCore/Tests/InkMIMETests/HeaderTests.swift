import XCTest
@testable import InkMIME

final class HeaderTests: XCTestCase {
    func testUnfoldingAndCaseInsensitiveLookup() {
        let headers = MIMEHeaders.parse(Raw.data("""
        Subject: This is a long subject
         that was folded
        \tacross three lines
        X-Custom: one
        x-custom: two
        CONTENT-TYPE: text/plain

        body
        """))
        XCTAssertEqual(headers["subject"], "This is a long subject that was folded across three lines")
        XCTAssertEqual(headers["SUBJECT"], headers["Subject"])
        XCTAssertEqual(headers.values("X-CUSTOM"), ["one", "two"])
        XCTAssertEqual(headers["Content-Type"], "text/plain")
        XCTAssertNil(headers["Missing"])
        XCTAssertEqual(headers.all.count, 4)
        XCTAssertEqual(headers.all[1].name, "X-Custom")
    }

    func testDecodedHeader() {
        let headers = MIMEHeaders.parse("Subject: =?UTF-8?Q?Gr=C3=BC=C3=9Fe_aus_M=C3=BCnchen?=\r\n\r\n")
        XCTAssertEqual(headers["Subject"], "=?UTF-8?Q?Gr=C3=BC=C3=9Fe_aus_M=C3=BCnchen?=")
        XCTAssertEqual(headers.decoded("Subject"), "Grüße aus München")
    }

    func testRawUTF8HeaderValues() {
        // RFC 6532: UTF-8 straight in the header.
        let data = Raw.bytes("Subject: ", Array("Ünïcödé 日本語 ✓".utf8), "\nFrom: Zoë <zoe@example.com>\n\nbody")
        let headers = MIMEHeaders.parse(data)
        XCTAssertEqual(headers["Subject"], "Ünïcödé 日本語 ✓")
        XCTAssertEqual(headers["From"], "Zoë <zoe@example.com>")
    }

    func testRawLatin1HeaderFallsBackToDeclaredCharset() {
        // Old mailers put ISO-8859-1 bytes straight into headers.
        let data = Raw.bytes("From: Ren", [0xE9], " Dupont <rene@example.fr>\nSubject: Caf", [0xE9],
                             "\nContent-Type: text/plain; charset=iso-8859-1\n\nbody")
        let headers = MIMEHeaders.parse(data)
        XCTAssertEqual(headers["From"], "René Dupont <rene@example.fr>")
        XCTAssertEqual(headers["Subject"], "Café")
    }

    func testRawKOI8HeaderUsesDeclaredCharset() {
        let data = Raw.bytes("Subject: ", [0xF0, 0xD2, 0xC9, 0xD7, 0xC5, 0xD4], "\nContent-Type: text/plain; charset=koi8-r\n\nx")
        XCTAssertEqual(MIMEHeaders.parse(data)["Subject"], "Привет")
    }

    func testLFOnlyAndMboxFromLine() {
        let headers = MIMEHeaders.parse(Data("From alex@ink.example Tue Oct 20 09:00:00 2026\nFrom: a@b.example\nSubject: hi\n\nbody\n".utf8))
        XCTAssertEqual(headers["From"], "a@b.example")
        XCTAssertEqual(headers["Subject"], "hi")
    }

    func testBrokenFoldingWithoutLeadingWhitespace() {
        // Some generators wrap long values without indenting the continuation.
        let raw = "Subject: Part one\r\nand part two\r\nTo: a@b.example\r\n\r\nbody"
        let headers = MIMEHeaders.parse(raw)
        XCTAssertEqual(headers["Subject"], "Part one and part two")
        XCTAssertEqual(headers["To"], "a@b.example")
    }

    func testMissingBlankLineStartsBody() {
        let parsed = MIMEParser.parse(Data("Subject: hi\r\nTo: a@b.example\r\nThis is the body without a blank line.\r\n".utf8))
        XCTAssertEqual(parsed.subject, "hi")
        XCTAssertEqual(parsed.plainText, "This is the body without a blank line.\n")
    }

    func testSpaceBeforeColonAndEmptyValues() {
        let headers = MIMEHeaders.parse("Subject : spaced\r\nX-Empty:\r\nX-Tab:\tvalue\r\n\r\n")
        XCTAssertEqual(headers["Subject"], "spaced")
        XCTAssertEqual(headers["X-Empty"], "")
        XCTAssertEqual(headers["X-Tab"], "value")
    }

    func testFoldedHeaderWithBlankContinuationIsKept() {
        let headers = MIMEHeaders.parse("Received: from a\r\n by b\r\n \r\n with c\r\nSubject: x\r\n\r\n")
        XCTAssertEqual(headers["Received"], "from a by b with c")
        XCTAssertEqual(headers["Subject"], "x")
    }

    func testNotAHeaderBlock() {
        let headers = MIMEHeaders.parse("just some text\r\nwith lines\r\n")
        XCTAssertTrue(headers.isEmpty)
    }

    func testEncodedWordDecodingRemovesLineBreaks() {
        // A decoded CR/LF must not break the header onto two lines.
        let headers = MIMEHeaders.parse("Subject: =?UTF-8?Q?a=0D=0Ab?=\r\n\r\n")
        XCTAssertEqual(headers.decoded("Subject"), "a  b")
    }
}
