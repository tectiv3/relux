# Clipboard Fixes & Type Filter Implementation Plan

> **For agentic workers:** REQUIRED: Use superpowers-extended-cc:subagent-driven-development (if subagents available) or superpowers-extended-cc:executing-plans to implement this plan. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Add bump-on-use sorting to clipboard history, fix translate delete bug, and add type filtering to clipboard actions menu.

**Architecture:** Three independent changes to existing files. ClipboardStore gets schema migration + new method. ClipboardHistoryView gets filter state + UI + bump calls. TranslateView gets a two-line fix.

**Tech Stack:** Swift 6, SwiftUI, SQLite C-API

**Spec:** `docs/superpowers/specs/2026-03-21-clipboard-fixes-and-filter-design.md`

---

## File Map

| File | Action | Responsibility |
|------|--------|----------------|
| `Sources/Relux/Store/ClipboardStore.swift` | Modify | Schema migration, struct update, bump method, sort order |
| `Sources/Relux/UI/ClipboardHistoryView.swift` | Modify | Bump calls, type filter enum/state/UI/actions, escape chain, badge |
| `Sources/Relux/UI/TranslateView.swift` | Modify | Fix deleteEntry, fix .id() modifier |

---

### Task 1: Fix Translate Delete Bug

**Files:**
- Modify: `Sources/Relux/UI/TranslateView.swift:548-555` (deleteEntry)
- Modify: `Sources/Relux/UI/TranslateView.swift:177` (.id modifier)

- [ ] **Step 1: Fix deleteEntry to use in-place array mutation**

In `Sources/Relux/UI/TranslateView.swift`, replace the `deleteEntry` method (line 548-555):

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

The key change: `entries.removeAll { $0.id == entry.id }` instead of `loadEntries()`.

- [ ] **Step 2: Fix .id() modifier and scrollTo to use stable DB primary key**

In `Sources/Relux/UI/TranslateView.swift` line 177, change `.id(adjustedIndex)` to `.id(entry.id)`:

```swift
// Before:
.id(adjustedIndex)

// After:
.id(entry.id)
```

Then update the `scrollTo` call at line 185-188 to scroll by entry ID instead of index. Replace:

```swift
.onChange(of: selectedIndex) { _, newIndex in
    withAnimation {
        proxy.scrollTo(newIndex, anchor: .center)
    }
}
```

With:

```swift
.onChange(of: selectedIndex) { _, newIndex in
    let targetId: Int64? = if isTranslating {
        newIndex == 0 ? nil : (newIndex - 1 < entries.count ? entries[newIndex - 1].id : nil)
    } else {
        newIndex < entries.count ? entries[newIndex].id : nil
    }
    if let targetId {
        withAnimation {
            proxy.scrollTo(targetId, anchor: .center)
        }
    } else if isTranslating, newIndex == 0 {
        withAnimation {
            proxy.scrollTo(-1, anchor: .center)
        }
    }
}
```

This maps `selectedIndex` back to a stable `entry.id` for scrolling. The streaming row keeps `.id(-1)` so scrolling to index 0 during translation scrolls to -1.

- [ ] **Step 3: Build and verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 4: Format and lint**

Run: `swiftformat Sources/Relux/UI/TranslateView.swift && swiftlint lint --baseline .swiftlint.baseline --quiet Sources/Relux/UI/TranslateView.swift`

- [ ] **Step 5: Commit**

```
git add Sources/Relux/UI/TranslateView.swift
git commit -m "Fix translate history delete: use in-place array mutation and stable row IDs"
```

---

### Task 2: Add updated_at Column & Bump Method to ClipboardStore

**Files:**
- Modify: `Sources/Relux/Store/ClipboardStore.swift`

- [ ] **Step 1: Add updatedAt field to ClipboardEntry struct**

In `Sources/Relux/Store/ClipboardStore.swift` line 8-22, add `updatedAt` after `createdAt`:

```swift
struct ClipboardEntry: Identifiable, Sendable {
    let id: Int64
    let contentType: String
    let textContent: String?
    let rawData: Data?
    let imagePath: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let imageSize: Int?
    let sourceApp: String?
    let sourceName: String?
    let charCount: Int?
    let wordCount: Int?
    let createdAt: Date
    let updatedAt: Date
}
```

- [ ] **Step 2: Add migration in init()**

After the `CREATE TABLE` statement (line 61), add migration:

