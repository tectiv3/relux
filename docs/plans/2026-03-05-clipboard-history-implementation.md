# Clipboard History Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a clipboard history extension to Notty that monitors copies, stores them in SQLite, and lets users browse/paste from history via a dedicated hotkey.

**Architecture:** Integrated extension within the existing FloatingPanel. A `panelMode` enum on AppState controls whether OverlayView or ClipboardHistoryView is displayed. Clipboard monitoring uses timer-based polling of `NSPasteboard.general.changeCount`. Paste-back simulates Cmd+V via CGEvent into the previously active app.

**Tech Stack:** Swift 6, SwiftUI, SQLite3 (raw C API, matching VectorStore patterns), KeyboardShortcuts package, CGEvent for paste simulation.

---

### Task 1: ClipboardStore — Data Layer

**Files:**
- Create: `Sources/Notty/Store/ClipboardStore.swift`

**Context:** Follow `VectorStore.swift` patterns exactly — raw SQLite3 C API, `@MainActor`, `nonisolated(unsafe)` for db pointer, `StoreError` reuse, same App Support directory and `notty.db` file.

**Step 1: Create ClipboardStore with schema**

```swift
import AppKit
import Foundation
import os
import SQLite3

private let log = Logger(subsystem: "com.notty.app", category: "clipboardstore")

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
}

@MainActor
final class ClipboardStore {
    private nonisolated(unsafe) var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Directory for clipboard image files
    let imageDir: URL

    init() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Notty", isDirectory: true)
        imageDir = dir.appendingPathComponent("clipboard", isDirectory: true)
        try fileManager.createDirectory(at: imageDir, withIntermediateDirectories: true)

        let dbPath = dir.appendingPathComponent("notty.db").path
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StoreError.cannotOpen
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS clipboard_history (
                id            INTEGER PRIMARY KEY AUTOINCREMENT,
                content_type  TEXT NOT NULL,
                text_content  TEXT,
                raw_data      BLOB,
                image_path    TEXT,
                image_width   INTEGER,
                image_height  INTEGER,
                image_size    INTEGER,
                source_app    TEXT,
                source_name   TEXT,
                char_count    INTEGER,
                word_count    INTEGER,
                created_at    REAL NOT NULL
            )
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Insert

    func insert(
        contentType: String,
        textContent: String?,
        rawData: Data?,
        imagePath: String?,
        imageWidth: Int?,
        imageHeight: Int?,
        imageSize: Int?,
        sourceApp: String?,
        sourceName: String?
    ) throws {
        let charCount = textContent?.count
        let wordCount = textContent?.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

        let sql = """
            INSERT INTO clipboard_history
                (content_type, text_content, raw_data, image_path, image_width, image_height, image_size,
                 source_app, source_name, char_count, word_count, created_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, contentType, -1, Self.transient)
        bindOptionalText(stmt, 2, textContent)
        if let rawData {
            rawData.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(rawData.count), Self.transient)
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        bindOptionalText(stmt, 4, imagePath)
        bindOptionalInt(stmt, 5, imageWidth)
        bindOptionalInt(stmt, 6, imageHeight)
        bindOptionalInt(stmt, 7, imageSize)
        bindOptionalText(stmt, 8, sourceApp)
        bindOptionalText(stmt, 9, sourceName)
        bindOptionalInt(stmt, 10, charCount)
        bindOptionalInt(stmt, 11, wordCount)
        sqlite3_bind_double(stmt, 12, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    // MARK: - Query

    func fetchAll(limit: Int = 500) -> [ClipboardEntry] {
        let sql = "SELECT id, content_type, text_content, raw_data, image_path, image_width, image_height, image_size, source_app, source_name, char_count, word_count, created_at FROM clipboard_history ORDER BY created_at DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var entries: [ClipboardEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(readRow(stmt))
        }
        return entries
    }

    func search(filter: String) -> [ClipboardEntry] {
        let sql = "SELECT id, content_type, text_content, raw_data, image_path, image_width, image_height, image_size, source_app, source_name, char_count, word_count, created_at FROM clipboard_history WHERE text_content LIKE ? ORDER BY created_at DESC LIMIT 200"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        let pattern = "%\(filter)%"
        sqlite3_bind_text(stmt, 1, pattern, -1, Self.transient)

        var entries: [ClipboardEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(readRow(stmt))
        }
        return entries
    }

    /// Check if the most recent entry has the same text content (dedup)
    func isDuplicate(textContent: String) -> Bool {
        let sql = "SELECT text_content FROM clipboard_history ORDER BY created_at DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        guard let ptr = sqlite3_column_text(stmt, 0) else { return false }
        return String(cString: ptr) == textContent
    }

    // MARK: - Delete

    func delete(id: Int64) throws {
        // First get image path to clean up file
        let entry = fetchById(id: id)
        if let imagePath = entry?.imagePath {
            let fullPath = imageDir.appendingPathComponent(imagePath)
            try? FileManager.default.removeItem(at: fullPath)
        }

        let sql = "DELETE FROM clipboard_history WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    func clearAll() throws {
        // Delete all image files
        let fm = FileManager.default
        if let files = try? fm.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fm.removeItem(at: file)
            }
        }
        try execute("DELETE FROM clipboard_history")
    }

    /// Delete entries older than the given date and their associated image files
    func deleteExpired(before date: Date) throws {
        // Collect image paths first
        let sql = "SELECT image_path FROM clipboard_history WHERE created_at < ? AND image_path IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }

        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)

        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                paths.append(String(cString: ptr))
            }
        }
        sqlite3_finalize(stmt)

        for path in paths {
            let fullPath = imageDir.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: fullPath)
        }

        try execute("DELETE FROM clipboard_history WHERE created_at < \(date.timeIntervalSince1970)")
    }

    // MARK: - Private

    private func fetchById(id: Int64) -> ClipboardEntry? {
        let sql = "SELECT id, content_type, text_content, raw_data, image_path, image_width, image_height, image_size, source_app, source_name, char_count, word_count, created_at FROM clipboard_history WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readRow(stmt)
    }

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
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12))
        )
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StoreError.exec(msg)
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: add ClipboardStore data layer for clipboard history
```

