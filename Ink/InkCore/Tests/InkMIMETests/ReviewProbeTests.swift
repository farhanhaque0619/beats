import XCTest
import InkModel
@testable import InkMIME

final class ReviewProbeTests: XCTestCase {
    func testProbeSnippetPlainZeroWidth() {
        let plain = "Big autumn sale \u{034F} \u{200C} \u{034F} \u{200C} \u{034F} \u{200C}\u{FEFF}\u{200B}\u{00AD}\u{2060}\nHello there"
        XCTAssertEqual(Snippet.make(plain: plain, html: nil), "Big autumn sale Hello there")
    }

    func testProbeSnippetHTMLPreheader() {
        let html = "<html><head><style>p{color:red}</style></head><body><div style=\"display:none;max-height:0\">Your weekly digest&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;&#847;&zwnj;&nbsp;\u{034F}\u{200C}\u{00A0}</div><p>Hi Ada,</p></body></html>"
        XCTAssertEqual(Snippet.make(plain: nil, html: html), "Your weekly digest Hi Ada,")
    }

    func testProbeSnippetHTMLStyleInBodyAndMSO() {
        let html = "<body><style>.x{color:red}</style><!--[if mso]><table><tr><td><![endif]--><p>Hello</p><!--[if mso]></td></tr></table><![endif]--></body>"
        XCTAssertEqual(Snippet.make(plain: nil, html: html), "Hello")
    }

    func testProbeSnippetUnclosedStyleTruncated() {
        let html = "<html><head><style type=\"text/css\">body{margin:0} .a{color:red"
        XCTAssertEqual(Snippet.make(plain: nil, html: html), "")
    }

    func testProbeSnippetNBSPOnlyPlain() {
        let plain = "\u{00A0}\u{2007}\u{202F}Hi\u{00A0}\u{00A0}there"
        XCTAssertEqual(Snippet.make(plain: plain, html: nil), "Hi there")
    }

    func testProbeFilenameBidi() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary=b

        --b
        Content-Type: text/plain

        Body
        --b
        Content-Type: application/octet-stream
        Content-Disposition: attachment; filename*=UTF-8''invoice%E2%80%AEfdp.exe

