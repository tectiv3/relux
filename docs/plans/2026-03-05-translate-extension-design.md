# Translate Extension Design

Translate extension for Relux. Uses Anthropic API to translate selected text, stores history in SQLite, provides a two-pane UI for browsing/managing translations.

## Activation Flow

1. User selects text in any app → presses Relux hotkey
2. Panel opens in search mode — selection indicator already visible, selected text NOT in input
3. "Translate" appears as a search result (like scripts with `acceptsSelection`), selected text preview as subtitle
4. User selects "Translate" → `panelMode` switches to `.translate` → selected text moves into input → translation fires immediately via streaming
5. User can also type new text directly in translate mode and press Enter to translate

## Translate Mode UI (two-pane, like ClipboardHistoryView)

- **Top bar:** Input field (Enter to translate) + target language dropdown (top item from editable language list)
- **Left pane:** Translation history, most recent first. Each row: truncated source/translated text + timestamp
- **Right pane:** Selected entry detail — source text, translated text, detected source language, target language, model, timestamp. New translations stream in token-by-token
- **Bottom bar:** Keyboard hints — Enter (translate), Actions (Cmd+K)

### Actions Menu (Cmd+K)

- Re-translate (same input, fresh API call)
- Copy to clipboard
- Delete from history

## Data Layer

### TranslateStore

New table `translation_history` in existing `relux.db`, following ClipboardStore patterns (raw SQLite3 C API, `@MainActor`, `nonisolated(unsafe)` for db pointer, `StoreError` reuse):

```sql
CREATE TABLE IF NOT EXISTS translation_history (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    source_text   TEXT NOT NULL,
    translated_text TEXT NOT NULL,
    source_lang   TEXT,
    target_lang   TEXT NOT NULL,
    model         TEXT NOT NULL,
    created_at    REAL NOT NULL
);
```

## Anthropic API

### AnthropicService

Simple HTTP client using URLSession with streaming (SSE). No SDK dependency.

- API key stored in **macOS Keychain**
- Model configurable, default `claude-sonnet-4-20250514`
- Customizable system prompt, default:

```
You are a translation machine. Translate the user's text into {target_language}. Output ONLY the translated text with no additions whatsoever. No preamble, no explanation, no quotation marks, no markdown, no notes. Preserve original formatting including line breaks and whitespace. If the text is already in {target_language}, output it unchanged.
```

## Settings — Translate Tab

- Anthropic API key field (reads/writes Keychain)
- Model name text field (default pre-filled)
- System prompt multi-line editor
- Editable language list (reorderable, top = default target). English pre-populated.
- Clear history button

## Code Changes

### New PanelMode

```swift
enum PanelMode {
    case search
    case clipboard
    case translate
}
```

### New SearchItemKind

```swift
enum SearchItemKind {
    case note, app, webSearch, script, translate
}
```

### New Files

| File | Role |
|------|------|
| `Sources/Relux/Translate/AnthropicService.swift` | Streaming HTTP client for Anthropic Messages API |
| `Sources/Relux/Translate/TranslateStore.swift` | SQLite CRUD for translation history |
| `Sources/Relux/UI/TranslateView.swift` | Two-pane translate UI with streaming |

### Modified Files

| File | Change |
|------|--------|
| `Sources/Relux/AppState.swift` | Add TranslateStore init, PanelMode.translate |
| `Sources/Relux/Extensions/ExtensionProtocol.swift` | Add `.translate` to SearchItemKind |
| `Sources/Relux/AppState.swift` | Inject "Translate" search item when `currentSelection != nil` |
| `Sources/Relux/UI/OverlayView.swift` | PanelRootView routes `.translate` to TranslateView; handle selecting translate item → switch panel mode |
| `Sources/Relux/UI/SettingsView.swift` | Add Translate settings tab |
| `Sources/Relux/Extensions/ExtensionRegistry.swift` | Register translate extension |
