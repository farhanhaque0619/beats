import XCTest
@testable import InkIMAP

/// BODYSTRUCTURE samples as real servers send them (Gmail echoes the original case, Dovecot and
/// iCloud uppercase and add language/location, Outlook adds "en-US").
final class BodyStructureTests: XCTestCase {
    private func single(_ structure: BodyStructure?, file: StaticString = #filePath, line: UInt = #line) -> BodyPart? {
        guard case .single(let part)? = structure else {
            XCTFail("expected a single part", file: file, line: line)
            return nil
        }
        return part
    }

    private func multipart(_ structure: BodyStructure?, file: StaticString = #filePath, line: UInt = #line) -> BodyMultipart? {
        guard case .multipart(let part)? = structure else {
            XCTFail("expected a multipart", file: file, line: line)
            return nil
        }
        return part
    }

    // MARK: Single part

    func testDovecotSinglePartPlainText() {
        let part = single(bodyStructure("(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"us-ascii\") NIL NIL \"7BIT\" 1152 23 NIL NIL NIL NIL)"))
        XCTAssertEqual(part?.section, "1")
        XCTAssertEqual(part?.mimeType, "text/plain")
        XCTAssertEqual(part?.charset, "us-ascii")
        XCTAssertEqual(part?.encoding, "7bit")
        XCTAssertEqual(part?.size, 1152)
        XCTAssertEqual(part?.lines, 23)
        XCTAssertNil(part?.disposition)
        XCTAssertEqual(bodyStructure("(\"TEXT\" \"PLAIN\" (\"CHARSET\" \"us-ascii\") NIL NIL \"7BIT\" 1152 23 NIL NIL NIL NIL)")?.preferredTextPart()?.section, "1")
    }

    func testNonExtensibleBodyForm() {
        let response = fetchResponse("* 9 FETCH (BODY (\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 12 1))\r\n")
        let part = single(response?.bodyStructure)
        XCTAssertEqual(part?.encoding, "quoted-printable")
        XCTAssertEqual(part?.lines, 1)
        XCTAssertNil(part?.md5)
    }

    func testSinglePartHTMLNewsletterWithBase64() {
        let structure = bodyStructure("(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"base64\" 98432 1262 NIL NIL NIL)")
        XCTAssertEqual(structure?.preferredTextPart()?.part.subtype, "html")
        XCTAssertEqual(structure?.htmlPart?.section, "1")
        XCTAssertNil(structure?.plainTextPart)
        XCTAssertEqual(structure?.hasAttachments, false)
    }

    // MARK: Gmail

    func testGmailAlternative() {
        let structure = bodyStructure("((\"text\" \"plain\" (\"charset\" \"UTF-8\") NIL NIL \"quoted-printable\" 1532 34 NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"UTF-8\") NIL NIL \"quoted-printable\" 8711 175 NIL NIL NIL) \"alternative\" (\"boundary\" \"000000000000a1b2c3d4e5f6a7b8\") NIL NIL)")
        let root = multipart(structure)
        XCTAssertEqual(root?.section, "")
        XCTAssertEqual(root?.subtype, "alternative")
        XCTAssertEqual(root?.parameters["boundary"], "000000000000a1b2c3d4e5f6a7b8")
        XCTAssertEqual(root?.parts.map(\.section), ["1", "2"])
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1")
        XCTAssertEqual(structure?.htmlPart?.section, "2")
        XCTAssertEqual(structure?.attachmentParts.count, 0)
    }

