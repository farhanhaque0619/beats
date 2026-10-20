import XCTest
import InkModel
@testable import InkMIME

final class RealWorldMessageTests: XCTestCase {
    func testGmailAlternative() {
        let m = MIMEParser.parse(Raw.data(Fixtures.gmailAlternative))
        XCTAssertEqual(m.subject, "Café tomorrow?")
        XCTAssertEqual(m.from.first?.name, "Ada Lovelace")
        XCTAssertEqual(m.from.first?.address, "ada.lovelace@gmail.com")
        XCTAssertEqual(m.to.first?.address, "alex@ink.example")
        XCTAssertEqual(m.messageID, "CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com")
        XCTAssertEqual(m.date, Date.utc(2026, 10, 20, 9, 15, 30))
        XCTAssertEqual(m.plainText, "Hi Alex,\n\nAre you free for a coffee at Café Central tomorrow around 10? I'd love to hear how the launch went.\n\nCheers,\nAda\n")
        XCTAssertEqual(m.html?.contains("Café Central tomorrow around 10? I&#39;d love"), true)
        XCTAssertTrue(m.attachments.isEmpty)
        XCTAssertEqual(m.headers["DKIM-Signature"]?.contains("h=to:subject:message-id:date:from:mime-version:from:to:cc:subject :date"), true)
        XCTAssertEqual(m.headers.values("Received").count, 2)
    }

    func testGmailReplyQuotes() {
        let m = MIMEParser.parse(Raw.data(Fixtures.gmailReply))
        XCTAssertEqual(m.subject, "Re: Café tomorrow?")
        XCTAssertEqual(m.inReplyTo, ["CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com"])
        let split = QuoteSplitter.split(m.plainText ?? "")
        XCTAssertEqual(split.body, "Sounds great, see you at 10!")
        XCTAssertEqual(split.quoted?.hasPrefix("On Tue, Oct 20, 2026 at 11:15\u{202F}AM Ada Lovelace <ada.lovelace@gmail.com>\nwrote:"), true)
        let stripped = QuoteSplitter.stripQuotedHTML(m.html ?? "")
        XCTAssertTrue(stripped.hadQuote)
        XCTAssertFalse(stripped.html.contains("gmail_quote"))
        XCTAssertFalse(stripped.html.contains("Are you free"))
        XCTAssertTrue(stripped.html.contains("Sounds great"))
        XCTAssertEqual(Snippet.make(plain: m.plainText, html: m.html), "Sounds great, see you at 10!")
    }

    func testGmailInlineImage() {
        let m = MIMEParser.parse(Raw.data(Fixtures.gmailInlineImage))
        XCTAssertEqual(m.root.contentType.mimeType, "multipart/related")
        XCTAssertEqual(m.html?.contains("cid:ii_m2abc1230"), true)
        XCTAssertEqual(m.plainText?.contains("[image: whiteboard.png]"), true)
        XCTAssertEqual(m.attachments.count, 1)
        let image = m.attachments[0]
        XCTAssertEqual(image.id, "2")
        XCTAssertEqual(image.filename, "whiteboard.png")
        XCTAssertEqual(image.contentID, "ii_m2abc1230")
        XCTAssertTrue(image.isInline)
        XCTAssertEqual(image.size, 70)
        XCTAssertEqual(image.data?.prefix(4), Data([0x89, 0x50, 0x4E, 0x47]))
        XCTAssertEqual(Snippet.make(plain: m.plainText, html: m.html), "Here's the whiteboard: Ada")
    }

