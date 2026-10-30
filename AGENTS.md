## CRITICAL WORKFLOW - ALWAYS FOLLOW THIS

Activate serena project relux at the start of each session.
List memories and read one about task completion.
Update docs/decisions.md whenever user requests a change to architecture, dependencies, or build system.

## Build System

Source of truth is `project.yml` (XcodeGen). **Do NOT edit** `Relux.xcodeproj` directly.

```bash
# Generate the Xcode project (required after dependency or target changes)
make generate   # xcodegen generate

# CLI build — plain xcodebuild fails on this toolchain (KeyboardShortcuts
# macro sandbox); the Makefile target passes -skipMacroValidation and
# -disable-sandbox
make build

# Run from Xcode
open Relux.xcodeproj  # then Cmd+R

# Tests — the `test` action fails on this box with "Pseudo Terminal Setup
# Error ... Operation not permitted" (no free ptys). Build, then run the
# built bundle directly:
make build
DD=$(xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}'); xcrun xctest "$DD/ReluxTests.xctest"
```

Debug sets `ONLY_ACTIVE_ARCH: "YES"` at project level (Release untouched) because the `KeyboardShortcuts` package is built for the active arch, so a universal Debug app build cannot resolve its x86_64 module.

Adding dependencies: update `project.yml` under `packages` and `targets`, then `make generate`.

## Architecture

Three targets, all generated from `project.yml`:

- `Relux` — `type: application`, the app. Sources `Sources/Relux`; depends on the `KeyboardShortcuts` SPM package and on `ReluxCore`.
- `ReluxCore` — `type: framework` (`com.relux.core`), sources `Sources/ReluxCore`. Pure, SwiftUI-free code only: `Search/SearchItem.swift` (`SearchItem`/`SearchItemKind`), `Search/FuzzyMatch.swift`, `Search/ResultGrouping.swift`, `Util/Formatting.swift`, `JWT/JWTParser.swift`, plus the SQLite layer (`Storage/SQLiteDatabase.swift`, `Storage/ReluxSchema.swift`, `Storage/StoreError.swift`) — the SQLite helper lives here rather than in the app so the SQL layer can be tested host-free, since `ReluxTests` has no `TEST_HOST`. No dependencies. Needs `DYLIB_INSTALL_NAME_BASE: @rpath` — XcodeGen does not emit Xcode's framework default, so the install name would become `/Library/Frameworks/...` and loading fails.
- `ReluxTests` — `type: bundle.unit-test` (`com.relux.tests`), sources `Tests/ReluxTests` plus `Sources/Relux/Store` and `Sources/Relux/Translate/TranslateStore.swift` (the stores depend only on `ReluxCore` + Foundation, so compiling them into the bundle keeps their SQL covered without a host). No `TEST_HOST`: runs host-free against `ReluxCore` and never launches the app. 94 tests in 8 suites, wired into the shared `Relux` scheme under `test.targets`.

Dependency direction: `Relux` → `ReluxCore`; `ReluxTests` → `ReluxCore`, no host. Pure logic belongs in `ReluxCore` and is covered by tests; anything touching AppKit/SwiftUI stays in `Relux`.

Inside `Relux` (SwiftUI + AppKit), sources rooted at `Sources/Relux/`:

- `ReluxApp.swift`, `AppDelegate.swift`, `AppState.swift` — app entry point, `NSStatusItem`/`NSPanel` lifecycle, and the global `@MainActor @Observable` state object
- `HotkeyManager.swift`, `SelectionCapture.swift` — `KeyboardShortcuts` bindings; Accessibility (`AXUIElement`) capture of the selected text before the panel takes focus
- `UI/` — overlay, floating panel, clipboard history, settings, translate views, toasts
- `Search/` — `AppSearcher` (Spotlight `NSMetadataQuery`), `SystemSettingsSearcher`, `ScriptSearcher`, `ScriptRunner`, `FrecencyTracker`
- `Store/` — `ClipboardStore` (SQL on the shared `SQLiteDatabase` from `ReluxCore`)
- `Clipboard/` — `ClipboardMonitor` (pasteboard polling), `PasteService` (CGEvent Cmd+V)
- `Translate/` — `AnthropicService` (streaming HTTPS), `TranslateStore` (SQLite)
- `Calculator/` — `CalculatorService`, `ExchangeRateCache` (ECB daily XML), `NSExpression+Safe.m`
- `JWT/` — `JWTView` token decoder
- `Gestures/` — trackpad gesture engine, `TouchBridge.c`, `GestureBindingManager`, settings UI
- `VolumeHUD/` — CoreAudio volume listener plus HUD panel
- `SpaceSwitch/` — `SpaceSwitch.m/.h`, SkyLight Space switching
- `Extensions/` — `ExtensionRegistry`: plain string ids, UserDefaults on/off state, closures registered inline in `AppState.setup()`
- `Util/` — `ColorParser`, `DisplaySelection`

Panel modes (`.search`, `.clipboard`, `.translate`, `.jwt`) are selected on `AppState`; `PanelRootView` in `UI/OverlayView.swift` switches on them.

Persistence: raw SQLite C-API only — **no Core Data or SwiftData**. Wrapper classes (`ClipboardStore`, `TranslateStore`) own `OpaquePointer?` handles. Use `nonisolated(unsafe)` for pointers in Swift 6 mode.

### Key Dependencies

- `KeyboardShortcuts` (sindresorhus) — global hotkey binding

## Conventions

- **Swift 6** strict concurrency: enforce `Sendable` on data models, `@MainActor` on UI state
- **Logging**: `os.Logger` with subsystem `"com.relux.app"` and descriptive category