    func testGmailMixedRelatedAlternativeWithInlineImageAndPDF() {
        let structure = bodyStructure("""
        ((((\"text\" \"plain\" (\"charset\" \"UTF-8\") NIL NIL \"quoted-printable\" 543 14 NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"UTF-8\") NIL NIL \"quoted-printable\" 1876 38 NIL NIL NIL) \"alternative\" (\"boundary\" \"0000000000003a5f9c05f1b8c2d1\") NIL NIL)(\"image\" \"png\" (\"name\" \"logo.png\") \"<ii_lk2x9f0a0>\" NIL \"base64\" 18242 NIL (\"inline\" (\"filename\" \"logo.png\")) NIL) \"related\" (\"boundary\" \"0000000000003a5f9b05f1b8c2d0\") NIL NIL)(\"application\" \"pdf\" (\"name\" \"Invoice-2026-0412.pdf\") \"<f_lk2x9f0b1>\" NIL \"base64\" 248956 NIL (\"attachment\" (\"filename\" \"Invoice-2026-0412.pdf\")) NIL) \"mixed\" (\"boundary\" \"0000000000003a5f9e05f1b8c2d2\") NIL NIL)
        """)
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1.1.1")
        XCTAssertEqual(structure?.htmlPart?.section, "1.1.2")
        let attachments = structure?.attachmentParts ?? []
        XCTAssertEqual(attachments.map(\.section), ["2"])
        XCTAssertEqual(attachments.first?.filename, "Invoice-2026-0412.pdf")
        XCTAssertEqual(attachments.first?.size, 248_956)
        XCTAssertEqual(attachments.first?.disposition, "attachment")
        XCTAssertEqual(structure?.inlineParts.map(\.section), ["1.2"])
        XCTAssertEqual(structure?.inlineParts.first?.contentID, "ii_lk2x9f0a0")
        XCTAssertEqual(structure?.hasAttachments, true)
        XCTAssertEqual(structure?.part(section: "1.1")?.mimeType, "multipart/alternative")
        XCTAssertEqual(structure?.part(section: "1.2")?.mimeType, "image/png")
        XCTAssertNil(structure?.part(section: "3"))
    }

    func testGmailCalendarInvite() {
        let structure = bodyStructure("""
        (((\"text\" \"plain\" (\"charset\" \"UTF-8\" \"format\" \"flowed\" \"delsp\" \"yes\") NIL NIL \"base64\" 1386 28 NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"UTF-8\") NIL NIL \"quoted-printable\" 6440 129 NIL NIL NIL)(\"text\" \"calendar\" (\"charset\" \"UTF-8\" \"method\" \"REQUEST\") NIL NIL \"7bit\" 1590 32 NIL NIL NIL) \"alternative\" (\"boundary\" \"000000000000b55e2a05f1c0d9e2\") NIL NIL)(\"application\" \"ics\" (\"name\" \"invite.ics\") NIL NIL \"base64\" 2160 NIL (\"attachment\" (\"filename\" \"invite.ics\")) NIL) \"mixed\" (\"boundary\" \"000000000000b55e2c05f1c0d9e4\") NIL NIL)
        """)
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1.1")
        XCTAssertEqual(structure?.part(section: "1.3")?.mimeType, "text/calendar")
        XCTAssertEqual(single(structure?.part(section: "1.3"))?.parameters["method"], "REQUEST")
        XCTAssertEqual(structure?.attachmentParts.map(\.filename), ["invite.ics"])
    }

    // MARK: Apple Mail / iCloud

    func testAppleMailInlineImageSplitsHTML() {
        // Apple Mail puts an inline image between two HTML parts inside multipart/mixed.
        let structure = bodyStructure("""
        ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"us-ascii\") NIL NIL \"QUOTED-PRINTABLE\" 412 15 NIL NIL NIL NIL)((\"TEXT\" \"HTML\" (\"CHARSET\" \"us-ascii\") NIL NIL \"QUOTED-PRINTABLE\" 1203 25 NIL NIL NIL NIL)(\"IMAGE\" \"JPEG\" (\"NAME\" \"IMG_0042.jpeg\" \"X-UNIX-MODE\" \"0644\") \"<6C1D1B2E-0E57-4B0A-9C9F-2F1E7A0B5C11>\" NIL \"BASE64\" 1745120 NIL (\"INLINE\" (\"FILENAME\" \"IMG_0042.jpeg\")) NIL NIL)(\"TEXT\" \"HTML\" (\"CHARSET\" \"us-ascii\") NIL NIL \"7BIT\" 225 2 NIL NIL NIL NIL) \"MIXED\" (\"BOUNDARY\" \"Apple-Mail=_3F0D1E2A-7B6C-4D5E-8F90-A1B2C3D4E5F6\") NIL NIL NIL) \"ALTERNATIVE\" (\"BOUNDARY\" \"Apple-Mail=_9A8B7C6D-5E4F-3A2B-1C0D-E9F8A7B6C5D4\") NIL NIL NIL)
        """)
        let root = multipart(structure)
        XCTAssertEqual(root?.subtype, "alternative")
        XCTAssertEqual(root?.parameters["boundary"], "Apple-Mail=_9A8B7C6D-5E4F-3A2B-1C0D-E9F8A7B6C5D4")
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1")
        XCTAssertEqual(structure?.htmlPart?.section, "2.1")
        let image = single(structure?.part(section: "2.2"))
        XCTAssertEqual(image?.mimeType, "image/jpeg")
        XCTAssertEqual(image?.encoding, "base64")
        XCTAssertEqual(image?.disposition, "inline")
        XCTAssertEqual(image?.filename, "IMG_0042.jpeg")
        XCTAssertEqual(image?.parameters["x-unix-mode"], "0644")
        XCTAssertEqual(structure?.leafParts.count, 4)
    }

