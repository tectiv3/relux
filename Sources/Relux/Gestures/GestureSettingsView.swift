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

                Text(
                    "Configure System Settings: set \"Swipe between pages\" and \"Mission Control\" to 4 fingers. Disable \"Three finger drag\" in Accessibility > Pointer Control > Trackpad Options. Set \"Look up & data detectors\" to Off or Force Click."
                )
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }

            Section("Gesture Bindings") {
                ForEach(GestureType.allCases, id: \.rawValue) { gesture in
                    GestureBindingRow(gesture: gesture, manager: appState.gestureBindingManager)
                }
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

        let binding = manager.binding(for: gesture)
        let action = binding?.action ?? .none

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
