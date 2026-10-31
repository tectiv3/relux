/// One toggle row of the clipboard panel's type-filter section.
///
/// The filter enum lives in the app target, so the pure menu builder takes its label and icon
/// as data instead of depending on it.
public struct ClipboardFilterDescriptor: Equatable, Sendable {
    public let rawValue: String
    public let label: String
    public let icon: String

    public init(rawValue: String, label: String, icon: String) {
        self.rawValue = rawValue
        self.label = label
        self.icon = icon
    }
}

/// The actions each panel's overlay offers, in display order.
///
/// Menus are dynamic (a search row's kind, a clip's type or pin state, the active filter), but
/// the composition itself is pure: the views only attach handlers to the descriptors.
public enum PanelActions {
    // MARK: - Search overlay

    public static func search(kind: SearchItemKind, hasCapturedOutput: Bool) -> [ActionDescriptor] {
        switch kind {
        case .app:
            [
                ActionDescriptor(kind: .launch, label: "Launch", icon: "arrow.up.forward.app", shortcut: "⏎"),
                ActionDescriptor(
                    kind: .showInFinder,
                    label: "Show in Finder",
                    icon: "folder",
                    shortcut: "⌘⏎"
                ),
                ActionDescriptor(
                    kind: .removeFromHistory,
                    label: "Remove from history",
                    icon: "trash",
                    shortcut: nil
                ),
            ]
        case .webSearch:
            [
                ActionDescriptor(kind: .search, label: "Search", icon: "magnifyingglass", shortcut: "⏎"),
            ]
        case .translate:
            [
                ActionDescriptor(kind: .translate, label: "Translate", icon: "character.book.closed", shortcut: "⏎"),
            ]
        case .script:
            if hasCapturedOutput {
                [
                    ActionDescriptor(
                        kind: .copyOutput,
                        label: "Copy output",
                        icon: "doc.on.clipboard",
                        shortcut: nil
                    ),
                    ActionDescriptor(kind: .rerun, label: "Re-run", icon: "arrow.clockwise", shortcut: nil),
                    ActionDescriptor(kind: .clearOutput, label: "Clear", icon: "xmark", shortcut: nil),
                ]
            } else {
                [
                    ActionDescriptor(kind: .run, label: "Run", icon: "play.fill", shortcut: "⏎"),
                    ActionDescriptor(
                        kind: .removeFromHistory,
                        label: "Remove from history",
                        icon: "trash",
                        shortcut: nil
                    ),
                ]
            }
        case .calculator:
            [
                ActionDescriptor(kind: .copy, label: "Copy", icon: "doc.on.clipboard", shortcut: "⏎"),
            ]
        case .jwt:
            [
                ActionDescriptor(kind: .open, label: "Open", icon: "key.viewfinder", shortcut: "⏎"),
            ]
        case .systemSettings:
            [
                ActionDescriptor(kind: .open, label: "Open", icon: "gear", shortcut: "⏎"),
            ]
        }
    }

    // MARK: - Clipboard panel

    public static func clipboard(
        previousAppName: String,
        isRichText: Bool,
        isPinned: Bool,
        activeFilter: String?,
        filters: [ClipboardFilterDescriptor]
    ) -> [ActionDescriptor] {
        var actions: [ActionDescriptor] = [
            ActionDescriptor(
                kind: .paste,
                label: "Paste to \(previousAppName)",
                icon: "doc.on.clipboard.fill",
                shortcut: "⏎"
            ),
            ActionDescriptor(
                kind: .copyToClipboard,
                label: "Copy to Clipboard",
                icon: "doc.on.clipboard",
                shortcut: "⌘⏎"
            ),
        ]
        if isRichText {
            actions.append(ActionDescriptor(
                kind: .pasteFormatted,
                label: "Paste Formatted to \(previousAppName)",
                icon: "textformat",
                shortcut: "⌘⇧⏎"
            ))
        }
        actions.append(ActionDescriptor(kind: .delete, label: "Delete", icon: "trash", shortcut: "⌫"))
        actions.append(isPinned
            ? ActionDescriptor(kind: .unpin, label: "Unpin", icon: "pin.slash", shortcut: nil)
            : ActionDescriptor(kind: .pin, label: "Pin", icon: "pin", shortcut: nil))
        for filter in filters {
            let isActive = filter.rawValue == activeFilter
            actions.append(ActionDescriptor(
                kind: .filter(filter.rawValue),
                label: isActive ? "Clear Filter" : "Show \(filter.label) Only",
                icon: filter.icon,
                shortcut: nil
            ))
        }
        return actions
    }

    // MARK: - Translate panel

    public static func translate() -> [ActionDescriptor] {
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
    }

    // MARK: - JWT panel

    public static func jwt() -> [ActionDescriptor] {
        [
            ActionDescriptor(kind: .copyPayload, label: "Copy Payload", icon: "doc.on.clipboard", shortcut: "⏎"),
            ActionDescriptor(kind: .copyToken, label: "Copy Token", icon: "key", shortcut: nil),
        ]
    }
}
