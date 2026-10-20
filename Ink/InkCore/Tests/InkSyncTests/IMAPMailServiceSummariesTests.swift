import XCTest
import InkModel
import InkIMAP
import InkMIME
@testable import InkSync

/// FETCH responses (as real servers send them) → `MessageSummary`, snippets and bulk detection.
final class IMAPMailServiceSummariesTests: XCTestCase {
    typealias F = IMAPServiceFixtures

    private func summary(_ fetch: String, path: String = "INBOX", now: Date = Date(timeIntervalSince1970: 1_792_454_400),
                         file: StaticString = #filePath, line: UInt = #line) -> MessageSummary? {
        guard let response = F.fetchResponses(fetch, file: file, line: line).first else {
            XCTFail("no FETCH response", file: file, line: line)
            return nil
        }
        return IMAPMailServiceSummaries.summary(from: response, accountID: "acct", mailboxPath: path, uidValidity: 7, now: now)
    }

    private func date(_ text: String) -> Date? { RFC5322Date.parse(text) }

    func testGmailNewsletterSummary() throws {
        let headers = F.headerFields([
            "List-Unsubscribe: <https://acmebank.example/u/abc123>,",
            " <mailto:unsubscribe@acmebank.example?subject=unsub>",
            "List-Unsubscribe-Post: List-Unsubscribe=One-Click",
            "List-ID: <statements.acmebank.example>",
        ])
        let fetch = "* 2763 FETCH (X-GM-THRID 1781234567890123456 X-GM-MSGID 1781234567890123457 X-GM-LABELS (\"\\\\Important\" \"\\\\Inbox\" \"Finance/&AMk-t&AOk-\") UID 35860 FLAGS () "
            + "INTERNALDATE \"19-Oct-2026 16:02:11 +0000\" RFC822.SIZE 48213 ENVELOPE (\"Mon, 19 Oct 2026 09:02:03 -0700\" "
            + "\"=?UTF-8?Q?Your_October_statement_is_ready_=E2=80=94_Acme_Bank?=\" ((\"Acme Bank\" NIL \"statements\" \"acmebank.example\")) "
            + "((\"Acme Bank\" NIL \"statements\" \"acmebank.example\")) ((\"Acme Bank Support\" NIL \"help\" \"acmebank.example\")) "
            + "((NIL NIL \"ada\" \"gmail.com\")) NIL NIL NIL \"<0100018f.statement.2026-10@email.acmebank.example>\") "
            + "BODYSTRUCTURE ((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 1840 47 NIL NIL NIL NIL)"
            + "(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 45120 812 NIL NIL NIL NIL) \"alternative\" "
            + "(\"boundary\" \"----=_Part_123\") NIL NIL NIL) " + headers + ")\r\n"
        let s = try XCTUnwrap(summary(fetch))
        XCTAssertEqual(s.uid, 35860)
        XCTAssertEqual(s.uidValidity, 7)
        XCTAssertEqual(s.id, "acct|INBOX|7|35860")
        XCTAssertEqual(s.subject, "Your October statement is ready — Acme Bank")
        XCTAssertEqual(s.from, [EmailAddress(name: "Acme Bank", address: "statements@acmebank.example")])
        XCTAssertEqual(s.from.first?.name, "Acme Bank")
        XCTAssertEqual(s.replyTo.map(\.address), ["help@acmebank.example"])
        XCTAssertEqual(s.to.map(\.address), ["ada@gmail.com"])
        XCTAssertEqual(s.date, date("Mon, 19 Oct 2026 09:02:03 -0700"))
        XCTAssertEqual(s.receivedDate, date("Mon, 19 Oct 2026 16:02:11 +0000"))
        XCTAssertEqual(s.messageID, "0100018f.statement.2026-10@email.acmebank.example")
        XCTAssertEqual(s.gmailThreadID, 1781234567890123456)
        XCTAssertEqual(s.gmailMessageID, 1781234567890123457)
        XCTAssertEqual(s.gmailLabels, ["\\Important", "\\Inbox", "Finance/Été"])
        XCTAssertTrue(s.isUnread)
        XCTAssertEqual(s.size, 48213)
        XCTAssertFalse(s.hasAttachments)
        XCTAssertTrue(s.isBulk)
        XCTAssertEqual(s.listUnsubscribe, "<https://acmebank.example/u/abc123>, <mailto:unsubscribe@acmebank.example?subject=unsub>")
        XCTAssertEqual(s.listUnsubscribePost, "List-Unsubscribe=One-Click")
        XCTAssertEqual(s.snippet, "", "snippets are filled in by a separate fetch")
        XCTAssertEqual(s.dedupeKey, "acct|gm:1781234567890123457")
    }

