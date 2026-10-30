import ReluxCore
import XCTest

/// Pins each panel's actions-overlay contents: the same rows, labels and shortcut hints in the
/// same order the four views used to build by hand.
final class PanelActionsTests: XCTestCase {
    private func labels(_ actions: [ActionDescriptor]) -> [String] {
        actions.map(\.label)
    }

    private func kinds(_ actions: [ActionDescriptor]) -> [ActionKind] {
        actions.map(\.kind)
    }

    // MARK: - Search overlay

    func testAppMenuIsLaunchRevealRemove() {
        let actions = PanelActions.search(kind: .app, hasCapturedOutput: false)
        XCTAssertEqual(labels(actions), ["Launch", "Show in Finder", "Remove from history"])
        XCTAssertEqual(kinds(actions), [.launch, .showInFinder, .removeFromHistory])
        XCTAssertEqual(actions.map(\.shortcut), ["⏎", "⌘⏎", nil])
    }

    func testSingleRowMenus() {
        XCTAssertEqual(labels(PanelActions.search(kind: .webSearch, hasCapturedOutput: false)), ["Search"])
        XCTAssertEqual(labels(PanelActions.search(kind: .translate, hasCapturedOutput: false)), ["Translate"])
        XCTAssertEqual(labels(PanelActions.search(kind: .calculator, hasCapturedOutput: false)), ["Copy"])
        XCTAssertEqual(labels(PanelActions.search(kind: .jwt, hasCapturedOutput: false)), ["Open"])
        XCTAssertEqual(labels(PanelActions.search(kind: .systemSettings, hasCapturedOutput: false)), ["Open"])
    }

    func testScriptMenuWithoutCapturedOutputRunsOrForgets() {
        let actions = PanelActions.search(kind: .script, hasCapturedOutput: false)
        XCTAssertEqual(labels(actions), ["Run", "Remove from history"])
        XCTAssertEqual(actions.map(\.shortcut), ["⏎", nil])
    }

    func testScriptMenuWithCapturedOutputOffersCopyRerunClear() {
        let actions = PanelActions.search(kind: .script, hasCapturedOutput: true)
        XCTAssertEqual(labels(actions), ["Copy output", "Re-run", "Clear"])
        XCTAssertEqual(kinds(actions), [.copyOutput, .rerun, .clearOutput])
        XCTAssertEqual(actions.map(\.shortcut), [nil, nil, nil])
    }

    // MARK: - Clipboard panel

    private let filters = [
        ClipboardFilterDescriptor(rawValue: "text", label: "Text", icon: "doc.plaintext"),
        ClipboardFilterDescriptor(rawValue: "image", label: "Images", icon: "photo"),
        ClipboardFilterDescriptor(rawValue: "richText", label: "Rich Text", icon: "doc.richtext"),
        ClipboardFilterDescriptor(rawValue: "color", label: "Colors", icon: "paintpalette"),
    ]

    func testClipboardMenuPastesCopiesDeletesPinsAndFilters() {
        let actions = PanelActions.clipboard(
            previousAppName: "Terminal",
            isRichText: false,
            isPinned: false,
            activeFilter: nil,
            filters: filters
        )
        XCTAssertEqual(labels(actions), [
            "Paste to Terminal",
            "Copy to Clipboard",
            "Delete",
            "Pin",
            "Show Text Only",
            "Show Images Only",
            "Show Rich Text Only",
            "Show Colors Only",
        ])
        XCTAssertEqual(actions.map(\.shortcut), ["⏎", "⌘⏎", "⌫", nil, nil, nil, nil, nil])
        XCTAssertEqual(kinds(actions).suffix(4), [
            .filter("text"), .filter("image"), .filter("richText"), .filter("color"),
        ])
    }

    func testClipboardMenuAddsFormattedPasteForRichText() {
        let actions = PanelActions.clipboard(
            previousAppName: "Notes",
            isRichText: true,
            isPinned: true,
            activeFilter: nil,
            filters: filters
        )
        XCTAssertEqual(labels(actions).prefix(5), [
            "Paste to Notes", "Copy to Clipboard", "Paste Formatted to Notes", "Delete", "Unpin",
        ])
        XCTAssertEqual(actions[2].shortcut, "⌘⇧⏎")
        XCTAssertEqual(actions[4].kind, .unpin)
    }

    func testClipboardMenuMarksTheActiveFilterAsClear() {
        let actions = PanelActions.clipboard(
            previousAppName: "Terminal",
            isRichText: false,
            isPinned: false,
            activeFilter: "image",
            filters: filters
        )
        XCTAssertEqual(Array(labels(actions).suffix(4)), [
            "Show Text Only", "Clear Filter", "Show Rich Text Only", "Show Colors Only",
        ])
    }

    // MARK: - Translate panel

    func testTranslateMenuIsRetranslateCopyDelete() {
        let actions = PanelActions.translate()
        XCTAssertEqual(labels(actions), ["Re-translate", "Copy to Clipboard", "Delete"])
        XCTAssertEqual(kinds(actions), [.retranslate, .copyToClipboard, .delete])
        XCTAssertEqual(actions.map(\.shortcut), ["⌘R", "⌘⏎", "⌫"])
    }

    // MARK: - JWT panel

    func testJWTMenuIsCopyPayloadThenCopyToken() {
        let actions = PanelActions.jwt()
        XCTAssertEqual(labels(actions), ["Copy Payload", "Copy Token"])
        XCTAssertEqual(kinds(actions), [.copyPayload, .copyToken])
        XCTAssertEqual(actions.map(\.shortcut), ["⏎", nil])
    }

    // MARK: - Shared invariants

    func testEveryDescriptorCarriesAnIconAndIsEnabled() {
        let all = [SearchItemKind.app, .webSearch, .script, .translate, .calculator, .jwt, .systemSettings]
            .flatMap { PanelActions.search(kind: $0, hasCapturedOutput: false) }
            + PanelActions.clipboard(
                previousAppName: "Terminal",
                isRichText: true,
                isPinned: true,
                activeFilter: nil,
                filters: filters
            )
            + PanelActions.translate()
            + PanelActions.jwt()
        XCTAssertFalse(all.isEmpty)
        XCTAssertTrue(all.allSatisfy { !$0.icon.isEmpty && $0.isEnabled })
    }
}
