import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var keyCombo: KeyCombo?
    @State private var isRecording = false

    var body: some View {
        Button {
            if isRecording {
                stopRecording()
            } else {
                startRecording()
            }
        } label: {
            if isRecording {
                Text("Press keys...")
                    .foregroundStyle(.red)
                    .frame(minWidth: 100)
            } else if let combo = keyCombo {
                Text(combo.displayString)
                    .frame(minWidth: 100)
            } else {
                Text("Record")
                    .foregroundStyle(.secondary)
                    .frame(minWidth: 100)
            }
        }
        .background(
            PanelKeyMonitor(isActive: isRecording, onWindowLost: stopRecording, handler: record)
        )
        .onDisappear {
            stopRecording()
        }
    }

    private func startRecording() {
        guard !isRecording else { return }
        isRecording = true
        GlobalHotkeySuspension.suspend()
    }

    /// While recording, every key is consumed (as before) — nothing may reach the
    /// responder chain or a global hotkey.
    private func record(_ event: NSEvent) -> NSEvent? {
        let code = event.keyCode
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        // Escape cancels recording without changing the binding
        if code == 53 {
            stopRecording()
            return nil
        }

        keyCombo = KeyCombo(keyCode: code, modifierRawValue: mods.rawValue)
        stopRecording()
        return nil
    }

    /// The only place the suspension is released: the escape/recorded-key paths, the
    /// button, `.onDisappear` and window close all funnel through here, and the
    /// `isRecording` guard makes repeats no-ops.
    private func stopRecording() {
        guard isRecording else { return }
        isRecording = false
        GlobalHotkeySuspension.resume()
    }
}
