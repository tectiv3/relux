import Carbon
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var discoveredModels: [LocalModel] = []
    @State private var selectedLLM: LocalModel?
    @State private var selectedEmbedder: LocalModel?
    @State private var selectedInputSourceId: String = UserDefaults.standard.string(forKey: "forceInputSourceId") ?? ""
    @State private var clearQueryOnOpen: Bool = UserDefaults.standard.bool(forKey: "clearQueryOnOpen")
    @State private var launchAtLogin: Bool = SMAppService.mainApp.status == .enabled
    @State private var selectedAppearance: String = UserDefaults.standard.string(forKey: "appAppearance") ?? "system"
    @State private var availableInputSources: [(id: String, name: String)] = getKeyboardLayouts()
    @State private var showMaxResults: Int = UserDefaults.standard.object(forKey: "maxSearchResults") as? Int ?? 10

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            modelsTab.tabItem { Label("Models", systemImage: "cpu") }
            scriptsTab.tabItem { Label("Scripts", systemImage: "terminal") }
        }
        .frame(width: 450, height: 500)
        .onAppear {
            discoveredModels = ModelDiscovery.discoverModels()
            if let path = appState.savedLLMPath {
                selectedLLM = LocalModel.matching(path: path, in: discoveredModels)
            }
            if let path = appState.savedEmbedderPath {
                selectedEmbedder = LocalModel.matching(path: path, in: discoveredModels)
            }
        }
    }

    // MARK: - General Tab

    private var generalTab: some View {
        Form {
            Section("Startup") {
                Toggle("Launch at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, newValue in
                        do {
                            if newValue {
                                try SMAppService.mainApp.register()
                            } else {
                                try SMAppService.mainApp.unregister()
                            }
                        } catch {
                            launchAtLogin = SMAppService.mainApp.status == .enabled
                        }
                    }

                KeyboardShortcuts.Recorder("Hotkey:", name: .toggleNotty)
            }

            Section("Appearance") {
                Picker("Theme:", selection: $selectedAppearance) {
                    Text("System").tag("system")
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                }
                .pickerStyle(.segmented)
                .onChange(of: selectedAppearance) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "appAppearance")
                    applyAppearance(newValue)
                }
            }

            Section("Behavior") {
                Toggle("Clear search on open", isOn: $clearQueryOnOpen)
                    .onChange(of: clearQueryOnOpen) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "clearQueryOnOpen")
                    }

                Stepper("Max results: \(showMaxResults)", value: $showMaxResults, in: 5 ... 20)
                    .onChange(of: showMaxResults) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "maxSearchResults")
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
            applyAppearance(selectedAppearance)
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
                    appState.savedLLMPath = model.standardizedPath
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
                .onChange(of: selectedEmbedder) { oldValue, newValue in
                    guard let model = newValue, oldValue != newValue else { return }
                    appState.savedEmbedderPath = model.standardizedPath
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

    // MARK: - Scripts Tab

    @State private var newScriptTitle = ""
    @State private var newScriptCommand = ""

    private var scriptsTab: some View {
        Form {
            Section("Add Script") {
                TextField("Title", text: $newScriptTitle)
                TextField("Command", text: $newScriptCommand)
                Button("Add") {
                    guard !newScriptTitle.isEmpty, !newScriptCommand.isEmpty else { return }
                    appState.scriptSearcher.add(title: newScriptTitle, command: newScriptCommand)
                    newScriptTitle = ""
                    newScriptCommand = ""
                }
                .disabled(newScriptTitle.isEmpty || newScriptCommand.isEmpty)
            }

            Section("Scripts") {
                if appState.scriptSearcher.scripts.isEmpty {
                    Text("No scripts added yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.scriptSearcher.scripts) { script in
                        HStack {
                            VStack(alignment: .leading) {
                                Text(script.title).font(.system(size: 13, weight: .medium))
                                Text(script.command)
                                    .font(.system(size: 11, design: .monospaced))
                                    .foregroundStyle(.secondary)
                                    .lineLimit(1)
                            }
                            Spacer()
                            Toggle("stdin", isOn: Binding(
                                get: { script.acceptsSelection },
                                set: { newValue in
                                    var updated = script
                                    updated.acceptsSelection = newValue
                                    appState.scriptSearcher.update(updated)
                                }
                            ))
                            .toggleStyle(.checkbox)
                            .help("Pass selected text as stdin")
                            Button(role: .destructive) {
                                appState.scriptSearcher.remove(id: script.id)
                            } label: {
                                Image(systemName: "trash")
                            }
                            .buttonStyle(.borderless)
                        }
                    }
                }
            }

            Section {
                ForEach(appState.scriptSearcher.envVars) { envVar in
                    EnvVarRow(envVar: envVar) { updated in
                        appState.scriptSearcher.updateEnvVar(updated)
                    } onDelete: {
                        appState.scriptSearcher.removeEnvVar(id: envVar.id)
                    }
                }
                Button {
                    appState.scriptSearcher.addEnvVar()
                } label: {
                    Label("Add Variable", systemImage: "plus")
                }
                .buttonStyle(.borderless)
            } header: {
                Text("Environment Variables")
            }
        }
        .formStyle(.grouped)
        .padding()
    }

    // MARK: - Env Var Row

    private struct EnvVarRow: View {
        let envVar: EnvVar
        let onChange: (EnvVar) -> Void
        let onDelete: () -> Void

        @State private var name: String
        @State private var value: String
        @State private var enabled: Bool

        init(envVar: EnvVar, onChange: @escaping (EnvVar) -> Void, onDelete: @escaping () -> Void) {
            self.envVar = envVar
            self.onChange = onChange
            self.onDelete = onDelete
            _name = State(initialValue: envVar.name)
            _value = State(initialValue: envVar.value)
            _enabled = State(initialValue: envVar.enabled)
        }

        var body: some View {
            HStack(spacing: 8) {
                Toggle("", isOn: $enabled)
                    .labelsHidden()
                    .toggleStyle(.checkbox)
                    .onChange(of: enabled) { _, new in
                        var updated = envVar
                        updated.enabled = new
                        onChange(updated)
                    }

                TextField("NAME", text: $name)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(width: 140)
                    .onSubmit { commitName() }
                    .onChange(of: name) { _, _ in commitName() }

                TextField("value", text: $value)
                    .font(.system(size: 12, design: .monospaced))
                    .onSubmit { commitValue() }
                    .onChange(of: value) { _, _ in commitValue() }

                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "minus.circle")
                }
                .buttonStyle(.borderless)
            }
        }

        private func commitName() {
            var updated = envVar
            updated.name = name
            onChange(updated)
        }

        private func commitValue() {
            var updated = envVar
            updated.value = value
            onChange(updated)
        }
    }

    // MARK: - Helpers

    private func formatSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }

    private func applyAppearance(_ mode: String) {
        Appearance.apply(mode)
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
}
