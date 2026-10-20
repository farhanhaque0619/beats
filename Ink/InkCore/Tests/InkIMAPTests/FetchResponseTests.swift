import XCTest
import InkModel
@testable import InkIMAP

final class FetchResponseTests: XCTestCase {
    // MARK: ENVELOPE

    func testGmailEnvelopeWithEncodedSubject() {
        let fetch = fetchResponse("""
        * 4 FETCH (UID 31337 ENVELOPE ("Tue, 20 Oct 2026 08:41:07 -0700" "=?UTF-8?Q?Your_order_has_shipped_=F0=9F=93=A6?=" (("Acme Store" NIL "orders" "acme.example")) (("Acme Store" NIL "orders" "acme.example")) (("Acme Support" NIL "support" "acme.example")) ((NIL NIL "ada" "gmail.com")) NIL NIL NIL "<0100018f2a1b3c4d-5e6f7a8b-9c0d-4e1f-a2b3-c4d5e6f7a8b9-000000@email.amazonses.com>"))\r\n
        """)
        let envelope = fetch?.envelope
        XCTAssertEqual(envelope?.date, "Tue, 20 Oct 2026 08:41:07 -0700")
        XCTAssertEqual(envelope?.subject, "=?UTF-8?Q?Your_order_has_shipped_=F0=9F=93=A6?=", "subjects stay raw for InkMIME")
        XCTAssertEqual(envelope?.from, [IMAPAddress(name: "Acme Store", mailbox: "orders", host: "acme.example")])
        XCTAssertEqual(envelope?.from.first?.address, "orders@acme.example")
        XCTAssertEqual(envelope?.replyTo.first?.address, "support@acme.example")
        XCTAssertEqual(envelope?.to.first?.name, nil)
        XCTAssertEqual(envelope?.to.first?.address, "ada@gmail.com")
        XCTAssertEqual(envelope?.cc, [])
        XCTAssertEqual(envelope?.bcc, [])
        XCTAssertNil(envelope?.inReplyTo)
        XCTAssertEqual(envelope?.messageID, "<0100018f2a1b3c4d-5e6f7a8b-9c0d-4e1f-a2b3-c4d5e6f7a8b9-000000@email.amazonses.com>")
    }

    func testEnvelopeWithGroupsEscapesAndLiterals() {
        let subject = "Re: \"quoted\" subject with \\ backslash"
        let text = "* 7 FETCH (ENVELOPE (\"Mon, 19 Oct 2026 23:59:59 +0000\" " + literal(subject)
            + " ((\"O\\\"Brien, Pat\" NIL \"pat\" \"example.ie\")) NIL NIL ((NIL NIL \"undisclosed-recipients\" NIL)(NIL NIL NIL NIL)) ((NIL NIL \"team\" NIL)(\"Grace\" NIL \"grace\" \"example.org\")(NIL NIL NIL NIL)) NIL \"<parent@example.org>\" \"<child@example.ie>\"))\r\n"
        let envelope = fetchResponse(text)?.envelope
        XCTAssertEqual(envelope?.subject, subject)
        XCTAssertEqual(envelope?.from.first?.name, "O\"Brien, Pat")
        XCTAssertEqual(envelope?.sender, [], "NIL address lists are empty")
        XCTAssertEqual(envelope?.to.count, 2)
        XCTAssertEqual(envelope?.to.first?.isGroupStart, true)
        XCTAssertEqual(envelope?.to.last?.isGroupEnd, true)
        XCTAssertEqual(envelope?.to.mailboxes, [])
        XCTAssertEqual(envelope?.cc.mailboxes.map(\.address), ["grace@example.org"])
        XCTAssertEqual(envelope?.inReplyTo, "<parent@example.org>")
        XCTAssertEqual(envelope?.messageID, "<child@example.ie>")
    }

    func testEnvelopeAllNIL() {
        let envelope = fetchResponse("* 1 FETCH (ENVELOPE (NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL))\r\n")?.envelope
        XCTAssertNotNil(envelope)
        XCTAssertNil(envelope?.date)
        XCTAssertNil(envelope?.subject)
        XCTAssertEqual(envelope?.from, [])
        XCTAssertNil(envelope?.messageID)
    }

    func testTruncatedEnvelopeAndBareAddresses() {
        let envelope = fetchResponse("* 1 FETCH (ENVELOPE (\"date\" \"subj\" ((NIL NIL \"root\" NIL))))\r\n")?.envelope
        XCTAssertEqual(envelope?.subject, "subj")
        // A local-only address with NIL host reads as a group start per RFC 3501; keep it visible.
        XCTAssertEqual(envelope?.from.first?.mailbox, "root")
        XCTAssertEqual(envelope?.to, [])
        XCTAssertNil(envelope?.messageID)
        XCTAssertNil(fetchResponse("* 1 FETCH (ENVELOPE NIL)\r\n")?.envelope)
    }

