import AppKit
import Carbon
import os

private let log = Logger(subsystem: "com.relux.app", category: "pasteservice")

enum PasteService {
    /// Put text on clipboard and paste into the focused app
    @MainActor
    static func pasteText(_ text: String, asRichText rtfData: Data? = nil, monitor: ClipboardMonitor?) {
        let pb = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pb.clearContents()
        if let rtfData {
            pb.setData(rtfData, forType: .rtf)
        }
        pb.setString(text, forType: .string)
        sendPaste()
    }

    /// Put image on clipboard and paste into the focused app
    @MainActor
    static func pasteImage(at path: URL, monitor: ClipboardMonitor?) {
        guard let image = NSImage(contentsOf: path) else { return }
        let pb = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pb.clearContents()
        pb.writeObjects([image])
        sendPaste()
    }

    /// Copy text to clipboard without pasting
    @MainActor
    static func copyToClipboard(_ text: String, asRichText rtfData: Data? = nil, monitor: ClipboardMonitor?) {
        let pb = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pb.clearContents()
        if let rtfData {
            pb.setData(rtfData, forType: .rtf)
        }
        pb.setString(text, forType: .string)
    }

    @MainActor
    private static func sendPaste() {
        NSApp.keyWindow?.close()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulateCmdV()
        }
    }

    private static func simulateCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = V
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
