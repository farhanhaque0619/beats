import XCTest
@testable import InkIMAP

final class ModifiedUTF7Tests: XCTestCase {
    /// (decoded, wire) pairs: RFC 3501 §5.1.3's example plus folder names real servers send
    /// (Exchange in French/German/Russian, Gmail in Japanese, Dovecot with emoji).
    private let vectors: [(String, String)] = [
        ("~peter/mail/台北/日本語", "~peter/mail/&U,BTFw-/&ZeVnLIqe-"),
        ("Entwürfe", "Entw&APw-rfe"),
        ("Éléments envoyés", "&AMk-l&AOk-ments envoy&AOk-s"),
        ("Gelöschte Elemente", "Gel&APY-schte Elemente"),
        ("Отправленные", "&BB4EQgQ,BEAEMAQyBDsENQQ9BD0ESwQ1-"),
        ("Входящие/Работа", "&BBIERQQ+BDQETwRJBDgENQ-/&BCAEMAQxBD4EQgQw-"),
        ("受信トレイ", "&U9dP4TDIMOwwpA-"),
        ("📁 Projects", "&2D3cwQ- Projects"),
        ("☺!", "&Jjo-!"),
        ("Tom & Jerry", "Tom &- Jerry"),
        ("[Gmail]/All Mail", "[Gmail]/All Mail"),
        (" ünd", " &APw-nd"),
        ("", ""),
    ]

    func testEncodeVectors() {
        for (decoded, wire) in vectors {
            XCTAssertEqual(ModifiedUTF7.encode(decoded), wire, "encoding \(decoded)")
        }
    }

    func testDecodeVectors() {
        for (decoded, wire) in vectors {
            XCTAssertEqual(ModifiedUTF7.decode(wire), decoded, "decoding \(wire)")
        }
    }

    func testRFC3501Example() {
        XCTAssertEqual(ModifiedUTF7.decode("~peter/mail/&U,BTFw-/&ZeVnLIqe-"), "~peter/mail/台北/日本語")
        XCTAssertEqual(ModifiedUTF7.encode("~peter/mail/台北/日本語"), "~peter/mail/&U,BTFw-/&ZeVnLIqe-")
    }

    func testRoundTripsArbitraryText() {
        let samples = ["Ünïcödé/Ordner & Co", "日本語 + English", "emoji 🎉🎉 party", "tab\there", "a&b&c", "Ελληνικά", "עברית", "中文/子文件夹", "~&~"]
        for sample in samples {
            XCTAssertEqual(ModifiedUTF7.decode(ModifiedUTF7.encode(sample)), sample)
        }
    }

    func testEncodesControlCharactersAndTildeCorrectly() {
        // Only 0x20...0x7E stand for themselves; a tab is encoded.
        XCTAssertEqual(ModifiedUTF7.encode("a\tb"), "a&AAk-b")
        XCTAssertEqual(ModifiedUTF7.encode("~"), "~")
    }

    func testMalformedInputIsKeptRatherThanDropped() {
        // No terminating "-": the "&" stays literal.
        XCTAssertEqual(ModifiedUTF7.decode("Broken &U,BT"), "Broken &U,BT")
        // Illegal base64 character inside.
        XCTAssertEqual(ModifiedUTF7.decode("x&AB*C-y"), "x&AB*C-y")
        // Odd number of bytes (not whole UTF-16 units) is kept as-is.
        XCTAssertEqual(ModifiedUTF7.decode("&AA-"), "&AA-")
        // Raw UTF-8 from a non-conforming server passes through.
        XCTAssertEqual(ModifiedUTF7.decode("Entwürfe"), "Entwürfe")
        // "&-" is a literal ampersand.
        XCTAssertEqual(ModifiedUTF7.decode("&-&-"), "&&")
    }

    func testDecodeLeavesPlainASCIIUntouched() {
        XCTAssertEqual(ModifiedUTF7.decode("INBOX.Sent Items"), "INBOX.Sent Items")
    }
}