    func testEnvelopeWithRawUTF8AndLatin1() {
        let utf8 = fetchResponse("* 1 FETCH (ENVELOPE (NIL \"Grüße aus München\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n")?.envelope
        XCTAssertEqual(utf8?.subject, "Grüße aus München")
        var bytes = Array("* 1 FETCH (ENVELOPE (NIL \"Gr".utf8)
        bytes.append(0xFC)  // ü in Latin-1, invalid as UTF-8
        bytes.append(contentsOf: Array("n\" NIL NIL NIL NIL NIL NIL NIL NIL))\r\n".utf8))
        var parser = IMAPResponseParser()
        parser.append(bytes)
        guard case .untagged(.fetch(let fetch))? = try? parser.next() else { return XCTFail() }
        XCTAssertEqual(fetch.envelope?.subject, "Grün")
    }

    // MARK: Attributes

    func testSummaryFetchAsInkSyncRequestsIt() {
        let headers = "References: <a@x> <b@y>\r\nList-Unsubscribe: <mailto:u@list.example>, <https://list.example/u>\r\nList-Id: <news.list.example>\r\n\r\n"
        let text = "* 12 FETCH (UID 4401 FLAGS (\\Seen $Forwarded) INTERNALDATE \"20-Oct-2026 08:41:12 -0700\" RFC822.SIZE 48213 ENVELOPE (NIL \"Hi\" NIL NIL NIL NIL NIL NIL NIL \"<id@x>\") "
            + "BODY[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE AUTO-SUBMITTED)] " + literal(headers)
            + " BODYSTRUCTURE (\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 10 1 NIL NIL NIL))\r\n"
        let fetch = fetchResponse(text)
        XCTAssertEqual(fetch?.seq, 12)
        XCTAssertEqual(fetch?.uid, 4401)
        XCTAssertEqual(fetch?.flags, ["\\Seen", "$Forwarded"])
        XCTAssertEqual(fetch?.messageFlags, [.seen, .forwarded])
        XCTAssertEqual(fetch?.internalDate?.timeIntervalSince1970, 1_792_510_872)
        XCTAssertEqual(fetch?.size, 48213)
        XCTAssertEqual(fetch?.envelope?.messageID, "<id@x>")
        XCTAssertNotNil(fetch?.bodyStructure)
        let key = IMAPFetchItem.headerFields(["REFERENCES", "IN-REPLY-TO", "LIST-UNSUBSCRIBE", "LIST-UNSUBSCRIBE-POST", "LIST-ID", "PRECEDENCE", "AUTO-SUBMITTED"]).sectionKey
        XCTAssertEqual(key, "HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE AUTO-SUBMITTED)")
        XCTAssertEqual(fetch?.sections[key ?? ""], Data(headers.utf8))
        XCTAssertEqual(fetch?.section("header.fields (references in-reply-to list-unsubscribe list-unsubscribe-post list-id precedence auto-submitted)"), Data(headers.utf8))
    }

    func testBodySectionsWithOriginsAndPeekEcho() {
        let text = "* 3 FETCH (UID 9 BODY[1.2]<0> " + literal("Hello partial") + " BODY.PEEK[TEXT] " + literal("t") + " BODY[] {4}\r\nfull BODY[2.MIME] \"Content-Type: text/plain\")\r\n"
        let fetch = fetchResponse(text)
        XCTAssertEqual(fetch?.section("1.2"), Data("Hello partial".utf8))
        XCTAssertEqual(fetch?.sectionOrigins["1.2"], 0)
        XCTAssertEqual(fetch?.section("TEXT"), Data("t".utf8))
        XCTAssertEqual(fetch?.section(""), Data("full".utf8))
        XCTAssertEqual(fetch?.section("2.mime"), Data("Content-Type: text/plain".utf8))
        let partial = fetchResponse("* 3 FETCH (BODY[1]<2048> \"abc\")\r\n")
        XCTAssertEqual(partial?.sectionOrigins["1"], 2048)
        XCTAssertNil(fetchResponse("* 3 FETCH (BODY[1] NIL)\r\n")?.section("1"), "NIL section data stays absent")
    }

    func testRFC822Items() {
        let fetch = fetchResponse("* 1 FETCH (RFC822 {3}\r\nabc RFC822.HEADER {2}\r\nhh RFC822.TEXT \"tt\")\r\n")
        XCTAssertEqual(fetch?.section(""), Data("abc".utf8))
        XCTAssertEqual(fetch?.section("HEADER"), Data("hh".utf8))
        XCTAssertEqual(fetch?.section("TEXT"), Data("tt".utf8))
    }

