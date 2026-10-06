# Volume HUD

## Problem

macOS 26 "Tahoe" replaced the long-standing lower-center volume indicator with a small popover in the top-right corner that is easy to miss. Hudlum (Many Tricks) and the open-source volumeHUD restore a large, centered-overlay volume indicator. Relux should offer the same as an opt-in feature.

## Solution

A system-wide volume HUD: when the default output device's volume or mute state changes, show a large, Relux-styled indicator in the **lower-center of the active display**, then fade it out.

Detection uses **CoreAudio property listeners** (no private APIs, no key interception — `'vmvc'` is deprecated-by-association but functional via the HAL). The HUD appears *in addition to* macOS's own indicator (macOS is left completely untouched), so the feature is permission-free and low-risk.

## Locked decisions

| Decision | Choice |
|---|---|
| Scope | Volume only (no brightness) |
| Native HUD | Untouched — additive only |
| Key interception | None |
| Visual style | Relux-native HUD (retro/Hudlum style deferred; view kept isolated) |
| Form factor | Horizontal pill: SF Symbol speaker + segmented bar |
| Display | Display under the mouse cursor |
| Position | Bottom-center, `y = 17% of screen height`, fixed |
| Vertical offset | Scale-aware, not configurable |
| Enable toggle | General tab section, backed by `ExtensionRegistry` |
| Default state | **OFF** (opt-in) |
| Unsupported devices | Silent skip — never show a fake/stale HUD |
| Timing | 1.1 s hold, 0.11 s fade, timer resets on each change |
| Mute visual | `speaker.slash.fill` when muted or value ≤ 0.001; bars dimmed when muted |
| Full-screen apps | HUD shows over them |
| Programmatic changes | HUD shows on *any* volume/mute change |
| Relux panel open | Coexist, no special-casing |
| Device switching | Property listener on `kAudioHardwarePropertyDefaultOutputDevice` (no polling) |
| Lifecycle owner | `AppState` |
| Retro/brightness | Deferred — not scaffolded now |
| Verification | `xcodebuild` + SwiftUI `#Preview` + manual checklist (no test target) |

## Design

### Scope

- New feature code: `Sources/Relux/VolumeHUD/`.
- One shared utility: `Sources/Relux/Util/DisplaySelection.swift`, extracted from `AppDelegate` (see Position).
- Edits: `AppState.swift` (own/start/stop the controller), `UI/SettingsView.swift` (General-tab toggle), `AppDelegate.swift` (use the shared utility).

`project.yml` needs no change — `Sources/Relux` is globbed as a folder, so `xcodegen generate` picks up new directories automatically.

### Components

- **`VolumeSnapshot`** — `struct { let value: Float; let isMuted: Bool }` (`Sendable`).
- **`VolumeMonitor`** — owns the CoreAudio listeners; emits snapshots via a `@MainActor` callback. Silent when the device has no volume property.
- **`VolumeHUDController`** — owns the `NSWindow`, positions it, drives show/extend/hide timing.
- **`VolumeHUDView`** — the SwiftUI pill. Self-contained so a future retro view can replace it.

### Detection (CoreAudio)

Read the default output device from the system object:

```swift
var addr = AudioObjectPropertyAddress(
    mSelector: kAudioHardwarePropertyDefaultOutputDevice,
    mScope: kAudioObjectPropertyScopeGlobal,
    mElement: kAudioObjectPropertyElementMain)
AudioObjectGetPropertyData(AudioObjectID(kAudioObjectSystemObject), &addr, 0, nil, &size, &deviceID)
```

Register block listeners on that device (dispatched to the main queue):

| Property | Selector | Scope | Element |
|---|---|---|---|
| Volume | `kAudioHardwareServiceDeviceProperty_VirtualMainVolume` (`'vmvc'`) | `kAudioDevicePropertyScopeOutput` | `kAudioObjectPropertyElementMain` |
| Mute | `kAudioDevicePropertyMute` | `kAudioDevicePropertyScopeOutput` | `kAudioObjectPropertyElementMain` |

