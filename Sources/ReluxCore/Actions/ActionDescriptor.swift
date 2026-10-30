/// What an actions-overlay row runs.
///
/// The cases are flat across the four panels on purpose: each panel builds only its own kinds
/// and maps them back in its handler switch, so the menu contents stay pure data that tests can
/// pin without constructing a view. Kind lists are panel-specific and never mixed.
public enum ActionKind: Equatable, Sendable {
    // MARK: - Search overlay

    case launch
    case showInFinder
    case removeFromHistory
    case search
    case translate
    case copyOutput
    case rerun
    case clearOutput
    case run
    case copy
    case open

    // MARK: - Clipboard panel

    case paste
    case copyToClipboard
    case pasteFormatted
    case delete
    case pin
    case unpin
    /// Toggles the clipboard panel's type filter for this ClipboardTypeFilter raw value.
    case filter(String)

    // MARK: - Translate panel

    case retranslate

    // MARK: - JWT panel

    case copyPayload
    case copyToken
}

/// One row of a panel's actions overlay, minus the handler it runs.
///
/// Keeping the row data separate from the closure lets the overlays share one renderer and the
/// tests pin each panel's labels, order and shortcut hints.
public struct ActionDescriptor: Equatable, Sendable {
    public let kind: ActionKind
    public let label: String
    public let icon: String
    public let shortcut: String?
    public let isEnabled: Bool

    /// `isEnabled` defaults to true: no menu currently offers a disabled row.
    public init(
        kind: ActionKind,
        label: String,
        icon: String,
        shortcut: String?,
        isEnabled: Bool = true
    ) {
        self.kind = kind
        self.label = label
        self.icon = icon
        self.shortcut = shortcut
        self.isEnabled = isEnabled
    }
}
