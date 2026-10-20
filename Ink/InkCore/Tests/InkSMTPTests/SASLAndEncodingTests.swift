import XCTest
@testable import InkSMTP

final class SASLTests: XCTestCase {
    func testPlain() {
        XCTAssertEqual(SASL.plain(username: "ada@gmail.com", password: "abcd efgh ijkl mnop"), "AGFkYUBnbWFpbC5jb20AYWJjZCBlZmdoIGlqa2wgbW5vcA==")
        let decoded = Data(base64Encoded: SASL.plain(username: "tëst", password: "pä$$"))!
        XCTAssertEqual(Array(decoded), [0] + Array("tëst".utf8) + [0] + Array("pä$$".utf8))
    }

    /// The example from Google's XOAUTH2 documentation.
    func testXOAUTH2MatchesGoogleDocumentation() {
        XCTAssertEqual(
            SASL.xoauth2(username: "someuser@example.com", accessToken: "ya29.vF9dft4qmTc2Nvb3RlckBhdHRhdmlzdGEuY29tCg"),
            "dXNlcj1zb21ldXNlckBleGFtcGxlLmNvbQFhdXRoPUJlYXJlciB5YTI5LnZGOWRmdDRxbVRjMk52YjNSbGNrQmhkSFJoZG1semRHRXVZMjl0Q2cBAQ=="
        )
    }

    /// RFC 7628 §4.1 example.
    func testOAuthBearerMatchesRFC7628() {
        XCTAssertEqual(
            SASL.oauthBearer(username: "user@example.com", accessToken: "vF9dft4qmTc2Nvb3RlckBhdHRhdmlzdGEuY29tCg==", host: "server.example.com", port: 587),
            "bixhPXVzZXJAZXhhbXBsZS5jb20sAWhvc3Q9c2VydmVyLmV4YW1wbGUuY29tAXBvcnQ9NTg3AWF1dGg9QmVhcmVyIHZGOWRmdDRxbVRjMk52YjNSbGNrQmhkSFJoZG1semRHRXVZMjl0Q2c9PQEB"
        )
        let escaped = String(decoding: Data(base64Encoded: SASL.oauthBearer(username: "a,b=c@x", accessToken: "t"))!, as: UTF8.self)
        XCTAssertTrue(escaped.hasPrefix("n,a=a=2Cb=3Dc@x,\u{01}auth=Bearer t"))
    }

    func testLogin() {
        XCTAssertEqual(SASL.login("Username:"), "VXNlcm5hbWU6")
        XCTAssertEqual(SASL.login(""), "")
    }

    func testGmailErrorChallenge() {
        let challenge = SASL.decodeOAuthErrorChallenge("eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ==")
        XCTAssertEqual(challenge, SASL.OAuthErrorChallenge(status: "400", schemes: "Bearer", scope: "https://mail.google.com/"))
        XCTAssertFalse(challenge!.explanation.isEmpty)
    }

    func testErrorChallengeWithoutPaddingAndNumericStatus() {
        // {"status":401,"schemes":"bearer"} without the trailing '='.
        let base64 = Data(#"{"status":401,"schemes":"bearer"}"#.utf8).base64EncodedString().replacingOccurrences(of: "=", with: "")
        let challenge = SASL.decodeOAuthErrorChallenge(base64)
        XCTAssertEqual(challenge?.status, "401")
        XCTAssertTrue(challenge?.explanation.contains("expired") ?? false)
    }

    func testGarbageChallengeIsNil() {
        XCTAssertNil(SASL.decodeOAuthErrorChallenge(""))
        XCTAssertNil(SASL.decodeOAuthErrorChallenge("VXNlcm5hbWU6"))   // "Username:" isn't JSON
        XCTAssertNil(SASL.decodeOAuthErrorChallenge("!!!not base64!!!"))
        XCTAssertNil(SASL.decodeOAuthErrorChallenge(Data("[1,2]".utf8).base64EncodedString()))
    }
}

final class SMTPDataEncoderTests: XCTestCase {
    private func encode(_ text: String) -> String {
        String(decoding: SMTPDataEncoder.encode(Data(text.utf8)), as: UTF8.self)
    }

    func testCRLFMessageGetsTerminator() {
        XCTAssertEqual(encode("Subject: hi\r\n\r\nbody\r\n"), "Subject: hi\r\n\r\nbody\r\n.\r\n")
    }

    func testMissingFinalNewlineIsAdded() {
        XCTAssertEqual(encode("Subject: hi\r\n\r\nbody"), "Subject: hi\r\n\r\nbody\r\n.\r\n")
    }

    func testBareLFAndBareCRBecomeCRLF() {
        XCTAssertEqual(encode("a\nb\rc\r\nd\n\ne\r"), "a\r\nb\r\nc\r\nd\r\n\r\ne\r\n.\r\n")
    }

    func testCRCRLFIsOneBlankLinePlusLineEnd() {
        XCTAssertEqual(encode("a\r\r\nb"), "a\r\n\r\nb\r\n.\r\n")
    }

    func testDotStuffing() {
        XCTAssertEqual(encode(".hidden\r\nmid.dle\r\n.\r\n..two\n."), "..hidden\r\nmid.dle\r\n..\r\n...two\r\n..\r\n.\r\n")
    }

    func testEmptyMessage() {
        XCTAssertEqual(encode(""), ".\r\n")
    }

