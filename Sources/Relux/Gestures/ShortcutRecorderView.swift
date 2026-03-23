import AppKit
import SwiftUI

struct ShortcutRecorderView: View {
    @Binding var keyCombo: KeyCombo?
    @State private var isRecording = false
    @State private var monitor: Any?

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
        .onDisappear {
            removeMonitor()
        }
    }

    private func startRecording() {
        isRecording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
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
    }

    private func stopRecording() {
        isRecording = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}