    func testOutlookReplyWithAttachmentAndThreadingHeaders() throws {
        let headers = F.headerFields([
            "In-Reply-To: <DM6PR11MB4123ABCD@DM6PR11MB4123.namprd11.prod.outlook.com>",
            "References: <CAF=abc@mail.gmail.com>",
            " <DM6PR11MB4123ABCD@DM6PR11MB4123.namprd11.prod.outlook.com>",
        ])
        let fetch = "* 12 FETCH (UID 4410 FLAGS (\\Seen \\Answered $Forwarded) INTERNALDATE \"20-Oct-2026 08:15:42 +0200\" RFC822.SIZE 182733 "
            + "ENVELOPE (\"Tue, 20 Oct 2026 06:15:39 +0000\" \"RE: Q4 budget (draft v3)\" ((\"'Grace Hopper'\" NIL \"grace.hopper\" \"contoso.com\")) "
            + "NIL NIL ((\"Ada Lovelace\" NIL \"ada\" \"example.com\")(\"=?iso-8859-1?Q?Bj=F6rn_Str=F6m?=\" NIL \"bjorn\" \"contoso.com\")) "
            + "((\"finance-team\" NIL \"finance-team\" \"contoso.com\")) NIL \"<DM6PR11MB4123ABCD@DM6PR11MB4123.namprd11.prod.outlook.com>\" "
            + "\"<DM6PR11MB4999EFGH@DM6PR11MB4999.namprd11.prod.outlook.com>\") "
            + "BODYSTRUCTURE (((\"text\" \"plain\" (\"charset\" \"us-ascii\") NIL NIL \"quoted-printable\" 2210 60 NIL NIL NIL NIL)"
            + "(\"text\" \"html\" (\"charset\" \"us-ascii\") NIL NIL \"quoted-printable\" 9921 180 NIL NIL NIL NIL) \"alternative\" "
            + "(\"boundary\" \"_000_alt_\") NIL NIL NIL)(\"application\" \"vnd.openxmlformats-officedocument.spreadsheetml.sheet\" "
            + "(\"name\" \"Q4 budget v3.xlsx\") NIL \"Q4 budget v3.xlsx\" \"base64\" 167420 NIL (\"attachment\" (\"filename\" \"Q4 budget v3.xlsx\" "
            + "\"size\" \"122335\")) NIL NIL) \"mixed\" (\"boundary\" \"_004_mixed_\") NIL (\"en-US\") NIL) " + headers + ")\r\n"
        let s = try XCTUnwrap(summary(fetch))
        XCTAssertEqual(s.subject, "RE: Q4 budget (draft v3)")
        XCTAssertEqual(s.normalizedSubject, "Q4 budget (draft v3)")
        XCTAssertEqual(s.from.first?.name, "Grace Hopper", "Outlook's quoted display names are unwrapped")
        XCTAssertEqual(s.from.first?.address, "grace.hopper@contoso.com")
        XCTAssertTrue(s.replyTo.isEmpty, "NIL reply-to")
        XCTAssertEqual(s.to.map(\.displayName), ["Ada Lovelace", "Björn Ström"])
        XCTAssertEqual(s.cc.map(\.address), ["finance-team@contoso.com"])
        XCTAssertEqual(s.inReplyTo, ["DM6PR11MB4123ABCD@DM6PR11MB4123.namprd11.prod.outlook.com"])
        XCTAssertEqual(s.references, ["CAF=abc@mail.gmail.com", "DM6PR11MB4123ABCD@DM6PR11MB4123.namprd11.prod.outlook.com"])
        XCTAssertEqual(s.messageID, "DM6PR11MB4999EFGH@DM6PR11MB4999.namprd11.prod.outlook.com")
        XCTAssertEqual(s.flags, [.seen, .answered, .forwarded])
        XCTAssertTrue(s.hasAttachments)
        XCTAssertFalse(s.isBulk)
        XCTAssertNil(s.gmailMessageID)
        XCTAssertEqual(s.dedupeKey, "acct|mid:dm6pr11mb4999efgh@dm6pr11mb4999.namprd11.prod.outlook.com")
    }

