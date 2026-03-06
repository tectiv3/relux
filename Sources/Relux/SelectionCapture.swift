import AppKit

enum SelectionCapture {
    /// Reads the selected text from the currently focused app.
    /// Must be called BEFORE Relux's panel takes focus.
    static func captureSelectedText() -> String? {
        let systemWide = AXUIElementCreateSystemWide()

        var focusedApp: AnyObject?
        guard AXUIElementCopyAttributeValue(systemWide, kAXFocusedApplicationAttribute as CFString, &focusedApp) == .success else {
            return nil
        }

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedApp as! AXUIElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return nil
        }

        var selectedText: AnyObject?
        guard AXUIElementCopyAttributeValue(focusedElement as! AXUIElement, kAXSelectedTextAttribute as CFString, &selectedText) == .success else {
            return nil
        }

        let text = selectedText as? String
        guard let text, !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return nil
        }
        return text
    }

    /// Replaces the selected text in the given app via the Accessibility API.
    /// Does not touch the pasteboard.
    static func replaceSelectedText(with replacement: String, in app: NSRunningApplication) -> Bool {
        let appElement = AXUIElementCreateApplication(app.processIdentifier)

        var focusedElement: AnyObject?
        guard AXUIElementCopyAttributeValue(appElement, kAXFocusedUIElementAttribute as CFString, &focusedElement) == .success else {
            return false
        }

        return AXUIElementSetAttributeValue(
            focusedElement as! AXUIElement,
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
