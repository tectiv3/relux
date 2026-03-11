import AppKit

enum SelectionCapture {
    /// Reads the selected text from the currently focused app.
    /// Must be called BEFORE Relux's panel takes focus.
    static func captureSelectedText() -> String? {
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

    /// Extracts selected text using AX text markers (used by Safari/WebKit).
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

    /// Replaces the selected text in the given app via the Accessibility API.
    /// Does not touch the pasteboard.
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

    /// Prompts for Accessibility permission if not already granted.
    static func ensureAccessibilityPermission() {
        let prompt = "AXTrustedCheckOptionPrompt" as CFString
        let options = [prompt: true] as CFDictionary
        AXIsProcessTrustedWithOptions(options)
    }
}
