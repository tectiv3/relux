import AppKit
import os

private let log = Logger(subsystem: "com.relux.app", category: "selection")

/// Stateless accessibility primitives. The capture flow itself lives in `SelectionCaptureService`.
enum SelectionCapture {
    /// Apps that don't expose selection via AX. The caller must use
    /// `SelectionCaptureService.captureViaClipboard()` synchronously while they're still the key
    /// app — the synthesized ⌘C goes to whichever window is key, so it has to happen before
    /// Relux's panel takes focus.
    ///
    /// The list is a user setting (`SettingsStore.clipboardOnlySelectionApps`) and is passed in so
    /// this stays a pure predicate.
    static func isClipboardOnly(_ bundleID: String?, in apps: Set<String>) -> Bool {
        guard let bundleID else { return false }
        return apps.contains(bundleID)
    }

    static func replaceSelectedText(with replacement: String, in app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: AnyObject?
        let result = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard result == .success else { return false }

        // swiftlint:disable:next force_cast
        let element = focusedElement as! AXUIElement

        return AXUIElementSetAttributeValue(
            element,
            kAXSelectedTextAttribute as CFString,
            replacement as CFString
        ) == .success
    }

    static func ensureAccessibilityPermission() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        let options = [prompt: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}

// MARK: - Read outcome

/// One selection read. The failure case travels with the empty result because an app whose AX tree
/// is missing and an app where the user has nothing selected both come back as `nil` text but need
/// opposite treatment: only the first one is worth switching enhanced AX on for.
struct SelectionRead: Sendable, Equatable {
    enum Failure: Sendable, Equatable {
        /// `kAXFocusedUIElementAttribute` itself failed, so the app's tree is missing or not built
        /// yet. Electron 44 answers `-25212` (`kAXErrorNoValue`) here.
        case noFocusedElement(axError: Int32)
        /// The focused element answered, but neither selection attribute produced a value — the
        /// shape WebKit reports until enhanced AX is on.
        case noSelectionValue(textError: Int32, markerError: Int32)
        /// A selection attribute answered with an empty value: nothing is selected. No flag can
        /// change that, so the caller must not retry for it.
        case emptySelection

        var warrantsEnhancedAX: Bool {
            switch self {
            case .noFocusedElement, .noSelectionValue: true
            case .emptySelection: false
            }
        }
    }

    var text: String?
    var failure: Failure?

    static func captured(_ text: String) -> SelectionRead {
        SelectionRead(text: text, failure: nil)
    }

    static func failed(_ failure: Failure) -> SelectionRead {
        SelectionRead(text: nil, failure: failure)
    }
}

// MARK: - Accessibility bridge

/// The AX primitives the capture flow needs, injected so the retry policy and attribute-read
/// order can be tested without a live accessibility connection.
struct SelectionAXBridge: Sendable {
    /// Reads the focused element's selection: standard attribute first, text markers second.
    var selectedText: @Sendable (pid_t) async -> SelectionRead
    /// Switches the app into enhanced AX. Rebuilds the app's AX tree, so callers only do it when a
    /// read says the tree is missing.
    var enableEnhancedAX: @Sendable (pid_t) async -> Void
}

extension SelectionAXBridge {
    static let live = SelectionAXBridge(
        selectedText: { pid in
            await AXSelectionReader.selectedText(pid: pid)
        },
        enableEnhancedAX: { pid in
            await AXSelectionReader.enableEnhancedAccessibility(pid: pid)
        }
    )
}

/// AX calls block on IPC into the target app, and enabling enhanced AX rebuilds its tree — neither
/// belongs on the main actor while the panel is taking keystrokes. They are serialised here
/// because they touch another process's accessibility state, not because of local mutation.
@globalActor
private actor AXCaptureExecutor {
    static let shared = AXCaptureExecutor()
}

/// AX-only reads for a specific app. Isolated to `AXCaptureExecutor`; holds no local state.
@AXCaptureExecutor
private enum AXSelectionReader {
    /// The Chromium/WebKit marker attributes — ApplicationServices exports no `kAX…` constant for
    /// either.
    private static var markerRangeAttribute: CFString {
        "AXSelectedTextMarkerRange" as CFString
    }

    private static var textMarkerStringAttribute: CFString {
        "AXStringForTextMarkerRange" as CFString
    }

    private static let enhancedUserInterfaceAttribute: CFString = "AXEnhancedUserInterface" as CFString
    private static let manualAccessibilityAttribute: CFString = "AXManualAccessibility" as CFString

    static func selectedText(pid: pid_t) -> SelectionRead {
        let appElement = AXUIElementCreateApplication(pid)
        return selectedText(in: appElement)
    }

    /// Both opt-in flags are always written: `AXEnhancedUserInterface` is the WebKit one,
    /// `AXManualAccessibility` the Chromium one, and the target app picks whichever it implements.
    static func enableEnhancedAccessibility(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        _ = AXUIElementSetAttributeValue(
            appElement,
            enhancedUserInterfaceAttribute,
            kCFBooleanTrue
        )
        _ = AXUIElementSetAttributeValue(
            appElement,
            manualAccessibilityAttribute,
            kCFBooleanTrue
        )
    }

    private static func selectedText(in appElement: AXUIElement) -> SelectionRead {
        var focusedElement: AnyObject?
        let focusedResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard focusedResult == .success else {
            return .failed(.noFocusedElement(axError: focusedResult.rawValue))
        }
        // swiftlint:disable:next force_cast
        let element = focusedElement as! AXUIElement

        let textProbe = probe(element, kAXSelectedTextAttribute as CFString)
        let markerProbe = probe(element, markerRangeAttribute)

        // Standard path — works for most native apps
        if let text = textProbe.value as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return .captured(text)
        }