    func testGmailExtensions() {
        let fetch = fetchResponse("* 1 FETCH (X-GM-THRID 1278455344230334865 X-GM-MSGID 1278455344230334865 X-GM-LABELS (\\Inbox \\Sent Important \"Muy Importante\" \"[Imap]/Trash\" &AMk-t&AOk- \"\\\\Starred\") UID 7 MODSEQ (4416219))\r\n")
        XCTAssertEqual(fetch?.gmailThreadID, 1_278_455_344_230_334_865)
        XCTAssertEqual(fetch?.gmailMessageID, 1_278_455_344_230_334_865)
        XCTAssertEqual(fetch?.gmailLabels, ["\\Inbox", "\\Sent", "Important", "Muy Importante", "[Imap]/Trash", "&AMk-t&AOk-", "\\Starred"])
        XCTAssertEqual(fetch?.decodedGmailLabels.last(where: { $0.hasPrefix("É") }), "Été")
        XCTAssertEqual(fetch?.uid, 7)
        XCTAssertEqual(fetch?.modSeq, 4_416_219)
        XCTAssertEqual(fetchResponse("* 1 FETCH (X-GM-LABELS ())\r\n")?.gmailLabels, [])
        XCTAssertEqual(fetchResponse("* 1 FETCH (X-GM-LABELS NIL)\r\n")?.gmailLabels, [])
        XCTAssertEqual(fetchResponse("* 1 FETCH (X-GM-LABELS (" + literal("Label {with} braces") + " Work))\r\n")?.gmailLabels, ["Label {with} braces", "Work"])
        // A stray bracket in a label doesn't swallow what follows.
        let stray = fetchResponse("* 1 FETCH (X-GM-LABELS (Odd[label Work) UID 9 FLAGS (\\Seen [x]))\r\n")
        XCTAssertEqual(stray?.gmailLabels, ["Odd[label", "Work"])
        XCTAssertEqual(stray?.uid, 9)
        XCTAssertEqual(stray?.flags, ["\\Seen", "[x]"])
    }

    func testBinaryAndLowercaseSectionAttributes() {
        let fetch = fetchResponse("* 1 FETCH (binary[1] {3}\r\nabc body[header.fields (subject)] {2}\r\nhi BINARY.SIZE[2] 1234)\r\n")
        XCTAssertEqual(fetch?.section("HEADER.FIELDS (SUBJECT)"), Data("hi".utf8))
    }

    func testObjectIDAndPreview() {
        let fetch = fetchResponse("* 1 FETCH (EMAILID (M6d99ac3275bb4e) THREADID (T64b478a75b7ea9) PREVIEW \"Hi Ada, the numbers are in\")\r\n")
        XCTAssertEqual(fetch?.emailID, "M6d99ac3275bb4e")
        XCTAssertEqual(fetch?.threadID, "T64b478a75b7ea9")
        XCTAssertEqual(fetch?.preview, "Hi Ada, the numbers are in")
        XCTAssertNil(fetchResponse("* 1 FETCH (THREADID NIL)\r\n")?.threadID)
    }

    func testFlagUpdateWithoutUID() {
        let fetch = fetchResponse("* 22 FETCH (FLAGS (\\Seen \\Flagged))\r\n")
        XCTAssertEqual(fetch?.seq, 22)
        XCTAssertNil(fetch?.uid)
        XCTAssertEqual(fetch?.messageFlags, [.seen, .flagged])
        XCTAssertEqual(fetchResponse("* 22 FETCH (FLAGS ())\r\n")?.flags, [])
    }

    func testMalformedFetchesDegradeGracefully() {
        XCTAssertEqual(fetchResponse("* 5 FETCH\r\n")?.seq, 5)
        XCTAssertEqual(fetchResponse("* 5 FETCH (UID)\r\n")?.uid, nil)
        XCTAssertEqual(fetchResponse("* 5 FETCH (UID abc FLAGS (\\Seen))\r\n")?.flags, ["\\Seen"])
        XCTAssertEqual(fetchResponse("* 5 FETCH (\"junk\" UID 3)\r\n")?.uid, 3)
        XCTAssertEqual(fetchResponse("* 5 FETCH (UID 3 INTERNALDATE \"not a date\")\r\n")?.internalDate, nil)
        XCTAssertEqual(fetchResponse("* 5 FETCH (UID 3 FLAGS (\\Seen)\r\n")?.uid, 3, "missing close paren")
        XCTAssertEqual(fetchResponse("* 5 FETCH (UID 3 X-UNKNOWN-ITEM (a b c) RFC822.SIZE 10)\r\n")?.size, 10)
    }

