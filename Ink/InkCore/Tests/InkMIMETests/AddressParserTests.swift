import XCTest
import InkModel
@testable import InkMIME

final class AddressParserTests: XCTestCase {
    private func pairs(_ s: String) -> [String] {
        AddressParser.parseList(s).map { "\($0.name ?? "-")|\($0.address)" }
    }

    func testSimpleForms() {
        XCTAssertEqual(pairs("ada@example.com"), ["-|ada@example.com"])
        XCTAssertEqual(pairs("Ada Lovelace <ada@example.com>"), ["Ada Lovelace|ada@example.com"])
        XCTAssertEqual(pairs("<ada@example.com>"), ["-|ada@example.com"])
        XCTAssertEqual(pairs("  ada@example.com  "), ["-|ada@example.com"])
    }

    func testQuotedNames() {
        XCTAssertEqual(pairs(#""Lovelace, Ada" <ada@example.com>"#), ["Lovelace, Ada|ada@example.com"])
        XCTAssertEqual(pairs(#""Ada \"The Countess\" Lovelace" <ada@example.com>"#), [#"Ada "The Countess" Lovelace|ada@example.com"#])
        XCTAssertEqual(pairs(#"'Ada Lovelace' <ada@example.com>"#), ["Ada Lovelace|ada@example.com"])
        XCTAssertEqual(pairs(#""ada@example.com" <ada@example.com>"#), ["-|ada@example.com"])
    }

    func testList() {
        let list = pairs(#"Alex Rivera <alex@ink.example>, "Doe, Jane" <jane.doe@contoso.example>,bob@example.org"#)
        XCTAssertEqual(list, ["Alex Rivera|alex@ink.example", "Doe, Jane|jane.doe@contoso.example", "-|bob@example.org"])
    }

    func testUnquotedLastFirst() {
        // Outlook/Exchange sometimes forget the quotes.
        XCTAssertEqual(pairs("Smith, John <john.smith@contoso.example>, Doe, Jane <jane@contoso.example>"),
                       ["Smith, John|john.smith@contoso.example", "Doe, Jane|jane@contoso.example"])
    }

    func testComments() {
        XCTAssertEqual(pairs("ada@example.com (Ada Lovelace)"), ["Ada Lovelace|ada@example.com"])
        XCTAssertEqual(pairs("MAILER-DAEMON@mail.ink.example (Mail Delivery System)"), ["Mail Delivery System|MAILER-DAEMON@mail.ink.example"])
        XCTAssertEqual(pairs("Ada (work) <ada(at)@example.com>"), ["Ada|ada@example.com"])
        XCTAssertEqual(pairs("root (Cron Daemon)"), ["Cron Daemon|root"])
    }

    func testGroups() {
        XCTAssertEqual(pairs("undisclosed-recipients:;"), [])
        XCTAssertEqual(pairs("Undisclosed recipients:;"), [])
        XCTAssertEqual(pairs("Team: ada@example.com, Grace <grace@example.com>;, bob@example.org"),
                       ["-|ada@example.com", "Grace|grace@example.com", "-|bob@example.org"])
        XCTAssertEqual(pairs("A Group:Ed Jones <c@a.test>,joe@where.test,John <jdoe@one.test>;"),
                       ["Ed Jones|c@a.test", "-|joe@where.test", "John|jdoe@one.test"])
    }

    func testEncodedWordNames() {
        XCTAssertEqual(pairs("=?UTF-8?B?5bGx55SwIOWkqumDjg==?= <yamada@example.co.jp>"), ["山田 太郎|yamada@example.co.jp"])
        XCTAssertEqual(pairs("=?ISO-8859-1?Q?Keld_J=F8rn_Simonsen?= <keld@dkuug.dk>"), ["Keld Jørn Simonsen|keld@dkuug.dk"])
        // Encoded words inside quotes (not allowed, but common).
        XCTAssertEqual(pairs(#""=?UTF-8?Q?Ren=C3=A9_Dupont?=" <rene@example.fr>"#), ["René Dupont|rene@example.fr"])
        XCTAssertEqual(pairs("=?utf-8?Q?Zo=C3=AB?= =?utf-8?Q?_M=C3=BCller?= <zoe@example.de>"), ["Zoë Müller|zoe@example.de"])
        // The whole "Name <addr>" sent as one encoded word by a broken mailer.
        let whole = "=?UTF-8?B?" + Data("José García <jose@example.es>".utf8).base64EncodedString() + "?="
        XCTAssertEqual(pairs(whole), ["José García|jose@example.es"])
    }

    func testMissingBracketsAndJunk() {
        XCTAssertEqual(pairs("Ada Lovelace ada@example.com"), ["Ada Lovelace|ada@example.com"])
        XCTAssertEqual(pairs("Ada Lovelace <ada@example.com"), ["Ada Lovelace|ada@example.com"])
        XCTAssertEqual(pairs("Ada <ada@example.com>, Grace <grace@example.com"), ["Ada|ada@example.com", "Grace|grace@example.com"])
        XCTAssertEqual(pairs("<ada@example.com> trailing junk"), ["trailing junk|ada@example.com"])
        XCTAssertEqual(pairs("Ada <mailto:ada@example.com>"), ["Ada|ada@example.com"])
        XCTAssertEqual(pairs("ada @ example.com"), ["-|ada@example.com"])
        XCTAssertEqual(pairs("Ada <ada@example.com>,,, ;"), ["Ada|ada@example.com"])
        XCTAssertEqual(pairs("Ada <@relay.example:ada@example.com>"), ["Ada|ada@example.com"])
        XCTAssertEqual(pairs("Ada < ada@example.com >"), ["Ada|ada@example.com"])
    }

    func testDomainLiteralAndQuotedLocalPart() {
        XCTAssertEqual(pairs("postmaster@[192.0.2.1]"), ["-|postmaster@[192.0.2.1]"])
        XCTAssertEqual(pairs("Ops <ops@[IPv6:2001:db8::1]>"), ["Ops|ops@[IPv6:2001:db8::1]"])
        XCTAssertEqual(pairs(#"<"john smith"@example.com>"#), [#"-|"john smith"@example.com"#])
    }

    func testInternationalAddresses() {
        XCTAssertEqual(pairs("用户 <用户@例子.广告>"), ["用户|用户@例子.广告"])
        XCTAssertEqual(pairs("Zoë <zoë@example.com>"), ["Zoë|zoë@example.com"])
    }

    func testGarbage() {
        XCTAssertEqual(pairs(""), [])
        XCTAssertEqual(pairs("   "), [])
        XCTAssertEqual(pairs("<>"), [])
        XCTAssertEqual(pairs("\"unterminated <ada@example.com>"), [])
        XCTAssertEqual(pairs("Just A Name"), [])
        XCTAssertEqual(pairs(",,,"), [])
        XCTAssertEqual(pairs("(((("), [])
        XCTAssertEqual(pairs(String(repeating: "<", count: 1000)), [])
    }

    func testParseSingle() {
        XCTAssertEqual(AddressParser.parse("Ada <ada@example.com>, Grace <grace@example.com>")?.address, "ada@example.com")
        XCTAssertNil(AddressParser.parse(""))
    }
}

final class MessageIDParserTests: XCTestCase {
    func testLists() {
        XCTAssertEqual(MessageIDParser.parseList("<a@b> <c@d>"), ["a@b", "c@d"])
        XCTAssertEqual(MessageIDParser.parseList("<a@b>,<c@d>"), ["a@b", "c@d"])
        XCTAssertEqual(MessageIDParser.parseList("<a@b>\r\n\t<c@d>\r\n <e@f>"), ["a@b", "c@d", "e@f"])
        XCTAssertEqual(MessageIDParser.parseList("<CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com>"), ["CAJ8x=Qm3b5N7v+Tz1aK4pLw_Y2Zx9cR0eHf@mail.gmail.com"])
    }

    func testTolerance() {
        XCTAssertEqual(MessageIDParser.parseList("a@b"), ["a@b"])
        XCTAssertEqual(MessageIDParser.parseList("a@b c@d"), ["a@b", "c@d"])
        XCTAssertEqual(MessageIDParser.parseList("<a@b> (comment) <c@d>"), ["a@b", "c@d"])
        XCTAssertEqual(MessageIDParser.parseList("<a@b> <a@b> <c@d>"), ["a@b", "c@d"])
        XCTAssertEqual(MessageIDParser.parseList("<a@ b>"), ["a@b"])
        XCTAssertEqual(MessageIDParser.parseList("<a@b"), ["a@b"])
        XCTAssertEqual(MessageIDParser.parseList("<a@b> from Ada's message of \"Tue, 20 Oct 2026\""), ["a@b"])
        XCTAssertEqual(MessageIDParser.parseList("abc123"), ["abc123"])
        XCTAssertEqual(MessageIDParser.parseList(""), [])
        XCTAssertEqual(MessageIDParser.parseList("<>"), [])
        XCTAssertEqual(MessageIDParser.parseList("   "), [])
    }
}