    func testChunkBoundariesDoNotChangeOutput() {
        let text = "From: a@b\r\n\r\n.line one\r\nline\rtwo\n.three\r\n\r\n..four\r"
        let expected = encode(text)
        let bytes = Array(text.utf8)
        for split in 0...bytes.count {
            var encoder = SMTPDataEncoder()
            var output = encoder.encode(Data(bytes[..<split]))
            output.append(encoder.encode(Data(bytes[split...])))
            output.append(encoder.finish())
            XCTAssertEqual(String(decoding: output, as: UTF8.self), expected, "split at \(split)")
        }
        // Byte at a time.
        var encoder = SMTPDataEncoder()
        var output = Data()
        for byte in bytes { output.append(encoder.encode(Data([byte]))) }
        output.append(encoder.finish())
        XCTAssertEqual(String(decoding: output, as: UTF8.self), expected)
    }

    func testEncodedLengthMatchesEncoding() {
        let samples = ["", "a", "a\n", ".", ".\r\n.", "x\r\r\n.y\rz", "Subject: é\r\n\r\nü\n", String(repeating: ".a\n\r", count: 50)]
        for sample in samples {
            let data = Data(sample.utf8)
            XCTAssertEqual(SMTPDataEncoder.encodedLength(of: data), SMTPDataEncoder.encode(data).count - 3, sample.debugDescription)
        }
    }

    func testBinaryBytesPassThrough() {
        let data = Data([0x00, 0xFF, 0x80, 0x0A, 0x2E, 0x00])
        XCTAssertEqual(Array(SMTPDataEncoder.encode(data)), [0x00, 0xFF, 0x80, 0x0D, 0x0A, 0x2E, 0x2E, 0x00, 0x0D, 0x0A, 0x2E, 0x0D, 0x0A])
    }

    func testLargeMessagePerformanceIsLinear() {
        let line = Array("The quick brown fox jumps over the lazy dog. 0123456789\n".utf8)
        var bytes: [UInt8] = []
        bytes.reserveCapacity(line.count * 100_000)
        for _ in 0..<100_000 { bytes.append(contentsOf: line) }
        let data = Data(bytes)
        let start = Date()
        let encoded = SMTPDataEncoder.encode(data)
        XCTAssertEqual(encoded.count, data.count + 100_000 + 3)
        XCTAssertLessThan(Date().timeIntervalSince(start), 5)
    }

    func testMessageTraits() {
        XCTAssertEqual(MessageTraits.scan(sampleMessage()), MessageTraits(hasEightBit: false, hasEightBitHeaders: false))
        XCTAssertEqual(MessageTraits.scan(Data("Subject: hi\r\n\r\nGrüße\r\n".utf8)), MessageTraits(hasEightBit: true, hasEightBitHeaders: false))
        XCTAssertEqual(MessageTraits.scan(Data("Subject: Grüße\r\n\r\nhi\r\n".utf8)), MessageTraits(hasEightBit: true, hasEightBitHeaders: true))
        XCTAssertEqual(MessageTraits.scan(Data("Subject: hi\n\nGrüße\n".utf8)), MessageTraits(hasEightBit: true, hasEightBitHeaders: false))
    }
}

final class SMTPAddressTests: XCTestCase {
    func testCleaning() throws {
        XCTAssertEqual(try SMTPAddress.clean(" <ada@example.com> ", allowEmpty: false), "ada@example.com")
        XCTAssertEqual(try SMTPAddress.clean("ada+tag@example.com", allowEmpty: false), "ada+tag@example.com")
        XCTAssertEqual(try SMTPAddress.clean("\"ada lovelace\"@example.com", allowEmpty: false), "\"ada lovelace\"@example.com")
        XCTAssertEqual(try SMTPAddress.clean("<>", allowEmpty: true), "")
        XCTAssertEqual(try SMTPAddress.clean("用户@例子.广告", allowEmpty: false), "用户@例子.广告")
    }

    func testRejectsInjectionAndJunk() {
        let bad = ["ada@example.com>\r\nRCPT TO:<eve@evil.example", "ada@example.com\nDATA", "ada lovelace@example.com", "no-at-sign", "@example.com", "ada@", "a<b@example.com", "ada@exa mple.com", "ada@@example.com", "nul\u{0}@example.com"]
        for address in bad {
            XCTAssertThrowsError(try SMTPAddress.clean(address, allowEmpty: false), address.debugDescription)
        }
        XCTAssertThrowsError(try SMTPAddress.clean("  ", allowEmpty: false)) { error in
            XCTAssertEqual(error as? SMTPAddress.Problem, .empty)
        }
    }

    func testASCIIForm() {
        XCTAssertEqual(SMTPAddress.asciiForm("ada@example.com"), "ada@example.com")
        XCTAssertEqual(SMTPAddress.asciiForm("info@bücher.example"), "info@xn--bcher-kva.example")
        XCTAssertEqual(SMTPAddress.asciiForm("info@MÜNCHEN.de"), "info@xn--mnchen-3ya.de")
        XCTAssertNil(SMTPAddress.asciiForm("jürgen@example.com"))
    }

    func testPunycodeVectors() {
        XCTAssertEqual(Punycode.encode("bücher"), "bcher-kva")
        // RFC 3492 §7.1 samples.
        XCTAssertEqual(Punycode.encode("ليهمابتكلموشعربي؟"), "egbpdaj6bu4bxfgehfvwxn")
        XCTAssertEqual(Punycode.encode("他们为什么不说中文"), "ihqwcrb4cv8a8dqg056pqjye")
        XCTAssertEqual(Punycode.encode("Pročprostěnemluvíčesky"), "Proprostnemluvesky-uyb24dma41a")
        XCTAssertEqual(Punycode.idnaDomain("例え.テスト"), "xn--r8jz45g.xn--zckzah")
        XCTAssertEqual(Punycode.idnaDomain("example.com"), "example.com")
        XCTAssertEqual(Punycode.idnaDomain("bücher。example"), "xn--bcher-kva.example")
        XCTAssertNil(Punycode.idnaDomain(String(repeating: "ü", count: 80) + ".example"))
    }
}
