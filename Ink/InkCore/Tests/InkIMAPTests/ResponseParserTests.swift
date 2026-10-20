import XCTest
import InkModel
@testable import InkIMAP

final class ResponseParserTests: XCTestCase {
    // MARK: Greetings

    func testDovecotGreetingWithCapabilities() {
        let text = "* OK [CAPABILITY IMAP4rev1 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ STARTTLS AUTH=PLAIN] Dovecot (Ubuntu) ready.\r\n"
        guard case .ok(let response)? = untagged(text) else { return XCTFail() }
        XCTAssertEqual(response.code, .capability(["IMAP4rev1", "SASL-IR", "LOGIN-REFERRALS", "ID", "ENABLE", "IDLE", "LITERAL+", "STARTTLS", "AUTH=PLAIN"]))
        XCTAssertEqual(response.text, "Dovecot (Ubuntu) ready.")
    }

    func testICloudGreeting() {
        let text = "* OK [CAPABILITY ST11p00mm-iscream013 1S XAPPLEPUSHSERVICE IMAP4 IMAP4rev1 SASL-IR AUTH=ATOKEN AUTH=PLAIN] iSCREAM ready to rumble (1S:4246) ms6p00mm-pnmdp01 [33:33333]\r\n"
        guard case .ok(let response)? = untagged(text) else { return XCTFail() }
        guard case .capability(let caps)? = response.code else { return XCTFail("no capability code") }
        XCTAssertTrue(caps.contains("AUTH=PLAIN"))
        XCTAssertTrue(response.text.hasPrefix("iSCREAM ready to rumble"))
    }

    func testOutlookGreetingWithTrailingBracketIsNotACode() {
        let text = "* OK The Microsoft Exchange IMAP4 service is ready. [TQBXADQAUABSADAANABDAEEAMAAwADAAMgAuAG4AYQBtAHAAcgBkADAANAAuAHAAcgBvAGQALgBvAHUAdABsAG8AbwBrAC4AYwBvAG0A]\r\n"
        guard case .ok(let response)? = untagged(text) else { return XCTFail() }
        XCTAssertNil(response.code)
        XCTAssertTrue(response.text.hasPrefix("The Microsoft Exchange IMAP4 service is ready."))
    }

    func testGmailGreetingAndPreauthAndBye() {
        guard case .ok(let gmail)? = untagged("* OK Gimap ready for requests from 203.0.113.5 f1mb123456789abc\r\n") else { return XCTFail() }
        XCTAssertNil(gmail.code)
        guard case .preauth(let preauth)? = untagged("* PREAUTH [CAPABILITY IMAP4rev2] Logged in as ada\r\n") else { return XCTFail() }
        XCTAssertEqual(preauth.code, .capability(["IMAP4rev2"]))
        XCTAssertEqual(untagged("* BYE Too many connections from your IP\r\n"), .bye("Too many connections from your IP"))
        XCTAssertEqual(untagged("* BYE [UNAVAILABLE] Server shutting down\r\n"), .bye("Server shutting down"))
    }

    // MARK: Tagged completions

    func testTaggedResponses() {
        let responses = parseAll(crlf("""
        A001 OK [READ-WRITE] SELECT completed
        A002 NO [AUTHENTICATIONFAILED] Invalid credentials (Failure)
        A003 BAD Command Argument Error. 12
        a004 ok done
        A005 OK
        A006 HUH what is this
        """) + "\r\n")
        XCTAssertEqual(responses.count, 6)
        XCTAssertEqual(responses[0], .tagged(IMAPTaggedResponse(tag: "A001", status: .ok, text: IMAPResponseText(code: .readWrite, text: "SELECT completed"))))
        XCTAssertEqual(responses[1], .tagged(IMAPTaggedResponse(tag: "A002", status: .no, text: IMAPResponseText(code: .authenticationFailed, text: "Invalid credentials (Failure)"))))
        XCTAssertEqual(responses[2], .tagged(IMAPTaggedResponse(tag: "A003", status: .bad, text: IMAPResponseText(text: "Command Argument Error. 12"))))
        XCTAssertEqual(responses[3], .tagged(IMAPTaggedResponse(tag: "a004", status: .ok, text: IMAPResponseText(text: "done"))))
        XCTAssertEqual(responses[4], .tagged(IMAPTaggedResponse(tag: "A005", status: .ok, text: IMAPResponseText(text: ""))))
        guard case .tagged(let bogus) = responses[5] else { return XCTFail() }
        XCTAssertEqual(bogus.status, .bad, "an unknown status word must never pass as OK")
    }