```swift
// Migrate: add updated_at column if missing
let pragmaSql = "PRAGMA table_info(clipboard_history)"
var pragmaStmt: OpaquePointer?
if sqlite3_prepare_v2(db, pragmaSql, -1, &pragmaStmt, nil) == SQLITE_OK {
    var hasUpdatedAt = false
    while sqlite3_step(pragmaStmt) == SQLITE_ROW {
        if let name = sqlite3_column_text(pragmaStmt, 1) {
            if String(cString: name) == "updated_at" {
                hasUpdatedAt = true
                break
            }
        }
    }
    sqlite3_finalize(pragmaStmt)
    if !hasUpdatedAt {
        try execute("ALTER TABLE clipboard_history ADD COLUMN updated_at REAL")
        try execute("UPDATE clipboard_history SET updated_at = created_at")
    }
}
```

- [ ] **Step 3: Update INSERT to set updated_at = created_at**

In the `insert()` method, update the SQL and bindings. Change the SQL (line 84-88):

```swift
let sql = """
    INSERT INTO clipboard_history
        (content_type, text_content, raw_data, image_path, image_width, image_height, image_size,
         source_app, source_name, char_count, word_count, created_at, updated_at)
    VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
"""
```

After the `created_at` bind (line 113), add:

```swift
let now = Date().timeIntervalSince1970
sqlite3_bind_double(stmt, 12, now)
sqlite3_bind_double(stmt, 13, now)
```

(Replace the existing line 113 `sqlite3_bind_double(stmt, 12, Date().timeIntervalSince1970)` with these two lines sharing the same `now` value.)

- [ ] **Step 4: Add bumpTimestamp method**

Add after the `isDuplicate` method (after line 187):

```swift
func bumpTimestamp(id: Int64) {
    let sql = "UPDATE clipboard_history SET updated_at = ? WHERE id = ?"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
    sqlite3_bind_int64(stmt, 2, id)
    sqlite3_step(stmt)
}
```

- [ ] **Step 5: Update all SELECT queries to include updated_at and sort by it**

Update `fetchAll()` SQL (line 135-139):

```swift
let sql = """
SELECT id, content_type, text_content, NULL, image_path, \
image_width, image_height, image_size, source_app, \
source_name, char_count, word_count, created_at, updated_at \
FROM clipboard_history ORDER BY updated_at DESC LIMIT ?
"""
```

Update `search()` SQL (line 155-161):

```swift
let sql = """
SELECT id, content_type, text_content, NULL, image_path, \
image_width, image_height, image_size, source_app, \
source_name, char_count, word_count, created_at, updated_at \
FROM clipboard_history \
WHERE text_content LIKE ? \
ORDER BY updated_at DESC LIMIT 200
"""
```

Update `fetchById()` SQL (line 261-264):

```swift
let sql = """
SELECT id, content_type, text_content, raw_data, image_path, \
image_width, image_height, image_size, source_app, \
source_name, char_count, word_count, created_at, updated_at \
FROM clipboard_history WHERE id = ?
"""
```

- [ ] **Step 6: Update readRow to parse updated_at**

In `readRow()` (line 275-294), add `updatedAt` after `createdAt`. The `updated_at` is at column index 13:

```swift
private func readRow(_ stmt: OpaquePointer?) -> ClipboardEntry {
    ClipboardEntry(
        id: sqlite3_column_int64(stmt, 0),
        contentType: String(cString: sqlite3_column_text(stmt, 1)),
        textContent: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
        rawData: {
            guard let ptr = sqlite3_column_blob(stmt, 3) else { return nil }
            let size = Int(sqlite3_column_bytes(stmt, 3))
            return Data(bytes: ptr, count: size)
        }(),
        imagePath: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
        imageWidth: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil,
        imageHeight: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil,
        imageSize: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil,
        sourceApp: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
        sourceName: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
        charCount: sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 10)) : nil,
        wordCount: sqlite3_column_type(stmt, 11) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 11)) : nil,
        createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
        updatedAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 13))
    )
}
```

- [ ] **Step 7: Build and verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED (`createdAt` still exists on the struct, so all existing references compile fine)

- [ ] **Step 8: Format and lint**

Run: `swiftformat Sources/Relux/Store/ClipboardStore.swift && swiftlint lint --baseline .swiftlint.baseline --quiet Sources/Relux/Store/ClipboardStore.swift`

- [ ] **Step 9: Commit**

```
git add Sources/Relux/Store/ClipboardStore.swift
git commit -m "Add updated_at column to clipboard history with migration and bump method"
```

---

### Task 3: Wire Bump Calls & Update Date Grouping in ClipboardHistoryView

**Files:**
- Modify: `Sources/Relux/UI/ClipboardHistoryView.swift`

- [ ] **Step 1: Update groupedEntries to use updatedAt**

In `groupedEntries` (line 160-194), change all `entry.createdAt` references to `entry.updatedAt`:

