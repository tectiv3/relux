import ReluxCore
import XCTest

final class ResultGroupingTests: XCTestCase {
    private func item(_ id: String, _ kind: SearchItemKind) -> SearchItem {
        SearchItem(id: id, title: id, subtitle: "", icon: "", kind: kind, meta: [:])
    }

    func testEmptyInput() {
        XCTAssertTrue(ResultGrouping.groupByKind([]).isEmpty)
    }

    func testKindsAppearInFirstSeenOrderAndItemsStayStable() {
        let items = [
            item("s1", .script),
            item("a1", .app),
            item("s2", .script),
            item("j1", .jwt),
            item("a2", .app),
        ]
        XCTAssertEqual(ResultGrouping.groupByKind(items).map(\.id), ["s1", "s2", "a1", "a2", "j1"])
    }

    func testEveryKindIsBucketable() {
        let kinds: [SearchItemKind] = [
            .app, .webSearch, .script, .translate, .calculator, .jwt, .systemSettings,
        ]
        let items = kinds.reversed().map { item(String(describing: $0), $0) }
        let grouped = ResultGrouping.groupByKind(items)
        XCTAssertEqual(grouped.count, kinds.count)
        XCTAssertEqual(grouped.map(\.kind), Array(kinds.reversed()))
    }

    func testSingleKindInputIsUnchanged() {
        let items = [item("a1", .app), item("a2", .app), item("a3", .app)]
        XCTAssertEqual(ResultGrouping.groupByKind(items).map(\.id), ["a1", "a2", "a3"])
    }

    func testAlreadyGroupedInputIsUnchanged() {
        let items = [item("a1", .app), item("w1", .webSearch), item("s1", .script)]
        XCTAssertEqual(ResultGrouping.groupByKind(items).map(\.id), ["a1", "w1", "s1"])
    }
}
