import AppKit
import os

private let log = Logger(subsystem: "com.relux.app", category: "selection")

/// Apps that don't expose selection via standard AX — capture via simulated Cmd+C instead.
/// Chromium browsers (AXEnhancedUserInterface interferes) plus other non-AX toolkits (Telegram).
private let clipboardOnlyBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser",
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.nickvision.nicegab",
    "org.chromium.Chromium",
    "ru.keepcoder.Telegram",
]

/// Stateless accessibility primitives. The capture flow itself — and every piece of mutable
/// state it needs — lives in `SelectionCaptureService`.
enum SelectionCapture {
    /// Apps that don't expose selection via AX. The caller must use
    /// `SelectionCaptureService.captureViaClipboard()` synchronously while they're still the key
    /// app — the synthesized ⌘C goes to whichever window is key, so it has to happen before
    /// Relux's panel takes focus.
    static func isClipboardOnly(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return clipboardOnlyBundleIDs.contains(bundleID)
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

// MARK: - Accessibility bridge

/// The AX primitives the capture flow needs, injected so the retry policy and attribute-read
/// order can be tested without a live accessibility connection.
struct SelectionAXBridge: Sendable {
    /// Reads the focused element's selection: standard attribute first, text markers second.
    var selectedText: @Sendable (pid_t) async -> String?
    /// Switches the app into enhanced AX. Rebuilds the app's AX tree, so callers do it once.
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
    static func selectedText(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        return selectedText(in: appElement)
    }

    /// Enables enhanced AX via the app-level element, which is the same proxy
    /// `AXUIElementCreateApplication` hands out for the capture read.
    static func enableEnhancedAccessibility(pid: pid_t) {
        let appElement = AXUIElementCreateApplication(pid)
        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
    }

    private static func selectedText(in appElement: AXUIElement) -> String? {
        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        ) == .success else { return nil }
        // swiftlint:disable:next force_cast
        let element = focusedElement as! AXUIElement

        // Standard path — works for most native apps
        var selectedText: AnyObject?
        if AXUIElementCopyAttributeValue(element, kAXSelectedTextAttribute as CFString, &selectedText) == .success,
           let text = selectedText as? String,
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return text
        }

        // Text marker path — WebKit views (Safari, Orion) use markers instead
        if let text = selectedTextViaMarkers(from: element),
           !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        {
            return text
        }

        return nil
    }

    private static func selectedTextViaMarkers(from element: AXUIElement) -> String? {
        var markerRange: AnyObject?
        let mrResult = AXUIElementCopyAttributeValue(
            element,
            "AXSelectedTextMarkerRange" as CFString,
            &markerRange
        )
        guard mrResult == .success, markerRange != nil else {
            return nil
        }

        var text: AnyObject?
        let stResult = AXUIElementCopyParameterizedAttributeValue(
            element,
            "AXStringForTextMarkerRange" as CFString,
            markerRange!,
            &text
        )
        guard stResult == .success else {
            return nil
        }
        return text as? String
    }
}

// MARK: - Capture flow

/// The selection capture flow. Its only mutable state — the apps already switched into enhanced
/// AX — is main-actor isolated by construction, so there is no unsynchronised global; the blocking
/// AX work hops to `AXCaptureExecutor` inside `SelectionAXBridge`.
@MainActor
final class SelectionCaptureService {
    private let bridge: SelectionAXBridge
    private var enhancedAXPIDs: Set<pid_t> = []

    init(bridge: SelectionAXBridge = .live) {
        self.bridge = bridge
    }

    /// AX-only selection read for a specific app. Injects no events, so it can run *after* Relux's
    /// panel is already key — capture never blocks panel presentation or keyboard input.
    func capture(from pid: pid_t) async -> String? {
        if let text = await bridge.selectedText(pid) {
            return text
        }

        // Stubborn apps (Firefox, some Electron) only expose selection once enhanced AX is on.
        // Setting it rebuilds the app's AX tree, so do it once per app and retry — never on
        // every activation, which was the prior latency hit.
        guard firstEnhancedAXRequest(for: pid) else { return nil }
        await bridge.enableEnhancedAX(pid)
        return await bridge.selectedText(pid)
    }

    /// True the first time an app is asked to switch enhanced AX on, so the retry runs at most
    /// once per app for this process's lifetime.
    private func firstEnhancedAXRequest(for pid: pid_t) -> Bool {
        enhancedAXPIDs.insert(pid).inserted
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
