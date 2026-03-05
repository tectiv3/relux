# Notty — Decisions & Request History

Only architectural/behavioral decisions with downstream implications. Not bug fixes or cosmetic tweaks.

## Search Architecture

- `SourceNote` replaced with generic `SearchItem` supporting `.note` and `.app` kinds — all future result types extend this
- Search is instant, as-you-type — keyword matching on VectorStore cache + app name fuzzy matching. No embedding needed for basic search.
- LLM generation is opt-in only, behind Cmd+K → "Ask AI" action. Never auto-triggers.
- App search scans `/Applications`, `~/Applications`, `/System/Applications`, caches at init
- Do NOT use `Bundle(url:)` to read app bundles — triggers App Management permission. Only use `FileManager` + path inspection.

## Frecency System

- Tracks query→item selections (frequency + recency) to rank results
- Query normalized to first 4 chars for grouping similar queries
- Stores full SearchItem data so recents can be displayed on empty query
- Data persisted in `~/Library/Application Support/Notty/` (frecency.json, recents.json)

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

- On hotkey press, selected text is read from the focused app via Accessibility API (`AXUIElement`) BEFORE Notty takes focus
- Stored in `AppState.currentSelection`, cleared on panel close
- Scripts opt in via `acceptsSelection: Bool` — selection is piped as stdin
- Web search uses selection as query when search bar is empty
- Ask AI prepends selection as context to the LLM prompt
- Bottom bar shows truncated selection preview when captured
- Requires Accessibility permission (prompted on first launch)

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
- Storage: SQLite `clipboard_history` table in existing `notty.db`, images saved as PNG files in `~/Library/Application Support/Notty/clipboard/`
- Paste-back: puts content on system clipboard, closes panel, activates previous app, simulates Cmd+V via CGEvent
- `suppressNextCapture` flag prevents self-paste recording
- Hotkey: Opt+Cmd+V (configurable via KeyboardShortcuts)
- Disabled apps list stored in UserDefaults, defaults include Keychain Access and Passwords
- Retention-based cleanup runs once on app launch (configurable: 1/3/6 months)