    func testICloudForwardedMessageAttachment() {
        // Thunderbird "forward as attachment", as stored on iCloud.
        let structure = bodyStructure("""
        ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\" \"FORMAT\" \"flowed\") NIL NIL \"7BIT\" 64 3 NIL NIL NIL NIL)(\"MESSAGE\" \"RFC822\" (\"NAME\" \"Quarterly numbers.eml\") NIL NIL \"7BIT\" 3841 (\"Tue, 13 Oct 2026 09:12:44 +0200\" \"Quarterly numbers\" ((\"Grace Hopper\" NIL \"grace\" \"example.org\")) ((\"Grace Hopper\" NIL \"grace\" \"example.org\")) ((\"Grace Hopper\" NIL \"grace\" \"example.org\")) ((\"Ada Lovelace\" NIL \"ada\" \"example.com\")) NIL NIL NIL \"<0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0@example.org>\") ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 420 12 NIL NIL NIL NIL)(\"APPLICATION\" \"VND.OPENXMLFORMATS-OFFICEDOCUMENT.SPREADSHEETML.SHEET\" (\"NAME\" \"Q3.xlsx\") NIL NIL \"BASE64\" 2210 NIL (\"ATTACHMENT\" (\"FILENAME\" \"Q3.xlsx\")) NIL NIL) \"MIXED\" (\"BOUNDARY\" \"------------B2rQzM0d3Y8Vt1cK9sL4hE7f\") NIL NIL NIL) 71 NIL (\"ATTACHMENT\" (\"FILENAME\" \"Quarterly numbers.eml\")) NIL NIL) \"MIXED\" (\"BOUNDARY\" \"------------n7Xk3W9pQ2rT5vY8zA1bC4dE\") NIL (\"en-US\") NIL)
        """)
        let root = multipart(structure)
        XCTAssertEqual(root?.language, ["en-US"])
        let forwarded = single(structure?.part(section: "2"))
        XCTAssertEqual(forwarded?.mimeType, "message/rfc822")
        XCTAssertEqual(forwarded?.isMessage, true)
        XCTAssertEqual(forwarded?.lines, 71)
        XCTAssertEqual(forwarded?.size, 3841)
        XCTAssertEqual(forwarded?.disposition, "attachment")
        XCTAssertEqual(forwarded?.filename, "Quarterly numbers.eml")
        let inner = forwarded?.message
        XCTAssertEqual(inner?.envelope?.subject, "Quarterly numbers")
        XCTAssertEqual(inner?.envelope?.from.first?.address, "grace@example.org")
        XCTAssertEqual(inner?.envelope?.to.first?.name, "Ada Lovelace")
        XCTAssertEqual(inner?.envelope?.messageID, "<0f1e2d3c-4b5a-6978-8796-a5b4c3d2e1f0@example.org>")
        XCTAssertEqual(inner?.lines, 71)
        // The attached message's parts are numbered under it: 2.1, 2.2.
        XCTAssertEqual(inner?.body.section, "2")
        XCTAssertEqual(structure?.part(section: "2.1")?.mimeType, "text/plain")
        XCTAssertEqual(structure?.part(section: "2.2")?.mimeType, "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet")
        // The outer text is preferred; the forwarded message is one attachment.
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1")
        XCTAssertEqual(structure?.attachmentParts.map(\.section), ["2"])
    }

