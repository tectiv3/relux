import SwiftUI

struct GestureSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var gesturesEnabled: Bool = false
    @State private var stableFrames: Double = .init(UserDefaults.standard.object(forKey: "gesture.stableFrames") as? Int ?? 2)
    @State private var swipeThreshold: Double = .init(UserDefaults.standard.object(forKey: "gesture.swipeThreshold") as? Float ?? 0.15)
    @State private var edgeMargin: Double = .init(UserDefaults.standard.object(forKey: "gesture.edgeMargin") as? Float ?? 0.05)

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
                    if gesture == .threeFingerClick {
                        HStack(spacing: 8) {
                            Text(gesture.displayName)
                                .frame(minWidth: 130, alignment: .leading)
                            Text("\u{2318}+Click")
                                .foregroundStyle(.secondary)
                            Spacer()
                        }
                    } else {
                        GestureBindingRow(gesture: gesture, manager: appState.gestureBindingManager)
                    }
                }
            }
            .disabled(!gesturesEnabled)

            Section("Keyboard Shortcuts") {
                ForEach(appState.gestureBindingManager.shortcutBindings) { binding in
                    ShortcutBindingRow(binding: binding, manager: appState.gestureBindingManager)
                }
                AddShortcutButton(manager: appState.gestureBindingManager)
            }

            DisclosureGroup("Advanced") {
                VStack(alignment: .leading, spacing: 12) {
                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Stable frames")
                            Spacer()
                            Text("\(Int(stableFrames))")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $stableFrames, in: 1 ... 8, step: 1)
                            .onChange(of: stableFrames) { _, v in
                                UserDefaults.standard.set(Int(v), forKey: "gesture.stableFrames")
                            }
                        Text("Frames with 3 fingers before tracking starts. Lower = faster but more false positives.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Swipe threshold")
                            Spacer()
                            Text(String(format: "%.2f", swipeThreshold))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $swipeThreshold, in: 0.05 ... 0.40, step: 0.01)
                            .onChange(of: swipeThreshold) { _, v in
                                UserDefaults.standard.set(Float(v), forKey: "gesture.swipeThreshold")
                            }
                        Text("Minimum finger travel to register a swipe. Lower = easier to trigger.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Edge margin")
                            Spacer()
                            Text(String(format: "%.2f", edgeMargin))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $edgeMargin, in: 0.0 ... 0.15, step: 0.01)
                            .onChange(of: edgeMargin) { _, v in
                                UserDefaults.standard.set(Float(v), forKey: "gesture.edgeMargin")
                            }
                        Text("Trackpad edge zone for palm rejection. Higher = more aggressive filtering.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }
                }
                .padding(.vertical, 4)
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
        _manager = State(initialValue: manager)

        let action = manager.binding(for: gesture)?.action ?? .none

        switch action {
        case let .keyCombo(combo):
            _actionTag = State(initialValue: "keyCombo")
            _selectedKeyCombo = State(initialValue: combo)
            _selectedSystemAction = State(initialValue: .missionControl)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        case let .system(sys):
            _actionTag = State(initialValue: "system")
            _selectedKeyCombo = State(initialValue: nil)
            _selectedSystemAction = State(initialValue: sys)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        case let .relux(rel):
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
        HStack(spacing: 8) {
            Text(gesture.displayName)
                .frame(minWidth: 130, alignment: .leading)

            Picker("Type", selection: $actionTag) {
                Text("None").tag("none")
                Text("Key Combo").tag("keyCombo")
                Text("System").tag("system")
                Text("Relux").tag("relux")
            }
            .labelsHidden()
            .fixedSize()
            .onChange(of: actionTag) { _, newValue in
                updateAction(tag: newValue)
            }

            actionDetail

            Spacer()
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
            Picker("Action", selection: $selectedSystemAction) {
                ForEach(SystemAction.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .onChange(of: selectedSystemAction) { _, newAction in
                manager.updateBinding(for: gesture, action: .system(newAction))
            }
        case "relux":
            Picker("Action", selection: $selectedReluxAction) {
                ForEach(ReluxAction.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
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
        _manager = State(initialValue: manager)

        switch binding.action {
        case let .system(sys):
            _actionTag = State(initialValue: "system")
            _selectedSystemAction = State(initialValue: sys)
            _selectedReluxAction = State(initialValue: .toggleRelux)
        case let .relux(rel):
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
        HStack(spacing: 8) {
            Text(binding.trigger.displayString)
                .font(.system(.body, design: .monospaced))
                .frame(minWidth: 50, alignment: .leading)

            Picker("Type", selection: $actionTag) {
                Text("System").tag("system")
                Text("Relux").tag("relux")
            }
            .labelsHidden()
            .onChange(of: actionTag) { _, newValue in
                let action: GestureActionType = newValue == "relux"
                    ? .relux(selectedReluxAction)
                    : .system(selectedSystemAction)
                manager.updateShortcutBinding(id: binding.id, action: action)
            }

            actionDetail

            Spacer()

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
            Picker("Action", selection: $selectedSystemAction) {
                ForEach(SystemAction.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .onChange(of: selectedSystemAction) { _, v in
                manager.updateShortcutBinding(id: binding.id, action: .system(v))
            }
        case "relux":
            Picker("Action", selection: $selectedReluxAction) {
                ForEach(ReluxAction.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
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
