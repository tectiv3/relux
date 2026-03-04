import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var discoveredModels: [LocalModel] = []
    @State private var selectedLLM: LocalModel?
    @State private var selectedEmbedder: LocalModel?

    var body: some View {
        TabView {
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }
            shortcutsTab.tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 450, height: 350)
        .onAppear {
            discoveredModels = ModelDiscovery.discoverModels()
            if let path = appState.savedLLMPath {
                selectedLLM = discoveredModels.first { $0.path.path == path }
            }
            if let path = appState.savedEmbedderPath {
                selectedEmbedder = discoveredModels.first { $0.path.path == path }
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
                .onChange(of: selectedLLM) { _, newValue in
                    guard let model = newValue else { return }
                    appState.savedLLMPath = model.path.path
                    appState.markSetupComplete()
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
                .onChange(of: selectedEmbedder) { _, newValue in
                    guard let model = newValue else { return }
                    appState.savedEmbedderPath = model.path.path
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
