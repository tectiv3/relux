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
            Task { @MainActor in
                NSApp.sendAction(Selector(("showSettingsWindow:")), to: nil, from: nil)
            }
        } else {
            appState.restoreModels()
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

    func togglePanel() {
        guard let panel else { return }
        if panel.isVisible {
            let frame = panel.frame
            UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
            UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
            appState.currentSelection = nil
            panel.close()
        } else {
            appState.previousApp = NSWorkspace.shared.frontmostApplication
            appState.currentSelection = SelectionCapture.captureSelectedText()
            appState.panelMode = .search
            applyForcedInputSource()
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
        }
    }

    func toggleClipboardHistory() {
        guard let panel else { return }
        if panel.isVisible, appState.panelMode == .clipboard {
            let frame = panel.frame
            UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
            UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
            panel.close()
            return
        }

        if !panel.isVisible {
            appState.previousApp = NSWorkspace.shared.frontmostApplication
        }

        appState.panelMode = .clipboard
        if !panel.isVisible {
            panel.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
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
