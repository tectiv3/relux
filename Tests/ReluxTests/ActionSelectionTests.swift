import ReluxCore
import XCTest

final class ActionSelectionTests: XCTestCase {
    // MARK: - Open / close

    func testToggleOpensOnFirstRowAndResetsTheCursor() {
        var selection = ActionSelection()
        selection.toggle(isAvailable: true)
        XCTAssertTrue(selection.isOpen)
        XCTAssertEqual(selection.index, 0)

        selection.moveDown(count: 3)
        selection.close()
        selection.toggle(isAvailable: true)
        XCTAssertTrue(selection.isOpen)
        XCTAssertEqual(selection.index, 0, "Cmd+K always reopens on the first row")
    }

    func testToggleClosesAnOpenMenu() {
        var selection = ActionSelection()
        selection.toggle(isAvailable: true)
        selection.toggle(isAvailable: true)
        XCTAssertFalse(selection.isOpen)
    }

    func testToggleUnavailableLeavesTheMenuClosed() {
        var selection = ActionSelection()
        selection.toggle(isAvailable: false)
        XCTAssertFalse(selection.isOpen)
    }

    func testToggleUnavailableDoesNotCloseAnOpenMenu() {
        // A menu is only ever opened with rows, so this only pins the guard's shape.
        var selection = ActionSelection(isOpen: true)
        selection.toggle(isAvailable: false)
        XCTAssertTrue(selection.isOpen)
    }

    // MARK: - Forward movement

    func testMoveDownAdvances() {
        var selection = ActionSelection()
        XCTAssertTrue(selection.moveDown(count: 3))
        XCTAssertEqual(selection.index, 1)
        XCTAssertTrue(selection.moveDown(count: 3))
        XCTAssertEqual(selection.index, 2)
    }

    func testMoveDownWrapsPastTheLastRow() {
        var selection = ActionSelection()
        selection.moveDown(count: 3)
        selection.moveDown(count: 3)
        XCTAssertTrue(selection.moveDown(count: 3))
        XCTAssertEqual(selection.index, 0)
    }

    func testMoveDownOnASingleRowStaysPut() {
        var selection = ActionSelection()
        XCTAssertTrue(selection.moveDown(count: 1))
        XCTAssertEqual(selection.index, 0)
    }

    func testMoveDownOnAnEmptyMenuReportsNoMove() {
        var selection = ActionSelection()
        XCTAssertFalse(selection.moveDown(count: 0))
        XCTAssertEqual(selection.index, 0)
    }

    // MARK: - Backward movement

    func testMoveUpWrapsBeforeTheFirstRow() {
        var selection = ActionSelection()
        XCTAssertTrue(selection.moveUp(count: 3))
        XCTAssertEqual(selection.index, 2)
    }

    func testMoveUpOnASingleRowStaysPut() {
        var selection = ActionSelection()
        XCTAssertTrue(selection.moveUp(count: 1))
        XCTAssertEqual(selection.index, 0)
    }

    func testMoveUpOnAnEmptyMenuReportsNoMove() {
        var selection = ActionSelection()
        XCTAssertFalse(selection.moveUp(count: 0))
        XCTAssertEqual(selection.index, 0)
    }

    func testUpThenDownRoundTripsThroughTheWrap() {
        var selection = ActionSelection()
        selection.moveUp(count: 4)
        XCTAssertEqual(selection.index, 3)
        selection.moveDown(count: 4)
        XCTAssertEqual(selection.index, 0)
    }

    // MARK: - Activation

    func testActivationIndexReturnsTheCursorWhenInRange() {
        var selection = ActionSelection()
        selection.moveDown(count: 2)
        XCTAssertEqual(selection.activationIndex(count: 2), 1)
    }

    func testActivationIndexIsNilOutsideTheList() {
        XCTAssertNil(ActionSelection().activationIndex(count: 0))
        XCTAssertNil(ActionSelection(isOpen: true, index: 5).activationIndex(count: 2))
    }
}