    func testGroupsDovecotPlaceholdersAndMissingSubject() throws {
        let fetch = "* 1 FETCH (UID 9 FLAGS (\\Seen) INTERNALDATE \"02-Mar-2026 11:00:00 +0000\" RFC822.SIZE 900 ENVELOPE "
            + "(\"Mon, 2 Mar 2026 11:00:00 +0000\" NIL ((NIL NIL \"MAILER-DAEMON\" \"mx.example.net\")) NIL NIL "
            + "((NIL NIL \"undisclosed-recipients\" NIL)(NIL NIL NIL NIL)) ((NIL NIL \"localuser\" \"MISSING_DOMAIN\")) "
            + "((NIL NIL \"MISSING_MAILBOX\" \"MISSING_DOMAIN\")) NIL NIL) BODYSTRUCTURE (\"text\" \"plain\" NIL NIL NIL \"7bit\" 120 4 NIL NIL NIL NIL))\r\n"
        let s = try XCTUnwrap(summary(fetch))
        XCTAssertEqual(s.subject, "")
        XCTAssertTrue(s.to.isEmpty, "group markers are not addresses")
        XCTAssertEqual(s.cc.map(\.address), ["localuser"])
        XCTAssertTrue(s.bcc.isEmpty)
        XCTAssertEqual(s.replyTo, [], "servers copy From into Reply-To when it is missing")
        XCTAssertTrue(s.isBulk, "MAILER-DAEMON is automated")
        XCTAssertNil(s.messageID)
    }

    func testDateFallbacks() throws {
        // Unparseable Date header → INTERNALDATE.
        let garbage = "* 1 FETCH (UID 1 FLAGS () INTERNALDATE \"05-Jan-2026 10:00:00 +0000\" ENVELOPE (\"sometime last week\" \"Hi\" "
            + "((\"A\" NIL \"a\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n"
        XCTAssertEqual(try XCTUnwrap(summary(garbage)).date, date("Mon, 5 Jan 2026 10:00:00 +0000"))
        // Spam dated years ahead would stick to the top of the list.
        let future = "* 1 FETCH (UID 2 FLAGS () INTERNALDATE \"05-Jan-2026 10:00:00 +0000\" ENVELOPE (\"Fri, 1 Jan 2038 00:00:00 +0000\" \"WIN\" "
            + "((\"A\" NIL \"a\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n"
        XCTAssertEqual(try XCTUnwrap(summary(future)).date, date("Mon, 5 Jan 2026 10:00:00 +0000"))
        // A day of clock skew is fine.
        let skewed = "* 1 FETCH (UID 3 FLAGS () INTERNALDATE \"05-Jan-2026 10:00:00 +0000\" ENVELOPE (\"Tue, 6 Jan 2026 09:00:00 +0000\" \"Hi\" "
            + "((\"A\" NIL \"a\" \"example.com\")) NIL NIL NIL NIL NIL NIL NIL))\r\n"
        XCTAssertEqual(try XCTUnwrap(summary(skewed)).date, date("Tue, 6 Jan 2026 09:00:00 +0000"))
        // No dates at all → now.
        let none = "* 1 FETCH (UID 4 FLAGS ())\r\n"
        let now = Date(timeIntervalSince1970: 1_792_454_400)
        XCTAssertEqual(try XCTUnwrap(summary(none, now: now)).date, now)
        // Epoch-ish dates from broken mailers.
        let epoch = "* 1 FETCH (UID 5 INTERNALDATE \"05-Jan-2026 10:00:00 +0000\" ENVELOPE (\"Thu, 1 Jan 1970 00:00:00 +0000\" NIL NIL NIL NIL NIL NIL NIL NIL NIL))\r\n"
        XCTAssertEqual(try XCTUnwrap(summary(epoch)).date, date("Mon, 5 Jan 2026 10:00:00 +0000"))
    }

    func testResponseWithoutUIDIsSkipped() {
        let responses = F.fetchResponses("* 3 FETCH (FLAGS (\\Seen))\r\n")
        XCTAssertNil(IMAPMailServiceSummaries.summary(from: responses[0], accountID: "a", mailboxPath: "INBOX", uidValidity: 1))
    }

