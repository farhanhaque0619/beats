import Foundation
import InkModel
@testable import InkSync

/// Server transcripts for the scripted IMAPMailService tests, modelled on real sessions
/// (Dovecot 2.4, Gmail, GreenMail, Courier).
enum IMAPServiceTranscripts {
    typealias Step = ScriptedTransport.Step

    // MARK: Dovecot

    static let dovecotCapabilities = "IMAP4rev1 IMAP4rev2 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE SORT SORT=DISPLAY THREAD=REFERENCES THREAD=REFS THREAD=ORDEREDSUBJECT MULTIAPPEND URL-PARTIAL CATENATE UNSELECT CHILDREN NAMESPACE UIDPLUS LIST-EXTENDED I18NLEVEL=1 CONDSTORE QRESYNC ESEARCH ESORT SEARCHRES WITHIN CONTEXT=SEARCH LIST-STATUS BINARY MOVE REPLACE SNIPPET=FUZZY PREVIEW=FUZZY PREVIEW SPECIAL-USE STATUS=SIZE SAVEDATE COMPRESS=DEFLATE INPROGRESS NOTIFY LITERAL+ UTF8=ACCEPT"

    /// Greeting and AUTHENTICATE PLAIN (SASL-IR) for a Dovecot server, with `capabilities` after login.
    static func dovecotLogin(capabilities: String = dovecotCapabilities) -> [Step] {
        [
            .send("* OK [CAPABILITY IMAP4rev1 IMAP4rev2 SASL-IR LOGIN-REFERRALS ID ENABLE IDLE LITERAL+ AUTH=PLAIN] Dovecot ready.\r\n"),
            .expect("* AUTHENTICATE PLAIN", reply: "{TAG} OK [CAPABILITY \(capabilities)] Logged in\r\n"),
        ]
    }

    static let dovecotList = IMAPServiceFixtures.crlf("""
    * LIST (\\HasNoChildren) "/" INBOX
    * LIST (\\HasNoChildren \\Drafts) "/" Drafts
    * LIST (\\HasNoChildren \\Sent) "/" Sent
    * LIST (\\HasNoChildren \\Junk) "/" Junk
    * LIST (\\HasNoChildren \\Trash) "/" Trash
    * LIST (\\HasNoChildren \\Archive) "/" Archive
    * LIST (\\HasNoChildren) "/" "Clients/Acme"

    """)

    static func listStep(_ list: String = dovecotList, extended: Bool = true) -> Step {
        .expect(extended ? "* LIST \"\" \"*\" RETURN (SPECIAL-USE)" : "* LIST \"\" \"*\"",
                reply: list + "{TAG} OK List completed (0.001 + 0.000 secs).\r\n")
    }

    static func dovecotSelect(_ mailbox: String = "INBOX", exists: Int, uidValidity: UInt32 = 1792470281, uidNext: UInt32,
                              modSeq: UInt64? = nil, condstore: Bool = true) -> Step {
        var lines = """
        * FLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft)
        * OK [PERMANENTFLAGS (\\Answered \\Flagged \\Deleted \\Seen \\Draft \\*)] Flags permitted.
        * \(exists) EXISTS
        * 0 RECENT
        * OK [UIDVALIDITY \(uidValidity)] UIDs valid
        * OK [UIDNEXT \(uidNext)] Predicted next UID

        """
        if let modSeq { lines += "* OK [HIGHESTMODSEQ \(modSeq)] Highest\n" }
        let quoted = mailbox == "INBOX" ? mailbox : "\"\(mailbox)\""
        return .expect("* SELECT \(quoted)\(condstore ? " (CONDSTORE)" : "")",
                       reply: IMAPServiceFixtures.crlf(lines) + "{TAG} OK [READ-WRITE] Select completed (0.002 + 0.000 secs).\r\n")
    }

    // MARK: GreenMail

    static let greenMailCapabilities = "IMAP4rev1 LITERAL+ UIDPLUS SORT IDLE MOVE QUOTA"

    static func greenMailLogin() -> [Step] {
        [
            .send("* OK IMAP4rev1 Server GreenMail v2.1.0 ready\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(greenMailCapabilities)\r\n{TAG} OK CAPABILITY completed.\r\n"),
            .expect("* LOGIN", reply: "{TAG} OK LOGIN completed.\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(greenMailCapabilities)\r\n{TAG} OK CAPABILITY completed.\r\n"),
        ]
    }