```swift
// Line 170: change entry.createdAt to entry.updatedAt
if calendar.isDateInToday(entry.updatedAt) {
// Line 172: change entry.createdAt to entry.updatedAt
} else if calendar.isDateInYesterday(entry.updatedAt) {
// Line 178: change entry.createdAt to entry.updatedAt
label = formatter.string(from: entry.updatedAt)
```

- [ ] **Step 2: Add bump call to pasteEntry**

In `pasteEntry` (line 602-609), add bump at the start of the method:

```swift
private func pasteEntry(_ entry: ClipboardEntry, formatted: Bool) {
    appState.clipboardStore?.bumpTimestamp(id: entry.id)
    if entry.contentType == "image", let imagePath = entry.imagePath {
        let url = appState.clipboardStore!.imageDir.appendingPathComponent(imagePath)
        PasteService.pasteImage(at: url, monitor: appState.clipboardMonitor)
    } else if let text = entry.textContent {
        let rtfData = formatted ? appState.clipboardStore?.fetchRawData(id: entry.id) : nil
        PasteService.pasteText(text, asRichText: rtfData, monitor: appState.clipboardMonitor)
    }
}
```

- [ ] **Step 3: Add bump call to copyEntry**

In `copyEntry` (line 612-618), add bump at the start:

```swift
private func copyEntry(_ entry: ClipboardEntry) {
    appState.clipboardStore?.bumpTimestamp(id: entry.id)
    if let text = entry.textContent {
        let rtfData = appState.clipboardStore?.fetchRawData(id: entry.id)
        PasteService.copyToClipboard(text, asRichText: rtfData, monitor: appState.clipboardMonitor)
    }
    NSApp.keyWindow?.close()
}
```

- [ ] **Step 4: Build and verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 5: Format and lint**

Run: `swiftformat Sources/Relux/UI/ClipboardHistoryView.swift && swiftlint lint --baseline .swiftlint.baseline --quiet Sources/Relux/UI/ClipboardHistoryView.swift`

- [ ] **Step 6: Commit**

```
git add Sources/Relux/UI/ClipboardHistoryView.swift
git commit -m "Wire bump-on-use to clipboard paste and copy actions, group by updatedAt"
```

---

### Task 4: Add Type Filter to Clipboard Actions Menu

**Files:**
- Modify: `Sources/Relux/UI/ClipboardHistoryView.swift`

- [ ] **Step 1: Add ClipboardContentType enum and filter state**

Add the enum before the `ClipboardHistoryView` struct (after `import SwiftUI`, before line 3):

```swift
private enum ClipboardContentType: String, CaseIterable {
    case text
    case image
    case richText
    case color

    var label: String {
        switch self {
        case .text: "Text"
        case .image: "Images"
        case .richText: "Rich Text"
        case .color: "Colors"
        }
    }

    var icon: String {
        switch self {
        case .text: "doc.plaintext"
        case .image: "photo"
        case .richText: "doc.richtext"
        case .color: "paintpalette"
        }
    }

    func matches(_ contentType: String) -> Bool {
        switch self {
        case .text: contentType == "text"
        case .image: contentType == "image"
        case .richText: contentType == "rtf" || contentType == "html"
        case .color: contentType == "color"
        }
    }
}
```

Add state variable inside `ClipboardHistoryView` (after line 9, near other `@State` vars):

```swift
@State private var typeFilter: ClipboardContentType?
```

- [ ] **Step 2: Update filteredEntries to apply type filter**

Replace `filteredEntries` (line 12-25) to add type filtering:

```swift
private var filteredEntries: [ClipboardEntry] {
    var result = entries
    if let typeFilter {
        result = result.filter { typeFilter.matches($0.contentType) }
    }
    let query = filter.trimmingCharacters(in: .whitespaces).lowercased()
    if query.isEmpty { return result }
    return result.filter { entry in
        let text = entry.textContent ?? ""
        let firstLine = String(text.split(separator: "\n", maxSplits: 1).first ?? "")
        return text.lowercased().contains(query)
            || fuzzyMatch(query: query, target: firstLine)
            || fuzzyMatch(query: query, target: entry.sourceName ?? "")
    }
}
```

- [ ] **Step 3: Reset typeFilter in loadEntries**

In `loadEntries()` (line 628-632), add `typeFilter = nil`:

```swift
private func loadEntries() {
    entries = appState.clipboardStore?.fetchAll() ?? []
    selectedIndex = 0
    filter = ""
    typeFilter = nil
}
```

- [ ] **Step 4: Add filter actions to currentActions**

In `currentActions` (line 37-59), append filter actions after the Delete action:

