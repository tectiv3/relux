import AppKit
import KeyboardShortcuts
import SwiftUI

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?
    var panel: FloatingPanel?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(
            systemSymbolName: "note.text", accessibilityDescription: "Notty")

        let menu = NSMenu()
        menu.addItem(
            NSMenuItem(title: "Re-index Notes", action: #selector(reindex), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(
            NSMenuItem(title: "Quit Notty", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu

        setupPanel()

        KeyboardShortcuts.onKeyUp(for: .toggleNotty) { [weak self] in
            self?.togglePanel()
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

        let hostingView = NSHostingView(rootView: OverlayView())
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

    @objc func reindex() {}
    @objc func openSettings() {}
    @objc func quit() { NSApp.terminate(nil) }
}