    func testAppleMailInlineImage() {
        let m = MIMEParser.parse(Raw.data(Fixtures.appleMailInlineImage))
        XCTAssertEqual(m.subject, "Photo from the offsite")
        XCTAssertEqual(m.date, Date.utc(2026, 10, 20, 1, 42, 7))
        XCTAssertEqual(m.messageID, "8F2A1B3C-4D5E-6F7A-8B9C-0D1E2F3A4B5C@icloud.com")
        XCTAssertEqual(m.plainText?.contains("Here's the team photo!"), true)
        XCTAssertEqual(m.html?.contains("src=\"cid:A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D\""), true)
        XCTAssertEqual(m.attachments.count, 1)
        let image = m.attachments[0]
        XCTAssertEqual(image.id, "2.2")
        XCTAssertEqual(image.filename, "team.png")
        XCTAssertEqual(image.mimeType, "image/png")
        XCTAssertTrue(image.isInline)
        XCTAssertEqual(image.contentID, "A1B2C3D4-E5F6-4A7B-8C9D-0E1F2A3B4C5D")
        XCTAssertEqual(m.root.children[1].contentType.parameters["type"], "text/html")
        XCTAssertEqual(m.headers["Mime-Version"], "1.0 (Mac OS X Mail 16.0 \\(3826.200.121\\))")
    }

    func testICloudPlainReply() {
        let m = MIMEParser.parse(Raw.data(Fixtures.iCloudPlainReply))
        XCTAssertEqual(m.references, ["8F2A1B3C-4D5E-6F7A-8B9C-0D1E2F3A4B5C@icloud.com", "CAH5r7=abc@mail.gmail.com"])
        XCTAssertNil(m.html)
        XCTAssertEqual(m.plainText?.hasPrefix("Yes, Thursday works 👍"), true)
        let split = QuoteSplitter.split(m.plainText ?? "")
        XCTAssertEqual(split.body, "Yes, Thursday works 👍\n\nSent from my iPhone")
        XCTAssertEqual(split.quoted?.hasPrefix("> On Oct 20, 2026"), true)
        XCTAssertEqual(split.quoted?.hasSuffix("> Love it! Can we print one for the office?"), true)   // stray BOM removed
        XCTAssertEqual(Snippet.make(plain: m.plainText, html: nil), "Yes, Thursday works 👍")
    }

    func testOutlookWinmail() {
        let m = MIMEParser.parse(Raw.data(Fixtures.outlookWinmail))
        XCTAssertEqual(m.subject, "RE: Q3 budget review")
        XCTAssertEqual(m.from.first?.name, "Smith, John")
        XCTAssertEqual(m.from.first?.address, "John.Smith@contoso.example")
        XCTAssertEqual(m.to.map(\.address), ["alex@ink.example", "jane.doe@contoso.example"])
        XCTAssertEqual(m.to.last?.name, "Doe, Jane")
        XCTAssertEqual(m.cc.map(\.address), ["leads@contoso.example"])
        XCTAssertEqual(m.references.count, 2)
        XCTAssertEqual(m.inReplyTo.first?.hasPrefix("AM0PR04MB6849"), true)
        XCTAssertEqual(m.plainText?.contains("The revised numbers are attached – let’s discuss on Thursday."), true)
        XCTAssertEqual(m.html?.contains("let’s discuss on Thursday"), true)
        XCTAssertEqual(m.attachments.map(\.filename), ["winmail.dat"])
        XCTAssertEqual(m.attachments.first?.mimeType, "application/ms-tnef")
        XCTAssertEqual(m.attachments.first?.size, 34)
        XCTAssertEqual(m.attachments.first?.id, "2")
        XCTAssertFalse(m.attachments[0].isInline)

        let split = QuoteSplitter.split(m.plainText ?? "")
        XCTAssertEqual(split.body, "Hi Alex,\n\nThe revised numbers are attached – let’s discuss on Thursday.\n\nThanks,\nJohn")
        XCTAssertEqual(split.quoted?.hasPrefix("From: Alex Rivera"), true)

        let stripped = QuoteSplitter.stripQuotedHTML(m.html ?? "")
        XCTAssertTrue(stripped.hadQuote)
        XCTAssertFalse(stripped.html.contains("could you send the latest"))
        XCTAssertTrue(stripped.html.contains("John<o:p>"))
        XCTAssertFalse(EmailHTMLDocument.isDesigned(m.html ?? ""))
        XCTAssertEqual(HTMLText.toPlainText(stripped.html), "Hi Alex,\n\nThe revised numbers are attached – let’s discuss on Thursday.\n\nThanks,\nJohn")
    }

