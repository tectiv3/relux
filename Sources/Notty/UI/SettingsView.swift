import Carbon
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var discoveredModels: [LocalModel] = []
    @State private var selectedLLM: LocalModel?
    @State private var selectedEmbedder: LocalModel?
    @State private var selectedInputSourceId: String = UserDefaults.standard.string(forKey: "forceInputSourceId") ?? ""
    @State private var clearQueryOnOpen: Bool = UserDefaults.standard.bool(forKey: "clearQueryOnOpen")
    @State private var availableInputSources: [(id: String, name: String)] = []

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }
            shortcutsTab.tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 450, height: 400)
        .onAppear {
            discoveredModels = ModelDiscovery.discoverModels()
            if let path = appState.savedLLMPath {
                let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                selectedLLM = discoveredModels.first { $0.path.standardizedFileURL.path == standardized }
            }
            if let path = appState.savedEmbedderPath {
                let standardized = URL(fileURLWithPath: path).standardizedFileURL.path
                selectedEmbedder = discoveredModels.first { $0.path.standardizedFileURL.path == standardized }
            }
        }
    }

    // MARK: - Models Tab

    private var modelsTab: some View {
        Form {
            Section("LLM Model") {
                Picker("Model:", selection: $selectedLLM) {
                    Text("None").tag(LocalModel?.none)
                    ForEach(discoveredModels) { model in
                        Text("\(model.name) (\(formatSize(model.sizeBytes)))")
                            .tag(Optional(model))
                    }
                }
                .onChange(of: selectedLLM) { oldValue, newValue in
                    guard let model = newValue, oldValue != newValue else { return }
                    appState.savedLLMPath = model.path.standardizedFileURL.path
                    appState.markSetupComplete()
                    // Skip if already loaded (e.g. restored on launch)
                    guard !appState.mlx.isLLMLoaded else { return }
                    Task {
                        try? await appState.mlx.loadLLM(model: model)
                    }
                }

                if !appState.mlx.loadingStatus.isEmpty {
                    HStack {
                        ProgressView().controlSize(.small)
                        Text(appState.mlx.loadingStatus)
                            .foregroundStyle(.secondary)
                    }
                }
            }

            Section("Embedder Model") {
                Picker("Model:", selection: $selectedEmbedder) {
                    Text("None").tag(LocalModel?.none)
                    ForEach(discoveredModels) { model in
                        Text("\(model.name) (\(formatSize(model.sizeBytes)))")
                            .tag(Optional(model))
                    }
                }
                .onChange(of: selectedEmbedder) { oldValue, newValue in
                    guard let model = newValue, oldValue != newValue else { return }
                    appState.savedEmbedderPath = model.path.standardizedFileURL.path
                    guard !appState.mlx.isEmbedderLoaded else { return }
                    Task {
                        try? await appState.mlx.loadEmbedder(model: model)
                    }
                }
            }

            Section("Indexing") {
                Button("Re-index Notes") {
                    appState.reindex()
                }
                .disabled(appState.isIndexing)

                if appState.isIndexing, let progress = appState.indexProgress {
                    VStack(alignment: .leading, spacing: 4) {
                        ProgressView(
                            value: Double(progress.current),
                            total: Double(progress.total)
                        )
                        Text(progress.currentTitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Behavior") {
                Toggle("Clear search on open", isOn: $clearQueryOnOpen)
                    .onChange(of: clearQueryOnOpen) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "clearQueryOnOpen")
                    }
            }

            Section("Keyboard Layout") {
                Picker("Force layout on open:", selection: $selectedInputSourceId) {
                    Text("Don't change").tag("")
                    ForEach(availableInputSources, id: \.id) { source in
                        Text(source.name).tag(source.id)
                    }
                }
                .onChange(of: selectedInputSourceId) { _, newValue in
                    if newValue.isEmpty {
                        UserDefaults.standard.removeObject(forKey: "forceInputSourceId")
                    } else {
                        UserDefaults.standard.set(newValue, forKey: "forceInputSourceId")
                    }
                }
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            availableInputSources = Self.getKeyboardLayouts()
        }
    }

    private static func getKeyboardLayouts() -> [(id: String, name: String)] {
        guard let sources = TISCreateInputSourceList(nil, false)?.takeRetainedValue() as? [TISInputSource] else {
            return []
        }
        var layouts: [(id: String, name: String)] = []
        for source in sources {
            guard let categoryRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceCategory) else { continue }
            let category = Unmanaged<CFString>.fromOpaque(categoryRef).takeUnretainedValue() as String
            guard category == kTISCategoryKeyboardInputSource as String else { continue }

            guard let typeRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceType) else { continue }
            let type = Unmanaged<CFString>.fromOpaque(typeRef).takeUnretainedValue() as String
            guard type == kTISTypeKeyboardLayout as String || type == kTISTypeKeyboardInputMode as String else { continue }

            guard let selectableRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceIsSelectCapable) else { continue }
            let selectable = Unmanaged<CFNumber>.fromOpaque(selectableRef).takeUnretainedValue() as! Bool
            guard selectable else { continue }

            guard let idRef = TISGetInputSourceProperty(source, kTISPropertyInputSourceID),
                  let nameRef = TISGetInputSourceProperty(source, kTISPropertyLocalizedName) else { continue }
            let id = Unmanaged<CFString>.fromOpaque(idRef).takeUnretainedValue() as String
            let name = Unmanaged<CFString>.fromOpaque(nameRef).takeUnretainedValue() as String
            layouts.append((id: id, name: name))
        }
        return layouts
    }

    // MARK: - Shortcuts Tab

    private var shortcutsTab: some View {
        Form {
            KeyboardShortcuts.Recorder("Toggle Notty:", name: .toggleNotty)
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Helpers

    private func formatSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }
}
