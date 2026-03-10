# Relux — Decisions & Request History

Only architectural/behavioral decisions with downstream implications. Not bug fixes or cosmetic tweaks.

## Search Architecture

- `SourceNote` replaced with generic `SearchItem` supporting `.note` and `.app` kinds — all future result types extend this
- Search is instant, as-you-type — keyword matching on VectorStore cache + app name fuzzy matching. No embedding needed for basic search.
- LLM generation is opt-in only, behind Cmd+K → "Ask AI" action. Never auto-triggers.
- App search uses configurable Spotlight scopes (default includes `/Applications`, Utilities, `/System/Library/CoreServices/Applications`, `~/Applications`); live re-indexes via `NSMetadataQueryDidUpdate`
- Do NOT use `Bundle(url:)` to read app bundles — triggers App Management permission. Only use `FileManager` + path inspection.

## Frecency System

- Tracks query→item selections (frequency + recency) to rank results
- Query normalized to first 4 chars for grouping similar queries
- Stores full SearchItem data so recents can be displayed on empty query
- Data persisted in `~/Library/Application Support/Relux/` (frecency.json, recents.json)

## UI Behavior

- Actions menu (Cmd+K) floats as overlay over results (ZStack, bottom-trailing), does NOT replace them
- Empty query shows up to 8 recently used items
- Keyboard layout can be forced on panel open (setting in General tab, uses `TISSelectInputSource`)
- App icons via `NSWorkspace.shared.icon(forFile:)`, notes use SF Symbol `doc.text`

## Keyboard Navigation

- Arrow keys MUST wrap around in all navigable lists (results, actions menu)
- Up from first item → last item; Down from last item → first item
- Applies to both the main results list and the Cmd+K actions overlay

## Extension Registry

- `ExtensionRegistry` tracks which extensions (search sources) are enabled/disabled, backed by UserDefaults (key pattern: `extension.<id>.enabled`)
- "Models" settings tab renamed to "Notes" — models are an implementation detail of the notes extension
- When notes disabled: models fully unloaded (`unloadAll` clears containers + model refs + GPU cache), note search skipped in `performSearch`, `restoreModels` no-ops
- When notes enabled: models restored via `restoreModels()` (same as app startup)
- Pattern is general-purpose — scripts, clipboard, apps can register in the same registry for their own toggle

## Model Lifecycle

- Models are NOT loaded at startup — only loaded on first use (lazy loading)
- After 10 minutes of inactivity, models are unloaded from memory (set containers to nil)
- On next use, auto-reload from stored model path
- MLXService stores the loaded model's `LocalModel` reference so it knows what to reload
- `isLLMLoaded`/`isEmbedderLoaded` flags update on both load and unload
- UI feedback during auto-reload uses existing `loadingStatus` mechanism

## Layout Rules (DO NOT BREAK)

- Panel width: 750, height: 474
- Results section: maxHeight 400, compact single-line rows
- VStack fills available space with Spacer + maxHeight .infinity
- NSHostingView pinned to all 4 edges of panel contentView
- **Every time the overlay layout is modified, verify results are visible with at least 8 rows**

## Selection Capture

- On hotkey press, selected text is read from the focused app via Accessibility API (`AXUIElement`) BEFORE Relux takes focus
- Stored in `AppState.currentSelection`, cleared on panel close
- Scripts opt in via `inputMode: InputMode` (.none/.stdin/.argument) — stdin pipes to process, argument appends shell-escaped value to command
- Web search uses selection as query when search bar is empty
- Ask AI prepends selection as context to the LLM prompt
- Bottom bar shows truncated selection preview when captured
- Requires Accessibility permission (prompted on first launch)
- Pattern for selection-aware features: any search result item that needs selected text appears only when `currentSelection != nil` (scripts with `inputMode != .none`, translate extension, etc.). The selected text is NOT placed in the search bar — only an indicator is shown. The text is passed to the feature when the user explicitly selects the item.

## Capture Output Scripts

- Scripts can opt into `capturesOutput: Bool` to stream stdout into the panel's answer section
- When enabled, the panel stays open and output streams incrementally (same UX as Ask AI)
- When disabled, existing fire-and-forget behavior with toast is preserved
- Uses `AsyncStream<String>` via `ScriptRunner.stream()` reading `availableData` in a loop
- Backward-compatible: existing scripts.json without the field default to `false`

## Clipboard History

