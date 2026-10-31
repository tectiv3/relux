import AppKit
import Foundation

/// The one place that reads the clipboard store and monitor out of `AppState`. Both are
/// optional because `AppState.setup()` can throw before either is assigned, and that failure
/// path still leaves the app running with its settings window reachable.
@MainActor
enum ClipboardServices {
    static func store(_ appState: AppState) -> ClipboardStore? {
        appState.clipboardStore
    }

    static func monitor(_ appState: AppState) -> ClipboardMonitor? {
        appState.clipboardMonitor
    }

    /// A list model wired to the live pasteboard. Settings uses it for `deleteAll`; the panel
    /// keeps its own instance because the model also owns panel-local filter/selection state.
    static func model(_ appState: AppState) -> ClipboardListModel {
        ClipboardListModel(
            store: store(appState),
            board: .live(monitor: monitor(appState)),
            searchDebounceNanos: ClipboardListModel.panelSearchDebounceNanos
        )
    }
}

extension ClipboardBoard {
    /// `PasteService` owns the pasteboard and CGEvent work; wrapping it in closures keeps the
    /// model free of AppKit.
    @MainActor
    static func live(monitor: ClipboardMonitor?) -> ClipboardBoard {
        ClipboardBoard(
            pasteText: { text, richText in
                PasteService.pasteText(text, asRichText: richText, monitor: monitor)
            },
            pasteImage: { url in
                PasteService.pasteImage(at: url, monitor: monitor)
            },
            copyText: { text, richText in
                PasteService.copyToClipboard(text, asRichText: richText, monitor: monitor)
            },
            dismissPanel: {
                NSApp.keyWindow?.close()
            }
        )
    }
}

extension ClipboardListModel {
    /// The panel's `AppState` comes from the environment, so its dependencies are attached on
    /// first appearance rather than at construction.
    func attach(to appState: AppState) {
        attach(
            store: ClipboardServices.store(appState),
            board: .live(monitor: ClipboardServices.monitor(appState))
        )
    }
}
