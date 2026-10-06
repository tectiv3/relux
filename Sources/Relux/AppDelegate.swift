import AppKit
import Carbon
import KeyboardShortcuts
import os
import SwiftUI

private let log = Logger(subsystem: "com.relux.app", category: "appdelegate")

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    let appState = AppState()
    var panel: FloatingPanel?

    func applicationDidFinishLaunching(_: Notification) {
        UserDefaults.standard.register(defaults: [
            "showMenuBarIcon": true,
            "clipboardEnabled": true,
            "clipboardRetentionMonths": 3,
            "clipboardDisabledApps": ClipboardMonitor.defaultDisabledApps,
        ])

        do {
            try appState.setup()
        } catch {
            log.error("Failed to initialize app state: \(error.localizedDescription)")
        }
        applyAppearance()

        SelectionCapture.ensureAccessibilityPermission()
        setupPanel()

        KeyboardShortcuts.onKeyUp(for: .toggleRelux) { [weak self] in
            self?.togglePanel()
        }

        KeyboardShortcuts.onKeyUp(for: .clipboardHistory) { [weak self] in
            self?.toggleClipboardHistory()
        }

        if appState.needsFirstRun {
            appState.markSetupComplete()
        }

        // Show the panel on launch so Relux is immediately usable after start.
        showPanel()
    }

    func setupPanel() {
        guard let screen = NSScreen.main else { return }
        let panelWidth: CGFloat = 750
        let panelHeight: CGFloat = 474
        let screenFrame = screen.visibleFrame

        let savedX = UserDefaults.standard.object(forKey: "panelX") as? CGFloat
        let savedY = UserDefaults.standard.object(forKey: "panelY") as? CGFloat

        let posX = savedX ?? (screenFrame.midX - panelWidth / 2)
        let posY = savedY ?? (screenFrame.origin.y + screenFrame.height * 0.65 - panelHeight / 2)

        let contentRect = NSRect(x: posX, y: posY, width: panelWidth, height: panelHeight)
        let floatingPanel = FloatingPanel(contentRect: contentRect)

        let hostingView = NSHostingView(rootView: PanelRootView().environment(appState))
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

    /// Positions the panel on the active display and shows it. All open paths
    /// (hotkey, gesture, launch) go through here so the panel always follows the user.
    func showPanel() {
        guard let panel else { return }
        movePanelToActiveDisplay()
        panel.makeKeyAndOrderFront(nil)
    }

    /// The "active" display is the one under the mouse cursor — the same display
    /// gestures and Mission Control act on. Moves the panel there, preserving its
    /// relative placement on the previous screen, and clamps it into view.
    private func movePanelToActiveDisplay() {
        guard let panel else { return }

        let frame = panel.frame
        guard let target = DisplaySelection.screenUnderMouse() else { return }
        let current = DisplaySelection.screen(containing: NSPoint(x: frame.midX, y: frame.midY))
        if let current,
           DisplaySelection.identifier(of: current) == DisplaySelection.identifier(of: target)
        {
            return
        }

        let source = current?.visibleFrame ?? target.visibleFrame
        let relX = source.width > 0 ? (frame.midX - source.minX) / source.width : 0.5
        let relY = source.height > 0 ? (frame.midY - source.minY) / source.height : 0.5

        let visible = target.visibleFrame
        var origin = NSPoint(
            x: visible.minX + relX * visible.width - frame.width / 2,
            y: visible.minY + relY * visible.height - frame.height / 2
        )
        origin.x = min(max(origin.x, visible.minX), visible.maxX - frame.width)
        origin.y = min(max(origin.y, visible.minY), visible.maxY - frame.height)
        panel.setFrameOrigin(origin)
    }

    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            let frame = panel.frame
            UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
            UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
            appState.currentSelection = nil
            appState.panelClosedAt = Date()
            panel.close()
        } else {
            let previousApp = NSWorkspace.shared.frontmostApplication
            appState.previousApp = previousApp
            appState.currentSelection = nil
            // Keep last panel mode if closed within 60s
            if Date().timeIntervalSince(appState.panelClosedAt) > 60 {
                appState.panelMode = .search
            }
            applyForcedInputSource()

            if SelectionCapture.isClipboardOnly(previousApp?.bundleIdentifier) {
                // ⌘C must be synthesized while the source app is still key — before the panel.
                appState.currentSelection = SelectionCapture.captureViaClipboard()
                showPanel()
            } else {
                // Panel first so keystrokes are never dropped; read the selection via AX
                // off the main thread and fill it in when ready.
                showPanel()
                if let pid = previousApp?.processIdentifier {
                    Task.detached(priority: .userInitiated) { [appState] in
                        guard let text = SelectionCapture.captureViaAX(pid: pid) else { return }
                        await MainActor.run {
                            appState.currentSelection = text
                            appState.selectionCaptureID = UUID()
                        }
                    }
                }
            }
        }
    }

    func toggleClipboardHistory() {
        guard let panel else { return }
        if panel.isVisible, appState.panelMode == .clipboard {
            let frame = panel.frame
            UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
            UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
            appState.panelClosedAt = Date()
            panel.close()
            return
        }

        if !panel.isVisible {
            appState.previousApp = NSWorkspace.shared.frontmostApplication
        }

        appState.panelMode = .clipboard
        if !panel.isVisible {
            showPanel()
        }
    }

    private func applyAppearance() {
        let mode = UserDefaults.standard.string(forKey: "appAppearance") ?? "system"
        Appearance.apply(mode)
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