---

### Task 2: ClipboardMonitor — Polling and Capture

**Files:**
- Create: `Sources/Notty/Clipboard/ClipboardMonitor.swift`

**Context:** Timer polls `NSPasteboard.general.changeCount` every 0.5s. Captures text, RTF, HTML, and images. Skips disabled apps. Suppresses self-paste recording.

**Step 1: Create ClipboardMonitor**

```swift
import AppKit
import Foundation
import os

private let log = Logger(subsystem: "com.notty.app", category: "clipboardmonitor")

@MainActor
@Observable
final class ClipboardMonitor {
    private let store: ClipboardStore
    private var timer: Timer?
    private var lastChangeCount: Int = 0
    var suppressNextCapture = false

    /// Bundle IDs of apps whose copies should be ignored
    var disabledApps: Set<String> {
        get {
            let arr = UserDefaults.standard.stringArray(forKey: "clipboardDisabledApps") ?? [
                "com.apple.keychainaccess",
                "com.apple.Passwords",
            ]
            return Set(arr)
        }
        set {
            UserDefaults.standard.set(Array(newValue), forKey: "clipboardDisabledApps")
        }
    }

    var isEnabled: Bool {
        get { UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true }
        set {
            UserDefaults.standard.set(newValue, forKey: "clipboardEnabled")
            if newValue { start() } else { stop() }
        }
    }

    init(store: ClipboardStore) {
        self.store = store
        lastChangeCount = NSPasteboard.general.changeCount
    }

    func start() {
        guard isEnabled, timer == nil else { return }
        lastChangeCount = NSPasteboard.general.changeCount
        timer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            Task { @MainActor [weak self] in
                self?.checkClipboard()
            }
        }
        log.info("Clipboard monitoring started")
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        log.info("Clipboard monitoring stopped")
    }

    private func checkClipboard() {
        let pb = NSPasteboard.general
        let currentCount = pb.changeCount
        guard currentCount != lastChangeCount else { return }
        lastChangeCount = currentCount

        if suppressNextCapture {
            suppressNextCapture = false
            return
        }

        // Check if frontmost app is disabled
        if let frontApp = NSWorkspace.shared.frontmostApplication,
           let bundleId = frontApp.bundleIdentifier,
           disabledApps.contains(bundleId)
        {
            log.info("Skipping clipboard from disabled app: \(bundleId)")
            return
        }

        captureClipboard(pb)
    }

    private func captureClipboard(_ pb: NSPasteboard) {
        let sourceApp = NSWorkspace.shared.frontmostApplication
        let sourceBundle = sourceApp?.bundleIdentifier
        let sourceName = sourceApp?.localizedName

        // Priority: image → RTF → HTML → plain text
        if let imageData = pb.data(forType: .tiff) ?? pb.data(forType: .png) {
            captureImage(imageData, sourceApp: sourceBundle, sourceName: sourceName)
        } else if let rtfData = pb.data(forType: .rtf), let plainText = pb.string(forType: .string) {
            captureRichText(contentType: "rtf", rawData: rtfData, plainText: plainText, sourceApp: sourceBundle, sourceName: sourceName)
        } else if let htmlData = pb.data(forType: .html), let plainText = pb.string(forType: .string) {
            captureRichText(contentType: "html", rawData: htmlData, plainText: plainText, sourceApp: sourceBundle, sourceName: sourceName)
        } else if let text = pb.string(forType: .string) {
            capturePlainText(text, sourceApp: sourceBundle, sourceName: sourceName)
        }
    }

    private func capturePlainText(_ text: String, sourceApp: String?, sourceName: String?) {
        guard !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !store.isDuplicate(textContent: text) else { return }

        do {
            try store.insert(
                contentType: "text",
                textContent: text,
                rawData: nil,
                imagePath: nil,
                imageWidth: nil,
                imageHeight: nil,
                imageSize: nil,
                sourceApp: sourceApp,
                sourceName: sourceName
            )
        } catch {
            log.error("Failed to store clipboard text: \(error.localizedDescription)")
        }
    }

    private func captureRichText(contentType: String, rawData: Data, plainText: String, sourceApp: String?, sourceName: String?) {
        guard !plainText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        guard !store.isDuplicate(textContent: plainText) else { return }

        do {
            try store.insert(
                contentType: contentType,
                textContent: plainText,
                rawData: rawData,
                imagePath: nil,
                imageWidth: nil,
                imageHeight: nil,
                imageSize: nil,
                sourceApp: sourceApp,
                sourceName: sourceName
            )
        } catch {
            log.error("Failed to store clipboard rich text: \(error.localizedDescription)")
        }
    }

    private func captureImage(_ data: Data, sourceApp: String?, sourceName: String?) {
        guard let image = NSImage(data: data) else { return }
        let width = Int(image.size.width)
        let height = Int(image.size.height)

        // Save as PNG
        guard let tiffRep = image.tiffRepresentation,
              let bitmapRep = NSBitmapImageRep(data: tiffRep),
              let pngData = bitmapRep.representation(using: .png, properties: [:])
        else { return }

        let filename = "\(UUID().uuidString).png"
        let filePath = store.imageDir.appendingPathComponent(filename)

        do {
            try pngData.write(to: filePath)
            try store.insert(
                contentType: "image",
                textContent: nil,
                rawData: nil,
                imagePath: filename,
                imageWidth: width,
                imageHeight: height,
                imageSize: pngData.count,
                sourceApp: sourceApp,
                sourceName: sourceName
            )
        } catch {
            log.error("Failed to store clipboard image: \(error.localizedDescription)")
        }
    }
}
```

**Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: add ClipboardMonitor for polling and capturing clipboard changes
```

---

### Task 3: Panel Mode Switching — AppState + HotkeyManager

**Files:**
- Modify: `Sources/Notty/AppState.swift`
- Modify: `Sources/Notty/HotkeyManager.swift`

**Context:** Add `panelMode` enum to AppState, wire up ClipboardStore and ClipboardMonitor lifecycle. Add new keyboard shortcut for clipboard history.

**Step 1: Add panel mode and clipboard properties to AppState**

In `Sources/Notty/HotkeyManager.swift`, add below `toggleNotty`:

```swift
static let clipboardHistory = Self("clipboardHistory", default: .init(.v, modifiers: [.option, .command]))
```

In `Sources/Notty/AppState.swift`:

Add enum before the class:

```swift
enum PanelMode: Sendable {
    case search
    case clipboard
}
```

Add properties to `AppState`:

```swift
var clipboardStore: ClipboardStore?
var clipboardMonitor: ClipboardMonitor?
var panelMode: PanelMode = .search
var previousApp: NSRunningApplication?
```

In the `setup()` method, after existing code, add:

```swift
let cs = try ClipboardStore()
clipboardStore = cs
let monitor = ClipboardMonitor(store: cs)
clipboardMonitor = monitor
monitor.start()
```

Add import for AppKit at the top of AppState.swift (needed for NSRunningApplication).

**Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: add panel mode switching and clipboard lifecycle to AppState
```

---

### Task 4: AppDelegate — Hotkey Registration + Panel Mode

**Files:**
- Modify: `Sources/Notty/AppDelegate.swift`

**Context:** Register second hotkey. Track previous app. Switch panel content based on which hotkey was pressed.

**Step 1: Add clipboard hotkey handling to AppDelegate**

In `applicationDidFinishLaunching`, after the existing `KeyboardShortcuts.onKeyUp` block, add:

```swift
KeyboardShortcuts.onKeyUp(for: .clipboardHistory) { [weak self] in
    self?.toggleClipboardHistory()
}
```

Add new method to AppDelegate:

