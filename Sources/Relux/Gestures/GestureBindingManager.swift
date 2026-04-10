import AppKit
import KeyboardShortcuts
import os

private let log = Logger(subsystem: "com.relux.app", category: "gesture-bindings")

@MainActor
@Observable
final class GestureBindingManager {
    private(set) var bindings: [GestureBinding]
    private(set) var shortcutBindings: [ShortcutBinding]
    private let engine = GestureEngine()
    private let storageKey = "gesture.bindings"
    private let shortcutStorageKey = "gesture.shortcutBindings"

    init() {
        if let data = UserDefaults.standard.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode([GestureBinding].self, from: data)
        {
            // Merge in any new gesture types that didn't exist in saved data
            let saved = Dictionary(uniqueKeysWithValues: decoded.map { ($0.gesture, $0.action) })
            bindings = GestureType.allCases.map { gesture in
                if let action = saved[gesture] {
                    return GestureBinding(gesture: gesture, action: action)
                }
                return GestureBinding(gesture: gesture, action: Self.defaultAction(for: gesture))
            }
        } else {
            bindings = GestureType.allCases.map { GestureBinding(gesture: $0, action: Self.defaultAction(for: $0)) }
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
    }

    func addShortcutBinding(trigger: KeyCombo, action: GestureActionType) {
        let binding = ShortcutBinding(trigger: trigger, action: action)
        shortcutBindings.append(binding)
        saveShortcuts()
        registerShortcut(for: binding)
    }

    func updateShortcutBinding(id: String, action: GestureActionType) {
        if let index = shortcutBindings.firstIndex(where: { $0.id == id }) {
            shortcutBindings[index].action = action
            saveShortcuts()
        }
    }

    func removeShortcutBinding(id: String) {
        unregisterShortcut(storageKey: id)
        shortcutBindings.removeAll { $0.id == id }
        saveShortcuts()
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
        registerAllShortcuts()

        if registry.isEnabled("gestures") {
            engine.start()
        }
    }

    func syncWithExtension(enabled: Bool) {
        if enabled {
            engine.start()
        } else {
            engine.stop()
        }
    }

    // MARK: - KeyboardShortcuts Registration

    private static func shortcutName(for storageKey: String) -> KeyboardShortcuts.Name {
        KeyboardShortcuts.Name("gesture.shortcut.\(storageKey)")
    }

    private func registerShortcut(for binding: ShortcutBinding) {
        let name = Self.shortcutName(for: binding.trigger.storageKey)
        let key = KeyboardShortcuts.Key(rawValue: Int(binding.trigger.keyCode))
        KeyboardShortcuts.setShortcut(.init(key, modifiers: binding.trigger.modifiers), for: name)
        let trigger = binding.trigger
        KeyboardShortcuts.onKeyUp(for: name) { [weak self] in
            self?.handleHotkey(trigger)
        }
    }

    private func unregisterShortcut(storageKey: String) {
        let name = Self.shortcutName(for: storageKey)
        KeyboardShortcuts.removeHandler(for: name)
        KeyboardShortcuts.setShortcut(nil, for: name)
    }

    private func registerAllShortcuts() {
        for binding in shortcutBindings {
            registerShortcut(for: binding)
        }
    }

    // MARK: - Persistence

    private func save() {
        guard let data = try? JSONEncoder().encode(bindings) else { return }
        UserDefaults.standard.set(data, forKey: storageKey)
    }

    private func saveShortcuts() {
        guard let data = try? JSONEncoder().encode(shortcutBindings) else { return }
        UserDefaults.standard.set(data, forKey: shortcutStorageKey)
    }

    private static func defaultAction(for gesture: GestureType) -> GestureActionType {
        switch gesture {
        case .fourFingerSwipeLeft: .system(.switchSpaceLeft)
        case .fourFingerSwipeRight: .system(.switchSpaceRight)
        default: .none
        }
    }

    // MARK: - Action Handling

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
        case let .keyCombo(combo):
            postKeyCombo(combo)
        case let .system(sysAction):
            executeSystemAction(sysAction)
        case let .relux(reluxAction):
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
        case .switchSpaceLeft:
            _ = iss_switch(ISSDirectionLeft)
        case .switchSpaceRight:
            _ = iss_switch(ISSDirectionRight)
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
