import AppKit
import KeyboardShortcuts
import SwiftUI

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        try? appState.setup()

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
        let panelWidth: CGFloat = 680
        let panelHeight: CGFloat = 420
        let screenFrame = screen.visibleFrame

        let x = screenFrame.midX - panelWidth / 2
        let y = screenFrame.origin.y + screenFrame.height * 0.65 - panelHeight / 2

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
            panel.close()
        } else {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }
}