```swift
func toggleClipboardHistory() {
    guard let panel else { return }
    if panel.isVisible, appState.panelMode == .clipboard {
        let frame = panel.frame
        UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
        UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
        panel.close()
        return
    }

    // Track the app that was active before we show the panel
    if !panel.isVisible {
        appState.previousApp = NSWorkspace.shared.frontmostApplication
    }

    appState.panelMode = .clipboard
    if !panel.isVisible {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

Also update `togglePanel()` to set `panelMode = .search` before showing, and track previousApp:

```swift
func togglePanel() {
    guard let panel else { return }
    if panel.isVisible {
        let frame = panel.frame
        UserDefaults.standard.set(frame.origin.x, forKey: "panelX")
        UserDefaults.standard.set(frame.origin.y, forKey: "panelY")
        appState.currentSelection = nil
        panel.close()
    } else {
        appState.previousApp = NSWorkspace.shared.frontmostApplication
        appState.currentSelection = SelectionCapture.captureSelectedText()
        appState.panelMode = .search
        applyForcedInputSource()
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: register clipboard history hotkey and panel mode switching
```

---

### Task 5: PasteService — Paste-back to Previous App

**Files:**
- Create: `Sources/Notty/Clipboard/PasteService.swift`

**Context:** Puts content on system clipboard, hides Notty, activates previous app, simulates Cmd+V via CGEvent. Uses the existing Accessibility permission.

**Step 1: Create PasteService**

```swift
import AppKit
import Carbon
import os

private let log = Logger(subsystem: "com.notty.app", category: "pasteservice")

enum PasteService {
    /// Put text on clipboard and paste into the previously active app
    @MainActor
    static func pasteText(_ text: String, asRichText rtfData: Data? = nil, to app: NSRunningApplication?, monitor: ClipboardMonitor?) {
        let pb = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pb.clearContents()
        if let rtfData {
            pb.setData(rtfData, forType: .rtf)
        }
        pb.setString(text, forType: .string)
        sendPaste(to: app)
    }

    /// Put image on clipboard and paste into the previously active app
    @MainActor
    static func pasteImage(at path: URL, to app: NSRunningApplication?, monitor: ClipboardMonitor?) {
        guard let image = NSImage(contentsOf: path) else { return }
        let pb = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pb.clearContents()
        pb.writeObjects([image])
        sendPaste(to: app)
    }

    /// Copy text to clipboard without pasting
    @MainActor
    static func copyToClipboard(_ text: String, asRichText rtfData: Data? = nil, monitor: ClipboardMonitor?) {
        let pb = NSPasteboard.general
        monitor?.suppressNextCapture = true
        pb.clearContents()
        if let rtfData {
            pb.setData(rtfData, forType: .rtf)
        }
        pb.setString(text, forType: .string)
    }

    private static func sendPaste(to app: NSRunningApplication?) {
        // Close the panel
        NSApp.keyWindow?.close()

        // Activate previous app and simulate Cmd+V
        guard let app else { return }
        app.activate()

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            simulateCmdV()
        }
    }

    private static func simulateCmdV() {
        let src = CGEventSource(stateID: .hidSystemState)

        // Key code 9 = V
        guard let keyDown = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: true),
              let keyUp = CGEvent(keyboardEventSource: src, virtualKey: 9, keyDown: false)
        else { return }

        keyDown.flags = .maskCommand
        keyUp.flags = .maskCommand

        keyDown.post(tap: .cghidEventTap)
        keyUp.post(tap: .cghidEventTap)
    }
}
```

**Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: add PasteService for paste-back into previous app
```

---

### Task 6: ClipboardHistoryView — Main UI

**Files:**
- Create: `Sources/Notty/UI/ClipboardHistoryView.swift`

**Context:** Two-pane layout: left list (grouped by day) + right preview. Back arrow returns to search mode. Filter text field stays focused and filters items. Bottom bar shows "Paste to [App]" + Actions hint. Matches existing OverlayView visual style exactly (same fonts, spacing, colors, selection highlighting).

**Step 1: Create ClipboardHistoryView**

