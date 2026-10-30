import ReluxCore
import XCTest

final class ResultSelectionTests: XCTestCase {
    private func item(_ id: String, _ kind: SearchItemKind = .app) -> SearchItem {
        SearchItem(id: id, title: id, subtitle: "", icon: "", kind: kind, meta: [:])
    }

    // MARK: - index(of:in:)

    func testIndexFindsPresentItem() {
        let items = [item("a1"), item("a2"), item("a3")]
        XCTAssertEqual(ResultSelection.index(of: "a2", in: items), 1)
    }

    func testIndexNilForAbsentItem() {
        XCTAssertNil(ResultSelection.index(of: "gone", in: [item("a1"), item("a2")]))
    }

    func testIndexNilForNilSelection() {
        XCTAssertNil(ResultSelection.index(of: nil, in: [item("a1")]))
        XCTAssertNil(ResultSelection.index(of: nil, in: []))
    }

    func testIndexNilForEmptyResults() {
        XCTAssertNil(ResultSelection.index(of: "a1", in: []))
    }

    func testIndexResolvesDuplicateIdsToFirstOccurrence() {
        let items = [item("dup"), item("other"), item("dup")]
        XCTAssertEqual(ResultSelection.index(of: "dup", in: items), 0)
    }

    // MARK: - restoredIndex(of:in:)

    func testRestoredIndexPrefersSurvivingSelection() {
        let items = [item("new-top"), item("kept"), item("other")]
        XCTAssertEqual(ResultSelection.restoredIndex(of: "kept", in: items), 1)
    }

    func testRestoredIndexFallsBackToZeroWhenSelectionDisappears() {
        XCTAssertEqual(ResultSelection.restoredIndex(of: "gone", in: [item("a1")]), 0)
    }

    func testRestoredIndexFallsBackToZeroForNilAndEmpty() {
        XCTAssertEqual(ResultSelection.restoredIndex(of: nil, in: [item("a1"), item("a2")]), 0)
        XCTAssertEqual(ResultSelection.restoredIndex(of: "a1", in: []), 0)
    }

    func testRestoredIndexSurvivesRegroupingOfRealGroupingOutput() {
        // Display order is the grouped order, so restore must run against that same array.
        let ungrouped = [item("s1", .script), item("a1", .app), item("w1", .webSearch), item("s2", .script)]
        let grouped = ResultGrouping.groupByKind(ungrouped)
        XCTAssertEqual(grouped.map(\.id), ["s1", "s2", "a1", "w1"])
        XCTAssertEqual(ResultSelection.restoredIndex(of: "a1", in: grouped), 2)

        // The same ids in the ungrouped order would give a different index; the grouped array wins.
        XCTAssertEqual(ResultSelection.restoredIndex(of: "a1", in: ungrouped), 1)
    }

    func testRestoredIndexAfterSelectionRowDropsOut() {
        let before = [item("a1"), item("a2"), item("a3")]
        let selected = ResultSelection.restoredIndex(of: "a3", in: before)
        XCTAssertEqual(selected, 2)

        let after = [item("a1"), item("a2")]
        XCTAssertEqual(ResultSelection.restoredIndex(of: before[selected].id, in: after), 0)
    }

    // MARK: - advanced(_:count:)

    func testAdvancedMovesForward() {
        XCTAssertEqual(ResultSelection.advanced(0, count: 3), 1)
        XCTAssertEqual(ResultSelection.advanced(1, count: 3), 2)
    }

    func testAdvancedWrapsPastTheEnd() {
        XCTAssertEqual(ResultSelection.advanced(2, count: 3), 0)
        XCTAssertEqual(ResultSelection.advanced(0, count: 1), 0)
    }

    func testAdvancedHandlesEmptyAndOutOfRange() {
        XCTAssertEqual(ResultSelection.advanced(0, count: 0), 0)
        XCTAssertEqual(ResultSelection.advanced(7, count: 3), 0)
        XCTAssertEqual(ResultSelection.advanced(-1, count: 3), 0)
    }

    // MARK: - retreated(_:count:)

    func testRetreatedMovesBackward() {
        XCTAssertEqual(ResultSelection.retreated(2, count: 3), 1)
        XCTAssertEqual(ResultSelection.retreated(1, count: 3), 0)
    }

    func testRetreatedWrapsPastTheStart() {
        XCTAssertEqual(ResultSelection.retreated(0, count: 3), 2)
        XCTAssertEqual(ResultSelection.retreated(0, count: 1), 0)
    }

    func testRetreatedHandlesEmptyAndOutOfRange() {
        XCTAssertEqual(ResultSelection.retreated(0, count: 0), 0)
        XCTAssertEqual(ResultSelection.retreated(7, count: 3), 0)
        XCTAssertEqual(ResultSelection.retreated(-1, count: 3), 0)
    }

    // MARK: - rowIndex(forCommandKey:rowCount:)

    func testCommandKeyMapsOneBasedCapsToZeroBasedRows() {
        XCTAssertEqual(ResultSelection.rowIndex(forCommandKey: 1, rowCount: 5), 0)
        XCTAssertEqual(ResultSelection.rowIndex(forCommandKey: 5, rowCount: 5), 4)
        XCTAssertEqual(ResultSelection.rowIndex(forCommandKey: 9, rowCount: 9), 8)
    }

    func testCommandKeyIsNilBeyondLastRow() {
        XCTAssertNil(ResultSelection.rowIndex(forCommandKey: 3, rowCount: 2))
        XCTAssertNil(ResultSelection.rowIndex(forCommandKey: 1, rowCount: 0))
    }

    func testCommandKeyIsNilOutsideOneThroughNine() {
        XCTAssertNil(ResultSelection.rowIndex(forCommandKey: 0, rowCount: 20))
        XCTAssertNil(ResultSelection.rowIndex(forCommandKey: 10, rowCount: 20))
        XCTAssertNil(ResultSelection.rowIndex(forCommandKey: -1, rowCount: 20))
    }
}
