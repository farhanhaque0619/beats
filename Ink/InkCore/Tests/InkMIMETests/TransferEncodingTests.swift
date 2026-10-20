import XCTest
@testable import InkMIME

final class TransferEncodingTests: XCTestCase {
    // MARK: Quoted-printable

    func testQPDecodeBasics() {
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("Caf=C3=A9"), as: UTF8.self), "Café")
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("caf=c3=a9 lowercase"), as: UTF8.self), "café lowercase")
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("a=3Db"), as: UTF8.self), "a=b")
    }

    func testQPSoftLineBreaks() {
        let decoded = QuotedPrintable.decode("This is a lo=\r\nng line and an=\nother.=  \r\nTrailing ws after =.\r\nHard break")
        XCTAssertEqual(String(decoding: decoded, as: UTF8.self), "This is a long line and another.Trailing ws after =.\r\nHard break")
    }

    func testQPMalformedIsKept() {
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("50% =ZZ off = now"), as: UTF8.self), "50% =ZZ off = now")
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("x=4"), as: UTF8.self), "x")   // truncated escape at the end
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("x="), as: UTF8.self), "x")
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("=4G"), as: UTF8.self), "=4G")
    }

    func testQPDataOverload() {
        XCTAssertEqual(QuotedPrintable.decode(Data("=E2=82=AC".utf8)), Data([0xE2, 0x82, 0xAC]))
    }

    func testQPEncodeRoundTripAndLineLength() {
        let text = """
        Grüße! This line is deliberately long so that the encoder has to insert soft line breaks, more than once in fact, because it keeps going and going.
        Line with trailing space\u{20}
        From the start of a line
        .
        tabs\there = equals
        日本語のテキストも大丈夫です。日本語のテキストも大丈夫です。日本語のテキストも大丈夫です。
        """
        let encoded = QuotedPrintable.encode(Data(text.utf8))
        for line in encoded.components(separatedBy: "\r\n") {
            XCTAssertLessThanOrEqual(line.count, 76)
            XCTAssertFalse(line.hasSuffix(" "))
            XCTAssertFalse(line.hasPrefix("From "))
            XCTAssertNotEqual(line, ".")
        }
        XCTAssertTrue(encoded.utf8.allSatisfy { $0 < 0x80 })
        XCTAssertFalse(encoded.replacingOccurrences(of: "\r\n", with: "").contains("\n"))
        let decoded = String(decoding: QuotedPrintable.decode(encoded), as: UTF8.self)
        XCTAssertEqual(decoded, text.replacingOccurrences(of: "\n", with: "\r\n"))
    }

    func testQPEncodeCustomLineLength() {
        let encoded = QuotedPrintable.encode(Data(String(repeating: "a", count: 100).utf8), lineLength: 20)
        XCTAssertTrue(encoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 20 })
        XCTAssertEqual(String(decoding: QuotedPrintable.decode(encoded), as: UTF8.self), String(repeating: "a", count: 100))
    }

    // MARK: Base64

    func testBase64Lenient() {
        XCTAssertEqual(String(decoding: Base64Lenient.decode("SGVsbG8="), as: UTF8.self), "Hello")
        XCTAssertEqual(String(decoding: Base64Lenient.decode("SGVsbG8"), as: UTF8.self), "Hello")           // missing padding
        XCTAssertEqual(String(decoding: Base64Lenient.decode("SGV s\r\nbG8=\r\n"), as: UTF8.self), "Hello")  // whitespace
        XCTAssertEqual(String(decoding: Base64Lenient.decode("SGV*sb!G8="), as: UTF8.self), "Hello")       // garbage
        XCTAssertEqual(String(decoding: Base64Lenient.decode("SGVsbG8=V29ybGQ="), as: UTF8.self), "HelloWorld") // concatenated blocks
        XCTAssertEqual(String(decoding: Base64Lenient.decode("SGVsbG8gV29ybGQ"), as: UTF8.self), "Hello World")
        XCTAssertEqual(Base64Lenient.decode("S"), Data())       // a lone character carries no byte
        XCTAssertEqual(Base64Lenient.decode(""), Data())
        XCTAssertEqual(Base64Lenient.decode("_-8="), Data([0xFF, 0xEF]))   // URL-safe alphabet
    }

    func testBase64TruncatedTail() {
        // Partial IMAP fetches cut base64 anywhere.
        let full = "VGhlIHF1aWNrIGJyb3duIGZveA=="
        for cut in 0..<full.count {
            let decoded = Base64Lenient.decode(String(full.prefix(cut)))
            XCTAssertTrue("The quick brown fox".utf8.starts(with: decoded))
        }
    }

    func testBase64DataOverloadAndEncode() {
        let bytes = Data((0..<255).map { UInt8($0) })
        let encoded = Base64Lenient.encode(bytes, lineLength: 76)
        XCTAssertTrue(encoded.components(separatedBy: "\r\n").allSatisfy { $0.count <= 76 })
        XCTAssertEqual(Base64Lenient.decode(Data(encoded.utf8)), bytes)
        XCTAssertEqual(Base64Lenient.encode(Data("Hello".utf8), lineLength: 0), "SGVsbG8=")
        XCTAssertEqual(Base64Lenient.encode(Data(), lineLength: 76), "")
    }

    // MARK: uuencode and dispatch

    func testUUDecode() {
        let block = "begin 644 hello.txt\n12&5L;&\\L('5U96YC;V1E(0H \n`\nend\n"
        XCTAssertEqual(String(decoding: UUEncode.decode(Data(block.utf8)), as: UTF8.self), "Hello, uuencode!\n")
        XCTAssertEqual(UUEncode.filename(in: Data(block.utf8)), "hello.txt")
    }

    func testNormalize() {
        XCTAssertEqual(TransferEncoding.normalize(nil), "7bit")
        XCTAssertEqual(TransferEncoding.normalize(" Base64 "), "base64")
        XCTAssertEqual(TransferEncoding.normalize("QUOTED-PRINTABLE"), "quoted-printable")
        XCTAssertEqual(TransferEncoding.normalize("\"8bit\""), "8bit")
        XCTAssertEqual(TransferEncoding.normalize("base64 (encoded)"), "base64")
        XCTAssertEqual(TransferEncoding.normalize("x-uuencode"), "x-uuencode")
        XCTAssertEqual(TransferEncoding.normalize(""), "7bit")
    }

    func testDecodeDispatch() {
        let raw = Data("SGk=".utf8)
        XCTAssertEqual(TransferEncoding.decode(raw, encoding: "base64"), Data("Hi".utf8))
        XCTAssertEqual(TransferEncoding.decode(raw, encoding: "8bit"), raw)
        XCTAssertEqual(TransferEncoding.decode(raw, encoding: "binary"), raw)
        XCTAssertEqual(TransferEncoding.decode(raw, encoding: "x-unknown"), raw)
        XCTAssertEqual(TransferEncoding.decode(Data("a=3Db".utf8), encoding: "Quoted-Printable"), Data("a=b".utf8))
    }
}
