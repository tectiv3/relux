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
# Error ... Operation not permitted" (no free ptys). Build the test bundle,
# then run it straight from the built products dir:
xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' \
    build-for-testing -skipPackageUpdates -skipMacroValidation \
    OTHER_SWIFT_FLAGS='$(inherited) -Xfrontend -disable-sandbox'
DD=$(xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug -showBuildSettings 2>/dev/null | awk -F'= ' '/ BUILT_PRODUCTS_DIR/{print $2; exit}'); xcrun xctest "$DD/ReluxTests.xctest"
```

Test and suite counts are deliberately not recorded in this file; a pinned count is wrong on the next commit. `Tests/ReluxTests/` is the source of truth for what exists.

Debug sets `ONLY_ACTIVE_ARCH: "YES"` at project level (Release untouched) because the `KeyboardShortcuts` package is built for the active arch, so a universal Debug app build cannot resolve its x86_64 module.

Adding dependencies: update `project.yml` under `packages` and `targets`, then `make generate`.

## Architecture

Three targets, all generated from `project.yml`:

- `Relux` — `type: application`, the app. Sources `Sources/Relux`; depends on the `KeyboardShortcuts` SPM package and on `ReluxCore`.
- `ReluxCore` — `type: framework` (`com.relux.core`), sources `Sources/ReluxCore`. Pure, SwiftUI-free code only: the search model (`Search/` — `SearchItem`, `FuzzyMatch`, `AppRanking`, `AppDisplayName`, `ResultGrouping`, `ResultSelection`), `JWT/JWTParser.swift`, `Util/Formatting.swift`, the actions-overlay descriptors (`Actions/`), and the SQLite layer (`Storage/`) — the SQL and ranking code lives here so it can be tested host-free, since `ReluxTests` has no `TEST_HOST`. No dependencies. Two settings are load-bearing and must not be dropped: `DYLIB_INSTALL_NAME_BASE: @rpath` (XcodeGen does not emit Xcode's framework default, so the install name would become `/Library/Frameworks/...` and loading fails) and `SKIP_INSTALL: "YES"` (without it the framework installs as a second root product in the archive, no `ApplicationProperties` is written, and Developer ID export offers no distribution method).
- `ReluxTests` — `type: bundle.unit-test` (`com.relux.tests`), sources `Tests/ReluxTests` plus a hand-picked list of app-side files; `project.yml`'s `ReluxTests.sources` is the source of truth for that list. Rule for adding one: an app-side file may be compiled into the bundle only if it depends on nothing beyond `ReluxCore` + Foundation/AppKit and its side effects are injectable (stores, state models, `FrecencyTracker`, `AppIconCache`, `SelectionCapture`, `SettingsStore` do; anything needing SwiftUI or `AppState` does not). No `TEST_HOST`: runs host-free against `ReluxCore` and never launches the app, wired into the shared `Relux` scheme under `test.targets`.

Dependency direction: `Relux` → `ReluxCore`; `ReluxTests` → `ReluxCore`, no host. Pure logic belongs in `ReluxCore` and is covered by tests; anything touching AppKit/SwiftUI stays in `Relux`.

Inside `Relux` (SwiftUI + AppKit), sources rooted at `Sources/Relux/`:

- `ReluxApp.swift`, `AppDelegate.swift`, `AppState.swift`, `Appearance.swift`, `AppIconCache.swift` — app entry point, `NSStatusItem`/`NSPanel` lifecycle, the global `@MainActor @Observable` state object, appearance, and the icon cache
- `HotkeyManager.swift`, `SelectionCapture.swift` — `KeyboardShortcuts` bindings; Accessibility (`AXUIElement`) capture of the selected text before the panel takes focus
- `UI/` — overlay, floating panel, clipboard history, settings, translate views, toasts
- `Search/` — `AppSearcher` (Spotlight `NSMetadataQuery`), `SystemSettingsSearcher`, `ScriptSearcher`, `ScriptRunner`, `FrecencyTracker`
- `Store/` — `ClipboardStore` (SQL on the shared `SQLiteDatabase` from `ReluxCore`)
- `Clipboard/` — `ClipboardMonitor` (pasteboard polling), `PasteService` (CGEvent Cmd+V), `ClipboardListModel`, `ClipboardServices`
- `Translate/` — `AnthropicService` (streaming HTTPS), `TranslationService` (streaming/dedup/cancel state machine), `TranslateStore` (SQLite)
- `Calculator/` — `CalculatorService`, `ExchangeRateCache` (ECB daily XML), `NSExpression+Safe.m`
- `JWT/` — `JWTView` token decoder
- `Gestures/` — trackpad gesture engine, `TouchBridge.c`, `GestureBindingManager`, settings UI
- `VolumeHUD/` — CoreAudio volume listener plus HUD panel
- `SpaceSwitch/` — `SpaceSwitch.m/.h`, SkyLight Space switching
- `Extensions/` — `ExtensionRegistry`: plain string ids, UserDefaults on/off state, closures registered inline in `AppState.setup()`
- `Util/` — `ColorParser`, `DisplaySelection`, `SettingsStore` (UserDefaults keys and defaults)

Panel modes (`.search`, `.clipboard`, `.translate`, `.jwt`) are selected on `AppState`; `PanelRootView` in `UI/OverlayView.swift` switches on them.

Persistence: raw SQLite C-API only — **no Core Data or SwiftData**. One connection for the whole app: `SQLiteDatabase` (`ReluxCore/Storage/SQLiteDatabase.swift`) owns the only `OpaquePointer` (opened `SQLITE_OPEN_FULLMUTEX`, `PRAGMA busy_timeout=5000`); `ClipboardStore` and `TranslateStore` are handed that database instead of opening handles of their own. Statements are `Statement` values that copy text/blob arguments on bind and finalize in `deinit`; multi-statement writes go through `SQLiteDatabase.transaction` (`BEGIN IMMEDIATE` … `COMMIT`, rollback on throw, not reentrant). The schema version lives in `PRAGMA user_version` and is applied by `ReluxSchema.migrate` through `SQLiteDatabase.migrate(to:apply:)`, which applies each pending version in its own transaction and refuses a database newer than the supported version rather than guessing. No C pointer is touched outside `SQLiteDatabase`/`Statement`, so no `nonisolated(unsafe)` pointer storage is needed.

### Key Dependencies

- `KeyboardShortcuts` (sindresorhus) — global hotkey binding

## Conventions

- **Swift 6** strict concurrency: enforce `Sendable` on data models, `@MainActor` on UI state
- **Logging**: `os.Logger` with subsystem `"com.relux.app"` and descriptive category
