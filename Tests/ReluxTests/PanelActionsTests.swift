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

    /// The exact descriptor of every row in every panel, in order, including icon and the
    /// `isEnabled` default. `ActionOverlay` honours `descriptor.isEnabled` (it refuses to run a
    /// disabled row and will not highlight it), but no builder passes `isEnabled: false` — the
    /// initializer defaults it to true — so there is no disabled state to pin; the equality
    /// below pins the default instead.
    func testPanelActionSetsAreExactlyTheExpectedDescriptors() {
        XCTAssertEqual(
            PanelActions.search(kind: .app, hasCapturedOutput: false),
            [
                ActionDescriptor(kind: .launch, label: "Launch", icon: "arrow.up.forward.app", shortcut: "⏎"),
                ActionDescriptor(kind: .showInFinder, label: "Show in Finder", icon: "folder", shortcut: "⌘⏎"),
                ActionDescriptor(
                    kind: .removeFromHistory,
                    label: "Remove from history",
                    icon: "trash",
                    shortcut: nil
                ),
            ]
        )
        XCTAssertEqual(
            PanelActions.search(kind: .script, hasCapturedOutput: false),
            [
                ActionDescriptor(kind: .run, label: "Run", icon: "play.fill", shortcut: "⏎"),
                ActionDescriptor(
                    kind: .removeFromHistory,
                    label: "Remove from history",
                    icon: "trash",
                    shortcut: nil
                ),
            ]
        )
        XCTAssertEqual(
            PanelActions.search(kind: .script, hasCapturedOutput: true),
            [
                ActionDescriptor(kind: .copyOutput, label: "Copy output", icon: "doc.on.clipboard", shortcut: nil),
                ActionDescriptor(kind: .rerun, label: "Re-run", icon: "arrow.clockwise", shortcut: nil),
                ActionDescriptor(kind: .clearOutput, label: "Clear", icon: "xmark", shortcut: nil),
            ]
        )
        XCTAssertEqual(
            [SearchItemKind.webSearch, .translate, .calculator, .jwt, .systemSettings]
                .flatMap { PanelActions.search(kind: $0, hasCapturedOutput: false) },
            [
                ActionDescriptor(kind: .search, label: "Search", icon: "magnifyingglass", shortcut: "⏎"),
                ActionDescriptor(kind: .translate, label: "Translate", icon: "character.book.closed", shortcut: "⏎"),
                ActionDescriptor(kind: .copy, label: "Copy", icon: "doc.on.clipboard", shortcut: "⏎"),
                ActionDescriptor(kind: .open, label: "Open", icon: "key.viewfinder", shortcut: "⏎"),
                ActionDescriptor(kind: .open, label: "Open", icon: "gear", shortcut: "⏎"),
            ]
        )
        XCTAssertEqual(
            PanelActions.clipboard(
                previousAppName: "Terminal",
                isRichText: true,
                isPinned: false,
                activeFilter: "image",
                filters: filters
            ),
            [
                ActionDescriptor(
                    kind: .paste,
                    label: "Paste to Terminal",
                    icon: "doc.on.clipboard.fill",
                    shortcut: "⏎"
                ),
                ActionDescriptor(
                    kind: .copyToClipboard,
                    label: "Copy to Clipboard",
                    icon: "doc.on.clipboard",
                    shortcut: "⌘⏎"
                ),
                ActionDescriptor(
                    kind: .pasteFormatted,
                    label: "Paste Formatted to Terminal",
                    icon: "textformat",
                    shortcut: "⌘⇧⏎"
                ),
                ActionDescriptor(kind: .delete, label: "Delete", icon: "trash", shortcut: "⌫"),
                ActionDescriptor(kind: .pin, label: "Pin", icon: "pin", shortcut: nil),
                ActionDescriptor(kind: .filter("text"), label: "Show Text Only", icon: "doc.plaintext", shortcut: nil),
                ActionDescriptor(kind: .filter("image"), label: "Clear Filter", icon: "photo", shortcut: nil),
                ActionDescriptor(
                    kind: .filter("richText"),
                    label: "Show Rich Text Only",
                    icon: "doc.richtext",
                    shortcut: nil
                ),
                ActionDescriptor(
                    kind: .filter("color"),
                    label: "Show Colors Only",
                    icon: "paintpalette",
                    shortcut: nil
                ),
            ]
        )
        XCTAssertEqual(
            PanelActions.translate(),
            [
                ActionDescriptor(kind: .retranslate, label: "Re-translate", icon: "arrow.clockwise", shortcut: "⌘R"),
                ActionDescriptor(
                    kind: .copyToClipboard,
                    label: "Copy to Clipboard",
                    icon: "doc.on.clipboard",
                    shortcut: "⌘⏎"
                ),
                ActionDescriptor(kind: .delete, label: "Delete", icon: "trash", shortcut: "⌫"),
            ]
        )
        XCTAssertEqual(
            PanelActions.jwt(),
            [
                ActionDescriptor(kind: .copyPayload, label: "Copy Payload", icon: "doc.on.clipboard", shortcut: "⏎"),
                ActionDescriptor(kind: .copyToken, label: "Copy Token", icon: "key", shortcut: nil),
            ]
        )
    }
}
