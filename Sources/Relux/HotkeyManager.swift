@preconcurrency import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRelux = Self("toggleRelux", default: .init(.space, modifiers: [.option]))
    static let clipboardHistory = Self("clipboardHistory", default: .init(.v, modifiers: [.option, .command]))
}

/// Suspends all Carbon-registered global hotkeys while a recorder captures keys.
///
/// `KeyboardShortcuts` (2.4.0) has no `suspend()`/`resume()`; the only public knob is
/// `KeyboardShortcuts.isEnabled`. Setting it to `false` runs `CarbonKeyboardShortcuts
/// .softUnregisterAll()` — every `RegisterEventHotKey`d shortcut is unregistered and the
/// hotkey event types are removed from the handler — so a recorded combo that collides
/// with ⌥Space / ⌥⌘V reaches the local monitor instead of being swallowed. Setting it
/// back to `true` re-registers the same hotkeys.
///
/// Depth-counted so two recorders in different windows cannot resume each other early;
/// the count never goes below zero, and each caller only transitions on its own
/// false↔true edge, which keeps suspend/resume balanced by construction.
@MainActor
enum GlobalHotkeySuspension {
    private static var depth = 0

    static func suspend() {
        depth += 1
        if depth == 1 {
            KeyboardShortcuts.isEnabled = false
        }
    }

    static func resume() {
        guard depth > 0 else { return }
        depth -= 1
        if depth == 0 {
            KeyboardShortcuts.isEnabled = true
        }
    }
}