    func testBulkDetection() {
        func headers(_ text: String) -> MIMEHeaders { MIMEHeaders.parse(Data((text + "\r\n\r\n").utf8)) }
        let person = [EmailAddress(name: "Grace", address: "grace@example.com")]
        XCTAssertFalse(IMAPMailServiceSummaries.isBulk(headers: headers(""), from: person))
        XCTAssertTrue(IMAPMailServiceSummaries.isBulk(headers: headers("Precedence: bulk"), from: person))
        XCTAssertTrue(IMAPMailServiceSummaries.isBulk(headers: headers("Precedence: list"), from: person))
        XCTAssertFalse(IMAPMailServiceSummaries.isBulk(headers: headers("Precedence: first-class"), from: person))
        XCTAssertTrue(IMAPMailServiceSummaries.isBulk(headers: headers("Auto-Submitted: auto-generated"), from: person))
        XCTAssertTrue(IMAPMailServiceSummaries.isBulk(headers: headers("Auto-Submitted: auto-replied"), from: person))
        XCTAssertFalse(IMAPMailServiceSummaries.isBulk(headers: headers("Auto-Submitted: no"), from: person))
        XCTAssertFalse(IMAPMailServiceSummaries.isBulk(headers: headers("Auto-Submitted: No ; reason=manual"), from: person))
        XCTAssertTrue(IMAPMailServiceSummaries.isBulk(headers: headers("List-Id: Ink devs <ink.lists.example>"), from: person))
        XCTAssertTrue(IMAPMailServiceSummaries.isBulk(headers: headers(""), from: [EmailAddress(address: "no-reply@accounts.example")]))
        XCTAssertTrue(IMAPMailServiceSummaries.isBulk(headers: headers(""), from: [EmailAddress(address: "notifications@github.com")]))
    }

    func testAddressDecoding() {
        let list = [
            IMAPAddress(name: "=?UTF-8?B?5bGx55Sw5aSq6YOO?=", mailbox: "taro", host: "example.jp"),
            IMAPAddress(name: "\"Quoted Name\"", mailbox: "q", host: "example.com"),
            IMAPAddress(name: "q2@example.com", mailbox: "q2", host: "example.com"),
            IMAPAddress(name: nil, mailbox: "", host: "example.com"),
            IMAPAddress(name: nil, mailbox: "bare", host: ".MISSING-HOST-NAME."),
            IMAPAddress(name: "Line\r\n Folded", mailbox: "f", host: "example.com"),
        ]
        let decoded = IMAPMailServiceSummaries.addresses(list)
        XCTAssertEqual(decoded.map(\.address), ["taro@example.jp", "q@example.com", "q2@example.com", "bare", "f@example.com"])
        XCTAssertEqual(decoded[0].name, "山田太郎")
        XCTAssertEqual(decoded[1].name, "Quoted Name")
        XCTAssertNil(decoded[2].name, "a name that is just the address adds nothing")
        XCTAssertEqual(decoded[4].name, "Line Folded")
    }

    func testSubjectDecodingVariants() {
        XCTAssertEqual(IMAPMailServiceSummaries.decodeText("=?ISO-8859-1?Q?R=E9union_d=27=E9quipe?= =?ISO-8859-1?Q?_lundi?="), "Réunion d'équipe lundi")
        XCTAssertEqual(IMAPMailServiceSummaries.decodeText("Fwd:\r\n\tLong   subject"), "Fwd: Long subject")
        XCTAssertEqual(IMAPMailServiceSummaries.decodeText(nil), "")
        XCTAssertEqual(IMAPMailServiceSummaries.decodeText("=?utf-8?B?8J+OiSBXZWxjb21lIQ==?="), "🎉 Welcome!")
        XCTAssertEqual(IMAPMailServiceSummaries.decodeText("100% =?broken"), "100% =?broken")
    }

    // MARK: Snippets

    private func target(_ structure: String, file: StaticString = #filePath, line: UInt = #line) -> IMAPMailServiceSummaries.SnippetTarget? {
        let response = F.fetchResponses("* 1 FETCH (UID 1 BODYSTRUCTURE \(structure))\r\n", file: file, line: line).first
        return IMAPMailServiceSummaries.snippetTarget(response?.bodyStructure, options: IMAPMailService.Options())
    }