    func testOutlookWebReply() {
        let m = MIMEParser.parse(Raw.data(Fixtures.outlookWebReply))
        XCTAssertNil(m.plainText)
        XCTAssertEqual(m.html?.contains("Café Nero"), true)
        let stripped = QuoteSplitter.stripQuotedHTML(m.html ?? "")
        XCTAssertTrue(stripped.hadQuote)
        XCTAssertFalse(stripped.html.contains("divRplyFwdMsg"))
        XCTAssertFalse(stripped.html.contains("Lunch today?"))
        XCTAssertFalse(stripped.html.contains("<hr"))
        XCTAssertTrue(stripped.html.contains("</body>"))
        XCTAssertEqual(Snippet.make(plain: nil, html: m.html), "Sure – let's do Café Nero at 1.")
    }

    func testYahooReply() {
        let m = MIMEParser.parse(Raw.data(Fixtures.yahooReply))
        XCTAssertEqual(m.date, Date.utc(2026, 10, 20, 14, 22, 10))
        let stripped = QuoteSplitter.stripQuotedHTML(m.html ?? "")
        XCTAssertTrue(stripped.hadQuote)
        XCTAssertFalse(stripped.html.contains("Hiking on Saturday?"))
        XCTAssertTrue(stripped.html.contains("Hiking sounds perfect."))
        let split = QuoteSplitter.split(m.plainText ?? "")
        XCTAssertEqual(split.body.trimmingCharacters(in: .whitespaces), "Hiking sounds perfect.")
    }

    func testProtonReply() {
        let m = MIMEParser.parse(Raw.data(Fixtures.protonReply))
        let stripped = QuoteSplitter.stripQuotedHTML(m.html ?? "")
        XCTAssertTrue(stripped.hadQuote)
        XCTAssertFalse(stripped.html.contains("Where are the keys?"))
        XCTAssertTrue(stripped.html.contains("I left them at reception."))
        XCTAssertTrue(stripped.html.contains("Noor"))
    }

    func testFastmailQuotedPrintable() {
        let m = MIMEParser.parse(Raw.data(Fixtures.fastmailQP))
        XCTAssertEqual(m.from.first?.name, "Sam Okafor")
        XCTAssertEqual(m.date, Date.utc(2026, 10, 20, 13))
        XCTAssertEqual(m.plainText, """
        This line is long enough that it needs a soft line break somewhere in the middle, and it also has an é encoded with lowercase hex.\u{20}
        Trailing space above was encoded.
        Soft break with trailing whitespace after the equals sign:still the same line.
        """)
    }

    func testThunderbirdFlowedAndForwardAttachment() {
        let m = MIMEParser.parse(Raw.data(Fixtures.thunderbirdForwardAttachment))
        XCTAssertEqual(m.plainText, "FYI, see the message below. This paragraph is long enough that Thunderbird wrapped it with a trailing space, so it should come back as one line.\n\n-- \nLinus\n")
        XCTAssertEqual(m.attachments.count, 1)
        let eml = m.attachments[0]
        XCTAssertEqual(eml.filename, "Lunch on Friday.eml")
        XCTAssertEqual(eml.mimeType, "message/rfc822")
        XCTAssertEqual(eml.id, "2")
        let inner = MIMEParser.parse(eml.data ?? Data())
        XCTAssertEqual(inner.subject, "Lunch on Friday")
        XCTAssertEqual(inner.plainText, "Shall we try the new ramen place?")
        XCTAssertEqual(m.root.part(withID: "2.1")?.contentType.mimeType, "text/plain")
        XCTAssertEqual(m.root.part(withID: "2.2")?.contentType.mimeType, "text/html")
        XCTAssertEqual(m.root.children[1].embeddedMessage?.from.first?.address, "maria@example.org")
        XCTAssertNil(m.html)
        XCTAssertEqual(QuoteSplitter.split(m.plainText ?? "").quoted, "-- \nLinus")
    }

