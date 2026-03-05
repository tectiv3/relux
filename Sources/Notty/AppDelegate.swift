import AppKit
import Carbon
import KeyboardShortcuts
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? appState.setup()
        applyAppearance()

        setupPanel()

        KeyboardShortcuts.onKeyUp(for: .toggleNotty) { [weak self] in
            self?.togglePanel()
        }

        if appState.needsFirstRun {
            DispatchQueue.main.async {
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        } else {
            Task { await appState.restoreModels() }
        }
    }

    func setupPanel() {
        guard let screen = NSScreen.main else { return }
        let panelWidth: CGFloat = 750
        let panelHeight: CGFloat = 474
        let screenFrame = screen.visibleFrame

        let savedX = UserDefaults.standard.object(forKey: "panelX") as? CGFloat
        let savedY = UserDefaults.standard.object(forKey: "panelY") as? CGFloat

        let x = savedX ?? (screenFrame.midX - panelWidth / 2)
        let y = savedY ?? (screenFrame.origin.y + screenFrame.height * 0.65 - panelHeight / 2)

        let contentRect = NSRect(x: x, y: y, width: panelWidth, height: panelHeight)
        let floatingPanel = FloatingPanel(contentRect: contentRect)

        let hostingView = NSHostingView(rootView: OverlayView().environment(appState))
        hostingView.translatesAutoresizingMaskIntoConstraints = false

        if let contentView = floatingPanel.contentView {
            contentView.addSubview(hostingView)
            NSLayoutConstraint.activate([
                hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
                hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
                hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
                hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
            ])
        }

        panel = floatingPanel
    }

    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            // Save position before closing
            let frame = panel.frame
            UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
            UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
            panel.close()
        } else {
            applyForcedInputSource()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    private func applyAppearance() {
        let mode = UserDefaults.standard.string(forKey: "appAppearance") ?? "system"
        switch mode {
        case "light":
            NSApp.appearance = NSAppearance(named: .aqua)
        case "dark":
            NSApp.appearance = NSAppearance(named: .darkAqua)
        default:
            NSApp.appearance = nil
        }
    }

    private func applyForcedInputSource() {
        guard let sourceId = UserDefaults.standard.string(forKey: "forceInputSourceId"),
              !sourceId.isEmpty else { return }
        let filter = [kTISPropertyInputSourceID: sourceId] as CFDictionary
        guard let sources = TISCreateInputSourceList(filter, false)?.takeRetainedValue() as? [TISInputSource],
              let source = sources.first else { return }
        TISSelectInputSource(source)
    }
}
