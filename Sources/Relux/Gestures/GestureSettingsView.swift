import SwiftUI

struct GestureSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var gesturesEnabled: Bool = false

    var body: some View {
        Form {
            Section {
                Toggle("Enable Gesture Shortcuts", isOn: $gesturesEnabled)
                    .onChange(of: gesturesEnabled) { _, enabled in
                        appState.extensionRegistry.setEnabled("gestures", enabled: enabled)
                        appState.gestureBindingManager.syncWithExtension(enabled: enabled)
                    }
            }

            Section("Gesture Bindings") {
                ForEach(GestureType.allCases, id: \.rawValue) { gesture in
                    GestureBindingRow(gesture: gesture, manager: appState.gestureBindingManager)
                }
            }
            .disabled(!gesturesEnabled)

            Section("Keyboard Shortcuts") {
                ForEach(appState.gestureBindingManager.shortcutBindings) { binding in
                    ShortcutBindingRow(binding: binding, manager: appState.gestureBindingManager)
                }
                AddShortcutButton(manager: appState.gestureBindingManager)
            }
            .disabled(!gesturesEnabled)
        }
        .formStyle(.grouped)
        .padding()
        .onAppear {
            gesturesEnabled = appState.extensionRegistry.isEnabled("gestures")
        }
    }
}

// MARK: - Gesture Binding Row

private struct GestureBindingRow: View {
    let gesture: GestureType
    @State var manager: GestureBindingManager
    @State private var actionTag: String
    @State private var selectedKeyCombo: KeyCombo?
    @State private var selectedSystemAction: SystemAction
    @State private var selectedReluxAction: ReluxAction

    init(gesture: GestureType, manager: GestureBindingManager) {
        self.gesture = gesture
        self._manager = State(initialValue: manager)

        let action = manager.binding(for: gesture)?.action ?? .none

        switch action {
        case .keyCombo(let combo):
            _actionTag = State(initialValue: "keyCombo")
            _selectedKeyCombo = State(initialValue: combo)
            _selectedSystemAction = State(initialValue: .missionControl)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        case .system(let sys):
            _actionTag = State(initialValue: "system")
            _selectedKeyCombo = State(initialValue: nil)
            _selectedSystemAction = State(initialValue: sys)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        case .relux(let rel):
            _actionTag = State(initialValue: "relux")
            _selectedKeyCombo = State(initialValue: nil)
            _selectedSystemAction = State(initialValue: .missionControl)
            _selectedReluxAction = State(initialValue: rel)
        case .none:
            _actionTag = State(initialValue: "none")
            _selectedKeyCombo = State(initialValue: nil)
            _selectedSystemAction = State(initialValue: .missionControl)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        }
    }

    var body: some View {
        HStack {
            Text(gesture.displayName)
                .frame(width: 150, alignment: .leading)

            Picker("", selection: $actionTag) {
                Text("None").tag("none")
                Text("Key Combo").tag("keyCombo")
                Text("System").tag("system")
                Text("Relux").tag("relux")
            }
            .frame(width: 120)
            .onChange(of: actionTag) { _, newValue in
                updateAction(tag: newValue)
            }

            actionDetail
        }
    }

    @ViewBuilder
    private var actionDetail: some View {
        switch actionTag {
        case "keyCombo":
            ShortcutRecorderView(keyCombo: $selectedKeyCombo)
                .onChange(of: selectedKeyCombo) { _, newCombo in
                    if let combo = newCombo {
                        manager.updateBinding(for: gesture, action: .keyCombo(combo))
                    }
                }
        case "system":
            Picker("", selection: $selectedSystemAction) {
                ForEach(SystemAction.allCases, id: \.rawValue) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .frame(width: 140)
            .onChange(of: selectedSystemAction) { _, newAction in
                manager.updateBinding(for: gesture, action: .system(newAction))
            }
        case "relux":
            Picker("", selection: $selectedReluxAction) {
                ForEach(ReluxAction.allCases, id: \.rawValue) { action in
                    Text(action.displayName).tag(action)
                }
            }
            .frame(width: 140)
            .onChange(of: selectedReluxAction) { _, newAction in
                manager.updateBinding(for: gesture, action: .relux(newAction))
            }
        default:
            EmptyView()
        }
    }

    private func updateAction(tag: String) {
        switch tag {
        case "keyCombo":
            if let combo = selectedKeyCombo {
                manager.updateBinding(for: gesture, action: .keyCombo(combo))
            } else {
                manager.updateBinding(for: gesture, action: .none)
            }
        case "system":
            manager.updateBinding(for: gesture, action: .system(selectedSystemAction))
        case "relux":
            manager.updateBinding(for: gesture, action: .relux(selectedReluxAction))
        default:
            manager.updateBinding(for: gesture, action: .none)
        }
    }
}

// MARK: - Shortcut Binding Row

private struct ShortcutBindingRow: View {
    let binding: ShortcutBinding
    @State var manager: GestureBindingManager
    @State private var actionTag: String
    @State private var selectedSystemAction: SystemAction
    @State private var selectedReluxAction: ReluxAction

