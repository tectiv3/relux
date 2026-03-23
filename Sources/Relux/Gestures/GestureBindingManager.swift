import AppKit
import os

private let log = Logger(subsystem: "com.relux.app", category: "gesture-bindings")

@MainActor
@Observable
final class GestureBindingManager {
    private(set) var bindings: [GestureBinding]
    private(set) var shortcutBindings: [ShortcutBinding]
    private let engine = GestureEngine()
    private let hotkeyListener = HotkeyListener()
    private let storageKey = "gesture.bindings"
    private let shortcutStorageKey = "gesture.shortcutBindings"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([GestureBinding].self, from: data)
        {
            bindings = decoded
        } else {
            bindings = GestureType.allCases.map { GestureBinding(gesture: $0, action: .none) }
        }

        if let data = UserDefaults.standard.data(forKey: shortcutStorageKey),
           let decoded = try? JSONDecoder().decode([ShortcutBinding].self, from: data)
        {
            shortcutBindings = decoded
        } else {
            shortcutBindings = []
        }

        engine.onGesture = { [weak self] gesture in
            self?.handleGesture(gesture)
        }
        hotkeyListener.onHotkey = { [weak self] combo in
            self?.handleHotkey(combo)
        }
    }

    func addShortcutBinding(trigger: KeyCombo, action: GestureActionType) {
        shortcutBindings.append(ShortcutBinding(trigger: trigger, action: action))
        saveShortcuts()
        syncHotkeyRegistrations()
    }

    func updateShortcutBinding(id: String, action: GestureActionType) {
        if let index = shortcutBindings.firstIndex(where: { $0.id == id }) {
            shortcutBindings[index].action = action
            saveShortcuts()
        }
    }

    func removeShortcutBinding(id: String) {
        shortcutBindings.removeAll { $0.id == id }
        saveShortcuts()
        syncHotkeyRegistrations()
    }

    func updateBinding(for gesture: GestureType, action: GestureActionType) {
        if let index = bindings.firstIndex(where: { $0.gesture == gesture }) {
            bindings[index].action = action
        }
        save()
    }

    func binding(for gesture: GestureType) -> GestureBinding? {
        bindings.first { $0.gesture == gesture }
    }

    func startIfEnabled(registry: ExtensionRegistry) {
        if registry.isEnabled("gestures") {
            engine.start()
            hotkeyListener.start()
            syncHotkeyRegistrations()
        }
    }

    func syncWithExtension(enabled: Bool) {
        if enabled {
            engine.start()
            hotkeyListener.start()
            syncHotkeyRegistrations()
        } else {
            engine.stop()
            hotkeyListener.stop()
        }
    }

    private func syncHotkeyRegistrations() {
        let keys = Set(shortcutBindings.map(\.trigger.storageKey))
        hotkeyListener.updateRegisteredKeys(keys)
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func saveShortcuts() {
        guard let data = try? JSONEncoder().encode(shortcutBindings) else { return }
        UserDefaults.standard.set(data, forKey: shortcutStorageKey)
    }

    private func handleHotkey(_ combo: KeyCombo) {
        guard let binding = shortcutBindings.first(where: { $0.trigger == combo }) else { return }
        executeAction(binding.action)
    }

    private func handleGesture(_ gesture: GestureType) {
        guard let binding = bindings.first(where: { $0.gesture == gesture }) else { return }
        executeAction(binding.action)
    }

    private func executeAction(_ action: GestureActionType) {
        switch action {
        case .keyCombo(let combo):
            postKeyCombo(combo)
        case .system(let sysAction):
            executeSystemAction(sysAction)
        case .relux(let reluxAction):
            executeReluxAction(reluxAction)
        case .none:
            break
        }
    }

    private func postKeyCombo(_ combo: KeyCombo) {
        var flags = CGEventFlags()
        if combo.modifiers.contains(.command) { flags.insert(.maskCommand) }
        if combo.modifiers.contains(.option) { flags.insert(.maskAlternate) }
        if combo.modifiers.contains(.control) { flags.insert(.maskControl) }
        if combo.modifiers.contains(.shift) { flags.insert(.maskShift) }

        guard let keyDown = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: nil, virtualKey: combo.keyCode, keyDown: false)
        else {
            log.error("Failed to create CGEvent for key combo")
            return
        }

        keyDown.flags = flags
        keyUp.flags = flags
        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }

    private func executeSystemAction(_ action: SystemAction) {
        switch action {
        case .lockScreen:
            postKeyCombo(KeyCombo(keyCode: 12, modifierRawValue: NSEvent.ModifierFlags([.control, .command]).rawValue))
        case .missionControl:
            postKeyCombo(KeyCombo(keyCode: 126, modifierRawValue: NSEvent.ModifierFlags([.control]).rawValue))
        case .appExpose:
            postKeyCombo(KeyCombo(keyCode: 125, modifierRawValue: NSEvent.ModifierFlags([.control]).rawValue))
        case .showDesktop:
            postKeyCombo(KeyCombo(keyCode: 103, modifierRawValue: 0))
        }
    }

    private func executeReluxAction(_ action: ReluxAction) {
        guard let delegate = NSApp.delegate as? AppDelegate else {
            log.error("Could not get AppDelegate for Relux action")
            return
        }

        switch action {
        case .toggleRelux:
            delegate.togglePanel()
        case .clipboardHistory:
            delegate.toggleClipboardHistory()
        case .translate:
            guard let panel = delegate.panel else { return }
            if panel.isVisible, delegate.appState.panelMode == .translate {
                let frame = panel.frame
                UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
                UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
                delegate.appState.panelClosedAt = Date()
                panel.close()
                return
            }
            if !panel.isVisible {
                delegate.appState.previousApp = NSWorkspace.shared.frontmostApplication
            }
            delegate.appState.panelMode = .translate
            if !panel.isVisible {
                DispatchQueue.main.async {
                    panel.makeKeyAndOrderFront(nil)
                }
            }
        }
    }
}
