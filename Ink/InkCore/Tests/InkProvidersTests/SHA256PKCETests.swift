import Foundation
import XCTest
@testable import InkProviders

final class SHA256Tests: XCTestCase {
    private func hex(_ string: String) -> String { InkSHA256.hexDigest(Array(string.utf8)) }

    /// FIPS 180-2 / NIST CAVS example vectors.
    func testNISTVectors() {
        XCTAssertEqual(hex(""), "e3b0c44298fc1c149afbf4c8996fb92427ae41e4649b934ca495991b7852b855")
        XCTAssertEqual(hex("abc"), "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad")
        XCTAssertEqual(hex("abcdbcdecdefdefgefghfghighijhijkijkljklmklmnlmnomnopnopq"),
                       "248d6a61d20638b8e5c026930c3e6039a33ce45964ff2167f6ecedd419db06c1")
        XCTAssertEqual(hex("abcdefghbcdefghicdefghijdefghijkefghijklfghijklmghijklmnhijklmnoijklmnopjklmnopqklmnopqrlmnopqrsmnopqrstnopqrstu"),
                       "cf5b16a778af8380036ce59e7b0492370b249b11e8f07a51afac45037afee9d1")
    }

    func testOneMillionAs() {
        let million = [UInt8](repeating: UInt8(ascii: "a"), count: 1_000_000)
        XCTAssertEqual(InkSHA256.hexDigest(million), "cdc76e5c9914fb9281a1c7e284d73e67f1809a48a497200e046d39ccc7112cd0")
    }

    /// Lengths around the 55/56/64-byte padding boundaries (checked against coreutils sha256sum).
    func testPaddingBoundaries() {
        let expected: [Int: String] = [
            55: "9f4390f8d30c2dd92ec9f095b65e2b9ae9b0a925a5258e241c9f1e910f734318",
            56: "b35439a4ac6f0948b6d6f9e3c6af0f5f590ce20f1bde7090ef7970686ec6738a",
            63: "7d3e74a05d7db15bce4ad9ec0658ea98e3f06eeecf16b4c6fff2da457ddc2f34",
            64: "ffe054fe7ae0cb6dc65c3af9b61d5209f439851db43d0ba5997337df154668eb",
            65: "635361c48bb9eab14198e76ea8ab7f1a41685d6ad62aa9146d301d4f17eb0ae0",
            119: "31eba51c313a5c08226adf18d4a359cfdfd8d2e816b13f4af952f7ea6584dcfb",
            120: "2f3d335432c70b580af0e8e1b3674a7c020d683aa5f73aaaedfdc55af904c21c",
        ]
        for (length, digest) in expected {
            XCTAssertEqual(InkSHA256.hexDigest([UInt8](repeating: 0x61, count: length)), digest, "length \(length)")
        }
    }

    func testIncrementalMatchesOneShot() {
        let data = Array("The quick brown fox jumps over the lazy dog".utf8)
        XCTAssertEqual(InkSHA256.hexDigest(data), "d7a8fbb307d7809469ca9abcb0082e4f8d5651e46d3cdb762d02d0bf37c9e592")
        for split in [0, 1, 7, 31, 43] {
            var hasher = InkSHA256()
            hasher.update(data[..<split])
            hasher.update(data[split...])
            XCTAssertEqual(hasher.finalize(), InkSHA256.hash(data), "split at \(split)")
        }
        XCTAssertEqual(InkSHA256.hash("abc"), InkSHA256.hash(Data("abc".utf8)))
        XCTAssertEqual(InkSHA256.hash("abc").count, 32)
    }
}

final class Base64URLTests: XCTestCase {
    func testEncodeWithoutPadding() {
        XCTAssertEqual(Base64URL.encode([]), "")
        XCTAssertEqual(Base64URL.encode([0xFB]), "-w")
        XCTAssertEqual(Base64URL.encode([0xFB, 0xFF]), "-_8")
        XCTAssertEqual(Base64URL.encode([0xFB, 0xFF, 0xBF]), "-_-_")
        XCTAssertEqual(Base64URL.encode(Array("hello".utf8)), "aGVsbG8")
    }

    func testDecode() {
        XCTAssertEqual(Base64URL.decode("-_-_"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertEqual(Base64URL.decode("aGVsbG8"), Data("hello".utf8))
        XCTAssertEqual(Base64URL.decode("aGVsbG8="), Data("hello".utf8))
        XCTAssertEqual(Base64URL.decode("+/+/"), Data([0xFB, 0xFF, 0xBF]))
        XCTAssertNil(Base64URL.decode("a"))
        XCTAssertNil(Base64URL.decode("!!!!"))
        XCTAssertEqual(Base64URL.decode(""), Data())
    }
}

final class PKCETests: XCTestCase {
    /// RFC 7636 Appendix B.
    func testRFC7636AppendixB() {
        let pkce = PKCE(verifier: "dBjftJeZ4CVP-mB92K27uhbUJU1p1r_wW1gFWFOEjXk")
        XCTAssertEqual(pkce.challenge, "E9Melhoa2OwvFrEMTJguCHaoeK1t8URWbuGJSstw-cM")
        XCTAssertEqual(pkce.method, "S256")
        // The verifier in the RFC is the base64url of these 32 octets.
        let octets: [UInt8] = [116, 24, 223, 180, 151, 153, 224, 37, 79, 250, 96, 125, 216, 173, 187, 186,
                               22, 212, 37, 77, 105, 214, 191, 240, 91, 88, 5, 88, 83, 132, 141, 121]
        XCTAssertEqual(Base64URL.encode(octets), pkce.verifier)
    }

    func testGenerateMakesValidVerifiers() {
        let unreserved = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        var seen = Set<String>()
        for _ in 0..<20 {
            let pkce = PKCE.generate()
            XCTAssertEqual(pkce.verifier.count, 43)
            XCTAssertTrue(pkce.verifier.allSatisfy { unreserved.contains($0) })
            XCTAssertEqual(pkce.challenge, PKCE(verifier: pkce.verifier).challenge)
            XCTAssertEqual(pkce.challenge.count, 43)
            XCTAssertFalse(pkce.challenge.contains("="))
            seen.insert(pkce.verifier)
        }
        XCTAssertEqual(seen.count, 20)
    }

    func testDeterministicGenerator() {
        struct Counter: RandomNumberGenerator {
            var value: UInt64 = 0
            mutating func next() -> UInt64 { value &+= 0x9E37_79B9_7F4A_7C15; return value }
        }
        var a = Counter(), b = Counter()
        XCTAssertEqual(PKCE.generate(using: &a), PKCE.generate(using: &b))
    }

    func testRandomState() {
        let state = PKCE.randomState()
        XCTAssertEqual(state.count, 22)
        XCTAssertNotEqual(state, PKCE.randomState())
    }
}
