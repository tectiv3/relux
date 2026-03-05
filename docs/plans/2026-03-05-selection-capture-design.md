# Selection Capture — Design

Capture selected text from any app via Accessibility API and pass it to Notty actions.

## Capture Mechanism

- New `SelectionCapture` enum with `captureSelectedText() -> String?`
- Uses `AXUIElement` system-wide element → focused app → focused UI element → `kAXSelectedTextAttribute`
- Called in `togglePanel()` **before** Notty takes focus (timing-critical)
- Result stored in `AppState.currentSelection: String?`, cleared on panel close
- Prompts for Accessibility permission via `AXIsProcessTrustedWithOptions` on first use

## Script Integration

- `ScriptItem` gains `acceptsSelection: Bool` (default false, persisted)
- `ScriptRunner.run()` gains `stdin: String?` parameter — pipes selection to process stdin
- Per-script toggle in Settings: "Pass selection as stdin"

## Web Search Integration

- When selection exists and query is empty, use selection as web search query
- No changes to the search result execution path

## Ask AI Integration

- When selection exists, prepend as context: `"Context:\n{selection}\n\nQuestion: {query}"`
- AI can work on selection even without a search result selected

## UI Indicator

- Subtle label in bottom bar when selection is captured (e.g. truncated preview)
- No changes to search bar or results flow
