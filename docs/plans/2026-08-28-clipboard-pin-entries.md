# Clipboard Pin/Unpin Feature

## Summary

Add the ability to pin and unpin clipboard history entries. Pinned entries appear in a dedicated "Pinned" section at the top of the clipboard history list, are exempt from both auto-expiration and manual "Clear All", and persist until explicitly unpinned and deleted.

## Decisions

| Question | Decision |
|---|---|
| Pin display | Separate "Pinned" section at top of list |
| Pin sort order | By `pinned_at ASC` (oldest pin at top, stable order) |
| Interaction | Toggle via Cmd+K actions overlay only |
| Expiration protection | Exempt from both auto-expiration AND Clear All |
| Pin limit | No limit |
| Filter/search behavior | Pinned section collapses; pins interleave by `updated_at DESC` in flat filtered results |
| Type filter behavior | Type filters apply to pinned section equally; hide "Pinned" header when empty |
| Pin dedup | Skip insert if text matches a pinned entry; bump its `updated_at` instead |

## Schema Change

Add `pinned_at` column to `clipboard_history`:

```sql
ALTER TABLE clipboard_history ADD COLUMN pinned_at REAL
```

- `NULL` = not pinned
- Non-null = pinned, value is the Unix timestamp when pinned (used for sort order within pinned section)

## ClipboardStore Changes

### Migration (in `init()`)
- Check for `pinned_at` column via `PRAGMA table_info`, add if missing (same pattern as `updated_at` migration).

### New Methods
- `pin(id: Int64)` — sets `pinned_at = now` for the given entry
- `unpin(id: Int64)` — sets `pinned_at = NULL` for the given entry

### Modified Methods
- `fetchAll(limit:)` — query returns pinned entries first (sorted by `pinned_at ASC`), then unpinned entries (sorted by `updated_at DESC`). The `ClipboardEntry` struct gains an `isPinned: Bool` computed from `pinned_at`.
- `fetchById(id:)` — SELECT must include `pinned_at` column to match updated `readRow` signature.
- `isDuplicate(textContent:)` — extend to also check pinned entries. Current query only checks `ORDER BY updated_at DESC LIMIT 1`. Change to: check the most recent entry by `updated_at` OR any pinned entry with matching text. If a pinned entry matches, bump its `updated_at` and return true.
- `deleteExpired(before:)` — add `AND pinned_at IS NULL` to both the image-path query and the DELETE statement.
- `clearAll()` — query unpinned image paths first, delete only those files, then `DELETE FROM clipboard_history WHERE pinned_at IS NULL`. This prevents orphaning image files for pinned entries.

### ClipboardEntry Struct
Add fields:
```swift
let pinnedAt: Date?
var isPinned: Bool { pinnedAt != nil }
```

### readRow
- Read column 14 as `pinned_at` (nullable REAL → `Date?`). All callers (`fetchAll`, `fetchById`) must include `pinned_at` in their SELECT column lists.

## ClipboardHistoryView Changes

### filteredEntries
When filter text is non-empty OR type filter is active, `filteredEntries` must re-sort the filtered results by `updatedAt` descending (ignoring pin-first ordering from `fetchAll`). This produces the interleaved behavior where pins mix naturally with unpinned entries by recency.

### Grouped Entries
When no filter/search is active AND no type filter is active:
1. First group: "Pinned" header, containing entries where `isPinned == true`, sorted by `pinnedAt ASC`
2. Remaining groups: existing date-based grouping of unpinned entries
3. If no pinned entries exist (or all are filtered out by type), omit the "Pinned" header entirely

When filter text is non-empty OR type filter is active:
- Flat filtered list (no separate pinned section), all entries sorted by `updated_at DESC`
- Pinned entries show a pin icon indicator to remain identifiable

### Entry Row
- Show `pin.fill` icon overlay/badge on pinned entries in the list

### Actions Overlay (`currentActions`)
- Add "Pin" action (icon: `pin`, no keyboard shortcut) for unpinned entries
- Add "Unpin" action (icon: `pin.slash`, no keyboard shortcut) for pinned entries
- Position: after "Delete" action, before filter actions

### Pin/Unpin Action
Must preserve filter state and selection. Do NOT call `loadEntries()` (which resets filter, typeFilter, selectedIndex). Instead, refetch `entries` array only and restore selection by entry ID:

```swift
private func togglePin(_ entry: ClipboardEntry) {
    if entry.isPinned {
        appState.clipboardStore?.unpin(id: entry.id)
    } else {
        appState.clipboardStore?.pin(id: entry.id)
    }
    let entryId = entry.id
    entries = appState.clipboardStore?.fetchAll() ?? []
    if let newIndex = filteredEntries.firstIndex(where: { $0.id == entryId }) {
        selectedIndex = newIndex
    } else {
        selectedIndex = min(selectedIndex, max(0, filteredEntries.count - 1))
    }
    showActions = false
}
```

## SettingsView Changes

Update the "Clear All" confirmation dialog text to reflect that pinned entries are preserved:
- Change from: "This will permanently delete **all** clipboard history entries and images."
- Change to: "This will permanently delete all unpinned clipboard history entries and images. Pinned entries will be kept."

## Files to Modify

1. `Sources/Relux/Store/ClipboardStore.swift` — schema migration, pin/unpin methods, modify fetchAll/fetchById/isDuplicate/deleteExpired/clearAll, update ClipboardEntry struct and readRow
2. `Sources/Relux/UI/ClipboardHistoryView.swift` — filteredEntries re-sort, pinned section in groupedEntries (hidden when empty), pin icon in entryRow, pin/unpin action in currentActions, togglePin with state preservation
3. `Sources/Relux/UI/SettingsView.swift` — update Clear All confirmation dialog text

## ClipboardMonitor Changes

No changes needed. `isDuplicate` is called from `ClipboardMonitor` but the dedup-with-pin-bump logic is encapsulated inside `ClipboardStore.isDuplicate`.
