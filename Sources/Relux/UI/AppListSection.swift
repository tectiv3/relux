import AppKit
import SwiftUI

/// A bundle-ID list rendered as a `Form` section: an "add" button that runs an `NSOpenPanel`, then
/// one row per app with its icon and name, each removable with the xmark button.
///
/// The view owns no persisted state — the caller passes a binding to whatever store holds the list,
/// so the same section backs settings persisted in different places.
struct AppListSection: View {
    struct Entry: Identifiable {
        let id: String // bundle ID
        let name: String
        let icon: NSImage?
    }

    let title: String
    let caption: String
    @Binding var bundleIDs: Set<String>

    @State private var entries: [Entry] = []

    var body: some View {
        Section {
            Button("Select More Apps") {
                addApp()
            }

            ForEach(entries) { entry in
                HStack {
                    if let icon = entry.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                    }
                    Text(entry.name)
                    Spacer()
                    Button {
                        bundleIDs.remove(entry.id)
                        // `SettingsStore` is not `@Observable`, so mutating the binding does not
                        // re-render this section; without the explicit reload the row lingers
                        // until an unrelated redraw.
                        reload()
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text(title)
        } footer: {
            Text(caption)
                .font(.caption)
        }
        .onAppear { reload() }
        .onChange(of: bundleIDs) { _, _ in reload() }
    }

    private func reload() {
        // Resolved names give a stable order; a `Set` alone iterates arbitrarily.
        entries = bundleIDs
            .map(Self.resolve)
            .sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
    }

    /// Falls back to the raw bundle ID when the app cannot be located, so a list entry added on
    /// another machine stays visible and removable instead of silently disappearing.
    private static func resolve(bundleID: String) -> Entry {
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else {
            return Entry(id: bundleID, name: bundleID, icon: nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return Entry(id: bundleID, name: name, icon: icon)
    }

    private func addApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url),
              let bundleID = bundle.bundleIdentifier else { return }

        bundleIDs.insert(bundleID)
        // See the remove button: the binding mutation alone does not invalidate the view.
        reload()
    }
}