        // Text marker path — WebKit views (Safari, Orion) use markers instead
        let markerRangeFound = markerProbe.error == .success && markerProbe.value != nil
        if markerRangeFound {
            if let text = markerString(of: markerProbe.value, on: element),
               !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            {
                return .captured(text)
            }
            return .failed(.emptySelection)
        }

        // Neither attribute answered: WebKit reports `kAXErrorNoValue` for both until enhanced AX
        // is on, so this is the case the opt-in flags exist for.
        guard textProbe.error == .success else {
            return .failed(
                .noSelectionValue(
                    textError: textProbe.error.rawValue,
                    markerError: markerProbe.error.rawValue
                )
            )
        }
        return .failed(.emptySelection)
    }

    private static func markerString(of markerRange: AnyObject?, on element: AXUIElement) -> String? {
        guard let markerRange else { return nil }
        var text: AnyObject?
        let stResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            textMarkerStringAttribute,
            markerRange,
            &text
        )
        guard stResult == .success else {
            return nil
        }
        return text as? String
    }

    /// One attribute read that keeps the raw `AXError` next to the value: a failed read and an
    /// empty value are different bugs, and the retry only exists for the first.
    private static func probe(
        _ element: AXUIElement,
        _ attribute: CFString
    ) -> (error: AXError, value: AnyObject?) {
        var value: AnyObject?
        let error = AXUIElementCopyAttributeValue(element, attribute, &value)
        return (error, error == .success ? value : nil)
    }
}

// MARK: - Capture flow

/// The selection capture flow: one read, and — only when the read says the app's AX tree is
/// missing — an opt-in write followed by a bounded re-read schedule. The blocking AX work hops to
/// `AXCaptureExecutor` inside `SelectionAXBridge`, so no AX call runs on the main actor.
@MainActor
final class SelectionCaptureService {
    private let bridge: SelectionAXBridge

    init(bridge: SelectionAXBridge = .live) {
        self.bridge = bridge
    }

    /// Re-read delays after the opt-in writes. Chromium flips its accessibility mode on in the
    /// renderer, so a zero-delay re-read races it — a marker read that only answers on the read
    /// *after* the enable call was observed. Three re-reads, ~560 ms in total: bounded, and short
    /// enough that the panel is never waiting on it (capture fills the field when it lands).
    nonisolated static let retryDelaysMilliseconds: [UInt64] = [80, 160, 320]

    /// AX-only selection read for a specific app. Injects no events, so it can run *after* Relux's
    /// panel is already key — capture never blocks panel presentation or keyboard input.
    func capture(from pid: pid_t) async -> String? {
        let first = await bridge.selectedText(pid)
        if let text = first.text {
            return text
        }

        // Nothing selected is nothing selected: rebuilding the app's AX tree cannot produce a
        // selection, and the rebuild is the latency this path exists to avoid.
        guard (first.failure ?? .emptySelection).warrantsEnhancedAX else {
            return nil
        }

        // The opt-in is (re-)written whenever the read says the tree is missing, even for an app
        // that accepted it before: Chromium drops accessibility mode again when it idles, and a
        // single raced attempt must not disable the retry for the process's lifetime.
        await bridge.enableEnhancedAX(pid)

        for delay in Self.retryDelaysMilliseconds {
            do {
                try await Task.sleep(nanoseconds: delay * 1_000_000)
            } catch {
                return nil
            }
            if let text = await bridge.selectedText(pid).text {
                return text
            }
        }
        return nil
    }

    // MARK: - Chromium clipboard fallback

    func captureViaClipboard() -> String? {
        let pasteboard = NSPasteboard.general
        let oldChangeCount = pasteboard.changeCount

        let savedItems = pasteboard.pasteboardItems?.compactMap { item -> [String: Data]? in
            var dict = [String: Data]()
            for type in item.types {
                if let data = item.data(forType: type) {
                    dict[type.rawValue] = data
                }
            }
            return dict.isEmpty ? nil : dict
        } ?? []

        let source = CGEventSource(stateID: CGEventSourceStateID.combinedSessionState)
        let cKeyCode: CGKeyCode = 0x08
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: cKeyCode, keyDown: false)
        else {
            log.error("Failed to create CGEvents for Cmd+C")
            return nil
        }
        keyDown.flags = CGEventFlags.maskCommand
        keyUp.flags = CGEventFlags.maskCommand
        keyDown.post(tap: CGEventTapLocation.cghidEventTap)
        keyUp.post(tap: CGEventTapLocation.cghidEventTap)

        var captured: String?
        for _ in 0 ..< 20 {
            usleep(10000) // 10ms per tick, up to 200ms total
            if pasteboard.changeCount != oldChangeCount {
                captured = pasteboard.string(forType: .string)
                break
            }
        }

        pasteboard.clearContents()
        for itemDict in savedItems {
            let newItem = NSPasteboardItem()
            for (typeRaw, data) in itemDict {
                newItem.setData(data, forType: NSPasteboard.PasteboardType(typeRaw))
            }
            pasteboard.writeObjects([newItem])
        }

        if let text = captured?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty {
            log.debug("Clipboard fallback captured \(text.prefix(50))…")
            return captured
        }

        log.debug("Clipboard fallback: no text captured")
        return nil
    }
}