> `'vmvc'` lives in `AudioToolbox/AudioHardwareService.h`. The *functions* in that header are deprecated (10.5–10.11); the constant itself is not. The SDK documents this property family as applying "only when accessed via the Audio Hardware Service API", yet the widely used pattern — and the reference implementation ([dannystewart/volumeHUD](https://github.com/dannystewart/volumeHUD), `VolumeMonitor.swift`) — reads it through `AudioObjectGetPropertyData`. Treat the HAL read as *empirically established but not cleanly documented*: verify it on the target machine during implementation. It is a fixed `Float32` 0…1 — there is no generic HAL range selector for it, so do **not** test "range" to detect support.

- **Volume capability check before registering** (this is what implements "silent skip"): `AudioObjectHasProperty(deviceID, &volAddr)` and a successful `AudioObjectGetPropertyData` of the volume. If the device does not expose a usable main volume, register nothing and show nothing.
- **Mute capability is checked separately.** `AudioObjectHasProperty(deviceID, &muteAddr)` before registering the mute listener. If the device has a usable main volume but no main-element mute, register **only** the volume listener — volume changes (including to 0) still show the HUD, and mute simply never fires. This is the normal per-channel-mute case. If the mute property reports present but its read fails, log it and treat the snapshot as not muted (volume events still show the HUD).
- Read values with `AudioObjectGetPropertyData` (volume = `Float32` 0…1, mute = `UInt32`).
- **Check every `AudioObjectAddPropertyListenerBlock` / `AudioObjectRemovePropertyListenerBlock` return status** and log non-`noErr` results (see logging below).
- **Retain the blocks.** `AudioObjectRemovePropertyListenerBlock` requires the *same* block reference, so `VolumeMonitor` stores each `((UInt32, UnsafePointer<AudioObjectPropertyAddress>) -> Void)?` and uses it for removal. The volume/mute block and the device block are stored separately.
- **Device switching:** register a third listener on `kAudioObjectSystemObject` for `kAudioHardwarePropertyDefaultOutputDevice`. On change: remove listeners from the old device, resolve the new one, re-check capability, re-register. No polling.
- **Teardown:** `stop()` removes the volume and mute blocks from the current device *and* the device block from the system object, then clears the stored references. Toggling the feature off must remove listeners, not just hide the window.

Swift 6: `VolumeMonitor` is `@MainActor`; listener blocks are submitted to `DispatchQueue.main`, so they hop in with `MainActor.assumeIsolated` (this traps rather than degrades if the queue contract is ever broken — acceptable, since it is a programming error).

### Rendering (window)

A borderless, transparent `NSWindow` — never key, never main:

```swift
let w = NSWindow(contentRect: ..., styleMask: [.borderless], backing: .buffered, defer: false)
w.level = .statusBar
w.isOpaque = false
w.backgroundColor = .clear
w.hasShadow = false
w.ignoresMouseEvents = true
w.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary, .ignoresCycle]
```

- `.canJoinAllSpaces` + `.fullScreenAuxiliary` → visible on every Space and over full-screen apps.
- `.ignoresCycle` → stays out of window cycling.
- **Do not set `.stationary`.** Its documented effect is the opposite of what a HUD wants: it keeps the window visible through Exposé / Mission Control / Show Desktop. (The repo's `FloatingPanel` uses `.stationary`, but it is an interactive panel; the HUD deliberately diverges.)
- **On `.transient`:** the earlier draft claimed to "avoid" it, but at a non-normal window level (`.statusBar`) the documented default *is* transient behavior, so omitting the flag does not avoid it. That is fine — "floats in spaces, hidden in Exposé" is exactly the desired HUD behavior. The spec simply does not opt into `.stationary`; no explicit `.transient` flag is needed.
- **Full-screen fallback:** `.fullScreenAuxiliary` at `.statusBar` is untested by precedent (the reference does not set it). Verify on a real full-screen space. If the HUD does not appear, raise `w.level` one notch — `.screenSaver` is the next sane step above `.statusBar` — and re-verify that it does not then draw over Mission Control / Exposé. This is a hard checklist gate: the lower-center HUD is the entire feature.
- Content is an `NSVisualEffectView` (`.hudWindow` material, rounded mask radius 12 — same helper pattern as `FloatingPanel`) hosting a `NSHostingView<VolumeHUDView>`.
- Window is created once and reused; content is updated on each change.

### Position

Center horizontally on the display under the mouse; anchor `y` at 17 % of screen height above the bottom of the **full** screen frame (ignores Dock).

`AppDelegate.movePanelToActiveDisplay()` cannot be reused as-is: it is `private`, and it preserves the panel's relative placement rather than bottom-centering. Extract the reusable display-selection piece into a shared utility.

**New file:** `Sources/Relux/Util/DisplaySelection.swift`

```swift
@MainActor
enum DisplaySelection {
    /// The screen whose frame contains the mouse cursor, else `NSScreen.main`, else the first screen.
    static func screenUnderMouse() -> NSScreen?
    /// The screen whose frame contains `point` (via `NSMouseInRect(point, screen.frame, false)`), or nil.
    static func screen(containing point: NSPoint) -> NSScreen?
    /// Stable identity for comparing screens.
    static func identifier(of screen: NSScreen?) -> CGDirectDisplayID?
}
```

`AppDelegate.movePanelToActiveDisplay()` is re-expressed against it (only the selection/identity lines change; the relative-placement and clamping logic stays):

```swift
guard let target = DisplaySelection.screenUnderMouse() else { return }
let current = DisplaySelection.screen(containing: NSPoint(x: frame.midX, y: frame.midY))
if let current,
   DisplaySelection.identifier(of: current) == DisplaySelection.identifier(of: target) { return }
```

The old `private static screenIdentifier(_:)` helper is removed. The HUD controller uses the same `screenUnderMouse()` for its target display. Re-apply HUD position on `NSApplication.didChangeScreenParametersNotification` and before each show.

### Volume HUD view

Relux-native pill, roughly 220 × 56:

- Left: SF Symbol speaker glyph, `speaker.fill` → `speaker.wave.1/2/3.fill` by level, `speaker.slash.fill` when muted or value ≤ 0.001.
- Right: 16-segment bar filled to the current level.
- Muted: bars rendered dimmed at the current level (mirrors volumeHUD).
- No text, so no localization keys needed.

### Logging

Per convention (`AGENTS.md`), use `os.Logger(subsystem: "com.relux.app", category: "volumehud")`. Log at least: no default output device; device lacks a usable main volume (skip); non-`noErr` from register/remove; device-switch re-registration. These paths are otherwise silent, and silent CoreAudio failures are the hardest part of this feature to diagnose.

### Timing

Single sequence, driven by `VolumeHUDController.apply(_:)`:

1. Cancel the pending hold timer **and** any in-flight fade-out, so its `orderOut` completion cannot fire.
2. Update the hosted view's model.
3. `alphaValue = 1` (always — this also aborts a mid-flight fade); reposition; if `!window.isVisible`, `orderFront(nil)`.
4. Schedule a 1.1 s hold timer.

**Cancellable fade.** The 0.11 s fade-out and its trailing `orderOut(nil)` are driven by one cancellable mechanism (a `DispatchWorkItem` / `Timer` that ramps alpha and then orders out) — **not** by an `NSAnimationContext` completion handler, which is not cancellable and would still hide the window after a new change. Cancelling it in step 1 is what makes the mid-fade case safe.

**De-duplication.** When the new snapshot (value + mute) equals the last applied one *and* the window is genuinely on screen (`window.isVisible && alphaValue == 1`), skip steps 2–3 and jump to step 4. Otherwise run all steps. A change arriving during the fade therefore runs step 3, restoring `alphaValue = 1` and cancelling the stale `orderOut` — no flicker.

**Hide.** On hold-timer fire, ramp `alphaValue → 0` over 0.11 s, then `orderOut(nil)`.

**Stop (`stop()` / feature disabled).** Cancel the hold timer and any fade, `orderOut(nil)` immediately (no fade — the feature is being turned off), reset `alphaValue = 1` and clear `lastApplied` for the next start, then remove listeners. Clearing `lastApplied` is required: `stop()` leaves the window hidden but at full alpha, so without it a same-value event after re-enabling would satisfy the de-dup guard and never `orderFront`.

### Settings

Register in `AppState.setup()`:

```swift
extensionRegistry.register(
    id: "volumeHUD", name: "Volume HUD", icon: "speaker.wave.3",
    defaultEnabled: false
)
```

Add a `Section("Volume HUD")` to the General settings tab. The toggle cannot bind directly into `ExtensionRegistry` (its `extensions` array is `private(set)`), so follow the `GestureSettingsView` pattern: a local `@State` seeded in `.onAppear`, and an `.onChange` that calls **both** `extensionRegistry.setEnabled("volumeHUD", ...)` and `appState.setVolumeHUDEnabled(...)` so persistence and the running controller stay in sync.

### Lifecycle

`AppState` holds an optional `volumeHUDController`. `setup()` creates and starts it iff the registry flag is on. A `setVolumeHUDEnabled(_:)` method starts/stops it from the toggle. `AppDelegate` stays panel-only.

## Known limitations

- **Boundary key presses produce no HUD.** Because the feature does not intercept keys and only reacts to CoreAudio property *changes*, pressing volume-up at 100 %, volume-down at 0 %, or muting while already muted changes nothing and therefore shows nothing. Hudlum/volumeHUD cover this with key interception, which is out of scope here. The de-duplication path (reschedule the timer without re-showing) only helps while the HUD is fully on screen. Accepted as inherent to the additive design.
- **Every programmatic change shows the HUD.** Any app or audio tool that sets the volume will trigger it; the only suppression is the 1.1 s hold. The reference implementation heuristically filters to user-initiated changes; we deliberately do not. Revisit if it proves noisy.
- **Per-channel mute devices:** if the device has no main-element mute, `AudioObjectHasProperty` returns false for `kAudioDevicePropertyMute` and the mute listener is simply not registered. Volume changes (including to 0) still show the HUD; a true per-channel mute at nonzero volume is not reflected. The `value ≤ 0.001` fallback covers mute-implemented-as-volume-zero only.
- **Volume-less-but-mutable devices** are skipped entirely (no HUD), by the capability check.

## Non-goals

- Brightness control (requires private `DisplayServices.framework`).
- Suppressing or replacing the native macOS HUD (no key interception).
- Retro/Hudlum visual style.
- Configurable position, size, offset, opacity, or duration.
- Per-app volume.

## Verification checklist

**Build / lint**
- [ ] `xcodegen generate` (new files/dirs require it; `Relux.xcodeproj` is gitignored, so a stale project yields a green build that silently omits the new code)
- [ ] `xcodebuild -scheme Relux -destination 'platform=macOS'` passes
- [ ] `swiftformat --indent 4 --maxwidth 120 --importgrouping alpha Sources/Relux/VolumeHUD Sources/Relux/Util/DisplaySelection.swift Sources/Relux/AppDelegate.swift Sources/Relux/AppState.swift Sources/Relux/UI/SettingsView.swift`
- [ ] `swiftlint lint --baseline .swiftlint.baseline --quiet` clean on changed files
      No repo `.swiftformat` file exists, so a bare `swiftformat <paths>` applies SwiftFormat *defaults*, not the 4-space / 120-width / alpha-imports convention the memory documents — hence the explicit flags. (Adding a real `.swiftformat` is a worthwhile follow-up, out of scope here.) Never run `swiftformat .` bare.

**Manual** (enable the toggle first)
- [ ] Volume up/down shows the pill at bottom-center; segments track the level — check boundaries explicitly: 0 segments at 0, 1 segment at the first step, 16 segments at 100 %
- [ ] Mute → `speaker.slash.fill`, bars dimmed; unmute restores
- [ ] Changing volume via Control Center / menu-bar slider shows the HUD (programmatic path)
- [ ] Plugging/unplugging headphones re-routes the HUD to the new default device without a restart
- [ ] Volume-less output device (HDMI/aggregate) shows nothing, and registers no listeners
- [ ] Volume-less-but-mutable device shows nothing
- [ ] Multi-display: HUD follows the display under the mouse
- [ ] Full-screen app: HUD appears above it (if not, apply the documented `level` fallback and re-verify)
- [ ] Rapid repeated presses keep the HUD visible and extend the timer (no flicker)
- [ ] Boundary press at 100 % / 0 % / re-mute shows no HUD (documented limitation, not a bug)
- [ ] With the Relux panel open, the HUD still appears and does not steal focus or clicks
- [ ] Toggle off: HUD stops **and** CoreAudio listeners are removed; toggle on restarts it
- [ ] Toggle off → toggle on → trigger the *same* volume value that was active at toggle-off: HUD appears (guards the `lastApplied` reset)
- [ ] Toggle on → quit → relaunch: setting persists and the HUD starts automatically
- [ ] Default (never enabled): confirm no listeners are registered in a clean profile
- [ ] 10+ rapid device switches: no duplicate HUDs, no leaked listeners, no crash

## Follow-ups (not now)

- `VolumeHUDStyle` enum + `volumeHUDStyle` pref, retro view, and a dedicated settings tab (revisit if brightness/style settings are added).
- Brightness HUD via `DisplayServices` (opt-in, experimental).
