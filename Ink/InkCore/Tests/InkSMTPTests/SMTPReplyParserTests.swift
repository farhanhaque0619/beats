import XCTest
@testable import InkSMTP

final class SMTPReplyParserTests: XCTestCase {
    private func parseAll(_ text: String) throws -> [SMTPReply] {
        var parser = SMTPReplyParser()
        parser.append(Data(text.utf8))
        var replies: [SMTPReply] = []
        while let reply = try parser.nextReply() { replies.append(reply) }
        return replies
    }

    func testSingleLineReply() throws {
        let replies = try parseAll("220 smtp.gmail.com ESMTP d9443c01a7336-29245ed2a4fsm1428375ad.16 - gsmtp\r\n")
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].code, 220)
        XCTAssertEqual(replies[0].lines, ["smtp.gmail.com ESMTP d9443c01a7336-29245ed2a4fsm1428375ad.16 - gsmtp"])
        XCTAssertNil(replies[0].enhancedStatus)
    }

    func testGmailMultilineEHLO() throws {
        let text = """
        250-smtp.gmail.com at your service, [203.0.113.42]\r
        250-SIZE 35882577\r
        250-8BITMIME\r
        250-AUTH LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH\r
        250-ENHANCEDSTATUSCODES\r
        250-PIPELINING\r
        250-CHUNKING\r
        250 SMTPUTF8\r

        """
        let replies = try parseAll(text)
        XCTAssertEqual(replies.count, 1)
        XCTAssertEqual(replies[0].code, 250)
        XCTAssertEqual(replies[0].lines.count, 8)
        let extensions = SMTPClient.parseExtensions(replies[0])
        XCTAssertEqual(extensions["SIZE"], "35882577")
        XCTAssertEqual(extensions["8BITMIME"], "")
        XCTAssertEqual(extensions["AUTH"], "LOGIN PLAIN XOAUTH2 PLAIN-CLIENTTOKEN OAUTHBEARER XOAUTH")
        XCTAssertNotNil(extensions["SMTPUTF8"])
        XCTAssertNil(extensions["STARTTLS"])
    }

    func testRepliesSplitAcrossChunksAndPipelined() throws {
        var parser = SMTPReplyParser()
        parser.append(Data("250 2.1.0 OK\r\n250-2.1".utf8))
        XCTAssertEqual(try parser.nextReply()?.code, 250)
        XCTAssertNil(try parser.nextReply())
        parser.append(Data(".5 first\r\n250 2.1.5 OK\r\n550 5.1.1 nope\r".utf8))
        let second = try parser.nextReply()
        XCTAssertEqual(second?.lines, ["2.1.5 first", "2.1.5 OK"])
        XCTAssertNil(try parser.nextReply())
        parser.append(Data("\n".utf8))
        let third = try parser.nextReply()
        XCTAssertEqual(third?.code, 550)
        XCTAssertEqual(third?.enhancedStatus, "5.1.1")
        XCTAssertFalse(parser.hasBufferedBytes)
    }

    func testBareLFAndCodeOnlyLines() throws {
        let replies = try parseAll("250-first\n250\n354\r\n")
        XCTAssertEqual(replies.map(\.code), [250, 354])
        XCTAssertEqual(replies[0].lines, ["first", ""])
        XCTAssertEqual(replies[1].lines, [""])
    }

    func testMalformedLineIsAnError() {
        var parser = SMTPReplyParser()
        parser.append(Data("HTTP/1.1 400 Bad Request\r\n".utf8))
        XCTAssertThrowsError(try parser.nextReply()) { error in
            guard case SMTPReplyParser.ParseError.malformedLine(let excerpt) = error else { return XCTFail("\(error)") }
            XCTAssertTrue(excerpt.hasPrefix("HTTP/1.1"))
        }
    }

    func testOutOfRangeCodeAndBadSeparatorAreErrors() {
        for text in ["099 too low\r\n", "250x nope\r\n", "25\r\n", "600 high\r\n"] {
            var parser = SMTPReplyParser()
            parser.append(Data(text.utf8))
            XCTAssertThrowsError(try parser.nextReply(), text)
        }
    }

    func testOverlongLineIsRejected() {
        var parser = SMTPReplyParser()
        parser.maxLineLength = 100
        parser.append(Data(("250-" + String(repeating: "x", count: 200)).utf8))
        XCTAssertThrowsError(try parser.nextReply()) { error in
            XCTAssertEqual(error as? SMTPReplyParser.ParseError, .lineTooLong)
        }
    }

    func testEndlessMultilineReplyIsRejected() {
        var parser = SMTPReplyParser()
        parser.maxLines = 10
        parser.append(Data(String(repeating: "250-more\r\n", count: 20).utf8))
        XCTAssertThrowsError(try parser.nextReply()) { error in
            XCTAssertEqual(error as? SMTPReplyParser.ParseError, .tooManyLines)
        }
    }

    func testStrayBlankLinesBetweenRepliesAreIgnored() throws {
        let replies = try parseAll("\r\n250 OK\r\n\r\n221 Bye\r\n")
        XCTAssertEqual(replies.map(\.code), [250, 221])
    }

    func testNonUTF8BytesDoNotCrash() throws {
        var parser = SMTPReplyParser()
        parser.append(Data([0x35, 0x35, 0x30, 0x20, 0xFF, 0xFE, 0x41, 0x0D, 0x0A]))
        let reply = try parser.nextReply()
        XCTAssertEqual(reply?.code, 550)
        XCTAssertEqual(reply?.lines.count, 1)
    }

    // MARK: Human text

    func testGmailBadCredentialsText() throws {
        let replies = try parseAll("535-5.7.8 Username and Password not accepted. For more information, go to\r\n535 5.7.8  https://support.google.com/mail/?p=BadCredentials d9443c01a7336-29245ed2a4fsm1428375ad.16 - gsmtp\r\n")
        XCTAssertEqual(replies[0].code, 535)
        XCTAssertEqual(replies[0].enhancedStatus, "5.7.8")
        XCTAssertEqual(replies[0].text, "Username and Password not accepted. For more information, go to https://support.google.com/mail/?p=BadCredentials")
    }

    func testOutlookTraceIsDropped() throws {
        let replies = try parseAll("535 5.7.139 Authentication unsuccessful, basic authentication is disabled. [PH8PR07CA0012.namprd07.prod.outlook.com 2026-10-20T14:03:12.345Z 08DEF0A1B2C3D4E5]\r\n")
        XCTAssertEqual(replies[0].enhancedStatus, "5.7.139")
        XCTAssertEqual(replies[0].text, "Authentication unsuccessful, basic authentication is disabled.")
    }

    func testTextKeepsMeaningfulBrackets() throws {
        let replies = try parseAll("550 5.1.1 <nobody@example.org>: Recipient address rejected: User unknown in virtual mailbox table [mx1]\r\n")
        XCTAssertEqual(replies[0].text, "<nobody@example.org>: Recipient address rejected: User unknown in virtual mailbox table [mx1]")
    }

    func testEnhancedStatusDetection() {
        XCTAssertNotNil(SMTPReply.enhancedStatusPrefix(of: "2.0.0 OK"))
        XCTAssertNotNil(SMTPReply.enhancedStatusPrefix(of: "5.7.139"))
        XCTAssertNil(SMTPReply.enhancedStatusPrefix(of: "3.1.4159 pi"))
        XCTAssertNil(SMTPReply.enhancedStatusPrefix(of: "1.2.3 not a class"))
        XCTAssertNil(SMTPReply.enhancedStatusPrefix(of: "5.7.8x"))
        XCTAssertNil(SMTPReply.enhancedStatusPrefix(of: "smtp.gmail.com"))
        XCTAssertEqual(SMTPReply(code: 250, lines: ["2.1.5 OK"]).text, "OK")
        XCTAssertEqual(SMTPReply(code: 250, lines: []).text, "")
    }

    func testExtensionParsingMergesOldStyleAuth() {
        let reply = SMTPReply(code: 250, lines: ["smtp.fastmail.com", "PIPELINING", "SIZE 71000000", "AUTH PLAIN LOGIN", "AUTH=PLAIN LOGIN CRAM-MD5", "auth=login", "8bitmime", "X-WEIRD!@# junk", ""])
        let extensions = SMTPClient.parseExtensions(reply)
        XCTAssertEqual(extensions["AUTH"], "PLAIN LOGIN CRAM-MD5")
        XCTAssertEqual(extensions["8BITMIME"], "")
        XCTAssertEqual(extensions["SIZE"], "71000000")
        XCTAssertNil(extensions["X-WEIRD!@#"])
        XCTAssertEqual(extensions.count, 4)
    }

    func testSanitizedHostname() {
        XCTAssertEqual(SMTPClient.sanitizedHostname("ada-macbook.local"), "ada-macbook.local")
        XCTAssertEqual(SMTPClient.sanitizedHostname("[192.0.2.1]"), "[192.0.2.1]")
        XCTAssertEqual(SMTPClient.sanitizedHostname("Ada's MacBook"), "localhost")
        XCTAssertEqual(SMTPClient.sanitizedHostname("evil\r\nRCPT TO:<x@y>"), "localhost")
        XCTAssertEqual(SMTPClient.sanitizedHostname(""), "localhost")
        XCTAssertEqual(SMTPClient.sanitizedHostname("münchen.example"), "localhost")
    }
}