    func testInlineForwardedMessage() {
        let m = MIMEParser.parse(Raw.data(Fixtures.inlineForwardedMessage))
        XCTAssertEqual(m.plainText?.hasPrefix("Look, it's on its way!\n"), true)
        XCTAssertEqual(m.plainText?.contains("---------- Forwarded message ----------\nFrom: Shop <orders@shop.example>"), true)
        XCTAssertEqual(m.plainText?.contains("Subject: Your order has shipped"), true)
        XCTAssertEqual(m.plainText?.contains("Tracking: 1Z999AA10123456784"), true)
        XCTAssertNil(m.html)
        XCTAssertEqual(m.attachments.map(\.filename), ["Your order has shipped.eml", "receipt.pdf"])
        XCTAssertEqual(m.attachments.map(\.id), ["2", "2.2"])
        XCTAssertEqual(m.attachments[1].data?.prefix(5), Data("%PDF-".utf8))
    }

    func testISO2022JP() {
        let m = MIMEParser.parse(Raw.data(Fixtures.iso2022jp))
        XCTAssertEqual(m.subject, "会議の議事録について")
        XCTAssertEqual(m.from.first?.name, "山田 太郎")
        XCTAssertEqual(m.from.first?.address, "yamada@example.co.jp")
        XCTAssertEqual(m.date, Date.utc(2026, 10, 20, 9, 30))
        XCTAssertEqual(m.plainText, "山田様\n\nお世話になっております。\n明日の会議は午後3時からです。\nよろしくお願いいたします。")
        XCTAssertEqual(Snippet.make(plain: m.plainText, html: nil), "山田様 お世話になっております。 明日の会議は午後3時からです。 よろしくお願いいたします。")
    }

    func testGB2312() {
        let m = MIMEParser.parse(Raw.data(Fixtures.gb2312))
        XCTAssertEqual(m.subject, "关于下周的会议安排")
        XCTAssertEqual(m.from.first?.name, "赵晓明")
        XCTAssertEqual(m.plainText, "各位同事：\n\n下周一上午十点在三楼会议室开会，请准时参加。\n\n谢谢！\n")
        XCTAssertEqual(m.date, Date.utc(2026, 10, 20, 9, 5, 12))
    }

