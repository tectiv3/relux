import ReluxCore
import XCTest

final class FuzzyMatchTests: XCTestCase {
    private func offsets(_ indices: [String.Index]?, in target: String) -> [Int]? {
        indices?.map { target.distance(from: target.startIndex, to: $0) }
    }

    func testExactMatchReturnsEveryCharacterIndex() {
        let target = "abc"
        XCTAssertTrue(FuzzyMatch.matches("abc", in: target))
        XCTAssertEqual(offsets(FuzzyMatch.matchedIndices(of: "abc", in: target), in: target), [0, 1, 2])
    }

    func testNonContiguousSubsequenceMatches() {
        let target = "axbxc"
        XCTAssertTrue(FuzzyMatch.matches("abc", in: target))
        XCTAssertEqual(offsets(FuzzyMatch.matchedIndices(of: "abc", in: target), in: target), [0, 2, 4])
    }

    /// The helper does not fold case; every current call site lowercases both sides first.
    func testCaseFoldingIsTheCallersResponsibility() {
        XCTAssertFalse(FuzzyMatch.matches("ABC", in: "abc"))
        XCTAssertTrue(FuzzyMatch.matches("AbC".lowercased(), in: "aXbXc".lowercased()))
    }

    func testEmptyPatternNeverMatches() {
        XCTAssertFalse(FuzzyMatch.matches("", in: "abc"))
        XCTAssertNil(FuzzyMatch.matchedIndices(of: "", in: "abc"))
        XCTAssertFalse(FuzzyMatch.matches("", in: ""))
    }

    func testNoMatchReturnsFalseAndNil() {
        XCTAssertFalse(FuzzyMatch.matches("abd", in: "abc"))
        XCTAssertNil(FuzzyMatch.matchedIndices(of: "abd", in: "abc"))
        XCTAssertFalse(FuzzyMatch.matches("abc", in: ""))
        XCTAssertNil(FuzzyMatch.matchedIndices(of: "abc", in: ""))
    }

    func testIndicesAreStrictlyIncreasing() {
        let target = "xaxbxcxaxb"
        let indices = offsets(FuzzyMatch.matchedIndices(of: "abc", in: target), in: target)
        XCTAssertEqual(indices?.count, 3)
        guard let indices, indices.count == 3 else {
            return XCTFail("expected three indices, got \(String(describing: indices))")
        }
        XCTAssertLessThan(indices[0], indices[1])
        XCTAssertLessThan(indices[1], indices[2])
    }

    func testTightestMatchWins() {
        let target = "aXab"
        // Anchor at 0 only reaches "b" at index 3 (span 4); anchor at 2 reaches it with span 2.
        XCTAssertEqual(offsets(FuzzyMatch.matchedIndices(of: "ab", in: target), in: target), [2, 3])
    }

    func testSpanLimitIsInclusive() {
        XCTAssertTrue(FuzzyMatch.matches("ab", in: "axxb", maxSpan: 4))
        XCTAssertFalse(FuzzyMatch.matches("ab", in: "axxxb", maxSpan: 4))
        XCTAssertNil(FuzzyMatch.matchedIndices(of: "ab", in: "axxxb", maxSpan: 4))
    }

    /// The clipboard filter and highlighter both pass `query.count * 2` as the span limit.
    func testClipboardSpanLimit() {
        XCTAssertTrue(FuzzyMatch.matches("abc", in: "axbxc", maxSpan: 6))
        XCTAssertFalse(FuzzyMatch.matches("abc", in: "axxxxbxxxxc", maxSpan: 6))
        XCTAssertTrue(FuzzyMatch.matches("abc", in: "axxxxbxxxxc"))
        XCTAssertEqual(
            offsets(FuzzyMatch.matchedIndices(of: "abc", in: "axxxxbxxxxc", maxSpan: 6), in: "axxxxbxxxxc"),
            nil
        )
    }
}