    func testContinuations() {
        XCTAssertEqual(parseOne("+ Ready for literal data\r\n"), .continuation("Ready for literal data"))
        XCTAssertEqual(parseOne("+ \r\n"), .continuation(""))
        XCTAssertEqual(parseOne("+\r\n"), .continuation(""))
        XCTAssertEqual(parseOne("+ eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ==\r\n"),
                       .continuation("eyJzdGF0dXMiOiI0MDAiLCJzY2hlbWVzIjoiQmVhcmVyIiwic2NvcGUiOiJodHRwczovL21haWwuZ29vZ2xlLmNvbS8ifQ=="))
        // A continuation whose text ends like a literal header is still just text.
        XCTAssertEqual(parseAll("+ send {5}\r\nA1 OK done\r\n").count, 2)
    }

    // MARK: Response codes

    private func code(_ text: String) -> IMAPResponseCode? {
        guard case .ok(let response)? = untagged("* OK [\(text)] text\r\n") else { return nil }
        return response.code
    }

    func testResponseCodes() {
        XCTAssertEqual(code("UIDVALIDITY 3857529045"), .uidValidity(3_857_529_045))
        XCTAssertEqual(code("UIDNEXT 4392"), .uidNext(4392))
        XCTAssertEqual(code("UNSEEN 12"), .unseen(12))
        XCTAssertEqual(code("HIGHESTMODSEQ 90060128194045007"), .highestModSeq(90_060_128_194_045_007))
        XCTAssertEqual(code("NOMODSEQ"), .noModSeq)
        XCTAssertEqual(code("PERMANENTFLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen $Forwarded $Junk \\*)"),
                       .permanentFlags(["\\Answered", "\\Flagged", "\\Draft", "\\Deleted", "\\Seen", "$Forwarded", "$Junk", "\\*"]))
        XCTAssertEqual(code("PERMANENTFLAGS ()"), .permanentFlags([]))
        XCTAssertEqual(code("READ-ONLY"), .readOnly)
        XCTAssertEqual(code("TRYCREATE"), .tryCreate)
        XCTAssertEqual(code("ALERT"), .alert)
        XCTAssertEqual(code("OVERQUOTA"), .overQuota)
        XCTAssertEqual(code("ALREADYEXISTS"), .alreadyExists)
        XCTAssertEqual(code("NONEXISTENT"), .nonExistent)
        XCTAssertEqual(code("UNAVAILABLE"), .unavailable)
        XCTAssertEqual(code("EXPUNGEISSUED"), .expungeIssued)
        XCTAssertEqual(code("CLOSED"), .closed)
        XCTAssertEqual(code("BADCHARSET (US-ASCII)"), .badCharset(["US-ASCII"]))
        XCTAssertEqual(code("COPYUID 38505 304,319:320 3956:3958"),
                       .copyUID(uidValidity: 38505, source: IMAPSequenceSet("304,319:320")!, destination: IMAPSequenceSet("3956:3958")!))
        XCTAssertEqual(code("APPENDUID 38505 3955"), .appendUID(uidValidity: 38505, uids: IMAPSequenceSet(3955)))
        XCTAssertEqual(code("MODIFIED 7,9"), .modified(IMAPSequenceSet([7, 9])))
        XCTAssertEqual(code("CAPABILITY IMAP4rev1 MOVE"), .capability(["IMAP4rev1", "MOVE"]))
        XCTAssertEqual(code("WEBALERT https://accounts.google.com/signin/continue?sarp=1"), .other("WEBALERT", "https://accounts.google.com/signin/continue?sarp=1"))
        XCTAssertEqual(code("X-UNKNOWN"), .other("X-UNKNOWN", nil))
        XCTAssertEqual(code("uidvalidity 7"), .uidValidity(7), "codes are case-insensitive")
    }