    init(binding: ShortcutBinding, manager: GestureBindingManager) {
        self.binding = binding
        self._manager = State(initialValue: manager)

        switch binding.action {
        case .system(let sys):
            _actionTag = State(initialValue: "system")
            _selectedSystemAction = State(initialValue: sys)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        case .relux(let rel):
            _actionTag = State(initialValue: "relux")
            _selectedSystemAction = State(initialValue: .lockScreen)
            _selectedReluxAction = State(initialValue: rel)
        default:
            _actionTag = State(initialValue: "system")
            _selectedSystemAction = State(initialValue: .lockScreen)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        }
    }

    var body: some View {
        HStack {
            Text(binding.trigger.displayString)
                .frame(width: 80, alignment: .leading)
                .font(.system(.body, design: .monospaced))

            Picker("", selection: $actionTag) {
                Text("System").tag("system")
                Text("Relux").tag("relux")
            }
            .frame(width: 90)
            .onChange(of: actionTag) { _, newValue in
                let action: GestureActionType = newValue == "relux"
                    ? .relux(selectedReluxAction)
                    : .system(selectedSystemAction)
                manager.updateShortcutBinding(id: binding.id, action: action)
            }

            actionDetail

            Button(role: .destructive) {
                manager.removeShortcutBinding(id: binding.id)
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
        }
    }

    @ViewBuilder
    private var actionDetail: some View {
        switch actionTag {
        case "system":
            Picker("", selection: $selectedSystemAction) {
                ForEach(SystemAction.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .frame(width: 120)
            .onChange(of: selectedSystemAction) { _, v in
                manager.updateShortcutBinding(id: binding.id, action: .system(v))
            }
        case "relux":
            Picker("", selection: $selectedReluxAction) {
                ForEach(ReluxAction.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .frame(width: 120)
            .onChange(of: selectedReluxAction) { _, v in
                manager.updateShortcutBinding(id: binding.id, action: .relux(v))
            }
        default:
            EmptyView()
        }
    }
}

// MARK: - Add Shortcut Button

private struct AddShortcutButton: View {
    static let functionKeyCodes: Set<Int> = [122, 120, 99, 118, 96, 97, 98, 100, 101, 109, 103, 111, 105, 107, 113]

    @State var manager: GestureBindingManager
    @State private var recording = false
    @State private var monitor: Any?

    var body: some View {
        HStack {
            if recording {
                Text("Press a key combination...")
                    .foregroundStyle(.red)
                Spacer()
                Button("Cancel") { stopRecording() }
            } else {
                Button("Add Shortcut") { startRecording() }
            }
        }
        .onDisappear { removeMonitor() }
    }

    private func startRecording() {
        recording = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            let code = event.keyCode
            let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

            if code == 53 {
                stopRecording()
                return nil
            }

            let isFunctionKey = Self.functionKeyCodes.contains(Int(code))
            if !isFunctionKey {
                guard !mods.intersection([.command, .option, .control]).isEmpty else {
                    return nil
                }
            }

            let combo = KeyCombo(keyCode: code, modifierRawValue: mods.rawValue)
            manager.addShortcutBinding(trigger: combo, action: .system(.lockScreen))
            stopRecording()
            return nil
        }
    }

    private func stopRecording() {
        recording = false
        removeMonitor()
    }

    private func removeMonitor() {
        if let m = monitor {
            NSEvent.removeMonitor(m)
            monitor = nil
        }
    }
}