    static func greenMailSelect(_ mailbox: String = "INBOX", exists: Int, uidValidity: UInt32 = 1792471486, uidNext: UInt32) -> Step {
        .expect("* SELECT \(mailbox)", reply: IMAPServiceFixtures.crlf("""
        * FLAGS (\\Answered \\Deleted \\Draft \\Flagged \\Seen)
        * \(exists) EXISTS
        * 0 RECENT
        * OK [UIDVALIDITY \(uidValidity)]
        * OK [UIDNEXT \(uidNext)]
        * OK [PERMANENTFLAGS (\\Answered \\Deleted \\Draft \\Flagged \\Seen \\*)]

        """) + "{TAG} OK [READ-WRITE] SELECT completed.\r\n")
    }

    // MARK: Messages

    /// The start of the summary FETCH command the service sends.
    static let summaryItemsPrefix = "(UID FLAGS INTERNALDATE RFC822.SIZE ENVELOPE BODYSTRUCTURE BODY.PEEK[HEADER.FIELDS (REFERENCES IN-REPLY-TO LIST-UNSUBSCRIBE LIST-UNSUBSCRIBE-POST LIST-ID PRECEDENCE AUTO-SUBMITTED)]"

    static let plainStructure = "(\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"7bit\" 120 4 NIL NIL NIL NIL)"
    static let alternativeStructure = "((\"text\" \"plain\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 1840 47 NIL NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"utf-8\") NIL NIL \"quoted-printable\" 45120 812 NIL NIL NIL NIL) \"alternative\" (\"boundary\" \"----=_Part_123\") NIL NIL NIL)"
    static let mixedStructure = "(((\"text\" \"plain\" (\"charset\" \"us-ascii\") NIL NIL \"7bit\" 220 6 NIL NIL NIL NIL)(\"text\" \"html\" (\"charset\" \"us-ascii\") NIL NIL \"7bit\" 900 18 NIL NIL NIL NIL) \"alternative\" (\"boundary\" \"alt\") NIL NIL NIL)(\"application\" \"pdf\" (\"name\" \"invoice.pdf\") NIL NIL \"base64\" 52000 NIL (\"attachment\" (\"filename\" \"invoice.pdf\")) NIL NIL) \"mixed\" (\"boundary\" \"mix\") NIL NIL NIL)"

    struct Gmail {
        var threadID: UInt64
        var messageID: UInt64
        var labels: String = "(\"\\\\Inbox\")"
    }

    /// One `* n FETCH (…)` answer to the summary items.
    static func summary(seq: Int, uid: UInt32, flags: String = "", subject: String, fromName: String = "Grace Hopper",
                        fromAddress: (String, String) = ("grace", "example.com"), to: (String, String) = ("ada", "example.com"),
                        date: String = "Mon, 19 Oct 2026 09:00:00 +0000", internalDate: String = "19-Oct-2026 09:00:05 +0000",
                        messageID: String, structure: String = plainStructure, headers: [String] = [], gmail: Gmail? = nil,
                        size: Int = 2048) -> String {
        var parts: [String] = []
        if let gmail { parts.append("X-GM-THRID \(gmail.threadID) X-GM-MSGID \(gmail.messageID) X-GM-LABELS \(gmail.labels)") }
        parts.append("UID \(uid) FLAGS (\(flags)) INTERNALDATE \"\(internalDate)\" RFC822.SIZE \(size)")
        let from = "((\"\(fromName)\" NIL \"\(fromAddress.0)\" \"\(fromAddress.1)\"))"
        parts.append("ENVELOPE (\"\(date)\" \"\(subject)\" \(from) \(from) \(from) ((NIL NIL \"\(to.0)\" \"\(to.1)\")) NIL NIL NIL \"<\(messageID)>\")")
        parts.append("BODYSTRUCTURE \(structure)")
        parts.append(IMAPServiceFixtures.headerFields(headers))
        return "* \(seq) FETCH (" + parts.joined(separator: " ") + ")\r\n"
    }

    /// A snippet answer: `* n FETCH (UID u BODY[section]<0> {len}\r\n text)`.
    static func snippet(seq: Int, uid: UInt32, section: String = "1", text: String) -> String {
        "* \(seq) FETCH (UID \(uid) BODY[\(section)]<0> \(IMAPServiceFixtures.literal(text)))\r\n"
    }

    static func ok(_ text: String = "Fetch completed (0.001 + 0.000 secs).") -> String { "{TAG} OK \(text)\r\n" }

    static let logoutStep = Step.expect("* LOGOUT", reply: "* BYE Logging out\r\n{TAG} OK Logout completed.\r\n")

    // MARK: Gmail