    func testMalformedCodesFallBackToOther() {
        XCTAssertEqual(code("UIDVALIDITY abc"), .other("UIDVALIDITY", "abc"))
        XCTAssertEqual(code("COPYUID 1"), .other("COPYUID", "1"))
        XCTAssertEqual(code("UIDNEXT 99999999999"), .other("UIDNEXT", "99999999999"))
        // An unterminated code is left in the text.
        guard case .ok(let response)? = untagged("* OK [UIDNEXT 5 never closed\r\n") else { return XCTFail() }
        XCTAssertNil(response.code)
        XCTAssertEqual(response.text, "[UIDNEXT 5 never closed")
    }

    func testCodeWithBracketInsideQuotes() {
        guard case .no(let response)? = untagged("* NO [X-NOTE \"a ] b\"] trailing text\r\n") else { return XCTFail() }
        XCTAssertEqual(response.code, .other("X-NOTE", "\"a ] b\""))
        XCTAssertEqual(response.text, "trailing text")
    }

    // MARK: Simple untagged responses

    func testCounts() {
        XCTAssertEqual(untagged("* 172 EXISTS\r\n"), .exists(172))
        XCTAssertEqual(untagged("* 1 RECENT\r\n"), .recent(1))
        XCTAssertEqual(untagged("* 44 EXPUNGE\r\n"), .expunge(44))
        XCTAssertEqual(untagged("* 0 exists\r\n"), .exists(0))
        XCTAssertEqual(untagged("* 12 WHATEVER\r\n"), .other("12 WHATEVER"))
    }

    func testFlagsAndCapability() {
        XCTAssertEqual(untagged("* FLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen $Forwarded $Junk $NotJunk $NotPhishing $Phishing NonJunk)\r\n"),
                       .flags(["\\Answered", "\\Flagged", "\\Draft", "\\Deleted", "\\Seen", "$Forwarded", "$Junk", "$NotJunk", "$NotPhishing", "$Phishing", "NonJunk"]))
        XCTAssertEqual(untagged("* CAPABILITY IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 XYZZY SASL-IR AUTH=XOAUTH2 AUTH=PLAIN AUTH=PLAIN-CLIENTTOKEN AUTH=OAUTHBEARER AUTH=XOAUTH\r\n"),
                       .capability(["IMAP4rev1", "UNSELECT", "IDLE", "NAMESPACE", "QUOTA", "ID", "XLIST", "CHILDREN", "X-GM-EXT-1", "XYZZY", "SASL-IR", "AUTH=XOAUTH2", "AUTH=PLAIN", "AUTH=PLAIN-CLIENTTOKEN", "AUTH=OAUTHBEARER", "AUTH=XOAUTH"]))
        XCTAssertEqual(untagged("* ENABLED CONDSTORE QRESYNC\r\n"), .enabled(["CONDSTORE", "QRESYNC"]))
        XCTAssertEqual(untagged("* ENABLED\r\n"), .enabled([]))
    }

    func testIDResponse() {
        XCTAssertEqual(untagged("* ID (\"name\" \"Dovecot\" \"version\" NIL \"vendor\" \"Open-Xchange\")\r\n"), .id(["name": "Dovecot", "vendor": "Open-Xchange"]))
        XCTAssertEqual(untagged("* ID NIL\r\n"), .id([:]))
    }

    func testSearchResponses() {
        XCTAssertEqual(untagged("* SEARCH 2 84 882\r\n"), .search([2, 84, 882], modSeq: nil))
        XCTAssertEqual(untagged("* SEARCH\r\n"), .search([], modSeq: nil))
        XCTAssertEqual(untagged("* SEARCH 2 5 6 7 11 12 18 19 20 23 (MODSEQ 917162500)\r\n"), .search([2, 5, 6, 7, 11, 12, 18, 19, 20, 23], modSeq: 917_162_500))
        XCTAssertEqual(untagged("* SEARCH 1 2 junk 3 99999999999\r\n"), .search([1, 2, 3], modSeq: nil))
    }