```swift
// After the existing actions.append for Delete (before `return actions`):
actions.append(ClipAction(
    label: typeFilter == .text ? "Clear Filter" : "Show Text Only",
    icon: ClipboardContentType.text.icon, shortcut: nil
) {
    typeFilter = typeFilter == .text ? nil : .text
    selectedIndex = 0
    showActions = false
})
actions.append(ClipAction(
    label: typeFilter == .image ? "Clear Filter" : "Show Images Only",
    icon: ClipboardContentType.image.icon, shortcut: nil
) {
    typeFilter = typeFilter == .image ? nil : .image
    selectedIndex = 0
    showActions = false
})
actions.append(ClipAction(
    label: typeFilter == .richText ? "Clear Filter" : "Show Rich Text Only",
    icon: ClipboardContentType.richText.icon, shortcut: nil
) {
    typeFilter = typeFilter == .richText ? nil : .richText
    selectedIndex = 0
    showActions = false
})
actions.append(ClipAction(
    label: typeFilter == .color ? "Clear Filter" : "Show Colors Only",
    icon: ClipboardContentType.color.icon, shortcut: nil
) {
    typeFilter = typeFilter == .color ? nil : .color
    selectedIndex = 0
    showActions = false
})
```

- [ ] **Step 5: Add badge indicator above the list**

In the `body` (around line 66-78), add the badge between the Divider and the content. Replace the block:

```swift
Divider()

if let typeFilter {
    HStack(spacing: 4) {
        Image(systemName: typeFilter.icon)
            .font(.system(size: 11))
        Text(typeFilter.label)
            .font(.system(size: 12, weight: .medium))
        Image(systemName: "xmark.circle.fill")
            .font(.system(size: 11))
            .foregroundColor(.secondary)
    }
    .padding(.horizontal, 8)
    .padding(.vertical, 4)
    .background(RoundedRectangle(cornerRadius: 6).fill(Color.accentColor.opacity(0.15)))
    .onTapGesture {
        typeFilter = nil
        selectedIndex = 0
    }
    .frame(maxWidth: .infinity, alignment: .leading)
    .padding(.horizontal, 16)
    .padding(.top, 6)
}

if filteredEntries.isEmpty {
```

- [ ] **Step 6: Update escape key chain**

In `handleKeyPress` (line 538-551), update the escape handling to: actions overlay → type filter → text filter → dismiss:

```swift
if keyPress.key == .escape {
    if showActions {
        showActions = false
        return .handled
    }
    if typeFilter != nil {
        typeFilter = nil
        selectedIndex = 0
        return .handled
    }
    if !filter.isEmpty {
        filter = ""
        selectedIndex = 0
        return .handled
    }
    return .ignored
}
```

- [ ] **Step 7: Update empty state text**

Update the empty state text (around line 68) to be filter-aware:

```swift
if filteredEntries.isEmpty {
    let message: String = if entries.isEmpty {
        "No clipboard history"
    } else if let typeFilter {
        "No \(typeFilter.label.lowercased()) in history"
    } else {
        "No matches"
    }
    Text(message)
        .font(.system(size: 13))
        .foregroundColor(.secondary)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
}
```

- [ ] **Step 8: Build and verify**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 9: Format and lint**

Run: `swiftformat Sources/Relux/UI/ClipboardHistoryView.swift && swiftlint lint --baseline .swiftlint.baseline --quiet Sources/Relux/UI/ClipboardHistoryView.swift`

- [ ] **Step 10: Commit**

```
git add Sources/Relux/UI/ClipboardHistoryView.swift
git commit -m "Add type filter to clipboard history actions menu with badge indicator"
```

---

### Task 5: Final Verification

- [ ] **Step 1: Full build**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -destination 'platform=macOS' build 2>&1 | tail -5`
Expected: BUILD SUCCEEDED

- [ ] **Step 2: Format and lint all changed files**

Run: `swiftformat Sources/Relux/Store/ClipboardStore.swift Sources/Relux/UI/ClipboardHistoryView.swift Sources/Relux/UI/TranslateView.swift && swiftlint lint --baseline .swiftlint.baseline --quiet`

- [ ] **Step 3: Manual test checklist**

Verify in running app:
- Clipboard: paste an old item → it moves to "Today" group at top
- Clipboard: Cmd+Enter copy → item bumps to top
- Clipboard: Cmd+K → filter actions visible → selecting "Show Images Only" filters list
- Clipboard: badge shows when filter active, clicking clears it
- Clipboard: Escape clears filter before dismissing panel
- Clipboard: empty filter shows "No images in history" (or similar)
- Translate: delete item → no ghost row, cursor moves correctly
