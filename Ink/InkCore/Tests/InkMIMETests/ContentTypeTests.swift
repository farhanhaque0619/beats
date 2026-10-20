import XCTest
@testable import InkMIME

final class ContentTypeTests: XCTestCase {
    func testBasicParse() {
        let ct = ContentType.parse("Text/HTML; Charset=\"UTF-8\"; format=flowed")
        XCTAssertEqual(ct.type, "text")
        XCTAssertEqual(ct.subtype, "html")
        XCTAssertEqual(ct.mimeType, "text/html")
        XCTAssertEqual(ct.parameters["charset"], "UTF-8")
        XCTAssertEqual(ct.parameters["format"], "flowed")
    }

    func testQuotedValuesWithSemicolonsAndEscapes() {
        let ct = ContentType.parse(#"multipart/mixed; boundary="----=_Part_0;abc"; name="say \"hi\".txt""#)
        XCTAssertEqual(ct.boundary, "----=_Part_0;abc")
        XCTAssertEqual(ct.parameters["name"], "say \"hi\".txt")
    }

    func testCommentsAndWhitespace() {
        let ct = ContentType.parse("text/plain (Plain text) ; charset = us-ascii ")
        XCTAssertEqual(ct.mimeType, "text/plain")
        XCTAssertEqual(ct.charset, "us-ascii")
    }

    func testMissingSemicolon() {
        let ct = ContentType.parse("text/plain charset=utf-8")
        XCTAssertEqual(ct.mimeType, "text/plain")
        XCTAssertEqual(ct.charset, "utf-8")
    }

    func testGarbageFallsBackToTextPlain() {
        XCTAssertEqual(ContentType.parse("").mimeType, "text/plain")
        XCTAssertEqual(ContentType.parse("garbage").mimeType, "text/plain")
        XCTAssertEqual(ContentType.parse("/").mimeType, "text/plain")
        XCTAssertEqual(ContentType.parse("text").mimeType, "text/plain")
        XCTAssertEqual(ContentType.parse("html; charset=utf-8").mimeType, "text/html")
        XCTAssertEqual(ContentType.parse("text/plain\"; charset=utf-8").mimeType, "text/plain")
        XCTAssertEqual(ContentType.parse("ima ge/png").mimeType, "text/plain")
    }

    func testRFC2231Continuations() {
        let ct = ContentType.parse("""
        message/external-body; access-type=URL;
         URL*0="ftp://";
         URL*1="cs.utk.edu/pub/moore/bulk-mailer/bulk-mailer.tar"
        """)
        XCTAssertEqual(ct.parameters["url"], "ftp://cs.utk.edu/pub/moore/bulk-mailer/bulk-mailer.tar")
        XCTAssertEqual(ct.parameters["access-type"], "URL")
    }

    func testRFC2231CharsetAndLanguage() {
        let ct = ContentType.parse("application/x-stuff; title*=us-ascii'en-us'This%20is%20%2A%2A%2Afun%2A%2A%2A")
        XCTAssertEqual(ct.parameters["title"], "This is ***fun***")
        let mixed = ContentType.parse("application/x-stuff; title*0*=us-ascii'en'This%20is%20even%20more%20; title*1*=%2A%2A%2Afun%2A%2A%2A%20; title*2=\"isn't it!\"")
        XCTAssertEqual(mixed.parameters["title"], "This is even more ***fun*** isn't it!")
    }

    func testRFC2231OutOfOrderAndExtendedWins() {
        let ct = ContentType.parse("application/pdf; name*1*=%20B.pdf; name*0*=UTF-8''Teil%20A; name=\"fallback.pdf\"")
        XCTAssertEqual(ct.parameters["name"], "Teil A B.pdf")
    }

    func testRFC2231Latin1() {
        let cd = ContentDisposition.parse("attachment; filename*=iso-8859-1'de'Rechnung%20M%E4rz.pdf")
        XCTAssertEqual(cd.filename, "Rechnung März.pdf")
    }

    func testRFC2047InParameter() {
        let cd = ContentDisposition.parse("attachment; filename=\"=?UTF-8?B?5aCx5ZGK5pu4LmRvY3g=?=\"")
        XCTAssertEqual(cd.filename, "報告書.docx")
        XCTAssertTrue(cd.isAttachment)
    }

    func testDispositionTolerance() {
        XCTAssertEqual(ContentDisposition.parse("INLINE").type, "inline")
        XCTAssertEqual(ContentDisposition.parse("filename=report.pdf").filename, "report.pdf")
        XCTAssertEqual(ContentDisposition.parse("filename=report.pdf").type, "attachment")
        XCTAssertEqual(ContentDisposition.parse("attachment filename=report.pdf").filename, "report.pdf")
        XCTAssertEqual(ContentDisposition.parse("attachment; filename=\"My Report (final).pdf\"; size=1234").filename, "My Report (final).pdf")
    }

    func testFilenameSanitizing() {
        XCTAssertEqual(ContentDisposition.parse("attachment; filename=\"../../etc/passwd\"").filename, "passwd")
        XCTAssertEqual(ContentDisposition.parse("attachment; filename=\"C:\\Users\\a\\file.txt\"").filename, "file.txt")
        XCTAssertNil(ContentDisposition.parse("attachment; filename=\"..\"").filename)
        XCTAssertNil(ContentDisposition.parse("attachment; filename=\"   \"").filename)
        XCTAssertEqual(ContentDisposition.parse("attachment; filename=\"a\u{0007}b.txt\"").filename, "ab.txt")
    }

    func testUnterminatedQuote() {
        let ct = ContentType.parse("multipart/mixed; boundary=\"abc")
        XCTAssertEqual(ct.boundary, "abc")
    }
}