```swift
import SwiftUI

struct ClipboardHistoryView: View {
    @Environment(AppState.self) private var appState
    @State private var filter: String = ""
    @State private var entries: [ClipboardEntry] = []
    @State private var selectedIndex: Int = 0
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0

    private var filteredEntries: [ClipboardEntry] {
        if filter.trimmingCharacters(in: .whitespaces).isEmpty {
            return entries
        }
        let lower = filter.lowercased()
        return entries.filter { entry in
            entry.textContent?.lowercased().contains(lower) == true
                || entry.sourceName?.lowercased().contains(lower) == true
        }
    }

    private var selectedEntry: ClipboardEntry? {
        let items = filteredEntries
        guard selectedIndex >= 0, selectedIndex < items.count else { return nil }
        return items[selectedIndex]
    }

    private var previousAppName: String {
        appState.previousApp?.localizedName ?? "App"
    }

    private var currentActions: [ClipAction] {
        guard let entry = selectedEntry else { return [] }
        var actions: [ClipAction] = [
            ClipAction(label: "Paste to \(previousAppName)", icon: "doc.on.clipboard.fill", shortcut: "⏎") {
                pasteEntry(entry, formatted: false)
            },
            ClipAction(label: "Copy to Clipboard", icon: "doc.on.clipboard", shortcut: "⌘⏎") {
                copyEntry(entry)
            },
        ]
        if entry.rawData != nil {
            actions.append(ClipAction(label: "Paste Formatted to \(previousAppName)", icon: "textformat", shortcut: "⌘⇧⏎") {
                pasteEntry(entry, formatted: true)
            })
        }
        actions.append(ClipAction(label: "Delete", icon: "trash", shortcut: "⌫") {
            deleteEntry(entry)
        })
        return actions
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            topBar
            Divider()

            if filteredEntries.isEmpty {
                Text(entries.isEmpty ? "No clipboard history" : "No matches")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                HSplitView {
                    listPanel
                        .frame(minWidth: 280, maxWidth: 320)
                    previewPanel
                }
            }

            Spacer(minLength: 0)
            Divider()
            bottomBar
        }
        .frame(width: 750)
        .frame(maxHeight: .infinity)
        .clipShape(RoundedRectangle(cornerRadius: 12))
        .overlay {
            if showActions {
                actionsOverlay
            }
        }
        .onAppear {
            loadEntries()
        }
        .onKeyPress(.upArrow) {
            if showActions {
                guard !currentActions.isEmpty else { return .ignored }
                actionIndex = actionIndex <= 0 ? currentActions.count - 1 : actionIndex - 1
                return .handled
            }
            let items = filteredEntries
            guard !items.isEmpty else { return .ignored }
            selectedIndex = selectedIndex <= 0 ? items.count - 1 : selectedIndex - 1
            return .handled
        }
        .onKeyPress(.downArrow) {
            if showActions {
                guard !currentActions.isEmpty else { return .ignored }
                actionIndex = actionIndex >= currentActions.count - 1 ? 0 : actionIndex + 1
                return .handled
            }
            let items = filteredEntries
            guard !items.isEmpty else { return .ignored }
            selectedIndex = selectedIndex >= items.count - 1 ? 0 : selectedIndex + 1
            return .handled
        }
        .onKeyPress(.return) {
            if showActions {
                guard actionIndex < currentActions.count else { return .ignored }
                currentActions[actionIndex].action()
                showActions = false
                return .handled
            }
            guard let entry = selectedEntry else { return .ignored }
            pasteEntry(entry, formatted: false)
            return .handled
        }
        .onKeyPress(.escape) {
            if showActions {
                showActions = false
                return .handled
            }
            return .ignored
        }
        .onKeyPress(.delete) {
            guard !showActions, let entry = selectedEntry else { return .ignored }
            deleteEntry(entry)
            return .handled
        }
        .background {
            // Cmd+K to toggle actions
            Button("") {
                guard selectedEntry != nil else { return }
                actionIndex = 0
                showActions.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()

            // Cmd+Enter to copy to clipboard
            Button("") {
                guard let entry = selectedEntry else { return }
                copyEntry(entry)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                appState.panelMode = .search
            } label: {
                Image(systemName: "arrow.left")
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.primary.opacity(0.08))
                    )
            }
            .buttonStyle(.plain)

            TextField("Type to filter entries...", text: $filter)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .onChange(of: filter) { _, _ in
                    selectedIndex = 0
                }
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List Panel

    private var groupedEntries: [(label: String, items: [(index: Int, entry: ClipboardEntry)])] {
        let items = filteredEntries
        let calendar = Calendar.current
        let now = Date()

        var groups: [(label: String, items: [(index: Int, entry: ClipboardEntry)])] = []
        var currentLabel = ""
        var currentItems: [(index: Int, entry: ClipboardEntry)] = []

        for (index, entry) in items.enumerated() {
            let label: String
            if calendar.isDateInToday(entry.createdAt) {
                label = "Today"
            } else if calendar.isDateInYesterday(entry.createdAt) {
                label = "Yesterday"
            } else {
                let formatter = DateFormatter()
                formatter.dateStyle = .medium
                formatter.timeStyle = .none
                label = formatter.string(from: entry.createdAt)
            }

            if label != currentLabel {
                if !currentItems.isEmpty {
                    groups.append((currentLabel, currentItems))
                }
                currentLabel = label
                currentItems = []
            }
            currentItems.append((index, entry))
        }
        if !currentItems.isEmpty {
            groups.append((currentLabel, currentItems))
        }
        return groups
    }

    private var listPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(spacing: 0) {
                    Spacer().frame(height: 4)
                    ForEach(Array(groupedEntries.enumerated()), id: \.element.label) { _, section in
                        Text(section.label)
                            .font(.system(size: 11, weight: .medium))
                            .foregroundColor(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.top, 8)
                            .padding(.bottom, 2)

                        ForEach(section.items, id: \.entry.id) { index, entry in
                            entryRow(entry: entry, isSelected: index == selectedIndex)
                                .id(index)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    selectedIndex = index
                                }
                                .onTapGesture(count: 2) {
                                    selectedIndex = index
                                    pasteEntry(entry, formatted: false)
                                }
                        }
                    }
                }
            }
            .onChange(of: selectedIndex) { _, newIndex in
                withAnimation {
                    proxy.scrollTo(newIndex, anchor: .center)
                }
            }
        }
    }

    private func entryRow(entry: ClipboardEntry, isSelected: Bool) -> some View {
        HStack(spacing: 8) {
            Image(systemName: entryIcon(for: entry))
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .font(.system(size: 13))
                .frame(width: 20)

            Text(entryTitle(for: entry))
                .font(.system(size: 13))
                .lineLimit(1)

            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    private func entryIcon(for entry: ClipboardEntry) -> String {
        switch entry.contentType {
        case "image": "photo"
        case "rtf", "html": "doc.richtext"
        default: "doc.text"
        }
    }

    private func entryTitle(for entry: ClipboardEntry) -> String {
        switch entry.contentType {
        case "image":
            if let w = entry.imageWidth, let h = entry.imageHeight {
                return "Image (\(w)×\(h))"
            }
            return "Image"
        default:
            let text = entry.textContent ?? ""
            let firstLine = text.split(separator: "\n", maxSplits: 1).first.map(String.init) ?? text
            return String(firstLine.prefix(80))
        }
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        VStack(spacing: 0) {
            if let entry = selectedEntry {
                // Content preview
                ScrollView {
                    VStack(alignment: .leading) {
                        if entry.contentType == "image", let imagePath = entry.imagePath {
                            let url = appState.clipboardStore!.imageDir.appendingPathComponent(imagePath)
                            if let nsImage = NSImage(contentsOf: url) {
                                Image(nsImage: nsImage)
                                    .resizable()
                                    .aspectRatio(contentMode: .fit)
                                    .frame(maxHeight: 250)
                                    .clipShape(RoundedRectangle(cornerRadius: 4))
                            }
                        } else if let text = entry.textContent {
                            Text(text)
                                .font(.system(size: 13, design: .monospaced))
                                .textSelection(.enabled)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                    .padding(12)
                }

                Divider()

                // Info footer
                infoFooter(entry: entry)
            }
        }
    }

    private func infoFooter(entry: ClipboardEntry) -> some View {
        VStack(spacing: 0) {
            infoRow(label: "Application") {
                HStack(spacing: 4) {
                    if let bundleId = entry.sourceApp,
                       let appURL = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId)
                    {
                        let icon = NSWorkspace.shared.icon(forFile: appURL.path)
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 16, height: 16)
                    }
                    Text(entry.sourceName ?? "Unknown")
                }
            }

            infoRow(label: "Content type") {
                Text(entry.contentType.capitalized)
            }

            if entry.contentType == "image" {
                if let w = entry.imageWidth, let h = entry.imageHeight {
                    infoRow(label: "Dimensions") { Text("\(w)×\(h)") }
                }
                if let size = entry.imageSize {
                    infoRow(label: "Image size") { Text(formatBytes(size)) }
                }
            } else {
                if let count = entry.charCount {
                    infoRow(label: "Characters") { Text("\(count)") }
                }
                if let count = entry.wordCount {
                    infoRow(label: "Words") { Text("\(count)") }
                }
            }

            infoRow(label: "Copied") {
                Text(formatTime(entry.createdAt))
            }
        }
        .font(.system(size: 12))
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
    }

    private func infoRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        HStack {
            Text(label)
                .foregroundColor(.secondary)
            Spacer()
            content()
        }
        .padding(.vertical, 2)
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            HStack(spacing: 4) {
                Image(systemName: "clipboard")
                    .font(.system(size: 11))
                Text("Clipboard History")
            }
            .foregroundColor(.secondary.opacity(0.7))

            Spacer()

            if selectedEntry != nil {
                keyboardHint(key: "⏎", label: "Paste to \(previousAppName)")
            }
            keyboardHint(key: "⌘K", label: "Actions")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .font(.system(size: 11))
        .foregroundColor(.secondary)
    }

    private func keyboardHint(key: String, label: String) -> some View {
        HStack(spacing: 4) {
            Text(key)
                .padding(.horizontal, 4)
                .padding(.vertical, 1)
                .background(
                    RoundedRectangle(cornerRadius: 3)
                        .stroke(Color.secondary.opacity(0.5), lineWidth: 0.5)
                )
            Text(label)
        }
    }

    // MARK: - Actions Overlay

    private var actionsOverlay: some View {
        VStack {
            Spacer()
            HStack {
                Spacer()
                VStack(spacing: 0) {
                    if let entry = selectedEntry {
                        HStack(spacing: 6) {
                            Image(systemName: entryIcon(for: entry))
                                .font(.system(size: 11))
                            Text(entryTitle(for: entry))
                                .font(.system(size: 12, weight: .medium))
                                .lineLimit(1)
                            Spacer()
                        }
                        .foregroundColor(.secondary)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        Divider()
                    }

                    ForEach(Array(currentActions.enumerated()), id: \.offset) { index, action in
                        HStack(spacing: 10) {
                            Image(systemName: action.icon)
                                .foregroundColor(index == actionIndex ? .white.opacity(0.8) : .secondary)
                                .font(.system(size: 13))
                                .frame(width: 20)
                            Text(action.label)
                                .font(.system(size: 13))
                            Spacer()
                            if let shortcut = action.shortcut {
                                Text(shortcut)
                                    .font(.system(size: 11))
                                    .foregroundColor(index == actionIndex ? .white.opacity(0.6) : .secondary)
                            }
                        }
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(
                            RoundedRectangle(cornerRadius: 6)
                                .fill(index == actionIndex ? Color.accentColor : Color.clear)
                                .padding(.horizontal, 4)
                        )
                        .foregroundColor(index == actionIndex ? .white : .primary)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            action.action()
                            showActions = false
                        }
                    }
                }
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 8)
                        .fill(.ultraThickMaterial)
                        .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
                )
                .clipShape(RoundedRectangle(cornerRadius: 8))
                .frame(width: 300)
                .padding(.trailing, 8)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Actions

    private func pasteEntry(_ entry: ClipboardEntry, formatted: Bool) {
        if entry.contentType == "image", let imagePath = entry.imagePath {
            let url = appState.clipboardStore!.imageDir.appendingPathComponent(imagePath)
            PasteService.pasteImage(at: url, to: appState.previousApp, monitor: appState.clipboardMonitor)
        } else if let text = entry.textContent {
            let rtfData = formatted ? entry.rawData : nil
            PasteService.pasteText(text, asRichText: rtfData, to: appState.previousApp, monitor: appState.clipboardMonitor)
        }
    }

    private func copyEntry(_ entry: ClipboardEntry) {
        if let text = entry.textContent {
            PasteService.copyToClipboard(text, asRichText: entry.rawData, monitor: appState.clipboardMonitor)
        }
        NSApp.keyWindow?.close()
    }

    private func deleteEntry(_ entry: ClipboardEntry) {
        try? appState.clipboardStore?.delete(id: entry.id)
        entries.removeAll { $0.id == entry.id }
        let items = filteredEntries
        selectedIndex = min(selectedIndex, max(0, items.count - 1))
        showActions = false
    }

    private func loadEntries() {
        entries = appState.clipboardStore?.fetchAll() ?? []
        selectedIndex = 0
        filter = ""
    }

    // MARK: - Helpers

    private func formatBytes(_ bytes: Int) -> String {
        let kb = Double(bytes) / 1024
        if kb < 1024 {
            return String(format: "%.0f KB", kb)
        }
        return String(format: "%.1f MB", kb / 1024)
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        if Calendar.current.isDateInToday(date) {
            formatter.dateFormat = "'Today at' HH:mm:ss"
        } else {
            formatter.dateStyle = .medium
            formatter.timeStyle = .short
        }
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Types

private struct ClipAction {
    let label: String
    let icon: String
    let shortcut: String?
    let action: () -> Void
}
```

