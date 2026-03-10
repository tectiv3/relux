// swiftlint:disable file_length
import Carbon
import KeyboardShortcuts
import ServiceManagement
import SwiftUI

// swiftlint:disable:next type_body_length
struct SettingsView: View {
    @Environment(AppState.self) private var appState
    @AppStorage("showMenuBarIcon") private var showMenuBarIcon = true
    @State private var selectedInputSourceId: String = ""
    @State private var clearQueryOnOpen: Bool = false
    @State private var launchAtLogin: Bool = false
    @State private var selectedAppearance: String = "system"
    @State private var availableInputSources: [(id: String, name: String)] = []
    @State private var showMaxResults: Int = 10
    @State private var clipboardEnabled: Bool =
        UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true
    @State private var clipboardRetention: Int =
        UserDefaults.standard.object(forKey: "clipboardRetentionMonths") as? Int ?? 3
    @State private var disabledApps: [DisabledApp] = []
    @State private var showClearConfirmation = false
    @State private var anthropicApiKey: String = ""
    @State private var translateModel: String = AnthropicService.defaultModel
    @State private var translateSystemPrompt: String = AnthropicService.defaultSystemPrompt
    @State private var translateLanguages: [String] = ["English"]
    @State private var newLanguage: String = ""
    @State private var showClearTranslateConfirmation: Bool = false
    @State private var searchPaths: [String] = []
    @State private var newSearchPath: String = ""

