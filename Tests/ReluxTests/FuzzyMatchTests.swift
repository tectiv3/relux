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

    // MARK: - Folding, initials, scoring

    private static let locale = Locale(identifier: "en_US_POSIX")

    func testFoldLowercasesAndStripsDiacritics() {
        XCTAssertEqual(FuzzyMatch.fold("Café", locale: Self.locale), "cafe")
        XCTAssertEqual(FuzzyMatch.fold("ÉCOLE", locale: Self.locale), "ecole")
        XCTAssertEqual(FuzzyMatch.fold("Plain", locale: Self.locale), "plain")
    }

    func testInitialsTakeWordStartsAndInnerCapitals() {
        XCTAssertEqual(FuzzyMatch.initials("Visual Studio Code"), "vsc")
        XCTAssertEqual(FuzzyMatch.initials("WebStorm"), "ws")
        XCTAssertEqual(FuzzyMatch.initials("Microsoft Remote Desktop"), "mrd")
        XCTAssertEqual(FuzzyMatch.initials("Xcode"), "x")
        XCTAssertEqual(FuzzyMatch.initials("7-Zip"), "7z")
    }

    func testTierOrderingIsMonotonic() {
        let name = "Visual Studio Code"
        // exact, name prefix, initials, word prefix, substring, subsequence
        let scores = ["visual studio code", "visual", "vsc", "studio", "isual", "vsd"]
            .compactMap { FuzzyMatch.score(query: $0, name: name, locale: Self.locale) }
        XCTAssertEqual(scores.count, 6)
        for (higher, lower) in zip(scores, scores.dropFirst()) {
            XCTAssertGreaterThan(higher, lower, "expected \(scores) to be strictly descending")
        }
        XCTAssertEqual(scores, [982, 882, 782, 682, 482, 236])
    }

    func testExactAndPrefixSubtractLengthPenalty() {
        XCTAssertEqual(FuzzyMatch.score(query: "code", name: "code", locale: Self.locale), 996)
        XCTAssertEqual(FuzzyMatch.score(query: "cod", name: "code", locale: Self.locale), 896)
    }

    func testLengthPenaltyIsCappedAtSixty() {
        let long = "q" + String(repeating: "x", count: 79)
        XCTAssertEqual(FuzzyMatch.score(query: "q", name: long, locale: Self.locale), 840)
        XCTAssertEqual(FuzzyMatch.score(query: "sw", name: "swift", locale: Self.locale), 895)
        XCTAssertEqual(FuzzyMatch.score(query: "sw", name: "swiftx", locale: Self.locale), 894)
    }

    func testSubsequenceScoreDropsWithGaps() {
        XCTAssertEqual(FuzzyMatch.score(query: "abc", name: "axbc", locale: Self.locale), 292)
        XCTAssertEqual(FuzzyMatch.score(query: "abc", name: "axxbc", locale: Self.locale), 284)
    }

    func testDiacriticQueryMatchesAccentedName() {
        XCTAssertEqual(FuzzyMatch.score(query: "cafe", name: "Café", locale: Self.locale), 996)
        XCTAssertEqual(FuzzyMatch.score(query: "CAFÉ", name: "cafe", locale: Self.locale), 996)
    }

    func testNoMatchIsNil() {
        XCTAssertNil(FuzzyMatch.score(query: "zzz", name: "Reminders", locale: Self.locale))
        XCTAssertNil(FuzzyMatch.score(query: "", name: "Reminders", locale: Self.locale))
        XCTAssertNil(FuzzyMatch.score(query: "rem", name: "", locale: Self.locale))
    }
}
