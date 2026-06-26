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

enum SelectionCapture {
    /// Apps that don't expose selection via AX. The caller must use `captureViaClipboard()`
    /// synchronously while they're still the key app — the synthesized ⌘C goes to whichever
    /// window is key, so it has to happen before Relux's panel takes focus.
    static func isClipboardOnly(_ bundleID: String?) -> Bool {
        guard let bundleID else { return false }
        return clipboardOnlyBundleIDs.contains(bundleID)
    }

    /// AX-only selection read for a specific app. Injects no events and is thread-safe, so it
    /// can run on a background queue *after* Relux's panel is already key — capture never blocks
    /// panel presentation or keyboard input.
    static func captureViaAX(pid: pid_t) -> String? {
        let appElement = AXUIElementCreateApplication(pid)
        if let text = selectedText(in: appElement) { return text }

        // Stubborn apps (Firefox, some Electron) only expose selection once enhanced AX is on.
        // Setting it rebuilds the app's AX tree, so do it once per app and retry — never on
        // every activation, which was the prior latency hit.
        if enableEnhancedAccessibilityIfNeeded(pid: pid, appElement: appElement) {
            return selectedText(in: appElement)
        }
        return nil
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

    // PIDs already switched into enhanced AX. captureViaAX runs off the main thread, so guard the set.
    private nonisolated(unsafe) static var enhancedPIDs: Set<pid_t> = []
    private static let enhancedLock = NSLock()

    /// Enables enhanced AX once per app. Returns true if it was just enabled (caller should retry).
    private static func enableEnhancedAccessibilityIfNeeded(pid: pid_t, appElement: AXUIElement) -> Bool {
        enhancedLock.lock()
        let alreadyEnabled = enhancedPIDs.contains(pid)
        if !alreadyEnabled { enhancedPIDs.insert(pid) }
        enhancedLock.unlock()
        guard !alreadyEnabled else { return false }

        AXUIElementSetAttributeValue(appElement, "AXEnhancedUserInterface" as CFString, kCFBooleanTrue)
        AXUIElementSetAttributeValue(appElement, "AXManualAccessibility" as CFString, kCFBooleanTrue)
        return true
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

    // MARK: - Chromium clipboard fallback

    static func captureViaClipboard() -> String? {
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

    static func ensureAccessibilityPermission() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        let options = [prompt: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