**Step 2: Build to verify**

Run: `xcodegen generate && xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: add ClipboardHistoryView with list, preview, and actions
```

---

### Task 7: Wire Panel Mode into OverlayView / AppDelegate

**Files:**
- Modify: `Sources/Notty/AppDelegate.swift`
- Modify: `Sources/Notty/UI/OverlayView.swift` (minimal change)

**Context:** The panel's hosted view needs to switch between OverlayView and ClipboardHistoryView based on `appState.panelMode`. The cleanest way is a wrapper view.

**Step 1: Create a PanelRootView that switches content**

Add to the **top** of `Sources/Notty/UI/OverlayView.swift` (before OverlayView struct):

```swift
struct PanelRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.panelMode {
        case .search:
            OverlayView()
        case .clipboard:
            ClipboardHistoryView()
        }
    }
}
```

**Step 2: Update AppDelegate to use PanelRootView**

In `AppDelegate.setupPanel()`, change:

```swift
let hostingView = NSHostingView(rootView: OverlayView().environment(appState))
```

to:

```swift
let hostingView = NSHostingView(rootView: PanelRootView().environment(appState))
```

**Step 3: Build to verify**

Run: `xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 4: Commit**

```
feat: wire panel mode switching between search and clipboard views
```

---

### Task 8: Settings — Clipboard Tab

**Files:**
- Modify: `Sources/Notty/UI/SettingsView.swift`

**Context:** Add a "Clipboard" tab with enable toggle, hotkey recorder, retention picker, disabled apps list, and clear button. Follow existing tab patterns.

**Step 1: Add clipboard settings state properties**

Add these `@State` properties to `SettingsView`:

```swift
@State private var clipboardEnabled: Bool = UserDefaults.standard.object(forKey: "clipboardEnabled") as? Bool ?? true
@State private var clipboardRetention: Int = UserDefaults.standard.object(forKey: "clipboardRetentionMonths") as? Int ?? 3
@State private var disabledApps: [DisabledApp] = []
@State private var showClearConfirmation = false
```

Add a helper struct inside SettingsView:

```swift
struct DisabledApp: Identifiable {
    let id: String  // bundle ID
    let name: String
    let icon: NSImage?
}
```

**Step 2: Add the clipboard tab**

Add to the `TabView` in `body`:

```swift
clipboardTab.tabItem { Label("Clipboard", systemImage: "clipboard") }
```

Add the tab view:

```swift
// MARK: - Clipboard Tab

