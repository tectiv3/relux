import SwiftUI

@main
struct ReluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Relux", systemImage: "magnifyingglass", isInserted: Binding(
            get: { appDelegate.appState.showMenuBarIcon },
            set: { appDelegate.appState.showMenuBarIcon = $0 }
        )) {
            MenuBarContentView(appState: appDelegate.appState)
        }

        Settings {
            SettingsView()
                .environment(appDelegate.appState)
        }
    }
}

struct MenuBarContentView: View {
    @Bindable var appState: AppState

    var body: some View {
        SettingsLink()
        Divider()

        Button("Quit Relux") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