    static let gmailPreAuthCapabilities = "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 XYZZY SASL-IR AUTH=XOAUTH2 AUTH=PLAIN AUTH=PLAIN-CLIENTTOKEN AUTH=OAUTHBEARER AUTH=XOAUTH"
    static let gmailCapabilities = "IMAP4rev1 UNSELECT IDLE NAMESPACE QUOTA ID XLIST CHILDREN X-GM-EXT-1 UIDPLUS COMPRESS=DEFLATE ENABLE MOVE CONDSTORE ESEARCH UTF8=ACCEPT LIST-EXTENDED LIST-STATUS LITERAL- SPECIAL-USE APPENDLIMIT=35651584"

    static func xoauth2(_ user: String, _ token: String) -> String {
        Data("user=\(user)\u{1}auth=Bearer \(token)\u{1}\u{1}".utf8).base64EncodedString()
    }

    static func gmailLogin(user: String = "ada@gmail.com", token: String = "ya29.a0AfB_token") -> [Step] {
        [
            .send("* OK Gimap ready for requests from 203.0.113.5 f1mb123456789abc\r\n"),
            .expect("* CAPABILITY", reply: "* CAPABILITY \(gmailPreAuthCapabilities)\r\n{TAG} OK Thats all she wrote! f1mb123456789abc\r\n"),
            .expect("* AUTHENTICATE XOAUTH2 \(xoauth2(user, token))",
                    reply: "{TAG} OK [CAPABILITY \(gmailCapabilities)] \(user) authenticated (Success)\r\n"),
        ]
    }

    static let gmailList = IMAPServiceFixtures.crlf("""
    * LIST (\\HasNoChildren) "/" "INBOX"
    * LIST (\\HasChildren \\Noselect) "/" "[Gmail]"
    * LIST (\\All \\HasNoChildren) "/" "[Gmail]/All Mail"
    * LIST (\\Drafts \\HasNoChildren) "/" "[Gmail]/Drafts"
    * LIST (\\HasNoChildren \\Important) "/" "[Gmail]/Important"
    * LIST (\\HasNoChildren \\Sent) "/" "[Gmail]/Sent Mail"
    * LIST (\\HasNoChildren \\Junk) "/" "[Gmail]/Spam"
    * LIST (\\Flagged \\HasNoChildren) "/" "[Gmail]/Starred"
    * LIST (\\HasNoChildren \\Trash) "/" "[Gmail]/Trash"
    * LIST (\\HasNoChildren) "/" "Receipts"

    """)

    static func gmailSelect(_ mailbox: String, exists: Int, uidNext: UInt32, modSeq: UInt64 = 4416219, uidValidity: UInt32 = 1) -> Step {
        let quoted = mailbox == "INBOX" ? mailbox : "\"\(mailbox)\""
        return .expect("* SELECT \(quoted) (CONDSTORE)", reply: IMAPServiceFixtures.crlf("""
        * FLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen $NotPhishing $Phishing)
        * OK [PERMANENTFLAGS (\\Answered \\Flagged \\Draft \\Deleted \\Seen $NotPhishing $Phishing \\*)] Flags permitted.
        * OK [UIDVALIDITY \(uidValidity)] UIDs valid.
        * \(exists) EXISTS
        * 0 RECENT
        * OK [UIDNEXT \(uidNext)] Predicted next UID.
        * OK [HIGHESTMODSEQ \(modSeq)]

        """) + "{TAG} OK [READ-WRITE] \(mailbox) selected. (Success)\r\n")
    }

    // MARK: SMTP

    static func smtpSession(from: String, recipients: [String], rcptReplies: [String]? = nil, auth: String = "AUTH PLAIN") -> [Step] {
        var steps: [Step] = [
            .send("220 smtp.example.com ESMTP Postfix (Debian/GNU)\r\n"),
            .expect("EHLO", reply: "250-smtp.example.com\r\n250-PIPELINING\r\n250-SIZE 52428800\r\n250-AUTH PLAIN LOGIN XOAUTH2\r\n250-ENHANCEDSTATUSCODES\r\n250 8BITMIME\r\n"),
            .expect(auth, reply: "235 2.7.0 Authentication successful\r\n"),
            .expect("MAIL FROM:<\(from)>", reply: "250 2.1.0 Ok\r\n"),
        ]
        for (index, recipient) in recipients.enumerated() {
            steps.append(.expect("RCPT TO:<\(recipient)>", reply: rcptReplies?[index] ?? "250 2.1.5 Ok\r\n"))
        }
        return steps
    }

    static let smtpData: [Step] = [
        .expect("DATA", reply: "354 End data with <CR><LF>.<CR><LF>\r\n"),
        .expect(".", reply: "250 2.0.0 Ok: queued as 4QZ1X25ZbKz9sWq\r\n"),
        .expect("QUIT", reply: "221 2.0.0 Bye\r\n"),
    ]
}
