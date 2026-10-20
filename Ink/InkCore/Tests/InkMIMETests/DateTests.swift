import XCTest
@testable import InkMIME

final class DateTests: XCTestCase {
    private let reference = Date.utc(2026, 10, 20, 9, 15, 30)

    func testStandardForms() {
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 11:15:30 +0200"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 02:15:30 -0700 (PDT)"), reference)
        XCTAssertEqual(RFC5322Date.parse("20 Oct 2026 09:15:30 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue,20 Oct 2026 09:15:30 +0000"), reference)
    }

    func testObsoleteZones() {
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 05:15:30 EDT"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 04:15:30 EST"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 02:15:30 PDT"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 01:15:30 PST"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 03:15:30 MDT"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 04:15:30 CDT"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 GMT"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 UT"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 UTC"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 Z"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 11:15:30 CEST"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 18:15:30 JST"), reference)
    }

    func testMilitaryZonesReadAsUTC() {
        // RFC 5322 §4.3: military zones other than Z are unreliable and treated as -0000.
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 A"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 y"), reference)
    }

    func testSloppyForms() {
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15 +0000"), Date.utc(2026, 10, 20, 9, 15))
        XCTAssertEqual(RFC5322Date.parse("20 Oct 26 09:15:30 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 99 09:15:30 +0000"), Date.utc(1999, 10, 20, 9, 15, 30))
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 126 09:15:30 +0000"), reference)   // three-digit year
        XCTAssertEqual(RFC5322Date.parse("Tuesday, 20 October 2026 09:15:30 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20-Oct-2026 09:15:30 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue Oct 20 09:15:30 2026"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 9:15:30 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 +02:00"), Date.utc(2026, 10, 20, 7, 15, 30))
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 11:15:30 GMT+0200"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30 +0000 (GMT Standard Time)"), reference)
        XCTAssertEqual(RFC5322Date.parse("(Tuesday) 20 (day) Oct 2026 09:15:30 (UTC)"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30.123 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 09:15:30"), reference)          // no zone: UTC
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 9:15:30 AM +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026 9:15:30 PM +0000"), Date.utc(2026, 10, 20, 21, 15, 30))
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Oct 2026"), Date.utc(2026, 10, 20))
        XCTAssertEqual(RFC5322Date.parse("Tue, 20 Okt 2026 09:15:30 +0000"), reference)  // German month
        XCTAssertEqual(RFC5322Date.parse("  Tue,  20   Oct   2026   09:15:30   +0000  "), reference)
    }

    func testISO8601() {
        XCTAssertEqual(RFC5322Date.parse("2026-10-20T09:15:30Z"), reference)
        XCTAssertEqual(RFC5322Date.parse("2026-10-20T11:15:30+02:00"), reference)
        XCTAssertEqual(RFC5322Date.parse("2026-10-20 09:15:30 +0000"), reference)
        XCTAssertEqual(RFC5322Date.parse("2026-10-20T09:15:30.500Z"), reference)
    }

    func testLeapSecondAndYearBoundaries() {
        XCTAssertEqual(RFC5322Date.parse("Thu, 31 Dec 2026 23:59:60 +0000"), Date.utc(2026, 12, 31, 23, 59, 59))
        XCTAssertEqual(RFC5322Date.parse("Thu, 1 Jan 1970 00:00:00 +0000"), Date(timeIntervalSince1970: 0))
        XCTAssertEqual(RFC5322Date.parse("Thu, 29 Feb 2024 12:00:00 +0000"), Date.utc(2024, 2, 29, 12))
        XCTAssertEqual(RFC5322Date.parse("Sat, 1 Jan 2000 00:30:00 +0100"), Date.utc(1999, 12, 31, 23, 30))
    }

    func testInvalid() {
        XCTAssertNil(RFC5322Date.parse(""))
        XCTAssertNil(RFC5322Date.parse("not a date"))
        XCTAssertNil(RFC5322Date.parse("Tue, 20 2026 09:15:30"))      // no month
        XCTAssertNil(RFC5322Date.parse("Tue, Oct 2026 09:15:30"))     // no day
        XCTAssertNil(RFC5322Date.parse("Tue, 32 Oct 2026 09:15:30"))
        XCTAssertNil(RFC5322Date.parse("Tue, 20 Oct 2026 25:15:30 +0000"))
        XCTAssertNil(RFC5322Date.parse("2026-13-40T00:00:00Z"))
    }

    func testFormat() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RFC5322Date.format(reference, timeZone: utc), "Tue, 20 Oct 2026 09:15:30 +0000")
        let berlin = TimeZone(secondsFromGMT: 7200)!
        XCTAssertEqual(RFC5322Date.format(reference, timeZone: berlin), "Tue, 20 Oct 2026 11:15:30 +0200")
        let newYork = TimeZone(secondsFromGMT: -4 * 3600)!
        XCTAssertEqual(RFC5322Date.format(reference, timeZone: newYork), "Tue, 20 Oct 2026 05:15:30 -0400")
        let india = TimeZone(secondsFromGMT: 19800)!
        XCTAssertEqual(RFC5322Date.format(reference, timeZone: india), "Tue, 20 Oct 2026 14:45:30 +0530")
        XCTAssertEqual(RFC5322Date.format(Date.utc(2027, 1, 3, 4, 5, 6), timeZone: utc), "Sun, 3 Jan 2027 04:05:06 +0000")
        XCTAssertEqual(RFC5322Date.format(Date(timeIntervalSince1970: -86400), timeZone: utc), "Wed, 31 Dec 1969 00:00:00 +0000")
    }

    func testFormatRoundTrip() {
        var rng = SplitMix64(seed: 42)
        for _ in 0..<500 {
            let seconds = TimeInterval(Int64.random(in: 0...4_102_444_800, using: &rng))
            let date = Date(timeIntervalSince1970: seconds)
            let offset = Int.random(in: -12...14, using: &rng) * 3600
            let formatted = RFC5322Date.format(date, timeZone: TimeZone(secondsFromGMT: offset)!)
            XCTAssertEqual(RFC5322Date.parse(formatted), date, formatted)
        }
        let now = Date(timeIntervalSince1970: 1_792_487_742)
        XCTAssertEqual(RFC5322Date.parse(RFC5322Date.format(now)), now)
    }
}