    func testMessageRFC822WithSinglePartBodyNumbersItX1() {
        let structure = bodyStructure("""
        ((\"text\" \"plain\" NIL NIL NIL \"7bit\" 10 1 NIL NIL NIL)(\"message\" \"rfc822\" NIL NIL NIL \"7bit\" 900 (NIL \"Fwd\" NIL NIL NIL NIL NIL NIL NIL NIL) (\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"8bit\" 400 9 NIL NIL NIL) 20 NIL NIL NIL) \"mixed\" (\"boundary\" \"b\") NIL NIL)
        """)
        let forwarded = single(structure?.part(section: "2"))
        XCTAssertEqual(forwarded?.message?.body.section, "2.1")
        XCTAssertEqual(structure?.part(section: "2.1")?.mimeType, "text/html")
        XCTAssertEqual(forwarded?.message?.envelope?.subject, "Fwd")
        XCTAssertEqual(forwarded?.message?.envelope?.from, [])
    }

    func testMessageWithOnlyAnAttachedMessageUsesItsText() {
        // A bounce or "forward as attachment" with no text of its own.
        let structure = bodyStructure("""
        (\"message\" \"rfc822\" NIL NIL NIL \"7bit\" 900 (NIL \"Inner\" NIL NIL NIL NIL NIL NIL NIL NIL) ((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 40 2 NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 80 2 NIL NIL NIL) \"alternative\" (\"boundary\" \"x\") NIL NIL) 20)
        """)
        XCTAssertEqual(structure?.section, "1")
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1.1")
        XCTAssertEqual(structure?.htmlPart?.section, "1.2")
    }

    func testDeliveryStatusNotification() {
        let structure = bodyStructure("""
        ((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 512 14 NIL NIL NIL NIL)(\"message\" \"delivery-status\" NIL NIL NIL \"7bit\" 420 NIL NIL NIL NIL)(\"text\" \"rfc822-headers\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 2203 40 NIL NIL NIL NIL) \"report\" (\"report-type\" \"delivery-status\" \"boundary\" \"7A1F2C3D.1760000000/mx.example.com\") NIL NIL NIL)
        """)
        XCTAssertEqual(multipart(structure)?.subtype, "report")
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1")
        XCTAssertEqual(single(structure?.part(section: "2"))?.isMessage, false, "message/delivery-status isn't an attached email")
        XCTAssertNil(single(structure?.part(section: "2"))?.message)
    }

    // MARK: Outlook / Exchange

    func testOutlookRelatedWithImage001AndLanguage() {
        let structure = bodyStructure("""
        ((\"text\" \"plain\" (\"charset\" \"us-ascii\") NIL NIL \"quoted-printable\" 2104 61 NIL NIL \"en-US\" NIL)((\"text\" \"html\" (\"charset\" \"us-ascii\") NIL NIL \"quoted-printable\" 14522 290 NIL NIL \"en-US\" NIL)(\"image\" \"png\" (\"name\" \"image001.png\") \"<image001.png@01DB1234.56789ABC>\" \"image001.png\" \"base64\" 9612 NIL (\"inline\" (\"filename\" \"image001.png\" \"size\" \"7023\" \"creation-date\" \"Mon, 19 Oct 2026 14:02:11 GMT\" \"modification-date\" \"Mon, 19 Oct 2026 14:02:11 GMT\")) NIL NIL) \"related\" (\"boundary\" \"_004_DM6PR11MB4321ABCD_\" \"type\" \"multipart/alternative\") NIL NIL NIL) \"alternative\" (\"boundary\" \"_000_DM6PR11MB4321ABCD_\") NIL \"en-US\" NIL)
        """)
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1")
        XCTAssertEqual(structure?.htmlPart?.section, "2.1")
        let image = single(structure?.part(section: "2.2"))
        XCTAssertEqual(image?.contentID, "image001.png@01DB1234.56789ABC")
        XCTAssertEqual(image?.description, "image001.png")
        XCTAssertEqual(image?.dispositionParameters["size"], "7023")
        XCTAssertEqual(image?.language, [])
        XCTAssertEqual(single(structure?.part(section: "1"))?.language, ["en-US"])
        XCTAssertEqual(multipart(structure)?.language, ["en-US"])
        XCTAssertEqual(structure?.attachmentParts.count, 0, "inline images in related aren't attachments")
        XCTAssertEqual(structure?.inlineParts.count, 1)
    }

