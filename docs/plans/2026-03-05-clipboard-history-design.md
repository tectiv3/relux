# Clipboard History — Design

## Overview

Clipboard history extension for Relux. Monitors the system clipboard, stores copied items (text, RTF, HTML, images), and lets users browse/paste from history via a dedicated hotkey.

## Architecture: Integrated Extension

Clipboard history lives inside the existing `FloatingPanel` as an alternate view mode. A `panelMode` enum on `AppState` (`.search` | `.clipboard`) controls which view is displayed. The same panel, keyboard nav, and actions patterns are reused.

## Data Model

SQLite table in existing `relux.db`:

```sql
CREATE TABLE clipboard_history (
    id            INTEGER PRIMARY KEY AUTOINCREMENT,
    content_type  TEXT NOT NULL,  -- "text", "rtf", "html", "image"
    text_content  TEXT,           -- plain text (for display/filter)
    raw_data      BLOB,          -- RTF/HTML bytes when applicable
    image_path    TEXT,           -- relative to App Support/Relux/clipboard/
    image_width   INTEGER,
    image_height  INTEGER,
    image_size    INTEGER,        -- bytes
    source_app    TEXT,           -- bundle ID
    source_name   TEXT,           -- display name
    char_count    INTEGER,
    word_count    INTEGER,
    created_at    REAL NOT NULL   -- unix timestamp
);
```

Images stored as PNG files in `~/Library/Application Support/Relux/clipboard/`. Cleanup job deletes orphaned files when entries expire based on retention setting.

## Clipboard Monitor

`ClipboardMonitor` — polls `NSPasteboard.general.changeCount` every 0.5s via `Timer`.

On change detected:
1. Check frontmost app bundle ID against disabled apps list → skip if matched
2. Read pasteboard types in priority: image (TIFF/PNG) → RTF → HTML → plain text
3. For images: save PNG to disk, record path + dimensions + file size
4. For rich text: store raw RTF/HTML data + extracted plain text
5. For plain text: store directly
6. Record source app via `NSWorkspace.shared.frontmostApplication`
7. Deduplicate — skip if text content matches most recent entry

Self-paste suppression: when Relux pastes an item back, a flag suppresses recording the next changeCount bump.

Starts automatically on app launch. No system clipboard history API exists on macOS — polling is the standard approach (used by Raycast, Maccy, Paste).

## Paste-back Flow

1. Before showing clipboard view: record `NSWorkspace.shared.frontmostApplication`
2. User selects item, presses Enter:
   - Put content on `NSPasteboard.general` (set self-paste flag)
   - Hide panel
   - `previousApp.activate()`
   - ~50ms delay, simulate Cmd+V via `CGEvent`
3. Requires Accessibility permission (already requested by `SelectionCapture`)

## UI — ClipboardHistoryView

Triggered by dedicated hotkey (default Cmd+Opt+V). Replaces panel content.

### Top bar
- Back arrow button (←) → returns to main search view
- Filter text field (focused, filters items by text content)
- "All Types" dropdown (future nice-to-have, not in v1)

### Left panel (list)
- Grouped by day: "Today", "Yesterday", then dates
- Each row: content type icon + preview text (truncated) or "Image (WxH)"
- Keyboard nav: up/down arrows, highlighted selection

### Right panel (preview)
- Text entries: full text, scrollable
- Image entries: thumbnail preview
- Info footer: source app (icon + name), content type, char/word count or dimensions/size, timestamp

### Bottom bar
- Left: "Paste to [App Name]" + Enter hint
- Right: "Actions" + Cmd+K hint

### Keyboard
- Enter → paste to previous app
- Cmd+Enter → copy to clipboard only
- Cmd+K → actions menu
- Esc → close panel entirely
- Delete → remove entry from history

### Actions menu (Cmd+K)
- Paste to [App]
- Copy to Clipboard
- Paste Formatted (preserves RTF/HTML)
- Delete

## Navigation

- **Cmd+Opt+V** (or custom hotkey): opens panel in clipboard mode. If panel already open in search mode, switches to clipboard mode.
- **Back arrow**: returns to main search view
- **Esc**: always closes panel
- **Option+Space** (existing toggle): always opens main search view

## Settings — New "Clipboard" Tab

- **Enable clipboard monitoring** — toggle (on by default)
- **Hotkey** — `KeyboardShortcuts` recorder, new `.clipboardHistory` shortcut
- **Keep History For** — dropdown: 1 month / 3 months (default) / 6 months
- **Disabled Applications** — list with default entries (Keychain Access, Passwords by bundle ID)
  - "Select More Apps" button → `NSOpenPanel` filtered to `.app`
  - Each entry: app icon + name + remove button
- **Clear History** — button with confirmation dialog

## New Files

| File | Responsibility |
|------|----------------|
| `Store/ClipboardStore.swift` | SQLite CRUD, image file management, expiry cleanup |
| `Clipboard/ClipboardMonitor.swift` | Timer polling, dedup, disabled app check, self-paste suppression |
| `UI/ClipboardHistoryView.swift` | List + preview + actions + filter UI |

## Modified Files

| File | Changes |
|------|---------|
| `HotkeyManager.swift` | Add `.clipboardHistory` shortcut definition |
| `AppDelegate.swift` | Register second hotkey, panel mode switching, track previous app |
| `AppState.swift` | `panelMode` enum, `ClipboardMonitor` + `ClipboardStore` lifecycle |
| `UI/SettingsView.swift` | New "Clipboard" tab |
| `UI/OverlayView.swift` | Wrap in conditional based on `panelMode` |
| `project.yml` | No changes needed (sources auto-discovered) |