    func testESearchResponses() {
        XCTAssertEqual(untagged("* ESEARCH (TAG \"A282\") MIN 2 COUNT 3\r\n"), .esearch(IMAPESearchResponse(tag: "A282", min: 2, count: 3)))
        XCTAssertEqual(untagged("* ESEARCH (TAG \"A285\") UID MIN 7 MAX 3800 COUNT 15 ALL 7,9:12,3800\r\n"),
                       .esearch(IMAPESearchResponse(tag: "A285", isUID: true, min: 7, max: 3800, count: 15, all: IMAPSequenceSet("7,9:12,3800"))))
        XCTAssertEqual(untagged("* ESEARCH (TAG \"A286\") UID\r\n"), .esearch(IMAPESearchResponse(tag: "A286", isUID: true)))
        XCTAssertEqual(untagged("* ESEARCH UID ALL 1:3 MODSEQ 12345\r\n"), .esearch(IMAPESearchResponse(isUID: true, all: IMAPSequenceSet("1:3"), modSeq: 12345)))
    }

    func testVanished() {
        XCTAssertEqual(untagged("* VANISHED 405,407,410,425\r\n"), .vanished(IMAPSequenceSet([405, 407, 410, 425]), earlier: false))
        XCTAssertEqual(untagged("* VANISHED (EARLIER) 300:310,405,411\r\n"), .vanished(IMAPSequenceSet("300:310,405,411")!, earlier: true))
        XCTAssertEqual(untagged("* VANISHED garbage\r\n"), .other("VANISHED garbage"))
    }

    func testStatus() {
        XCTAssertEqual(untagged("* STATUS blurdybloop (MESSAGES 231 UIDNEXT 44292)\r\n"),
                       .status(mailbox: "blurdybloop", IMAPStatus(messages: 231, uidNext: 44292)))
        XCTAssertEqual(untagged("* STATUS \"[Gmail]/All Mail\" (MESSAGES 18234 UIDNEXT 99121 UIDVALIDITY 11 UNSEEN 7 HIGHESTMODSEQ 4416219)\r\n"),
                       .status(mailbox: "[Gmail]/All Mail", IMAPStatus(messages: 18234, uidNext: 99121, uidValidity: 11, unseen: 7, highestModSeq: 4_416_219)))
        XCTAssertEqual(untagged("* STATUS {11}\r\nSent Mail 2 (MESSAGES 3 SIZE 120334)\r\n"),
                       .status(mailbox: "Sent Mail 2", IMAPStatus(messages: 3, size: 120_334)))
        XCTAssertEqual(untagged("* STATUS INBOX (MESSAGES)\r\n"), .status(mailbox: "INBOX", IMAPStatus()))
    }

    // MARK: LIST

    private func mailbox(_ line: String, utf8Mode: Bool = false) -> IMAPMailbox? {
        let responses = parseAll(line, utf8Mode: utf8Mode)
        guard case .untagged(.list(let mailbox))? = responses.first else {
            XCTFail("not a LIST response: \(responses)")
            return nil
        }
        return mailbox
    }

    func testGmailList() {
        let lines = crlf("""
        * LIST (\\HasNoChildren) "/" "INBOX"
        * LIST (\\HasChildren \\Noselect) "/" "[Gmail]"
        * LIST (\\All \\HasNoChildren) "/" "[Gmail]/All Mail"
        * LIST (\\Drafts \\HasNoChildren) "/" "[Gmail]/Drafts"
        * LIST (\\HasNoChildren \\Important) "/" "[Gmail]/Important"
        * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"
        * LIST (\\HasNoChildren \\Junk) "/" "[Gmail]/Spam"
        * LIST (\\Flagged \\HasNoChildren) "/" "[Gmail]/Starred"
        * LIST (\\HasNoChildren \\Trash) "/" "[Gmail]/Trash"
        * LIST (\\HasNoChildren) "/" "Receipts/2026"
        * LIST (\\HasNoChildren) "/" "&MMYwuTDI-"
        A004 OK Success
        """) + "\r\n"
        let mailboxes: [IMAPMailbox] = parseAll(lines).compactMap {
            if case .untagged(.list(let mailbox)) = $0 { return mailbox }
            return nil
        }
        XCTAssertEqual(mailboxes.count, 11)
        XCTAssertEqual(mailboxes.map(\.specialUse), [.inbox, nil, .all, .drafts, nil, .sent, .junk, .flagged, .trash, nil, nil])
        XCTAssertFalse(mailboxes[1].isSelectable)
        XCTAssertEqual(mailboxes[1].hasChildren, true)
        XCTAssertEqual(mailboxes[0].hasChildren, false)
        XCTAssertEqual(mailboxes[2].rawName, "[Gmail]/All Mail")
        XCTAssertEqual(mailboxes[2].delimiter, "/")
        XCTAssertEqual(mailboxes[10].name, "テスト")
        XCTAssertEqual(mailboxes[10].rawName, "&MMYwuTDI-")
    }