    func testOutlookWinmailDatAndDispositionAsBareString() {
        let structure = bodyStructure("""
        ((\"text\" \"plain\" (\"charset\" \"iso-8859-1\") NIL NIL \"quoted-printable\" 300 10 NIL NIL NIL NIL)(\"application\" \"ms-tnef\" (\"name\" \"winmail.dat\") NIL NIL \"base64\" 7234 NIL \"attachment\" NIL NIL) \"mixed\" (\"boundary\" \"_002_\") NIL NIL NIL)
        """)
        XCTAssertEqual(structure?.attachmentParts.first?.mimeType, "application/ms-tnef")
        XCTAssertEqual(structure?.attachmentParts.first?.disposition, "attachment")
        XCTAssertEqual(structure?.attachmentParts.first?.filename, "winmail.dat")
    }

    // MARK: Yahoo / Fastmail / misc

    func testYahooAlternative() {
        let structure = bodyStructure("""
        ((\"TEXT\" \"PLAIN\" (\"CHARSET\" \"UTF-8\") NIL NIL \"7BIT\" 312 9 NIL NIL NIL NIL)(\"TEXT\" \"HTML\" (\"CHARSET\" \"UTF-8\") NIL NIL \"QUOTED-PRINTABLE\" 2875 41 NIL NIL NIL NIL) \"ALTERNATIVE\" (\"BOUNDARY\" \"----=_Part_1234567_890123456.1760000000000\") NIL NIL NIL)
        """)
        XCTAssertEqual(multipart(structure)?.parameters["boundary"], "----=_Part_1234567_890123456.1760000000000")
        XCTAssertEqual(structure?.preferredTextPart()?.part.charset, "utf-8")
    }

    func testFastmailRFC2231FilenamesAndSignedMail() {
        let structure = bodyStructure("""
        (((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 200 6 NIL NIL NIL NIL)(\"application\" \"pdf\" (\"name*\" \"utf-8''%E2%82%AC%20rates%202026.pdf\") NIL NIL \"base64\" 5000 NIL (\"attachment\" (\"filename*\" \"utf-8''%E2%82%AC%20rates%202026.pdf\")) NIL NIL)(\"application\" \"octet-stream\" NIL NIL NIL \"base64\" 900 NIL (\"attachment\" (\"filename*0*\" \"utf-8''Sehr%20langer%20Dateiname%20\" \"filename*1*\" \"f%C3%BCr\" \"filename*2\" \" den Bericht.txt\")) NIL NIL) \"mixed\" (\"boundary\" \"inner\") NIL NIL NIL)(\"application\" \"pgp-signature\" (\"name\" \"signature.asc\") NIL \"OpenPGP digital signature\" \"7bit\" 833 NIL (\"attachment\" (\"filename\" \"signature.asc\")) NIL NIL) \"signed\" (\"micalg\" \"pgp-sha256\" \"protocol\" \"application/pgp-signature\" \"boundary\" \"outer\") NIL NIL NIL)
        """)
        let attachments = structure?.attachmentParts ?? []
        XCTAssertEqual(attachments.map(\.filename), ["€ rates 2026.pdf", "Sehr langer Dateiname für den Bericht.txt"])
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1.1")
    }

    func testISO88591RFC2231Filename() {
        let structure = bodyStructure("(\"application\" \"pdf\" NIL NIL NIL \"base64\" 10 NIL (\"attachment\" (\"filename*\" \"iso-8859-1'de'Pr%FCfung.pdf\")) NIL NIL)")
        XCTAssertEqual(single(structure)?.filename, "Prüfung.pdf")
    }

    func testEncodedWordFilenameIsLeftForMIME() {
        let structure = bodyStructure("(\"application\" \"pdf\" (\"name\" \"=?UTF-8?B?UHLDvGZ1bmcucGRm?=\") NIL NIL \"base64\" 10 NIL (\"attachment\" NIL) NIL NIL)")
        XCTAssertEqual(single(structure)?.filename, "=?UTF-8?B?UHLDvGZ1bmcucGRm?=")
        XCTAssertEqual(single(structure)?.dispositionParameters, [:])
    }

    func testTextAttachmentWithFilenameCountsAsAttachment() {
        let structure = bodyStructure("""
        ((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 20 1 NIL NIL NIL)(\"text\" \"csv\" (\"charset\" \"utf-8\" \"name\" \"export.csv\") NIL NIL \"base64\" 400 6 NIL (\"attachment\" (\"filename\" \"export.csv\")) NIL)(\"text\" \"plain\" (\"name\" \"notes.txt\") NIL NIL \"7bit\" 30 2 NIL NIL NIL) \"mixed\" (\"boundary\" \"z\") NIL NIL)
        """)
        XCTAssertEqual(structure?.attachmentParts.map(\.section), ["2", "3"])
        XCTAssertEqual(structure?.preferredTextPart()?.section, "1")
    }

