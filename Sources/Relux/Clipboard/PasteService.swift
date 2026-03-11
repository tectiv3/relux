import AppKit
import Carbon
import os

private let log = Logger(subsystem: "com.relux.app", category: "pasteservice")

enum PasteService {
    /// Put text on clipboard and paste into the focused app
    @MainActor
    static func pasteText(_ text: String, asRichText rtfData: Data? = nil, monitor: ClipboardMonitor?) {
        let pasteboard = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pasteboard.clearContents()
        if let rtfData {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        pasteboard.setString(text, forType: .string)
        sendPaste()
    }

    /// Put image on clipboard and paste into the focused app
    @MainActor
    static func pasteImage(at path: URL, monitor: ClipboardMonitor?) {
        guard let image = NSImage(contentsOf: path) else { return }
        let pasteboard = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        sendPaste()
    }

    /// Copy text to clipboard without pasting
    @MainActor
    static func copyToClipboard(_ text: String, asRichText rtfData: Data? = nil, monitor: ClipboardMonitor?) {
        let pasteboard = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pasteboard.clearContents()
        if let rtfData {
            pasteboard.setData(rtfData, forType: .rtf)
        }
        pasteboard.setString(text, forType: .string)
    }

    @MainActor
    private static func sendPaste() {
        NSApp.keyWindow?.close()
        simulateCmdV()
    }

    private static func simulateCmdV() {
        let source = CGEventSource(stateID: .combinedSessionState)
        // Suppress local keyboard events so our synthetic paste isn't echoed back
        source?.setLocalEventsFilterDuringSuppressionState(
            [.permitLocalMouseEvents, .permitSystemDefinedEvents],
            state: .eventSuppressionStateSuppressionInterval
        )

        // Key code 9 = V
        guard let keyDown = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: source, virtualKey: 9, keyDown: false)
        else { return }

        keyDown.flags = [.maskCommand, .maskNonCoalesced]
        keyUp.flags = [.maskCommand, .maskNonCoalesced]

        keyDown.post(tap: .cgSessionEventTap)
        keyUp.post(tap: .cgSessionEventTap)
    }
}
