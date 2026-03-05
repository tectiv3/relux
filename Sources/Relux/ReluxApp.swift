import SwiftUI

@main
struct ReluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        MenuBarExtra("Relux", systemImage: "note.text") {
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
        if appState.isIndexing {
            if let p = appState.indexProgress {
                Text("Indexing: \(p.currentTitle) (\(p.current)/\(p.total))")
                    .font(.caption)
                ProgressView(value: Double(p.current), total: Double(p.total))
                    .padding(.horizontal)
            } else {
                Text("Indexing...")
                    .font(.caption)
            }
            Divider()
        }

        Button("Re-index Notes") {
            // Dismiss menu first, then start async work
            NSApp.mainMenu?.cancelTracking()
            Task { @MainActor in
                appState.reindex()
            }
        }
        .disabled(appState.isIndexing)

        Divider()
        SettingsLink()
        Divider()

        Button("Quit Relux") {
            NSApp.terminate(nil)
        }
        .keyboardShortcut("q")
    }
}
