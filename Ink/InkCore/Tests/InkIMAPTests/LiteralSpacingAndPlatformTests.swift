import XCTest
import InkModel
@testable import InkIMAP

/// Literals glued to the item name (GreenMail 2.1 sends `BODY[1]<0>{22}`), and text handling
/// that must behave the same on Apple platforms and Linux: Swift treats `"\r\n"` as a single
/// Character, and `String.contains(String)` is a different algorithm on each.
final class LiteralSpacingAndPlatformTests: XCTestCase {
    // MARK: Literals without a leading space

    func testPartialSectionLiteralWithoutSpace() {
        let text = "* 1 FETCH (UID 5 BODY[1]<0>{23}\r\nHello from GreenMail!\r\n FLAGS (\\Seen))\r\n"
        guard let response = fetchResponse(text) else { return }
        XCTAssertEqual(response.uid, 5)
        XCTAssertEqual(response.section("1"), Data("Hello from GreenMail!\r\n".utf8))
        XCTAssertEqual(response.sectionOrigins["1"], 0)
        XCTAssertEqual(response.flags, ["\\Seen"], "items after the literal are still read")
    }

    func testWholeMessageAndHeaderFieldsLiteralsWithoutSpace() {
        let header = "References: <a@example.com>\r\n\r\n"
        let text = "* 2 FETCH (UID 9 BODY[]{5}\r\nHello BODY[HEADER.FIELDS (REFERENCES)]{\(header.utf8.count)}\r\n\(header) RFC822.SIZE 5)\r\n"
        guard let response = fetchResponse(text) else { return }
        XCTAssertEqual(response.section(""), Data("Hello".utf8))
        XCTAssertEqual(response.section("HEADER.FIELDS (REFERENCES)"), Data(header.utf8))
        XCTAssertEqual(response.size, 5)
    }

    func testLiteral8AndNonSynchronizingFormWithoutSpace() {
        let text = "* 3 FETCH (UID 1 BINARY[1]~{3}\r\nabc BODY[2]{4+}\r\nwxyz)\r\n"
        guard case .fetch(let response)? = untagged(text) else { return XCTFail("not a FETCH") }
        XCTAssertEqual(response.section("2"), Data("wxyz".utf8))
        XCTAssertEqual(response.uid, 1)
    }

    func testBracesInsideAtomsThatAreNotLiteralsStayInTheAtom() {
        // `{1}` not followed by a line break isn't a literal, so it stays part of the token.
        let text = "* FLAGS (\\Seen $Label{1}x Work)\r\n"
        XCTAssertEqual(untagged(text), .flags(["\\Seen", "$Label{1}x", "Work"]))
    }

    func testGluedLiteralSplitAcrossReads() throws {
        let text = "* 1 FETCH (UID 5 BODY[1]<0>{10}\r\n0123456789)\r\nA003 OK done\r\n"
        let bytes = Array(text.utf8)
        for split in 1..<bytes.count {
            var parser = IMAPResponseParser()
            parser.append(Array(bytes[..<split]))
            var responses: [IMAPResponse] = []
            while let response = try parser.next() { responses.append(response) }
            parser.append(Array(bytes[split...]))
            while let response = try parser.next() { responses.append(response) }
            XCTAssertEqual(responses.count, 2, "split at \(split)")
            guard case .untagged(.fetch(let fetch))? = responses.first else { return XCTFail("split at \(split)") }
            XCTAssertEqual(fetch.section("1"), Data("0123456789".utf8), "split at \(split)")
        }
    }

    // MARK: CRLF and platform-neutral text

