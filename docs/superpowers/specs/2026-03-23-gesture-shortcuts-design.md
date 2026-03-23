# Gesture Shortcuts Extension

**Date**: 2026-03-23
**Status**: Approved
**Goal**: Replace BetterTouchTool with a built-in Relux extension that maps trackpad gestures to actions (keyboard shortcuts, system actions, Relux actions).

## Requirements

- 5 gesture types: 3-finger swipe up/down/left/right, 3-finger click
- 3 action types: key combo (arbitrary), system action (enum), Relux action (enum)
- Settings UI to configure gesture → action bindings with a shortcut recorder
- Registered as a Relux extension via `ExtensionRegistry`

## Gesture Detection

Uses Apple's private `MultitouchSupport.framework` for reliable finger count and touch data. This is the same approach BetterTouchTool uses — public APIs (`CGEvent` tap) do not reliably expose touch count for trackpad events.

### Why not CGEvent tap?

- `CGEvent` scroll events don't have a reliable public field for touch/finger count
- `NSEvent(cgEvent:)` requires a view for `touchesMatchingPhase(_:in:)`, unavailable in a tap callback
- 3-finger click has no public API path at all — mouse-down events don't carry multi-touch data

### Approach: OpenMultitouchSupport SPM package

Uses [OpenMultitouchSupport](https://github.com/Kyome22/OpenMultitouchSupport) (MIT, Swift 6, macOS 13.0+) — a maintained wrapper around MultitouchSupport.framework. Provides an `async touchDataStream` interface with typed touch data (position, state, finger ID).

- Subscribe to `OMSManager.shared().touchDataStream`
- Each frame provides touch count, per-finger positions and states
- **Swipe detection**: track 3-touch contact frames, accumulate position deltas, determine direction at release. Threshold to reject micro-swipes.
- **3-finger click**: detect 3 touches in contact + mouse-down event (coordinate with a lightweight `NSEvent.addGlobalMonitorForEvents(matching: .leftMouseDown)`)

### Implementation note

Requires a proof-of-concept before full implementation to validate:
1. OpenMultitouchSupport works without sandbox (app is not sandboxed per entitlements)
2. Touch data is reliable with "three finger drag" disabled
3. Swipe direction thresholds feel natural

### Permissions

- Requires Accessibility permission (already granted for SelectionCapture)
- **User must configure:**
  - System Settings → Trackpad → "Swipe between pages" and "Mission Control" set to 4 fingers
  - System Settings → Accessibility → Pointer Control → Trackpad Options → "Three finger drag" OFF
  - System Settings → Trackpad → Point & Click → "Look up & data detectors" set to off or force click (for 3-finger click)

## Action System

### Model

```swift
enum GestureType: String, Codable, CaseIterable {
    case threeFingerSwipeUp
    case threeFingerSwipeDown
    case threeFingerSwipeLeft
    case threeFingerSwipeRight
    case threeFingerClick
}

struct KeyCombo: Codable, Equatable {
    var keyCode: UInt16       // Carbon virtual key code (kVK_*)
    var modifierRawValue: UInt  // NSEvent.ModifierFlags.rawValue (not directly Codable)

    var modifiers: NSEvent.ModifierFlags {
        get { NSEvent.ModifierFlags(rawValue: modifierRawValue) }
        set { modifierRawValue = newValue.rawValue }
    }
}

enum SystemAction: String, Codable, CaseIterable {
    case lockScreen
    case missionControl
    case appExpose
    case showDesktop
}

enum ReluxAction: String, Codable, CaseIterable {
    case toggleRelux
    case clipboardHistory
    case translate
}

enum GestureActionType: Codable {
    case keyCombo(KeyCombo)
    case system(SystemAction)
    case relux(ReluxAction)
    case none
}

struct GestureBinding: Codable {
    var gesture: GestureType
    var action: GestureActionType
}
```

### Execution

- **Key combo**: `CGEvent(keyboardEventSource:virtualKey:keyDown:)` with modifier flags. Posted via `CGEvent.post(tap: .cghidEventTap)`. Posted asynchronously (not from within the touch callback) to avoid re-entrant event processing.
- **System actions**: Simulated key combos (lock screen = Ctrl+Cmd+Q, mission control = Ctrl+↑, etc.). Acknowledged limitation: if user has remapped these system shortcuts, the simulated keys won't match.
- **Relux actions**: Direct method calls on `AppDelegate` (`togglePanel()`, `toggleClipboardHistory()`, etc.)

### Storage

UserDefaults: JSON-encoded `[GestureBinding]` under key `gesture.bindings`.
Default: all gestures mapped to `.none`.

## New Files

| File | Purpose |
|------|---------|
| `GestureEngine.swift` | MultitouchSupport.framework bridge, touch tracking, swipe/click detection. Fires callback with `GestureType`. |
| `GestureBindingManager.swift` | Loads/saves bindings from UserDefaults. Executes bound action for a given gesture. Observes `ExtensionRegistry` enabled state to start/stop engine. |
| `GestureSettingsView.swift` | Settings UI: list of gestures, action type picker, key combo recorder per row. |
| `ShortcutRecorderView.swift` | Reusable SwiftUI view: click to record, captures next keyDown (keyCode + modifiers), displays symbol string. |

## Settings UI

List of 5 rows, one per gesture type:
- Left: gesture label (e.g. "3 Finger Swipe Up")
- Right: action configuration
  - Action type picker (Key Combo / System Action / Relux Action / None)
  - For Key Combo: `ShortcutRecorderView` — click to record, press keys, displays captured combo
  - For System/Relux Action: dropdown picker from the respective enum

Note displayed at top: instruction to configure trackpad settings (4-finger swipe for Mission Control, disable "three finger drag", disable Look Up for 3-finger click).

## ShortcutRecorderView Lifecycle

Uses `NSEvent.addLocalMonitorForEvents(matching: .keyDown)` in recording mode:
- Monitor is created when user clicks "Record" button
- Monitor is removed on: (a) successful key capture, (b) user clicks "Cancel", (c) view's `onDisappear`
- `@State var monitor: Any?` tracks the active monitor, `onDisappear { removeMonitor() }` ensures cleanup even if settings view is dismissed during recording
- This is a brief, user-initiated capture — not a persistent monitor. The project's "NSEvent monitors leak" concern applies to long-lived monitors, not short-lived recorders with explicit cleanup.

## Integration

- Registered as extension `"gestures"` in `ExtensionRegistry` with `defaultEnabled: true`
- `GestureBindingManager` holds a reference to `GestureEngine` and observes the extension's enabled state on `AppState`. Starts/stops the engine accordingly.
- `GestureEngine` touch callback dispatches to `@MainActor` via `DispatchQueue.main.async` for action execution
- `GestureBindingManager` initialized in `AppState` alongside other services

## Thread Safety

- MultitouchSupport callback fires on an internal thread
- All action execution dispatched to `@MainActor`
- `CGEvent.post()` calls made from main thread (not from within touch callback) to avoid re-entrant event processing
- `ShortcutRecorderView` monitor is main-thread only (UI interaction)

## Out of Scope

- 4-finger gestures (handled by macOS system)
- Mouse button triggers
- Per-app gesture bindings
- Gesture customization beyond the 5 defined types