    func testWindows1252Newsletter() {
        let m = MIMEParser.parse(Raw.data(Fixtures.windows1252Newsletter))
        XCTAssertEqual(m.subject, "“Fall Sale” starts now – 20% off")
        XCTAssertEqual(m.from.first?.name, "Northwind Outfitters")
        XCTAssertEqual(m.replyTo.first?.address, "reply@email.northwind.example")
        XCTAssertEqual(m.plainText?.contains("“Fall Sale” – save 20% on everything… only €19!"), true)
        XCTAssertEqual(m.html?.contains("“Fall Sale” – save 20% on everything… only €19!"), true)
        XCTAssertEqual(m.headers["List-Unsubscribe-Post"], "List-Unsubscribe=One-Click")
        let html = m.html ?? ""
        XCTAssertTrue(EmailHTMLDocument.isDesigned(html))
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages(html), 2)
        XCTAssertEqual(EmailHTMLDocument.countTrackingPixels(html), 1)
        let text = HTMLText.toPlainText(html)
        XCTAssertTrue(text.hasPrefix("Our biggest sale of the season is here."))
        XCTAssertTrue(text.contains("Shop now →"))
        XCTAssertFalse(text.contains("background-color"))
        XCTAssertFalse(text.contains("Fall Sale\nFall Sale"))   // <title> is not body text
        XCTAssertEqual(Snippet.make(plain: m.plainText, html: m.html), "“Fall Sale” – save 20% on everything… only €19!")
        XCTAssertEqual(Snippet.make(plain: nil, html: m.html).hasPrefix("Our biggest sale of the season is here."), true)
    }

    func testBase64OddLines() {
        let m = MIMEParser.parse(Raw.data(Fixtures.base64OddLines))
        XCTAssertEqual(m.plainText, "Hello from a mailer that wraps base64 at odd lengths, and forgets the padding!")
        XCTAssertEqual(m.date, Date.utc(2026, 10, 20, 9))
        XCTAssertEqual(m.from.first?.address, "legacy@mailer.example")
    }

    func testMissingEndBoundary() {
        let m = MIMEParser.parse(Raw.data(Fixtures.missingEndBoundary))
        XCTAssertEqual(m.plainText, "Report attached.")
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertEqual(m.attachments.first?.filename, "report.pdf")
        XCTAssertEqual(m.attachments.first?.size, 77)
    }

    func testCalendarInvite() {
        let m = MIMEParser.parse(Raw.data(Fixtures.calendarInvite))
        XCTAssertEqual(m.subject, "Invitation: Design review @ Thu Oct 22, 2026 2pm - 3pm (CEST) (alex@ink.example)")
        XCTAssertEqual(m.plainText?.hasPrefix("You have been invited to the following event.\n\nDesign review\nThursday Oct 22, 2026 ⋅ 2pm – 3pm"), true)
        XCTAssertEqual(m.html?.contains("<h2>Design review</h2>"), true)
        XCTAssertEqual(m.attachments.map(\.mimeType), ["text/calendar", "application/ics"])
        XCTAssertEqual(m.attachments.map(\.filename), ["invite.ics", "invite.ics"])
        XCTAssertEqual(m.attachments.map(\.id), ["1.3", "2"])
        let ics = String(decoding: m.attachments[0].data ?? Data(), as: UTF8.self)
        XCTAssertTrue(ics.contains("SUMMARY:Design review"))
        XCTAssertTrue(ics.contains("METHOD:REQUEST"))
        XCTAssertEqual(m.attachments[1].size, 61)
        XCTAssertTrue(m.attachments.allSatisfy { !$0.isInline })
    }

    func testEncodedFilenames() {
        let m = MIMEParser.parse(Raw.data(Fixtures.encodedFilenames))
        XCTAssertEqual(m.subject, "Unterlagen für Montag")
        XCTAssertEqual(m.plainText, "Hallo Alex, anbei die Unterlagen.")
        XCTAssertEqual(m.attachments.map(\.filename), [
            "Präsentation Q3 – final.pdf", "報告書.docx", "Rechnung März.pdf", "IMG_0042.JPG", "passwd",
        ])
        XCTAssertEqual(m.attachments.map(\.id), ["2", "3", "4", "5", "6"])
        XCTAssertEqual(m.attachments[3].mimeType, "image/jpeg")
        XCTAssertEqual(m.attachments[3].data?.prefix(2), Data([0xFF, 0xD8]))
    }

    func testDovecotBounce() {
        let m = MIMEParser.parse(Raw.data(Fixtures.dovecotBounce))
        XCTAssertEqual(m.from.first?.address, "MAILER-DAEMON@mail.ink.example")
        XCTAssertEqual(m.from.first?.name, "Mail Delivery System")
        XCTAssertEqual(m.plainText?.contains("550 5.1.1 User unknown"), true)
        XCTAssertEqual(m.attachments.map(\.mimeType), ["message/delivery-status", "text/rfc822-headers"])
        XCTAssertEqual(m.attachments.map(\.filename), ["Attachment 2.txt", "Attachment 3.txt"])
        XCTAssertEqual(m.root.contentType.parameters["report-type"], "delivery-status")
    }

    func testMailmanFooterIsJoined() {
        let m = MIMEParser.parse(Raw.data(Fixtures.mailmanFooter))
        XCTAssertEqual(m.plainText, """
        Please review the checklist before Friday.
        _______________________________________________
        ink-dev mailing list
        ink-dev@lists.example.org
        https://lists.example.org/mailman/listinfo/ink-dev

        """)
        XCTAssertEqual(m.html?.hasPrefix("<p>Please review the <a href=\"https://wiki.example.org/release\">checklist</a> before Friday.</p>"), true)
        XCTAssertEqual(m.html?.contains("ink-plain-part"), true)
        XCTAssertEqual(m.html?.contains("<a href=\"mailto:ink-dev@lists.example.org\">"), true)
        XCTAssertTrue(m.attachments.isEmpty)
        XCTAssertEqual(Snippet.make(plain: m.plainText, html: m.html), "Please review the checklist before Friday. ink-dev mailing list ink-dev@lists.example.org")
    }

    func testSMIMESignatureIsHidden() {
        let m = MIMEParser.parse(Raw.data(Fixtures.smimeSigned))
        XCTAssertEqual(m.plainText, "Your October statement is ready in online banking.")
        XCTAssertTrue(m.attachments.isEmpty)
    }

    func testPreMIMEPlainWithLFLineEndings() {
        let m = MIMEParser.parse(Data(Fixtures.preMIMEPlain.utf8))
        XCTAssertEqual(m.from.first?.address, "root")
        XCTAssertEqual(m.from.first?.name, "Cron Daemon")
        XCTAssertEqual(m.subject, "Cron <root@server> /usr/local/bin/backup.sh")
        XCTAssertEqual(m.plainText, "backup completed: 1203 files, 4.2 GB")
    }

    func testHTMLOnlyMailchimp() {
        let m = MIMEParser.parse(Raw.data(Fixtures.htmlOnlyMailchimp))
        XCTAssertNil(m.plainText)
        let html = m.html ?? ""
        XCTAssertEqual(EmailHTMLDocument.countRemoteImages(html), 2)
        XCTAssertEqual(EmailHTMLDocument.countTrackingPixels(html), 1)
        XCTAssertEqual(Snippet.make(plain: nil, html: html), "This week: offline search and quieter notifications Issue #42 Hello & welcome to issue #42.")
    }

    func testEveryFixtureSurvivesTruncation() {
        // Partial downloads must never crash and must keep whatever headers arrived.
        let all = [
            Fixtures.gmailAlternative, Fixtures.gmailReply, Fixtures.gmailInlineImage, Fixtures.appleMailInlineImage,
            Fixtures.iCloudPlainReply, Fixtures.outlookWinmail, Fixtures.outlookWebReply, Fixtures.yahooReply, Fixtures.fastmailQP,
            Fixtures.thunderbirdForwardAttachment, Fixtures.inlineForwardedMessage, Fixtures.protonReply, Fixtures.iso2022jp,
            Fixtures.gb2312, Fixtures.windows1252Newsletter, Fixtures.base64OddLines, Fixtures.missingEndBoundary,
            Fixtures.calendarInvite, Fixtures.encodedFilenames, Fixtures.dovecotBounce, Fixtures.mailmanFooter,
            Fixtures.smimeSigned, Fixtures.preMIMEPlain, Fixtures.htmlOnlyMailchimp,
        ]
        for fixture in all {
            let data = Raw.data(fixture)
            let full = MIMEParser.parse(data)
            for fraction in stride(from: 0.05, to: 1.0, by: 0.07) {
                let cut = data.prefix(Int(Double(data.count) * fraction))
                let partial = MIMEParser.parse(cut)
                _ = partial.plainText
                _ = Snippet.make(plain: partial.plainText, html: partial.html)
                if fraction > 0.9, !full.subject.isEmpty, let headerEnd = data.range(of: Data("\r\n\r\n".utf8)), headerEnd.lowerBound < cut.count {
                    XCTAssertEqual(partial.subject, full.subject)
                }
            }
        }
    }
}
