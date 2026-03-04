import SwiftUI

@main
struct NottyApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Notty", systemImage: "note.text") {
            Button("Re-index Notes") {
                appDelegate.appState.reindex()
            }
            Divider()
            SettingsLink()
            Divider()
            Button("Quit Notty") {
                NSApp.terminate(nil)
            }
            .keyboardShortcut("q")
        }

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}