    /// `"\r\n"` is one Character, so a Character-level `case "\r", "\n"` misses it.
    func testSectionKeyTreatsCRLFAsWhitespace() {
        XCTAssertEqual(IMAPFetchResponse.sectionKey("header.fields (From\r\nTo)"), "HEADER.FIELDS (FROM TO)")
        XCTAssertEqual(IMAPFetchResponse.sectionKey("HEADER.FIELDS (\r\n\"Subject\"\r\n)"), "HEADER.FIELDS (SUBJECT)")
        XCTAssertEqual(IMAPFetchResponse.sectionKey(" 1.2 "), "1.2")
        XCTAssertEqual(IMAPFetchResponse.sectionKey("header.fields ( \"From\"  To )"), "HEADER.FIELDS (FROM TO)")
    }

    func testProtocolTextContainsIsByteLevel() {
        XCTAssertTrue(IMAPText.contains("Mailbox already exists\r\n", "\n"))
        XCTAssertTrue(IMAPText.contains("a\r\nb", "\r"))
        XCTAssertTrue(IMAPText.contains("Mailbox ALREADY Exists", "already exists", ignoringASCIICase: true))
        XCTAssertFalse(IMAPText.contains("Mailbox ALREADY Exists", "already exists"))
        // Byte-level: a base letter followed by a combining accent still contains the letter,
        // on every platform (a Character-level search says no).
        XCTAssertTrue(IMAPText.contains("Cafe\u{301}", "Cafe"))
        XCTAssertTrue(IMAPText.contains("x", ""))
        XCTAssertFalse(IMAPText.contains("ab", "abc"))
    }

    /// The alert isn't repeated when the completion text already carries it.
    func testAlertIsNotRepeatedInTheErrorText() {
        let response = IMAPTaggedResponse(tag: "A001", status: .no, text: IMAPResponseText(text: "[ALERT] Please log in via your web browser (Failure)"))
        let error = IMAPError.commandFailed(command: "LOGIN", response: response, mailbox: nil, alert: "Please log in via your web browser").mailError
        XCTAssertEqual(error, .authenticationFailed("[ALERT] Please log in via your web browser"))
        let other = IMAPTaggedResponse(tag: "A001", status: .no, text: IMAPResponseText(text: "Invalid credentials (Failure)"))
        let combined = IMAPError.commandFailed(command: "LOGIN", response: other, mailbox: nil, alert: "Application-specific password required").mailError
        XCTAssertEqual(combined, .authenticationFailed("Application-specific password required Invalid credentials"))
    }

    /// ByteCountFormatter words sizes differently on Apple platforms and Linux (and by locale);
    /// the APPENDLIMIT error is worded by hand so it reads the same everywhere.
    func testSizeWordingIsTheSameOnEveryPlatform() {
        XCTAssertEqual(IMAPClient.formatSize(10), "1 KB")
        XCTAssertEqual(IMAPClient.formatSize(700_000), "684 KB")
        XCTAssertEqual(IMAPClient.formatSize(5_500_000), "5.2 MB")
        XCTAssertEqual(IMAPClient.formatSize(35_651_584), "34 MB")
    }

    func testAppendLimitMessage() async throws {
        let transport = ScriptedTransport([.send("* PREAUTH [CAPABILITY IMAP4rev1 LITERAL+ APPENDLIMIT=35651584] ready\r\n")])
        let client = IMAPClient(host: "imap.gmail.com", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) { try await client.connect() }
        await assertThrowsMailError(.serverError("The message is too large for this server (limit 34 MB).")) {
            try await client.append(to: "[Gmail]/Sent Mail", message: Data(count: 35_651_585))
        }
        XCTAssertEqual(transport.transcript, "", "refused before anything is uploaded")
    }

    func testCreateTreatsAlreadyExistsInAnyCaseAsSuccess() async throws {
        let transport = ScriptedTransport([
            .send("* PREAUTH [CAPABILITY IMAP4rev1] ready\r\n"),
            .expect("* CREATE \"Archive\"", reply: "{TAG} NO Mailbox ALREADY EXISTS\r\n"),
        ])
        let client = IMAPClient(host: "h", port: 993, security: .tls, transport: transport)
        try await withWatchdog(transport) {
            try await client.connect()
            try await client.create("Archive")
        }
    }
}
