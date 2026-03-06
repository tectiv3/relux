## CRITICAL WORKFLOW - ALWAYS FOLLOW THIS

Activate serena project relux at the start of each session. Update docs/decisions.md whenever user requests a change to architecture, dependencies, or build system.

## Build System

Source of truth is `project.yml` (XcodeGen). **Do NOT edit** `Relux.xcodeproj` or `Package.swift` directly.

```bash
# Generate Xcode project (required after dependency/target changes)
xcodegen generate

# CLI build
xcodebuild -scheme Relux -destination 'platform=macOS'

# Run from Xcode
open Relux.xcodeproj  # then Cmd+R
```

Adding dependencies: update `project.yml` under `packages` and `targets`, then `xcodegen generate`.

No test suite exists.

## Architecture

Three SPM targets:
- **Relux** — Main macOS app (SwiftUI, menu bar, hotkey overlay)
- **ReluxCore** — Shared library (search math, read-only store)

### State Management

Global `@MainActor @Observable` singleton `AppState` holds all services (searchers, stores, frecency). Views observe it directly. Panel modes: `.search`, `.clipboard`, `.translate`.

### Extension System

`ExtensionRegistry` manages toggleable features (currently: Translate). Extensions are registered at init, persisted via UserDefaults with key `extension.<id>.enabled`.

### Persistence

Raw SQLite C-API only — **no Core Data or SwiftData**. Wrapper classes (`ClipboardStore`, `TranslateStore`) manage `OpaquePointer?` handles. Use `nonisolated(unsafe)` for pointers in Swift 6 mode.

### Key Dependencies

- `KeyboardShortcuts` (sindresorhus) — global hotkey binding

## Conventions

- **Swift 6** strict concurrency: enforce `Sendable` on data models, `@MainActor` on UI state
- **Logging**: `os.Logger` with subsystem `"com.relux.app"` and descriptive category
- **Search**: `SearchMath` in ReluxCore provides `cosineSimilarity` (vDSP/Accelerate) and `keywordScore` for hybrid search ranking