- Integrated as a second panel mode via `PanelMode` enum on AppState (`.search` / `.clipboard`)
- `PanelRootView` wrapper switches between `OverlayView` and `ClipboardHistoryView` based on mode
- Clipboard monitoring uses timer-based polling of `NSPasteboard.general.changeCount` every 0.5s
- Storage: SQLite `clipboard_history` table in existing `relux.db`, images saved as PNG files in `~/Library/Application Support/Relux/clipboard/`
- Paste-back: puts content on system clipboard, closes panel, activates previous app, simulates Cmd+V via CGEvent
- `suppressNextCapture` flag prevents self-paste recording
- Hotkey: Opt+Cmd+V (configurable via KeyboardShortcuts)
- Disabled apps list stored in UserDefaults, defaults include Keychain Access and Passwords
- Retention-based cleanup runs once on app launch (configurable: 1/3/6 months)

## 2026-03-06: Remove MLX Dependencies

**Context**: The project initially integrated `mlx-swift` and `mlx-swift-lm` for on-device LLM inference and embeddings.

**Decision**: We have removed all MLX dependencies from `project.yml` and the codebase.

**Rationale**:
- Simplification of the architecture.
- Focus on core utility features (Command Bar, Clipboard, Translation) rather than local LLM hosting.
- Reduction in build complexity and binary size.

## Translation Dedup & History Sorting

- Translation history uses `content_hash` (djb2 hash of source text + target language) to detect duplicate translations
- When a duplicate is requested, the existing entry's `updated_at` is bumped instead of re-translating
- History sorted by `COALESCE(updated_at, created_at) DESC` — most recently used on top
- `created_at` is immutable (original creation time), `updated_at` tracks last access
- This pattern (content hash dedup + updated_at sorting) should be reused for clipboard history if needed

## Recents Dedup in Search Panel

- Search results with fixed ids (e.g., `translate-selection`) are deduped against recents by id
- Selection-aware items (built fresh with preview subtitle) take priority over their stored recents counterpart
- No kind-based filtering needed — id-based dedup handles all cases generically

## Calculator Extension

- Inline calculator triggered by math expressions or currency patterns in the search query
- Math eval uses `NSExpression` with a hardened input whitelist (digits, operators, parens, decimal points only)
- Currency conversion via ECB daily reference rates, parsed from XML with `ECBXMLParser`
- `ExchangeRateCache` persists rates as JSON in app support dir; stale after 24h, fetched fresh on next use
- Results shown in a two-column card UI (Raycast-style), copied to clipboard on selection
- Excluded from frecency tracking — calculator results are ephemeral, not worth recording as recents
- Registered in `ExtensionRegistry` with a readiness gate (`extensionReady`) so search skips it until rates are loaded

## JWT Extension

- Decodes JWT tokens pasted or captured via selection — displays header and payload in a two-panel view
- Pure client-side base64 decoding, no signature verification
- Frecency integration persists the last decoded token in `meta["token"]` inside recents.json
- Excluded from generic `recordSelection` in `openSelectedItem` to prevent overwriting stored token with empty dict
- Actions overlay (Cmd+K) for copying header/payload/full token
- Lives in `Sources/Relux/JWT/JWTView.swift` as a self-contained view with inline key monitor

## System Settings Search

- Hardcoded list of macOS 13+ System Settings categories with `x-apple.systempreferences:` deep-link URLs
- `SystemSettingsSearcher` matches by pane name and keyword synonyms (e.g. "wifi" → Wi-Fi, "keychain" → Passwords)
- Results shown as `.systemSettings` kind with gear icon, opened via `NSWorkspace.shared.open(url)`
- List is static — may need updating across macOS versions

## Configurable Search Paths

- `AppSearcher` search scopes are user-configurable via Settings → General → Search Paths
- Persisted in UserDefaults key `appSearchPaths`
- Defaults include `/Applications`, `/Applications/Utilities`, `/System/Applications`, `/System/Applications/Utilities`, `/System/Library/CoreServices/Applications`, `~/Applications`
- Scopes converted to `URL` objects for reliable `NSMetadataQuery` recursion
- Changing paths restarts the Spotlight query immediately
- Live re-indexing via `NSMetadataQueryDidUpdate` observer — newly installed apps appear without restart

## Script Output Modes

- `ScriptOutputMode` enum replaces the previous `capturesOutput: Bool` on scripts
- Three modes: `.none` (fire-and-forget with toast), `.capture` (stream stdout into panel), `.replace` (replace active selection with stdout)
- `.replace` checks script exit code before replacing — on non-zero exit, shows error toast instead
- Backward-compatible: existing scripts.json entries without the field default to `.none`

## Shared Toast Utility

- `Toast` enum in `Sources/Relux/UI/Toast.swift` provides app-wide floating toast notifications
- Extracted from ScriptRunner's private implementation so other features (JWT validation, script errors) can reuse it
- Static `show(_:icon:)` method creates a borderless `NSPanel` positioned at top-center of the active screen