    var body: some View {
        TabView {
            generalTab.tabItem { Label("General", systemImage: "gear") }
            scriptsTab.tabItem { Label("Scripts", systemImage: "terminal") }
            clipboardTab.tabItem { Label("Clipboard", systemImage: "clipboard") }
            translateTab
                .tabItem { Label("Translate", systemImage: "character.book.closed") }
        }
        .frame(width: 450, height: 500)
        .onAppear {
            selectedInputSourceId = UserDefaults.standard.string(forKey: "forceInputSourceId") ?? ""
            clearQueryOnOpen = UserDefaults.standard.bool(forKey: "clearQueryOnOpen")
            launchAtLogin = SMAppService.mainApp.status == .enabled
            selectedAppearance = UserDefaults.standard.string(forKey: "appAppearance") ?? "system"
            availableInputSources = Self.getKeyboardLayouts()
            showMaxResults = UserDefaults.standard.object(forKey: "maxSearchResults") as? Int ?? 10
            searchPaths = appState.appSearcher.searchPaths
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

                KeyboardShortcuts.Recorder("Hotkey:", name: .toggleRelux)
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

                Toggle("Show menu bar icon", isOn: $showMenuBarIcon)
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

            Section {
                ForEach(Array(searchPaths.enumerated()), id: \.offset) { index, path in
                    HStack {
                        Image(systemName: "folder")
                            .foregroundColor(.secondary)
                            .font(.system(size: 12))
                        Text(path)
                            .font(.system(size: 12, design: .monospaced))
                            .lineLimit(1)
                        Spacer()
                        Button(role: .destructive) {
                            searchPaths.remove(at: index)
                            appState.appSearcher.searchPaths = searchPaths
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                    }
                }

                HStack {
                    TextField("/path/to/directory", text: $newSearchPath)
                        .font(.system(size: 12, design: .monospaced))
                    Button("Add") {
                        let trimmed = newSearchPath.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !searchPaths.contains(trimmed) else { return }
                        searchPaths.append(trimmed)
                        appState.appSearcher.searchPaths = searchPaths
                        newSearchPath = ""
                    }
                    .disabled(newSearchPath.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Button("Reset to Defaults") {
                    searchPaths = AppSearcher.defaultSearchPaths
                    appState.appSearcher.searchPaths = searchPaths
                }
                .font(.system(size: 12))
            } header: {
                Text("Search Paths")
            } footer: {
                Text("Directories indexed for application search.")
                    .font(.caption)
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

            Section {
                Button("Quit Relux") {
                    NSApp.terminate(nil)
                }
                .frame(maxWidth: .infinity, alignment: .center)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            applyAppearance(selectedAppearance)
        }
    }

    // MARK: - Scripts Tab

    @State private var expandedScriptId: String?
    @State private var editingScript: ScriptItem?

    private var scriptsTab: some View {
        Form {
            Section(header: HStack {
                Text("Scripts")
                Spacer()
                Button {
                    appState.scriptSearcher.load()
                } label: {
                    Image(systemName: "arrow.clockwise")
                        .font(.system(size: 11))
                }
                .buttonStyle(.borderless)
                .help("Reload scripts from disk")
            }) {
                if appState.scriptSearcher.scripts.isEmpty {
                    Text("No scripts added yet")
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(appState.scriptSearcher.scripts) { script in
                        scriptRow(script)
                    }
                }

                Button {
                    appState.scriptSearcher.add(title: "", command: "")
                    if let last = appState.scriptSearcher.scripts.last {
                        expandedScriptId = last.id
                        editingScript = last
                    }
                } label: {
                    Label("Add Script", systemImage: "plus")
                }
                .buttonStyle(.borderless)
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
        .onDisappear { commitEditing() }
    }

    @ViewBuilder
    private func scriptRow(_ script: ScriptItem) -> some View {
        let isExpanded = expandedScriptId == script.id

        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12)

                VStack(alignment: .leading, spacing: 2) {
                    Text(script.title.isEmpty ? "Untitled" : script.title)
                        .font(.system(size: 13, weight: .medium))
                        .foregroundStyle(script.title.isEmpty ? .secondary : .primary)
                    Text(script.command.isEmpty ? "no command" : script.command)
                        .font(.system(size: 11, design: .monospaced))
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Spacer()

                if !isExpanded {
                    scriptBadges(script)
                }

                Button(role: .destructive) {
                    appState.scriptSearcher.remove(id: script.id)
                    if expandedScriptId == script.id {
                        expandedScriptId = nil
                        editingScript = nil
                    }
                } label: {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
            }
            .contentShape(Rectangle())
            .onTapGesture {
                withAnimation(.easeInOut(duration: 0.15)) {
                    commitEditing()
                    if isExpanded {
                        expandedScriptId = nil
                        editingScript = nil
                    } else {
                        expandedScriptId = script.id
                        editingScript = script
                    }
                }
            }

            if isExpanded, editingScript != nil {
                Divider()
                    .padding(.vertical, 6)

                scriptEditForm()
            }
        }
    }

    @ViewBuilder
    private func scriptBadges(_ script: ScriptItem) -> some View {
        if script.acceptsSelection {
            scriptBadge("stdin")
        }
        if script.outputMode != .none {
            scriptBadge(script.outputMode.label)
        }
        if script.inputFilter != .any, script.acceptsSelection {
            scriptBadge(script.inputFilter.label)
        }
    }

    private func scriptBadge(_ text: String) -> some View {
        Text(text)
            .font(.system(size: 9, weight: .medium))
            .padding(.horizontal, 5)
            .padding(.vertical, 2)
            .background(.quaternary)
            .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    @ViewBuilder
    private func scriptEditForm() -> some View {
        if editingScript != nil {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent("Title") {
                    TextField("Script title", text: Binding(
                        get: { editingScript?.title ?? "" },
                        set: { editingScript?.title = $0 }
                    ))
                    .textFieldStyle(.roundedBorder)
                }

                LabeledContent("Command") {
                    TextField("Shell command", text: Binding(
                        get: { editingScript?.command ?? "" },
                        set: { editingScript?.command = $0 }
                    ))
                    .font(.system(size: 12, design: .monospaced))
                    .textFieldStyle(.roundedBorder)
                }

                Toggle("Accepts stdin (pass selected text)", isOn: Binding(
                    get: { editingScript?.acceptsSelection ?? false },
                    set: { editingScript?.acceptsSelection = $0 }
                ))
                .toggleStyle(.checkbox)

                scriptEditPickers()
            }
            .padding(.leading, 24)
            .padding(.bottom, 4)
        }
    }

    @ViewBuilder
    private func scriptEditPickers() -> some View {
        HStack(spacing: 16) {
            LabeledContent("Output") {
                Picker("", selection: Binding(
                    get: { editingScript?.outputMode ?? .none },
                    set: { editingScript?.outputMode = $0 }
                )) {
                    ForEach(ScriptOutputMode.allCases, id: \.self) { mode in
                        Text(mode.label).tag(mode)
                    }
                }
                .frame(width: 100)
            }

            if editingScript?.acceptsSelection == true {
                LabeledContent("Filter") {
                    Picker("", selection: Binding(
                        get: { editingScript?.inputFilter.tag ?? "any" },
                        set: { newValue in
                            let pattern = editingScript?.inputFilter.regexPattern
                            editingScript?.inputFilter = InputFilter.fromTag(newValue, existingPattern: pattern)
                        }
                    )) {
                        Text("Any").tag("any")
                        Text("Integer").tag("integer")
                        Text("Number").tag("number")
                        Text("URL").tag("url")
                        Text("JSON").tag("json")
                        Text("Date/Time").tag("datetime")
                        Text("Regex").tag("regex")
                    }
                    .frame(width: 100)
                }
            }
        }

        if editingScript?.acceptsSelection == true, editingScript?.inputFilter.regexPattern != nil {
            LabeledContent("Pattern") {
                TextField("Regular expression", text: Binding(
                    get: { editingScript?.inputFilter.regexPattern ?? "" },
                    set: { editingScript?.inputFilter = .regex($0) }
                ))
                .font(.system(size: 11, design: .monospaced))
                .textFieldStyle(.roundedBorder)
            }
        }
    }

    private func commitEditing() {
        guard let editing = editingScript else { return }
        // Only save if it has meaningful content
        if editing.title.isEmpty, editing.command.isEmpty {
            appState.scriptSearcher.remove(id: editing.id)
        } else {
            appState.scriptSearcher.update(editing)
        }
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

    // MARK: - Clipboard Tab

    private struct DisabledApp: Identifiable {
        let id: String // bundle ID
        let name: String
        let icon: NSImage?
    }

    private var clipboardTab: some View {
        Form {
            Section("Monitoring") {
                Toggle("Enable clipboard history", isOn: $clipboardEnabled)
                    .onChange(of: clipboardEnabled) { _, newValue in
                        if let monitor = appState.clipboardMonitor {
                            monitor.isEnabled = newValue
                        } else {
                            UserDefaults.standard.set(newValue, forKey: "clipboardEnabled")
                        }
                    }

                KeyboardShortcuts.Recorder("Hotkey:", name: .clipboardHistory)
            }

            Section("Storage") {
                Picker("Keep history for:", selection: $clipboardRetention) {
                    Text("1 Month").tag(1)
                    Text("3 Months").tag(3)
                    Text("6 Months").tag(6)
                }
                .onChange(of: clipboardRetention) { _, newValue in
                    UserDefaults.standard.set(newValue, forKey: "clipboardRetentionMonths")
                }

                Button("Clear All History", role: .destructive) {
                    showClearConfirmation = true
                }
                .alert("Clear Clipboard History?", isPresented: $showClearConfirmation) {
                    Button("Cancel", role: .cancel) {}
                    Button("Clear", role: .destructive) {
                        try? appState.clipboardStore?.clearAll()
                    }
                } message: {
                    Text("This will permanently delete all clipboard history entries and images.")
                }
            }

            Section {
                Button("Select More Apps") {
                    selectDisabledApp()
                }

                ForEach(disabledApps) { app in
                    HStack {
                        if let icon = app.icon {
                            Image(nsImage: icon)
                                .resizable()
                                .frame(width: 20, height: 20)
                        }
                        Text(app.name)
                        Spacer()
                        Button {
                            removeDisabledApp(bundleId: app.id)
                        } label: {
                            Image(systemName: "xmark.circle")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.borderless)
                    }
                }
            } header: {
                Text("Disabled Applications")
            } footer: {
                Text("Clipboard history will not record copies from these apps.")
                    .font(.caption)
            }
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            loadDisabledApps()
        }
    }

    private func loadDisabledApps() {
        let bundleIds = appState.clipboardMonitor?.disabledApps ?? []
        disabledApps = bundleIds.compactMap { bundleId in
            guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
                return DisabledApp(id: bundleId, name: bundleId, icon: nil)
            }
            let name = FileManager.default.displayName(atPath: url.path)
            let icon = NSWorkspace.shared.icon(forFile: url.path)
            return DisabledApp(id: bundleId, name: name, icon: icon)
        }
    }

    private func selectDisabledApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        guard let bundle = Bundle(url: url),
              let bundleId = bundle.bundleIdentifier else { return }

        appState.clipboardMonitor?.disabledApps.insert(bundleId)
        loadDisabledApps()
    }

    private func removeDisabledApp(bundleId: String) {
        appState.clipboardMonitor?.disabledApps.remove(bundleId)
        loadDisabledApps()
    }

    // MARK: - Translate Tab

    private var translateTab: some View {
        Form {
            Section("Anthropic API") {
                SecureField("API Key", text: $anthropicApiKey)
                    .onChange(of: anthropicApiKey) { _, newValue in
                        if newValue.isEmpty {
                            KeychainHelper.delete(key: "anthropicApiKey")
                        } else {
                            KeychainHelper.save(key: "anthropicApiKey", value: newValue)
                        }
                    }

                TextField("Model", text: $translateModel)
                    .onChange(of: translateModel) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "translateModel")
                    }
            }

            Section("System Prompt") {
                TextEditor(text: $translateSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
                    .onChange(of: translateSystemPrompt) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "translateSystemPrompt")
                    }

                Button("Reset to Default") {
                    translateSystemPrompt = AnthropicService.defaultSystemPrompt
                    UserDefaults.standard.removeObject(forKey: "translateSystemPrompt")
                }
                .font(.system(size: 12))
            }

            Section("Languages") {
                List {
                    ForEach(translateLanguages, id: \.self) { lang in
                        HStack {
                            Text(lang)
                            Spacer()
                            if lang == translateLanguages.first {
                                Text("Default")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        translateLanguages.move(fromOffsets: from, toOffset: to)
                        UserDefaults.standard.set(translateLanguages, forKey: "translateLanguages")
                    }
                    .onDelete { offsets in
                        guard translateLanguages.count > 1 else { return }
                        translateLanguages.remove(atOffsets: offsets)
                        UserDefaults.standard.set(translateLanguages, forKey: "translateLanguages")
                    }
                }
                .frame(minHeight: 80)

                HStack {
                    TextField("Add language...", text: $newLanguage)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newLanguage.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !translateLanguages.contains(trimmed) else { return }
                        translateLanguages.append(trimmed)
                        UserDefaults.standard.set(translateLanguages, forKey: "translateLanguages")
                        newLanguage = ""
                    }
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("Top language is the default for quick translation. Drag to reorder.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("History") {
                Button("Clear Translation History", role: .destructive) {
                    showClearTranslateConfirmation = true
                }
                .confirmationDialog("Clear all translation history?", isPresented: $showClearTranslateConfirmation) {
                    Button("Clear All", role: .destructive) {
                        try? appState.translateStore?.clearAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            anthropicApiKey = KeychainHelper.load(key: "anthropicApiKey") ?? ""
            translateModel = UserDefaults.standard.string(forKey: "translateModel") ?? AnthropicService.defaultModel
            translateSystemPrompt = UserDefaults.standard.string(forKey: "translateSystemPrompt")
                ?? AnthropicService.defaultSystemPrompt
            translateLanguages = UserDefaults.standard.stringArray(forKey: "translateLanguages") ?? ["English"]
        }
    }

    // MARK: - Helpers

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
            guard type == kTISTypeKeyboardLayout as String
                || type == kTISTypeKeyboardInputMode as String else { continue }

            guard let selectableRef = TISGetInputSourceProperty(
                source, kTISPropertyInputSourceIsSelectCapable
            ) else { continue }
            let selectable = (Unmanaged<CFNumber>.fromOpaque(selectableRef)
                .takeUnretainedValue() as? Bool) ?? false
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