private var clipboardTab: some View {
    Form {
        Section("Monitoring") {
            Toggle("Enable clipboard history", isOn: $clipboardEnabled)
                .onChange(of: clipboardEnabled) { _, newValue in
                    appState.clipboardMonitor?.isEnabled = newValue
                }

            KeyboardShortcuts.Recorder("Hotkey:", name: .clipboardHistory)
        }

        Section("Storage") {
            Picker("Keep history for:", selection: $clipboardRetention) {
                Text("1 Month").tag(1)
                Text("3 Months").tag(3)
                Text("6 Months").tag(6)
            }
            .onChange(of: clipboardRetention) { _, newValue in
                UserDefaults.standard.set(newValue, forKey: "clipboardRetentionMonths")
            }

            Button("Clear All History", role: .destructive) {
                showClearConfirmation = true
            }
            .alert("Clear Clipboard History?", isPresented: $showClearConfirmation) {
                Button("Cancel", role: .cancel) {}
                Button("Clear", role: .destructive) {
                    try? appState.clipboardStore?.clearAll()
                }
            } message: {
                Text("This will permanently delete all clipboard history entries and images.")
            }
        }

        Section {
            Button("Select More Apps") {
                selectDisabledApp()
            }

            ForEach(disabledApps) { app in
                HStack {
                    if let icon = app.icon {
                        Image(nsImage: icon)
                            .resizable()
                            .frame(width: 20, height: 20)
                    }
                    Text(app.name)
                    Spacer()
                    Button {
                        removeDisabledApp(bundleId: app.id)
                    } label: {
                        Image(systemName: "xmark.circle")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.borderless)
                }
            }
        } header: {
            Text("Disabled Applications")
        } footer: {
            Text("Clipboard history will not record copies from these apps.")
                .font(.caption)
        }
    }
    .formStyle(.grouped)
    .padding()
    .onAppear {
        loadDisabledApps()
    }
}

