import SwiftUI

struct GestureSettingsView: View {
    @Environment(AppState.self) private var appState
    @State private var gesturesEnabled: Bool = false
    // Seeded once from the store at view init (no environment access in a property initializer),
    // matching the previous direct UserDefaults reads.
    @State private var threeFingerClickEnabled: Bool = SettingsStore().gestureThreeFingerClickEnabled
    @State private var stableFrames: Double = .init(SettingsStore().gestureStableFrames)
    @State private var swipeThreshold: Double = .init(SettingsStore().gestureSwipeThreshold)
    @State private var edgeMargin: Double = .init(SettingsStore().gestureEdgeMargin)
    @State private var keystrokeWindowMs: Double = .init(SettingsStore().gestureKeystrokeWindowMs)
    @State private var touchQualityMin: Double = .init(SettingsStore().gestureTouchQualityMin)
    @State private var fingerSpreadMin: Double = .init(SettingsStore().gestureFingerSpreadMin)
    @State private var aspectRatioMax: Double = .init(SettingsStore().gestureAspectRatioMax)

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
                            Toggle(isOn: $threeFingerClickEnabled) {
                                Text("\u{2318}+Click")
                                    .foregroundStyle(.secondary)
                            }
                            .toggleStyle(.switch)
                            .controlSize(.small)
                            .onChange(of: threeFingerClickEnabled) { _, enabled in
                                appState.settings.gestureThreeFingerClickEnabled = enabled
                            }
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
                            .onChange(of: stableFrames) { _, newValue in
                                appState.settings.gestureStableFrames = Int(newValue)
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
                            .onChange(of: swipeThreshold) { _, newValue in
                                appState.settings.gestureSwipeThreshold = Float(newValue)
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
                            .onChange(of: edgeMargin) { _, newValue in
                                appState.settings.gestureEdgeMargin = Float(newValue)
                            }
                        Text("Trackpad edge zone for palm rejection. Higher = more aggressive filtering.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Keystroke suppression")
                            Spacer()
                            Text("\(Int(keystrokeWindowMs)) ms")
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $keystrokeWindowMs, in: 0 ... 500, step: 10)
                            .onChange(of: keystrokeWindowMs) { _, newValue in
                                appState.settings.gestureKeystrokeWindowMs = Int(newValue)
                            }
                        Text("Ignore gestures for N ms after a keystroke. 0 = disabled.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Touch quality")
                            Spacer()
                            Text(String(format: "%.2f", touchQualityMin))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $touchQualityMin, in: 0.0 ... 0.5, step: 0.01)
                            .onChange(of: touchQualityMin) { _, newValue in
                                appState.settings.gestureTouchQualityMin = Float(newValue)
                            }
                        Text("Minimum touch capacitance to count. Higher = reject more noise.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Finger spread")
                            Spacer()
                            Text(String(format: "%.2f", fingerSpreadMin))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $fingerSpreadMin, in: 0.0 ... 0.4, step: 0.01)
                            .onChange(of: fingerSpreadMin) { _, newValue in
                                appState.settings.gestureFingerSpreadMin = Float(newValue)
                            }
                        Text("Minimum X-axis spread at arming. Higher rejects more palms but swipes that start with clustered fingers (fanning out mid-swipe) may lose travel distance. 0 = disabled.")
                            .font(.system(size: 10))
                            .foregroundStyle(.tertiary)
                    }

                    VStack(alignment: .leading, spacing: 2) {
                        HStack {
                            Text("Aspect ratio max")
                            Spacer()
                            Text(String(format: "%.1f", aspectRatioMax))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        Slider(value: $aspectRatioMax, in: 1.5 ... 5.0, step: 0.1)
                            .onChange(of: aspectRatioMax) { _, newValue in
                                appState.settings.gestureAspectRatioMax = Float(newValue)
                            }
                        Text("Reject elongated touches (palms). Lower = stricter. Raise if real gestures are being rejected.")
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
            .onChange(of: selectedSystemAction) { _, newAction in
                manager.updateShortcutBinding(id: binding.id, action: .system(newAction))
            }
        case "relux":
            Picker("Action", selection: $selectedReluxAction) {
                ForEach(ReluxAction.allCases, id: \.rawValue) { Text($0.displayName).tag($0) }
            }
            .labelsHidden()
            .onChange(of: selectedReluxAction) { _, newAction in
                manager.updateShortcutBinding(id: binding.id, action: .relux(newAction))
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
        .background(
            PanelKeyMonitor(isActive: recording, onWindowLost: stopRecording, handler: record)
        )
        .onDisappear { stopRecording() }
    }

    private func startRecording() {
        guard !recording else { return }
        recording = true
        GlobalHotkeySuspension.suspend()
    }

    /// Every key is consumed while recording, exactly as before: a bare modifier-less
    /// key is dropped, not passed on.
    private func record(_ event: NSEvent) -> NSEvent? {
        let code = event.keyCode
        let mods = event.modifierFlags.intersection(.deviceIndependentFlagsMask)

        if code == 53 {
            stopRecording()
            return nil
        }

        let isFunctionKey = Self.functionKeyCodes.contains(Int(code))
        if !isFunctionKey {
            guard !mods.isDisjoint(with: [.command, .option, .control]) else {
                return nil
            }
        }

        let combo = KeyCombo(keyCode: code, modifierRawValue: mods.rawValue)
        manager.addShortcutBinding(trigger: combo, action: .system(.lockScreen))
        stopRecording()
        return nil
    }

    /// Single release point for the suspension; the `recording` guard makes the
    /// escape/recorded-key/Cancel/teardown/window-close paths idempotent.
    private func stopRecording() {
        guard recording else { return }
        recording = false
        GlobalHotkeySuspension.resume()
    }
}