    // MARK: Robustness

    func testNILEverywhere() {
        let part = single(bodyStructure("(NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL NIL)"))
        XCTAssertEqual(part?.mimeType, "application/octet-stream")
        XCTAssertEqual(part?.encoding, "7bit")
        XCTAssertEqual(part?.size, 0)
        XCTAssertEqual(part?.parameters, [:])
        let multi = multipart(bodyStructure("((\"text\" \"plain\" NIL NIL NIL NIL NIL NIL) NIL NIL NIL NIL NIL)"))
        XCTAssertEqual(multi?.subtype, "mixed")
        XCTAssertEqual(multi?.parts.count, 1)
    }

    func testOddSpacingAndCase() {
        let structure = bodyStructure("( ( \"Text\"  \"Plain\" ( \"Charset\" \"utf-8\" )  NIL NIL \"7Bit\" 10 1 )  ( \"TEXT\" \"HTML\" NIL NIL NIL \"7bit\" 20 1 ) \"Alternative\" )")
        XCTAssertEqual(multipart(structure)?.subtype, "alternative")
        XCTAssertEqual(structure?.preferredTextPart()?.part.charset, "utf-8")
        XCTAssertEqual(structure?.preferredTextPart()?.part.encoding, "7bit")
    }

    func testTruncatedAndMissingFields() {
        XCTAssertEqual(single(bodyStructure("(\"text\" \"plain\")"))?.mimeType, "text/plain")
        XCTAssertEqual(single(bodyStructure("(\"image\")"))?.mimeType, "image/octet-stream")
        // Numbers sent as strings, sizes that aren't numbers.
        let sloppy = single(bodyStructure("(\"text\" \"plain\" NIL NIL NIL \"7bit\" \"123\" \"abc\")"))
        XCTAssertEqual(sloppy?.size, 123)
        XCTAssertNil(sloppy?.lines)
        // Odd number of parameter items.
        XCTAssertEqual(single(bodyStructure("(\"text\" \"plain\" (\"charset\") NIL NIL \"7bit\" 1 1)"))?.parameters, [:])
        // Atoms where strings belong (some servers).
        XCTAssertEqual(single(bodyStructure("(TEXT PLAIN (CHARSET UTF-8) NIL NIL 8BIT 99 3)"))?.charset, "utf-8")
        // An empty structure isn't one.
        XCTAssertNil(fetchResponse("* 1 FETCH (BODYSTRUCTURE ())\r\n")?.bodyStructure)
    }

    func testExtensionDataBeyondTheSpecIsIgnored() {
        let structure = bodyStructure("(\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 10 1 \"md5sum\" (\"inline\" NIL) (\"en\" \"de\") \"http://example.com/loc\" (\"future\" (1 2 3)) 42 FUTURE)")
        let part = single(structure)
        XCTAssertEqual(part?.md5, "md5sum")
        XCTAssertEqual(part?.disposition, "inline")
        XCTAssertEqual(part?.language, ["en", "de"])
        XCTAssertEqual(part?.location, "http://example.com/loc")
    }

    func testLiteralInsideBodyStructure() {
        let name = "Bericht \"Q3\" (final).pdf"
        let text = "* 1 FETCH (UID 1 BODYSTRUCTURE (\"application\" \"pdf\" (\"name\" " + literal(name) + ") NIL NIL \"base64\" 10 NIL NIL NIL NIL))\r\n"
        XCTAssertEqual(single(fetchResponse(text)?.bodyStructure)?.filename, name)
    }

    func testDeepNestingDoesNotOverflow() {
        let depth = 2000
        let structure = String(repeating: "(", count: depth) + "\"text\" \"plain\" NIL NIL NIL \"7bit\" 1 1" + String(repeating: ")", count: depth)
        let response = fetchResponse("* 1 FETCH (UID 1 BODYSTRUCTURE \(structure) FLAGS (\\Seen))\r\n")
        XCTAssertEqual(response?.uid, 1)
        // Whatever comes back must be finite and not crash.
        _ = response?.bodyStructure?.leafParts
    }
}