private func loadDisabledApps() {
    let bundleIds = appState.clipboardMonitor?.disabledApps ?? []
    disabledApps = bundleIds.compactMap { bundleId in
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleId) else {
            return DisabledApp(id: bundleId, name: bundleId, icon: nil)
        }
        let name = FileManager.default.displayName(atPath: url.path)
        let icon = NSWorkspace.shared.icon(forFile: url.path)
        return DisabledApp(id: bundleId, name: name, icon: icon)
    }
}

private func selectDisabledApp() {
    let panel = NSOpenPanel()
    panel.allowedContentTypes = [.application]
    panel.directoryURL = URL(fileURLWithPath: "/Applications")
    panel.allowsMultipleSelection = false
    panel.canChooseDirectories = false

    guard panel.runModal() == .OK, let url = panel.url else { return }
    guard let bundle = Bundle(url: url),
          let bundleId = bundle.bundleIdentifier else { return }

    appState.clipboardMonitor?.disabledApps.insert(bundleId)
    loadDisabledApps()
}

private func removeDisabledApp(bundleId: String) {
    appState.clipboardMonitor?.disabledApps.remove(bundleId)
    loadDisabledApps()
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: add Clipboard settings tab with monitoring, retention, and disabled apps
```

---

### Task 9: Expiry Cleanup on Launch

**Files:**
- Modify: `Sources/Notty/AppState.swift`

**Context:** On app launch, delete entries older than the configured retention period. Simple and runs once.

**Step 1: Add cleanup to AppState.setup()**

After the clipboard monitor is started in `setup()`, add:

```swift
// Clean up expired clipboard entries
let retentionMonths = UserDefaults.standard.object(forKey: "clipboardRetentionMonths") as? Int ?? 3
if let cutoffDate = Calendar.current.date(byAdding: .month, value: -retentionMonths, to: Date()) {
    try? cs.deleteExpired(before: cutoffDate)
}
```

**Step 2: Build to verify**

Run: `xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Commit**

```
feat: clean up expired clipboard history on launch
```

---

### Task 10: Format + Final Build Verification

**Step 1: Format all code**

Run: `swiftformat Sources/`

**Step 2: Build**

Run: `xcodebuild -project Notty.xcodeproj -scheme Notty -configuration Debug build`

**Step 3: Fix any issues, re-format, re-build**

**Step 4: Final commit**

```
chore: format all sources
```

---

## File Summary

| New Files | Purpose |
|-----------|---------|
| `Sources/Notty/Store/ClipboardStore.swift` | SQLite CRUD for clipboard entries + image file management |
| `Sources/Notty/Clipboard/ClipboardMonitor.swift` | Timer-based polling, content capture, dedup, disabled app filtering |
| `Sources/Notty/Clipboard/PasteService.swift` | Paste-back via CGEvent, clipboard manipulation |
| `Sources/Notty/UI/ClipboardHistoryView.swift` | Two-pane UI: list + preview + actions |

| Modified Files | Changes |
|----------------|---------|
| `Sources/Notty/HotkeyManager.swift` | Add `.clipboardHistory` shortcut |
| `Sources/Notty/AppState.swift` | PanelMode enum, clipboard store/monitor lifecycle, previousApp tracking, expiry cleanup |
| `Sources/Notty/AppDelegate.swift` | Second hotkey registration, toggleClipboardHistory(), previousApp tracking in togglePanel() |
| `Sources/Notty/UI/OverlayView.swift` | Add PanelRootView wrapper |
| `Sources/Notty/UI/SettingsView.swift` | Clipboard settings tab |
