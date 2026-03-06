# Relux Codebase Instructions

## Build & Dependencies

- **System**: Uses `xcodegen`. Source of truth is `project.yml`.
- **Do NOT edit** `Relux.xcodeproj` or `Package.swift` directly.
- **Add Dependencies**: Add to `project.yml` `packages` and `targets`, then run `xcodegen generate`.
- **CLI Build**: `xcodebuild -scheme Relux -destination 'platform=macOS'`
- **Testing**: No test suite.

## Architecture & Patterns

### State Management
- **Pattern**: Global `@Observable` singleton `AppState` (`Sources/Relux/AppState.swift`).
- **Usage**:
  - Views observe `AppState` directly.
  - Services (Search, Translate) are properties of `AppState`.
  - Use `@MainActor` for all UI-facing state.

### Persistence (SQLite)
- **Constraint**: Use raw C-API `sqlite3`. **Do NOT use Core Data or SwiftData.**
- **Reason**:
  - The project is lightweight and uses direct SQLite wrappers (`ClipboardStore`, `TranslateStore`).
  - Avoids the overhead and boilerplate of Core Data contexts/managed objects for simple history tables.
  - Maintains consistency with existing store implementations.
- **Pattern**:
  - Wrapper classes manage pointers (`OpaquePointer?`).
  - Use `nonisolated(unsafe)` for pointers in Swift 6 mode if needed.
  - Handle queries with manual `sqlite3_prepare_v2`, `sqlite3_step`, `sqlite3_finalize`.

### Logging
- **Requirement**: Use `os.Logger`.
- **Format**: `Logger(subsystem: "com.relux.app", category: "component_name")`
- **Example**: `private let log = Logger(subsystem: "com.relux.app", category: "clipboard-monitor")`

### Concurrency
- **Swift 6**: Enforce `Sendable` on data models.
- **UI**: Ensure all View updates happen on `@MainActor`.