    func testMergeCombinesSplitResponses() {
        var first = IMAPFetchResponse(seq: 1, uid: 10, flags: ["\\Seen"])
        first.merge(IMAPFetchResponse(seq: 1, sections: ["1": Data("x".utf8)], gmailLabels: ["\\Inbox"]))
        XCTAssertEqual(first.uid, 10)
        XCTAssertEqual(first.flags, ["\\Seen"])
        XCTAssertEqual(first.section("1"), Data("x".utf8))
        XCTAssertEqual(first.gmailLabels, ["\\Inbox"])
    }

    // MARK: Fuzzing the incremental parser

    /// A Gmail-style batch: summaries with header literals, a partial body, a full message with
    /// CRLFs and braces in it, flag updates and an EXISTS, then the completion.
    private func largeFetchTranscript() -> String {
        var text = ""
        for index in 1...40 {
            let headers = "References: <r\(index)@example.com>\r\nList-Id: <list-\(index).example.com>\r\n\r\n"
            let body = "From: Sender \(index) <s\(index)@example.com>\r\nSubject: Message {\(index)} (test)\r\n\r\n" + String(repeating: "Line with ( and ) and \"quotes\" and {braces} \(index)\r\n", count: index % 7 + 1)
            text += "* \(index) FETCH (UID \(1000 + index) FLAGS (\\Seen) INTERNALDATE \"20-Oct-2026 08:\(10 + index % 50):00 +0000\" RFC822.SIZE \(body.utf8.count) "
            text += "X-GM-THRID \(9_000_000 + index / 3) X-GM-MSGID \(8_000_000 + index) X-GM-LABELS (\\Inbox \"Label \(index)\") "
            text += "ENVELOPE (\"Tue, 20 Oct 2026 08:00:00 +0000\" \"Subject \(index)\" ((\"Sender \\\"\(index)\\\"\" NIL \"s\(index)\" \"example.com\")) NIL NIL ((NIL NIL \"ada\" \"example.com\")) NIL NIL NIL \"<m\(index)@example.com>\") "
            text += "BODYSTRUCTURE ((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 100 3 NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"base64\" 200 4 NIL NIL NIL) \"alternative\" (\"boundary\" \"b\(index)\") NIL NIL) "
            text += "BODY[HEADER.FIELDS (REFERENCES LIST-ID)] " + literal(headers) + " BODY[1]<0> " + literal(String(body.prefix(30))) + " BODY[] " + literal(body) + ")\r\n"
            if index % 10 == 0 { text += "* \(index) FETCH (FLAGS (\\Seen \\Flagged))\r\n* \(100 + index) EXISTS\r\n" }
        }
        text += "A042 OK Success\r\n"
        return text
    }

    private func parse(_ chunks: [[UInt8]]) throws -> [IMAPResponse] {
        var parser = IMAPResponseParser()
        var results: [IMAPResponse] = []
        for chunk in chunks {
            parser.append(chunk)
            while let response = try parser.next() { results.append(response) }
        }
        XCTAssertEqual(parser.bufferedByteCount, 0)
        return results
    }

    func testRandomSplitPointsGiveIdenticalResults() throws {
        let bytes = Array(largeFetchTranscript().utf8)
        let reference = try parse([bytes])
        XCTAssertEqual(reference.count, 40 + 4 * 2 + 1)
        guard case .untagged(.fetch(let first)) = reference[0] else { return XCTFail() }
        XCTAssertEqual(first.uid, 1001)
        XCTAssertEqual(first.gmailLabels, ["\\Inbox", "Label 1"])
        XCTAssertEqual(first.envelope?.from.first?.name, "Sender \"1\"")
        XCTAssertNotNil(first.section(""))
        XCTAssertEqual(first.size, first.section("")?.count)

        var generator = SeededGenerator(seed: 2026)
        for round in 0..<150 {
            var chunks: [[UInt8]] = []
            var index = 0
            let maxChunk = [1, 2, 3, 7, 16, 64, 512, 4096][round % 8]
            while index < bytes.count {
                let size = Int.random(in: 1...maxChunk, using: &generator)
                let end = min(bytes.count, index + size)
                chunks.append(Array(bytes[index..<end]))
                index = end
            }
            XCTAssertEqual(try parse(chunks), reference, "round \(round) with chunks up to \(maxChunk) bytes")
        }
    }

    func testSplitsExactlyAroundEveryCRLFAndBrace() throws {
        let bytes = Array(largeFetchTranscript().utf8)
        let reference = try parse([bytes])
        let interesting = bytes.indices.filter { [0x0D, 0x0A, 0x7B, 0x7D].contains(bytes[$0]) }
        for split in interesting.prefix(150) {
            for offset in [0, 1] where split + offset > 0 && split + offset < bytes.count {
                let point = split + offset
                XCTAssertEqual(try parse([Array(bytes[..<point]), Array(bytes[point...])]), reference, "split at \(point)")
            }
        }
    }
}
