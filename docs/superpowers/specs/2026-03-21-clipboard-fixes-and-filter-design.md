# Clipboard Fixes & Type Filter — Design Spec

**Date:** 2026-03-21
**Scope:** 3 changes to clipboard and translate history features

---

## 1. Clipboard Bump on Use

### Problem
Clipboard history sorts by `created_at DESC` only. Frequently reused items sink to the bottom over time.

### Solution
Add `updated_at` column to `clipboard_history`. Set `updated_at = created_at` on insert. Bump `updated_at` on any use action. Sort and group by `updated_at DESC`.

### Schema Change
```sql
ALTER TABLE clipboard_history ADD COLUMN updated_at REAL;
UPDATE clipboard_history SET updated_at = created_at WHERE updated_at IS NULL;
```

Run migration on DB open if column doesn't exist. Single-user desktop app — no concurrent writer concern during migration.

### Store Changes (`ClipboardStore.swift`)
- **`ClipboardEntry` struct:** Add `updatedAt: Date` field.
- **`readRow()`:** Read `updated_at` column and map to `updatedAt`.
- **All SELECT queries:** Include `updated_at` in column list.
- **Insert:** Set `updated_at` to same value as `created_at` in the INSERT statement.
- **New method** `bumpTimestamp(id:)`: `UPDATE clipboard_history SET updated_at = ? WHERE id = ?`
- **Sort queries:** Change `ORDER BY created_at DESC` to `ORDER BY updated_at DESC` in `fetchAll()` and `search()`.
- **`isDuplicate()`:** Keep using `ORDER BY created_at DESC` — dedup checks the most recently *inserted* item, not most recently *bumped*.
- **`deleteExpired()`:** Keep using `WHERE created_at < cutoff` — old items should not survive expiry just because they were bumped.

### View Changes (`ClipboardHistoryView.swift`)
- Call `clipboardStore.bumpTimestamp(id:)` before executing any use action.
- Date grouping (Today, Yesterday, etc.) uses `updatedAt` instead of `createdAt`.

### What triggers a bump
- Enter (paste to app)
- Cmd+Enter (copy to clipboard)
- Cmd+Shift+Enter (paste formatted)
- NOT triggered by: navigation, deletion, or opening actions menu.

---

## 2. Translate Delete Bug Fix

### Problem
Deleting an item from translate history leaves a ghost row visible. The cursor skips around it.

### Root Cause
Two compounding issues:

1. `TranslateView.deleteEntry()` calls `loadEntries()` which re-fetches the full array from the DB, causing a full array replacement.
2. The `ForEach` row modifier `.id(adjustedIndex)` (line 177) overrides SwiftUI's stable `\.element.id` with a shifting integer. When the array shrinks, all IDs after the deleted index shift down, confusing SwiftUI's diffing.

### Fix
Two changes:

**a)** Replace `loadEntries()` with in-place array mutation (mirrors clipboard pattern):

```swift
private func deleteEntry(_ entry: TranslationEntry) {
    try? appState.translateStore?.delete(id: entry.id)
    entries.removeAll { $0.id == entry.id }
    if selectedIndex >= entries.count {
        selectedIndex = max(0, entries.count - 1)
    }
    showActions = false
}
```

**b)** Change `.id(adjustedIndex)` on line 177 to `.id(entry.id)` so SwiftUI uses stable DB primary keys for identity. This prevents ghost rows for any array mutation, not just delete (e.g. retranslate completion also calls `loadEntries()`).

---

## 3. Type Filter in Actions Menu

### Problem
No way to filter clipboard history by content type. When looking for a specific image or text snippet, the user must scroll through all items.

### Solution
Add filter actions to the Cmd+K actions menu. 4 filter categories: Text, Images, Rich Text, Color. Transient (resets on panel close). Badge indicator when active.

### State
```swift
@State private var typeFilter: ClipboardContentType?

enum ClipboardContentType: String, CaseIterable {
    case text
    case image
    case richText
    case color
}
```

Define enum in `ClipboardHistoryView.swift` (private to the view — it's a UI filter concept, not a store-level type).

Reset `typeFilter = nil` in `loadEntries()`.

### Content Type Mapping
| Filter | Matches `content_type` values |
|--------|-------------------------------|
| `.text` | `"text"` |
| `.image` | `"image"` |
| `.richText` | `"rtf"`, `"html"` |
| `.color` | `"color"` |

**Coordination note:** Color detection is being implemented by another agent using `content_type = "color"`. If the string value changes, update the mapping here.

### Actions Menu Additions
Append to `currentActions` (after existing actions):
- "Show Text Only" — icon: `doc.plaintext`
- "Show Images Only" — icon: `photo`
- "Show Rich Text Only" — icon: `doc.richtext`
- "Show Colors Only" — icon: `paintpalette`

If the active filter matches the action's type, the label changes to "Clear Filter" with the same icon. Selecting it sets `typeFilter = nil`.

### Filtering Logic
Applied on top of existing text search filter in `filteredEntries`:
```
entries → text search filter → type filter → displayed list
```

Performance: O(n) per render, acceptable for typical clipboard sizes (~500 items max).

### Badge Indicator
When `typeFilter != nil`, show a label above the list:
- Format: `"Images ×"` (category name + dismiss hint)
- Positioned in the list header area

### Escape Key Priority Chain
Escape key behavior, in order:
1. Close actions overlay (if open)
2. Clear type filter (if active)
3. Clear text filter (if non-empty)
4. Dismiss panel

### Behavior
- Filter is transient — resets to nil when panel closes (`loadEntries()`)
- `selectedIndex` resets to 0 when filter changes
- If filter yields 0 results, show empty state text (e.g. "No images in history")

---

## Files to Modify

| File | Changes |
|------|---------|
| `Sources/Relux/Store/ClipboardStore.swift` | Add `updated_at` column + migration, `updatedAt` to struct + `readRow()`, update all SELECTs, `bumpTimestamp()`, update INSERT, change sort to `updated_at DESC` in `fetchAll()`/`search()` |
| `Sources/Relux/UI/ClipboardHistoryView.swift` | Call bump on all use actions, group by `updatedAt`, add `ClipboardContentType` enum + type filter state/logic/UI, filter actions in Cmd+K, escape priority chain, badge indicator |
| `Sources/Relux/UI/TranslateView.swift` | Fix `deleteEntry()` to use `entries.removeAll`, change `.id(adjustedIndex)` to `.id(entry.id)` on row modifier |

## Files NOT Modified
- `ClipboardMonitor.swift` — color detection is handled by another agent
- `TranslateStore.swift` — no changes needed