    func testSnippetTargetPrefersPlainText() throws {
        let alternative = try XCTUnwrap(target("((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 100 3 NIL NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"base64\" 900 12 NIL NIL NIL NIL) \"alternative\" (\"boundary\" \"x\") NIL NIL NIL)"))
        XCTAssertEqual(alternative.section, "1")
        XCTAssertFalse(alternative.isHTML)
        XCTAssertEqual(alternative.length, 2048)
        XCTAssertEqual(alternative.encoding, "quoted-printable")

        let htmlOnly = try XCTUnwrap(target("(\"TEXT\" \"HTML\" (\"CHARSET\" \"windows-1252\") NIL NIL \"BASE64\" 900 12 NIL NIL NIL NIL)"))
        XCTAssertEqual(htmlOnly.section, "1")
        XCTAssertTrue(htmlOnly.isHTML)
        XCTAssertEqual(htmlOnly.length, 4096)
        XCTAssertEqual(htmlOnly.contentType.charset?.lowercased(), "windows-1252")

        // Apple Mail: mixed(alternative(plain, related(html, image)), attachment)
        let apple = try XCTUnwrap(target("(((\"text\" \"plain\" (\"charset\" \"us-ascii\") NIL NIL \"7bit\" 40 2 NIL NIL NIL NIL)((\"text\" \"html\" (\"charset\" \"us-ascii\") NIL NIL \"7bit\" 300 9 NIL NIL NIL NIL)(\"image\" \"png\" (\"name\" \"logo.png\") \"<logo@ink>\" NIL \"base64\" 4000 NIL (\"inline\" (\"filename\" \"logo.png\")) NIL NIL) \"related\" (\"boundary\" \"r\") NIL NIL NIL) \"alternative\" (\"boundary\" \"a\") NIL NIL NIL)(\"application\" \"pdf\" (\"name\" \"x.pdf\") NIL NIL \"base64\" 9000 NIL (\"attachment\" (\"filename\" \"x.pdf\")) NIL NIL) \"mixed\" (\"boundary\" \"m\") NIL NIL NIL)"))
        XCTAssertEqual(apple.section, "1.1")

        XCTAssertNil(target("(\"image\" \"jpeg\" NIL NIL NIL \"base64\" 9000 NIL NIL NIL NIL)"), "nothing to preview")
        XCTAssertNil(IMAPMailServiceSummaries.snippetTarget(nil, options: IMAPMailService.Options()))
    }

    func testSnippetDecodesTruncatedQuotedPrintable() throws {
        let t = try XCTUnwrap(target("(\"text\" \"plain\" (\"charset\" \"iso-8859-1\") NIL NIL \"quoted-printable\" 100 3 NIL NIL NIL NIL)"))
        let body = "Hallo Ada,\r\n\r\nk=F6nnen wir das Treffen auf Donnerstag verschieben? Das w=E4re=\r\n super.\r\n\r\nGr=FC=DF=\r\ne\r\nBj=F6"
        let snippet = IMAPMailServiceSummaries.snippet(from: Data(body.utf8), target: t)
        XCTAssertTrue(snippet.hasPrefix("Hallo Ada, können wir das Treffen auf Donnerstag verschieben? Das wäre super."), snippet)
    }

    func testSnippetFromTruncatedBase64HTML() throws {
        let t = try XCTUnwrap(target("(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"base64\" 90000 12 NIL NIL NIL NIL)"))
        let html = "<html><head><style>p{color:red}</style></head><body><div style=\"display:none\">Preheader: 20% off this week</div><p>Hi Ada — your order <b>#4411</b> has shipped.</p><p>Track it here: https://shop.example/t/4411</p></body></html>"
        var encoded = Data(html.utf8).base64EncodedString(options: [.lineLength76Characters, .endLineWithCarriageReturn, .endLineWithLineFeed])
        encoded = String(encoded.prefix(encoded.count - 7))
        let snippet = IMAPMailServiceSummaries.snippet(from: Data(encoded.utf8), target: t)
        XCTAssertTrue(snippet.contains("your order #4411 has shipped"), snippet)
        XCTAssertFalse(snippet.contains("color:red"))
    }

    func testSnippetSkipsQuotedReply() throws {
        let t = try XCTUnwrap(target("(\"text\" \"plain\" (\"charset\" \"utf-8\" \"format\" \"flowed\") NIL NIL \"8bit\" 100 3 NIL NIL NIL NIL)"))
        let body = "Sounds good, see you at 10. \r\nI'll bring the slides.\r\n\r\nOn Mon, Oct 19, 2026 at 4:02 PM Grace Hopper <grace@example.com> wrote:\r\n> Can we meet tomorrow?\r\n"
        XCTAssertEqual(IMAPMailServiceSummaries.snippet(from: Data(body.utf8), target: t), "Sounds good, see you at 10. I'll bring the slides.")
    }
}
