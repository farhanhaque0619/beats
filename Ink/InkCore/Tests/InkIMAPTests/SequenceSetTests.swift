import XCTest
@testable import InkIMAP

final class SequenceSetTests: XCTestCase {
    func testCompressesRuns() {
        XCTAssertEqual(IMAPSequenceSet([1, 2, 3, 4, 5, 9, 12, 13]).description, "1:5,9,12:13")
        XCTAssertEqual(IMAPSequenceSet([5, 1, 3, 2, 9]).description, "1:3,5,9")
        XCTAssertEqual(IMAPSequenceSet([7]).description, "7")
        XCTAssertEqual(IMAPSequenceSet([UInt32]()).description, "")
    }

    func testDeduplicatesAndDropsZero() {
        XCTAssertEqual(IMAPSequenceSet([3, 3, 0, 2, 2, 1]).description, "1:3")
        XCTAssertTrue(IMAPSequenceSet([0]).isEmpty)
    }

    func testHandlesUInt32Extremes() {
        XCTAssertEqual(IMAPSequenceSet([UInt32.max, UInt32.max - 1, 1]).description, "1,4294967294:4294967295")
    }

    func testRangesAndOpenEnded() {
        XCTAssertEqual(IMAPSequenceSet(100...200).description, "100:200")
        XCTAssertEqual(IMAPSequenceSet(5...5).description, "5")
        XCTAssertEqual(IMAPSequenceSet.from(4321).description, "4321:*")
        XCTAssertEqual(IMAPSequenceSet.all.description, "1:*")
        XCTAssertEqual(IMAPSequenceSet.last.description, "*")
        XCTAssertEqual(IMAPSequenceSet(42).description, "42")
        XCTAssertTrue(IMAPSequenceSet(0...0).isEmpty)
    }

    func testParsesWireForm() {
        let set = IMAPSequenceSet("1:5,9,12:*")
        XCTAssertEqual(set?.description, "1:5,9,12:*")
        XCTAssertEqual(set?.containsLast, true)
        XCTAssertEqual(IMAPSequenceSet("*:7")?.description, "7:*")
        XCTAssertEqual(IMAPSequenceSet("304,319:320")?.expanded(), [304, 319, 320])
        XCTAssertNil(IMAPSequenceSet(""))
        XCTAssertNil(IMAPSequenceSet("1:2:3"))
        XCTAssertNil(IMAPSequenceSet("abc"))
        XCTAssertNil(IMAPSequenceSet("1,,2"))
        XCTAssertNil(IMAPSequenceSet("99999999999"))
    }

    func testExpandedKeepsWireOrder() {
        // COPYUID pairs source and destination by position, so descending ranges stay descending.
        XCTAssertEqual(IMAPSequenceSet("3956:3958")?.expanded(), [3956, 3957, 3958])
        XCTAssertEqual(IMAPSequenceSet("5:3")?.expanded(), [5, 4, 3])
        XCTAssertEqual(IMAPSequenceSet("1:3,*")?.expanded(), [1, 2, 3])
    }

    func testExpandedIsBoundedForHostileRanges() {
        let huge = IMAPSequenceSet("1:4294967295")
        XCTAssertEqual(huge?.expanded(limit: 5), [1, 2, 3, 4, 5])
        XCTAssertEqual(huge?.count, 4_294_967_295)
        XCTAssertEqual(IMAPSequenceSet("4294967295:1")?.expanded(limit: 2), [4_294_967_295, 4_294_967_294])
    }

    func testCountAndContains() {
        let set = IMAPSequenceSet([1, 2, 3, 10])
        XCTAssertEqual(set.count, 4)
        XCTAssertTrue(set.contains(2))
        XCTAssertTrue(set.contains(10))
        XCTAssertFalse(set.contains(4))
        XCTAssertNil(IMAPSequenceSet.all.count)
        XCTAssertTrue(IMAPSequenceSet.from(100).contains(5000))
        XCTAssertFalse(IMAPSequenceSet.from(100).contains(99))
    }

    func testCompressionRoundTripsThroughParsing() {
        var generator = SeededGenerator(seed: 42)
        for _ in 0..<50 {
            let numbers = (0..<200).map { _ in UInt32.random(in: 1...400, using: &generator) }
            let set = IMAPSequenceSet(numbers)
            XCTAssertEqual(IMAPSequenceSet(set.description)?.expanded(), Array(Set(numbers)).sorted())
        }
    }
}