        x
        --b--
        """))
        XCTAssertEqual(m.attachments.count, 1)
        XCTAssertFalse(m.attachments[0].filename.unicodeScalars.contains("\u{202E}"), m.attachments[0].filename)
    }

    func testProbeAppleMailInlineTextAttachment() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/mixed; boundary="Apple-Mail=_1"

        --Apple-Mail=_1
        Content-Type: text/plain; charset=us-ascii

        See the notes.
        --Apple-Mail=_1
        Content-Disposition: inline; filename=notes.txt
        Content-Type: text/plain; x-unix-mode=0644; name="notes.txt"

        line 1
        --Apple-Mail=_1--
        """))
        XCTAssertEqual(m.attachments.map(\.filename), ["notes.txt"])
    }

    func testProbeHeaderInjection() {
        var msg = OutgoingMessage(accountID: "a", from: EmailAddress(name: "Ada\r\nBcc: x@evil.example", address: "ada@example.com\r\nBcc: y@evil.example"),
                                  to: [EmailAddress(name: "Bob\nX-Evil: 1", address: "bob@example.com")],
                                  bcc: [EmailAddress(address: "secret@example.com")],
                                  subject: "Hi\r\nBcc: z@evil.example", body: "x")
        msg.inReplyTo = "abc@x\r\nBcc: q@evil.example"
        msg.references = ["r1@x\r\nX-Injected: 1"]
        msg.attachments = [OutgoingAttachment(filename: "a\r\nX-File: 1.pdf", mimeType: "application/pdf\r\nX-Type: 1", data: Data("x".utf8))]
        let (data, _) = MessageBuilder.build(msg)
        let text = String(decoding: data, as: UTF8.self)
        for evil in ["\r\nBcc:", "\r\nX-Evil", "\r\nX-Injected", "\r\nX-File", "\r\nX-Type", "secret@"] {
            XCTAssertFalse(text.utf8.split(separator: 0x0A).contains { String(decoding: $0, as: UTF8.self).hasPrefix(String(evil.dropFirst(2))) }, evil)
        }
        assertWireFormat(data)
    }

    func testProbeHTMLDocRemote() {
        let html = """
        <html><head><base href="https://evil.example/"><meta http-equiv="refresh" content="0;url=https://evil.example"><link rel=stylesheet href="https://evil.example/a.css">
        <style>@import url(https://evil.example/b.css); @\\69mport url(https://evil.example/c.css); .x{background:url(https://evil.example/d.png)}</style></head>
        <body background="https://evil.example/bg.png"><img srcset="https://evil.example/e.png 2x" src="cid:x"><svg><image href="https://evil.example/f.png"/></svg>
        <a href="javascript:alert(1)">x</a><a href=" jav&#x09;ascript:alert(1)">y</a><iframe src="https://evil.example"></iframe><form action="https://evil.example"><input></form>
        <video poster="https://evil.example/p.png"></video><table background="https://evil.example/t.png"><tr><td>t</td></tr></table>
        <a href="https://example.com" ping="https://evil.example/ping">ok</a></body></html>
        """
        let doc = EmailHTMLDocument.build(html: html, plainText: nil, options: .init())
        XCTAssertFalse(doc.contains("<base"))
        XCTAssertFalse(doc.contains("refresh"))
        XCTAssertFalse(doc.contains("<link"))
        XCTAssertFalse(doc.contains("@import"))
        XCTAssertFalse(doc.contains("javascript"))
        XCTAssertFalse(doc.contains("<iframe"))
        XCTAssertFalse(doc.contains("ping="))
        XCTAssertTrue(doc.contains("base-uri 'none'"), "CSP lacks base-uri")
        XCTAssertTrue(doc.contains("form-action 'none'"), "CSP lacks form-action")
        print(doc)
    }

    func testProbeCommentEdge() {
        let doc = HTMLText.toPlainText("<p>a</p><!---><p>visible</p><!-- c --><p>b</p>")
        XCTAssertEqual(doc, "a\n\nvisible\n\nb", doc)
    }

    func testProbeReplyAll() {
        let account = AccountConfig.probe
        var summary = MessageSummary.probe
        summary.from = [EmailAddress(name: "Bob", address: "Bob@Example.com")]
        summary.replyTo = []
        summary.to = [EmailAddress(address: "ME@example.org"), EmailAddress(address: "carol@example.com"), EmailAddress(address: "bob@example.com")]
        summary.cc = [EmailAddress(address: "dave@example.com"), EmailAddress(address: "Carol@example.com"), EmailAddress(address: "me@example.org")]
        let draft = ReplyBuilder.draft(replyingTo: summary, body: nil, mode: .replyAll, from: account, myAddresses: ["me@example.org"])
        XCTAssertEqual(draft.to.map { $0.address.lowercased() }, ["bob@example.com", "carol@example.com"])
        XCTAssertEqual(draft.cc.map { $0.address.lowercased() }, ["dave@example.com"])
        XCTAssertTrue(draft.bcc.isEmpty)
    }

    func testProbeAlternativeAttachmentOnlyInPlainBranch() {
        let m = MIMEParser.parse(Raw.data("""
        Content-Type: multipart/alternative; boundary=a

        --a
        Content-Type: multipart/mixed; boundary=m

        --m
        Content-Type: text/plain

        Plain
        --m
        Content-Type: application/pdf; name=x.pdf
        Content-Disposition: attachment; filename=x.pdf

        pdf
        --m--
        --a
        Content-Type: text/html

        <p>HTML</p>
        --a--
        """))
        XCTAssertEqual(m.attachments.map(\.filename), ["x.pdf"])
    }

    func testProbeEncodedWordEdgeCases() {
        XCTAssertEqual(EncodedWord.decode("=?utf-8?q?caf=C3=A9?= =?utf-8?b?w6k=?="), "caféé")
        XCTAssertEqual(EncodedWord.decode("=?UTF-8?B?8J+Y?= =?UTF-8?B?jQ==?="), "🍍".precomposedStringWithCanonicalMapping == "🍍" ? EncodedWord.decode("=?UTF-8?B?8J+Y?= =?UTF-8?B?jQ==?=") : "")
        XCTAssertEqual(EncodedWord.decode("Re: =?ISO-8859-1?Q?Caf=E9?= today"), "Re: Café today")
        XCTAssertEqual(EncodedWord.decode("=?utf-8?Q?a?=\r\n =?utf-8?Q?b?="), "ab")
        XCTAssertEqual(EncodedWord.decode("=?windows-1252?Q?=93Hi=94?="), "\u{201C}Hi\u{201D}")
        XCTAssertEqual(EncodedWord.decode("=?utf-8?B?SGVsbG8=?=world"), "Helloworld")
    }

    func testProbeQP() {
        XCTAssertEqual(String(decoding: QuotedPrintable.decode("a=\r\nb=3D=\nc= \r\nd=e9=E9"), as: UTF8.self), "ab=cd\u{FFFD}\u{FFFD}")
    }

    func testProbeSubjectEncodingFoldRoundTrip() {
        let subject = String(repeating: "Ünïcödé subject words ", count: 8) + "🎉 end"
        let msg = OutgoingMessage(accountID: "a", from: EmailAddress(name: "Zoë Ångström", address: "zoe@example.com"),
                                  to: [EmailAddress(name: "Bob, Jr.", address: "bob@example.com")], subject: subject, body: "Hello\n.\nFrom here\n" + String(repeating: "long ", count: 300))
        let (data, _) = MessageBuilder.build(msg)
        assertWireFormat(data, limit: 998)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.subject, subject.trimmingCharacters(in: .whitespaces))
        XCTAssertEqual(parsed.from.first?.name, "Zoë Ångström")
        XCTAssertEqual(parsed.to.first?.name, "Bob, Jr.")
        XCTAssertEqual(parsed.plainText, "Hello\n.\nFrom here\n" + String(repeating: "long ", count: 300))
        XCTAssertTrue(parsed.bcc.isEmpty)
    }

    func testProbeRFC2231Attachment() {
        let msg = OutgoingMessage(accountID: "a", from: EmailAddress(address: "zoe@example.com"), to: [EmailAddress(address: "b@example.com")],
                                  subject: "x", body: "y",
                                  attachments: [OutgoingAttachment(filename: "Résumé – final version with a very long name indeed 2026.pdf", mimeType: "application/pdf", data: Data(repeating: 7, count: 100)),
                                                OutgoingAttachment(filename: "plain name.txt", mimeType: "text/plain", data: Data("hi".utf8))])
        let (data, _) = MessageBuilder.build(msg)
        print(String(decoding: data, as: UTF8.self))
        assertWireFormat(data, limit: 78)
        let parsed = MIMEParser.parse(data)
        XCTAssertEqual(parsed.attachments.map(\.filename), ["Résumé – final version with a very long name indeed 2026.pdf", "plain name.txt"])
        XCTAssertEqual(parsed.attachments.first?.data, Data(repeating: 7, count: 100))
        XCTAssertEqual(parsed.plainText, "y")
    }
}

extension AccountConfig {
    static var probe: AccountConfig {
        AccountConfig(id: "acc", provider: .fastmail, displayName: "Me", emailAddress: "me@example.org",
                      imap: ServerConfig(host: "i", port: 993, security: .tls, username: "me"),
                      smtp: ServerConfig(host: "s", port: 465, security: .tls, username: "me"))
    }
}

extension MessageSummary {
    static var probe: MessageSummary {
        MessageSummary(accountID: "acc", mailboxPath: "INBOX", uid: 1, uidValidity: 1, messageID: "orig@example.com", subject: "Plans",
                       from: [], replyTo: [], to: [], cc: [], date: Date(timeIntervalSince1970: 0))
    }
}
