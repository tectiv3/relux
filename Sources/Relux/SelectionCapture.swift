import AppKit
import os

private let log = Logger(subsystem: "com.relux.app", category: "selection")

private let chromiumBundleIDs: Set<String> = [
    "com.google.Chrome",
    "com.google.Chrome.canary",
    "com.brave.Browser",
    "com.microsoft.edgemac",
    "company.thebrowser.Browser", // Arc
    "com.vivaldi.Vivaldi",
    "com.operasoftware.Opera",
    "com.nickvision.nicegab", // Nicegab
    "org.chromium.Chromium",
]

enum SelectionCapture {
    /// Must be called BEFORE Relux's panel takes focus.
    static func captureSelectedText() -> String? {
        let frontApp = NSWorkspace.shared.frontmostApplication

        // Chromium browsers don't expose selection via AX — use clipboard hack
        if let bundleID = frontApp?.bundleIdentifier, chromiumBundleIDs.contains(bundleID) {
            log.debug("Chromium app detected (\(bundleID)), using clipboard fallback")
            return captureViaClipboard()
        }

        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        let appResult = AXUIElementCopyAttributeValue(
            systemWide,
            kAXFocusedApplicationAttribute as CFString,
            &focusedApp
        )
        guard appResult == .success else { return nil }

        // swiftlint:disable:next force_cast
        let appElement = focusedApp as! AXUIElement

        var focusedElement: AnyObject?
        let elemResult = AXUIElementCopyAttributeValue(
            appElement,
            kAXFocusedUIElementAttribute as CFString,
            &focusedElement
        )
        guard elemResult == .success else { return nil }
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

    private static func captureViaClipboard() -> String? {
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