    func testDovecotListWithAtomNamesAndDotDelimiter() {
        let box = mailbox("* LIST (\\HasNoChildren \\Sent) \".\" Sent\r\n")
        XCTAssertEqual(box?.rawName, "Sent")
        XCTAssertEqual(box?.delimiter, ".")
        XCTAssertEqual(box?.specialUse, .sent)
        let nested = mailbox("* LIST (\\HasNoChildren \\UnMarked) \".\" INBOX.Archive.2025\r\n")
        XCTAssertEqual(nested?.rawName, "INBOX.Archive.2025")
        XCTAssertNil(nested?.specialUse)
    }

    func testOutlookAndICloudLists() {
        XCTAssertEqual(mailbox("* LIST (\\Marked \\HasNoChildren \\Sent) \"/\" \"Sent Items\"\r\n")?.specialUse, .sent)
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren \\Trash) \"/\" \"Deleted Items\"\r\n")?.specialUse, .trash)
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren \\Junk) \"/\" Junk\r\n")?.rawName, "Junk")
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren \\Archive) \"/\" \"Archive\"\r\n")?.specialUse, .archive)
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren) \"/\" \"Deleted Messages\"\r\n")?.specialUse, nil)
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren) \"/\" inbox\r\n")?.specialUse, .inbox, "INBOX is case-insensitive")
    }

    func testXListAttributes() {
        XCTAssertEqual(mailbox("* XLIST (\\HasNoChildren \\Inbox) \"/\" \"Inbox\"\r\n")?.specialUse, .inbox)
        XCTAssertEqual(mailbox("* XLIST (\\HasNoChildren \\AllMail) \"/\" \"[Gmail]/All Mail\"\r\n")?.specialUse, .all)
        XCTAssertEqual(mailbox("* XLIST (\\HasNoChildren \\Spam) \"/\" \"[Gmail]/Spam\"\r\n")?.specialUse, .junk)
        XCTAssertEqual(mailbox("* XLIST (\\HasNoChildren \\Starred) \"/\" \"[Gmail]/Starred\"\r\n")?.specialUse, .flagged)
    }

    func testListEdgeCases() {
        let flat = mailbox("* LIST (\\Noselect) NIL \"\"\r\n")
        XCTAssertNil(flat?.delimiter)
        XCTAssertEqual(flat?.rawName, "")
        let literalName = mailbox("* LIST (\\HasNoChildren) \"/\" {17}\r\nWeird \"name\" here\r\n")
        XCTAssertEqual(literalName?.rawName, "Weird \"name\" here")
        let escaped = mailbox("* LIST () \"\\\\\" \"Back\\\\slash \\\"q\\\"\"\r\n")
        XCTAssertEqual(escaped?.delimiter, "\\")
        XCTAssertEqual(escaped?.rawName, "Back\\slash \"q\"")
        let nonExistent = mailbox("* LIST (\\NonExistent) \"/\" \"Gone\"\r\n")
        XCTAssertEqual(nonExistent?.isSelectable, false)
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren) \"/\" \"Entw&APw-rfe\"\r\n")?.name, "Entwürfe")
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren) \"/\" \"Entwürfe\"\r\n", utf8Mode: true)?.name, "Entwürfe")
        XCTAssertEqual(untagged("* LIST garbage\r\n"), .other("LIST garbage"))
    }

    func testBracketsInMailboxAtoms() {
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren) \"/\" [Gmail]/Sent\r\n")?.rawName, "[Gmail]/Sent")
        XCTAssertEqual(mailbox("* LIST (\\HasNoChildren) \"/\" Weird[name\r\n")?.rawName, "Weird[name")
    }

    func testLsub() {
        guard case .lsub(let box)? = untagged("* LSUB () \".\" #news.comp.mail.misc\r\n") else { return XCTFail() }
        XCTAssertEqual(box.rawName, "#news.comp.mail.misc")
    }

    // MARK: Framing

    func testLiteralSplitAcrossReads() throws {
        let body = "Subject: hello\r\n\r\nThis body has } and { and ) ( inside\r\n"
        let response = "* 12 FETCH (UID 99 BODY[] " + literal(body) + ")\r\nA7 OK done\r\n"
        let bytes = Array(response.utf8)
        for split in 1..<bytes.count {
            var parser = IMAPResponseParser()
            var results: [IMAPResponse] = []
            parser.append(Array(bytes[..<split]))
            while let next = try parser.next() { results.append(next) }
            parser.append(Array(bytes[split...]))
            while let next = try parser.next() { results.append(next) }
            XCTAssertEqual(results.count, 2, "split at \(split)")
            guard case .untagged(.fetch(let fetch))? = results.first else { return XCTFail("split at \(split)") }
            XCTAssertEqual(fetch.uid, 99)
            XCTAssertEqual(fetch.sections[""], Data(body.utf8), "split at \(split)")
        }
    }

    func testByteAtATime() throws {
        let response = crlf("""
        * OK [CAPABILITY IMAP4rev1 LITERAL+] ready
        * LIST (\\HasNoChildren) "/" {5}
        Inbox
        * 3 FETCH (BODY[HEADER.FIELDS (SUBJECT)] {17}
        Subject: test

         FLAGS (\\Seen))
        A1 OK done
        """) + "\r\n"
        var parser = IMAPResponseParser()
        var results: [IMAPResponse] = []
        for byte in Array(response.utf8) {
            parser.append([byte])
            while let next = try parser.next() { results.append(next) }
        }
        XCTAssertEqual(results.count, 4)
        guard case .untagged(.fetch(let fetch)) = results[2] else { return XCTFail() }
        XCTAssertEqual(fetch.section("HEADER.FIELDS (SUBJECT)"), Data("Subject: test\r\n\r\n".utf8))
        XCTAssertEqual(fetch.flags, ["\\Seen"])
        XCTAssertEqual(parser.bufferedByteCount, 0)
    }

    func testStatusLinesEndingInBracesAreNotLiterals() {
        let responses = parseAll("A1 NO quota exceeded {5}\r\nA2 OK fine\r\n* OK still here {3}\r\n* BYE bye {9}\r\n")
        XCTAssertEqual(responses.count, 4)
    }

    func testBareLineFeedsAndBlankLinesAreTolerated() {
        let responses = parseAll("* 3 EXISTS\n\r\n\n* 1 RECENT\nA1 OK done\n")
        XCTAssertEqual(responses, [.untagged(.exists(3)), .untagged(.recent(1)),
                                   .tagged(IMAPTaggedResponse(tag: "A1", status: .ok, text: IMAPResponseText(text: "done")))])
    }

    func testEmptyLiteral() {
        let fetch = fetchResponse("* 1 FETCH (BODY[1] {0}\r\n UID 4)\r\n")
        XCTAssertEqual(fetch?.section("1"), Data())
        XCTAssertEqual(fetch?.uid, 4)
    }

    func testIncompleteInputReturnsNil() throws {
        var parser = IMAPResponseParser()
        parser.append(Data("* 1 FETCH (BODY[] {100}\r\nonly a little".utf8))
        XCTAssertNil(try parser.next())
        parser.append(Data("* 2 EXI".utf8))
        XCTAssertNil(try parser.next())
    }

    func testLiteralTooLargeThrows() {
        var parser = IMAPResponseParser(maxLiteralSize: 1000)
        parser.append(Data("* 1 FETCH (BODY[] {1001}\r\n".utf8))
        XCTAssertThrowsError(try parser.next()) { error in
            XCTAssertEqual(error as? IMAPParseError, .literalTooLarge(1001))
        }
    }

    func testEndlessLineThrows() {
        var parser = IMAPResponseParser(maxLineLength: 64)
        parser.append(Data(repeating: 0x41, count: 100))
        XCTAssertThrowsError(try parser.next()) { error in
            XCTAssertEqual(error as? IMAPParseError, .lineTooLong)
        }
    }

    func testHugeLiteralLengthDigitsAreNotALiteral() {
        // 13+ digits can't be a real literal; the line is taken as-is rather than waiting forever.
        XCTAssertEqual(parseAll("* 1 FETCH (BODY[] {99999999999999})\r\nA1 OK x\r\n").count, 2)
    }

    func testSummaryElidesLiteralContents() throws {
        var parser = IMAPResponseParser()
        parser.capturesSummary = true
        parser.append(Data(("* 1 FETCH (UID 5 BODY[] " + literal("Subject: very private\r\n\r\nsecret") + ")\r\n").utf8))
        _ = try parser.next()
        let summary = try XCTUnwrap(parser.lastResponseSummary)
        XCTAssertFalse(summary.contains("private"))
        XCTAssertTrue(summary.contains("<"))
        XCTAssertTrue(summary.hasPrefix("* 1 FETCH (UID 5 BODY[] {"))
    }

    func testResetDropsBufferedBytes() throws {
        var parser = IMAPResponseParser()
        parser.append(Data("* 1 EXISTS\r\n* 2 EXI".utf8))
        parser.reset()
        XCTAssertNil(try parser.next())
        parser.append(Data("* 3 RECENT\r\n".utf8))
        XCTAssertEqual(try parser.next(), .untagged(.recent(3)))
    }

    func testLargeLiteralStreamedInSmallChunksIsLinear() throws {
        // 8 MB literal delivered in 4 KB chunks: the parser must not rescan the buffer per chunk.
        let size = 8 * 1024 * 1024
        var parser = IMAPResponseParser()
        parser.append(Data("* 1 FETCH (UID 1 BODY[] {\(size)}\r\n".utf8))
        let chunk = Data(repeating: 0x61, count: 4096)
        let start = Date()
        for _ in 0..<(size / chunk.count) {
            parser.append(chunk)
            XCTAssertNil(try parser.next())
        }
        parser.append(Data(")\r\n".utf8))
        let response = try parser.next()
        XCTAssertLessThan(Date().timeIntervalSince(start), 20)
        guard case .untagged(.fetch(let fetch))? = response else { return XCTFail() }
        XCTAssertEqual(fetch.sections[""]?.count, size)
    }

    func testUnknownUntaggedBecomesOther() {
        XCTAssertEqual(untagged("* NAMESPACE ((\"\" \"/\")) NIL NIL\r\n"), .other("NAMESPACE ((\"\" \"/\")) NIL NIL"))
        XCTAssertEqual(untagged("* QUOTA \"\" (STORAGE 10 512)\r\n"), .other("QUOTA \"\" (STORAGE 10 512)"))
    }

    func testGarbageNeverCrashes() throws {
        var generator = SeededGenerator(seed: 7)
        let alphabet = Array("* ()[]{}\"\\+~0123456789ABCNIL\r\n FETCH BODY LIST OK".utf8)
        for _ in 0..<300 {
            var parser = IMAPResponseParser(maxLiteralSize: 4096, maxLineLength: 1 << 20)
            let length = Int.random(in: 1...400, using: &generator)
            let bytes = (0..<length).map { _ in alphabet[Int.random(in: 0..<alphabet.count, using: &generator)] }
            parser.append(bytes)
            do {
                while try parser.next() != nil {}
            } catch is IMAPParseError {
                // Framing errors are fine; crashes are not.
            }
        }
    }
}
