import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

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
    }

    @objc func reindex() {}
    @objc func openSettings() {}
    @objc func quit() { NSApp.terminate(nil) }
}
