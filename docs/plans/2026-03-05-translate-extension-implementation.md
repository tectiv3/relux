# Translate Extension Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Add a translate extension that uses the Anthropic Messages API to translate text, stores history in SQLite, and presents a two-pane UI with streaming.

**Architecture:** Translate appears as a search result when `currentSelection != nil` (same pattern as scripts with `acceptsSelection`). Selecting it switches `panelMode` to `.translate`, passing the selected text. The translate UI has its own input field for new translations, a history list, a preview pane, and a language dropdown. AnthropicService handles streaming SSE from the Messages API. API key stored in macOS Keychain.

**Tech Stack:** Swift 6, SwiftUI, raw SQLite3 C API, URLSession streaming, Keychain Services C API

---

### Task 1: Fix Input Focus Bug

**Context:** Two bugs: (1) In clipboard history mode, the back button steals focus from the filter TextField. (2) In default search mode, the search field sometimes doesn't get focus because `NSWindow.didBecomeKeyNotification` fires before the view is ready.

**Files:**
- Modify: `Sources/Relux/UI/ClipboardHistoryView.swift`
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Fix ClipboardHistoryView focus**

The back button is a `Button` that takes focus by default. Add `.focusable(false)` to it, and add a small delay to `isFilterFocused` assignment to ensure the view hierarchy is ready.

In `Sources/Relux/UI/ClipboardHistoryView.swift`, find the back button in `topBar` (around line 158-170):

```swift
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
            .focusable(false)
```

Add `.focusable(false)` after `.buttonStyle(.plain)`.

**Step 2: Fix OverlayView focus**

In `Sources/Relux/UI/OverlayView.swift`, the `didBecomeKeyNotification` handler sets `isSearchFocused = true`. Add a matching `.onAppear` block that also sets focus, as a fallback:

Find the `.onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification))` block (around line 184) and add after it:

```swift
        .onAppear {
            isSearchFocused = true
        }
```

**Step 3: Build and verify**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 4: Commit**

```
git add Sources/Relux/UI/ClipboardHistoryView.swift Sources/Relux/UI/OverlayView.swift
git commit -m "fix: input focus in clipboard history and search mode"
```

---

### Task 2: TranslateStore — SQLite Persistence

**Context:** Follow `ClipboardStore` patterns exactly: raw SQLite3 C API, `@MainActor`, `nonisolated(unsafe)` for db pointer, reuse `StoreError` from VectorStore.swift. Table lives in the same `relux.db` file.

**Files:**
- Create: `Sources/Relux/Translate/TranslateStore.swift`

**Step 1: Create the store**

```swift
import Foundation
import os
import SQLite3

private let log = Logger(subsystem: "com.relux.app", category: "translatestore")

struct TranslationEntry: Identifiable, Sendable {
    let id: Int64
    let sourceText: String
    let translatedText: String
    let sourceLang: String?
    let targetLang: String
    let model: String
    let createdAt: Date
}

@MainActor
final class TranslateStore {
    private nonisolated(unsafe) var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Relux", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = dir.appendingPathComponent("relux.db").path
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StoreError.cannotOpen
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS translation_history (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                source_text     TEXT NOT NULL,
                translated_text TEXT NOT NULL,
                source_lang     TEXT,
                target_lang     TEXT NOT NULL,
                model           TEXT NOT NULL,
                created_at      REAL NOT NULL
            )
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Insert

    func insert(
        sourceText: String,
        translatedText: String,
        sourceLang: String?,
        targetLang: String,
        model: String
    ) throws -> Int64 {
        let sql = """
            INSERT INTO translation_history
                (source_text, translated_text, source_lang, target_lang, model, created_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sourceText, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, translatedText, -1, Self.transient)
        if let sourceLang {
            sqlite3_bind_text(stmt, 3, sourceLang, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, targetLang, -1, Self.transient)
        sqlite3_bind_text(stmt, 5, model, -1, Self.transient)
        sqlite3_bind_double(stmt, 6, Date().timeIntervalSince1970)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update

    func updateTranslation(id: Int64, translatedText: String) throws {
        let sql = "UPDATE translation_history SET translated_text = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, translatedText, -1, Self.transient)
        sqlite3_bind_int64(stmt, 2, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    // MARK: - Query

    func fetchAll(limit: Int = 500) -> [TranslationEntry] {
        let sql = "SELECT id, source_text, translated_text, source_lang, target_lang, model, created_at FROM translation_history ORDER BY created_at DESC LIMIT ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var entries: [TranslationEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(readRow(stmt))
        }
        return entries
    }

    // MARK: - Delete

    func delete(id: Int64) throws {
        let sql = "DELETE FROM translation_history WHERE id = ?"
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
        try execute("DELETE FROM translation_history")
    }

    // MARK: - Private

    private func readRow(_ stmt: OpaquePointer?) -> TranslationEntry {
        let id = sqlite3_column_int64(stmt, 0)
        let sourceText = String(cString: sqlite3_column_text(stmt, 1))
        let translatedText = String(cString: sqlite3_column_text(stmt, 2))
        let sourceLang: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL ? nil : String(cString: sqlite3_column_text(stmt, 3))
        let targetLang = String(cString: sqlite3_column_text(stmt, 4))
        let model = String(cString: sqlite3_column_text(stmt, 5))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))

        return TranslationEntry(
            id: id,
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLang: sourceLang,
            targetLang: targetLang,
            model: model,
            createdAt: createdAt
        )
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

**Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 3: Commit**

```
git add Sources/Relux/Translate/TranslateStore.swift
git commit -m "feat: add TranslateStore for translation history persistence"
```

---

### Task 3: AnthropicService — Streaming HTTP Client

**Context:** No SDK dependency. Uses URLSession with `bytes(for:)` async sequence to parse SSE events from the Anthropic Messages API. API key from Keychain. Streams `content_block_delta` events.

**Files:**
- Create: `Sources/Relux/Translate/AnthropicService.swift`

**Step 1: Create Keychain helper and AnthropicService**

```swift
import Foundation
import os
import Security

private let log = Logger(subsystem: "com.relux.app", category: "anthropic")

enum KeychainHelper {
    private static let service = "com.relux.app"

    static func save(key: String, value: String) {
        guard let data = value.data(using: .utf8) else { return }
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
        var add = query
        add[kSecValueData as String] = data
        SecItemAdd(add as CFDictionary, nil)
    }

    static func load(key: String) -> String? {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
            kSecReturnData as String: true,
            kSecMatchLimit as String: kSecMatchLimitOne,
        ]
        var result: AnyObject?
        guard SecItemCopyMatching(query as CFDictionary, &result) == errSecSuccess,
              let data = result as? Data else { return nil }
        return String(data: data, encoding: .utf8)
    }

    static func delete(key: String) {
        let query: [String: Any] = [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: key,
        ]
        SecItemDelete(query as CFDictionary)
    }
}

@MainActor
final class AnthropicService {
    static let defaultModel = "claude-sonnet-4-20250514"

    static let defaultSystemPrompt = """
        You are a translation machine. Translate the user's text into {target_language}. \
        Output ONLY the translated text with no additions whatsoever. \
        No preamble, no explanation, no quotation marks, no markdown, no notes. \
        Preserve original formatting including line breaks and whitespace. \
        If the text is already in {target_language}, output it unchanged.
        """

    private var apiKey: String? {
        KeychainHelper.load(key: "anthropicApiKey")
    }

    var model: String {
        UserDefaults.standard.string(forKey: "translateModel") ?? Self.defaultModel
    }

    var systemPrompt: String {
        UserDefaults.standard.string(forKey: "translateSystemPrompt") ?? Self.defaultSystemPrompt
    }

    /// Streams translated text token-by-token.
    /// Returns an AsyncStream of text deltas.
    func translate(text: String, targetLanguage: String) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task.detached { [weak self] in
                guard let self else {
                    continuation.finish()
                    return
                }
                do {
                    let apiKey = await self.apiKey
                    let model = await self.model
                    let systemPrompt = await self.systemPrompt

                    guard let apiKey, !apiKey.isEmpty else {
                        continuation.yield("[Error: Anthropic API key not set. Configure it in Settings → Translate.]")
                        continuation.finish()
                        return
                    }

                    let resolvedPrompt = systemPrompt.replacingOccurrences(of: "{target_language}", with: targetLanguage)

                    let url = URL(string: "https://api.anthropic.com/v1/messages")!
                    var request = URLRequest(url: url)
                    request.httpMethod = "POST"
                    request.setValue(apiKey, forHTTPHeaderField: "x-api-key")
                    request.setValue("2023-06-01", forHTTPHeaderField: "anthropic-version")
                    request.setValue("application/json", forHTTPHeaderField: "content-type")

                    let body: [String: Any] = [
                        "model": model,
                        "max_tokens": 4096,
                        "stream": true,
                        "system": resolvedPrompt,
                        "messages": [
                            ["role": "user", "content": text],
                        ],
                    ]
                    request.httpBody = try JSONSerialization.data(withJSONObject: body)

                    let (bytes, response) = try await URLSession.shared.bytes(for: request)

                    if let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode != 200 {
                        var errorBody = ""
                        for try await line in bytes.lines {
                            errorBody += line
                        }
                        continuation.yield("[Error \(httpResponse.statusCode): \(errorBody)]")
                        continuation.finish()
                        return
                    }

                    for try await line in bytes.lines {
                        guard line.hasPrefix("data: ") else { continue }
                        let json = String(line.dropFirst(6))
                        if json == "[DONE]" { break }

                        guard let data = json.data(using: .utf8),
                              let event = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                              let type = event["type"] as? String else { continue }

                        if type == "content_block_delta",
                           let delta = event["delta"] as? [String: Any],
                           let text = delta["text"] as? String
                        {
                            continuation.yield(text)
                        }
                    }
                } catch {
                    log.error("Translation failed: \(error.localizedDescription)")
                    continuation.yield("[Error: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
        }
    }
}
```

**Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 3: Commit**

```
git add Sources/Relux/Translate/AnthropicService.swift
git commit -m "feat: add AnthropicService with streaming SSE and Keychain storage"
```

---

### Task 4: Wire TranslateStore and PanelMode into AppState

**Context:** Add `.translate` to `PanelMode`, add `TranslateStore` to AppState init, add `.translate` to `SearchItemKind`, inject translate search item when selection is available.

**Files:**
- Modify: `Sources/Relux/AppState.swift` (PanelMode enum at line 7, AppState class)
- Modify: `Sources/Relux/Extensions/ExtensionProtocol.swift` (SearchItemKind at line 2)

**Step 1: Add `.translate` to PanelMode**

In `Sources/Relux/AppState.swift`, line 7-10, change:

```swift
enum PanelMode: Sendable {
    case search
    case clipboard
}
```

to:

```swift
enum PanelMode: Sendable {
    case search
    case clipboard
    case translate
}
```

**Step 2: Add TranslateStore and AnthropicService to AppState**

In `Sources/Relux/AppState.swift`, after the `clipboardMonitor` property (line 25), add:

```swift
    var translateStore: TranslateStore?
    let anthropicService = AnthropicService()
```

In the `setup()` method (around line 54), after the clipboard monitor setup block (after `monitor.start()` at line 65), add:

```swift
        let transStore = try TranslateStore()
        translateStore = transStore
```

**Step 3: Add `.translate` to SearchItemKind**

In `Sources/Relux/Extensions/ExtensionProtocol.swift`, line 2-7, change:

```swift
enum SearchItemKind: Sendable {
    case note
    case app
    case webSearch
    case script
}
```

to:

```swift
enum SearchItemKind: Sendable {
    case note
    case app
    case webSearch
    case script
    case translate
}
```

**Step 4: Fix kindLabel switch in OverlayView**

In `Sources/Relux/UI/OverlayView.swift`, find the `kindLabel(for:)` function (around line 535) and add the translate case:

```swift
    private func kindLabel(for item: SearchItem) -> String {
        switch item.kind {
        case .note: item.meta["folder"] ?? "Notes"
        case .app: "Application"
        case .webSearch: "Web Search"
        case .script: "Script"
        case .translate: "Translate"
        }
    }
```

**Step 5: Inject "Translate" search item when selection is available**

In `Sources/Relux/UI/OverlayView.swift`, find `performSearch` (around line 505). In the `if trimmed.isEmpty` block, after the web search item is appended (around line 519), add:

```swift
                results.append(SearchItem(
                    id: "translate-selection",
                    title: "Translate",
                    subtitle: preview,
                    icon: "character.book.closed",
                    kind: .translate,
                    meta: ["text": selection]
                ))
```

And in the `else` block (when query is not empty), after the web search item (around line 529), add:

```swift
            if let selection = appState.currentSelection {
                let preview = String(selection.prefix(80))
                results.append(SearchItem(
                    id: "translate-selection",
                    title: "Translate",
                    subtitle: preview,
                    icon: "character.book.closed",
                    kind: .translate,
                    meta: ["text": selection]
                ))
            }
```

**Step 6: Handle translate item selection in openSelectedItem**

In `Sources/Relux/UI/OverlayView.swift`, find `openSelectedItem()` (around line 544). Add a new case before the closing `}` of the switch:

```swift
        case .translate:
            if let text = item.meta["text"] {
                appState.panelMode = .translate
                // TranslateView reads currentSelection on appear
            }
```

**Step 7: Build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 8: Commit**

```
git add Sources/Relux/AppState.swift Sources/Relux/Extensions/ExtensionProtocol.swift Sources/Relux/UI/OverlayView.swift
git commit -m "feat: wire translate into AppState, SearchItemKind, and search results"
```

---

### Task 5: TranslateView — Two-Pane UI with Streaming

**Context:** Two-pane layout modeled on `ClipboardHistoryView`. Left: history list. Right: preview with source + translation + metadata. Top bar: input field + language dropdown. Streaming translation via `AnthropicService`. Actions via Cmd+K overlay.

**Files:**
- Create: `Sources/Relux/UI/TranslateView.swift`

**Step 1: Create TranslateView**

```swift
import SwiftUI

struct TranslateView: View {
    @Environment(AppState.self) private var appState
    @State private var inputText: String = ""
    @State private var entries: [TranslationEntry] = []
    @State private var selectedIndex: Int = 0
    @State private var showActions: Bool = false
    @State private var actionIndex: Int = 0
    @State private var isTranslating: Bool = false
    @State private var streamedText: String = ""
    @State private var streamingTask: Task<Void, Never>?
    @State private var activeEntryId: Int64?
    @FocusState private var isInputFocused: Bool

    private var languages: [String] {
        let stored = UserDefaults.standard.stringArray(forKey: "translateLanguages") ?? ["English"]
        return stored.isEmpty ? ["English"] : stored
    }

    @State private var selectedLanguage: String = ""

    private var selectedEntry: TranslationEntry? {
        guard selectedIndex >= 0, selectedIndex < entries.count else { return nil }
        return entries[selectedIndex]
    }

    private var currentActions: [TranslateAction] {
        guard let entry = selectedEntry else { return [] }
        return [
            TranslateAction(label: "Re-translate", icon: "arrow.clockwise", shortcut: "⌘R") {
                retranslate(entry)
            },
            TranslateAction(label: "Copy to Clipboard", icon: "doc.on.clipboard", shortcut: "⌘⏎") {
                copyTranslation(entry)
            },
            TranslateAction(label: "Delete", icon: "trash", shortcut: "⌫") {
                deleteEntry(entry)
            },
        ]
    }

    var body: some View {
        VStack(spacing: 0) {
            Spacer().frame(height: 6)
            topBar
            Divider()

            if entries.isEmpty && !isTranslating {
                Text("No translation history")
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
            if selectedLanguage.isEmpty {
                selectedLanguage = languages.first ?? "English"
            }
            loadEntries()
            if let selection = appState.currentSelection, !selection.isEmpty {
                inputText = selection
                appState.currentSelection = nil
                translateCurrent()
            }
            isInputFocused = true
        }
        .onKeyPress(.upArrow) {
            if showActions {
                guard !currentActions.isEmpty else { return .ignored }
                actionIndex = actionIndex <= 0 ? currentActions.count - 1 : actionIndex - 1
                return .handled
            }
            guard !entries.isEmpty else { return .ignored }
            selectedIndex = selectedIndex <= 0 ? entries.count - 1 : selectedIndex - 1
            return .handled
        }
        .onKeyPress(.downArrow) {
            if showActions {
                guard !currentActions.isEmpty else { return .ignored }
                actionIndex = actionIndex >= currentActions.count - 1 ? 0 : actionIndex + 1
                return .handled
            }
            guard !entries.isEmpty else { return .ignored }
            selectedIndex = selectedIndex >= entries.count - 1 ? 0 : selectedIndex + 1
            return .handled
        }
        .onKeyPress(.return) {
            if showActions {
                guard actionIndex < currentActions.count else { return .ignored }
                currentActions[actionIndex].action()
                showActions = false
                return .handled
            }
            translateCurrent()
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
            Button("") {
                guard selectedEntry != nil else { return }
                actionIndex = 0
                showActions.toggle()
            }
            .keyboardShortcut("k", modifiers: .command)
            .hidden()

            Button("") {
                guard let entry = selectedEntry else { return }
                copyTranslation(entry)
            }
            .keyboardShortcut(.return, modifiers: .command)
            .hidden()

            Button("") {
                guard let entry = selectedEntry else { return }
                retranslate(entry)
            }
            .keyboardShortcut("r", modifiers: .command)
            .hidden()
        }
    }

    // MARK: - Top Bar

    private var topBar: some View {
        HStack(spacing: 8) {
            Button {
                streamingTask?.cancel()
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
            .focusable(false)

            TextField("Enter text to translate...", text: $inputText)
                .textFieldStyle(.plain)
                .font(.system(size: 16))
                .focused($isInputFocused)

            Picker("", selection: $selectedLanguage) {
                ForEach(languages, id: \.self) { lang in
                    Text(lang).tag(lang)
                }
            }
            .pickerStyle(.menu)
            .frame(width: 130)
            .labelsHidden()
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    // MARK: - List Panel

    private var listPanel: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(spacing: 0) {
                    if isTranslating, let id = activeEntryId {
                        streamingRow(id: id)
                            .id(-1)
                    }

                    ForEach(Array(entries.enumerated()), id: \.element.id) { index, entry in
                        let adjustedIndex = isTranslating ? index + 1 : index
                        entryRow(entry: entry, isSelected: adjustedIndex == selectedIndex)
                            .id(adjustedIndex)
                            .contentShape(Rectangle())
                            .onTapGesture {
                                selectedIndex = adjustedIndex
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

    private func streamingRow(id: Int64) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(inputText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("Translating...")
                        .font(.system(size: 11))
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(selectedIndex == 0 && isTranslating ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(selectedIndex == 0 && isTranslating ? .white : .primary)
    }

    private func entryRow(entry: TranslationEntry, isSelected: Bool) -> some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(entry.sourceText)
                    .font(.system(size: 12, weight: .medium))
                    .lineLimit(1)
                Text(entry.translatedText)
                    .font(.system(size: 11))
                    .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
                    .lineLimit(1)
            }
            Spacer()
            Text(formatTime(entry.createdAt))
                .font(.system(size: 10))
                .foregroundColor(isSelected ? .white.opacity(0.5) : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    // MARK: - Preview Panel

    private var previewPanel: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                if isTranslating && selectedIndex == 0 {
                    // Streaming preview
                    if streamedText.isEmpty {
                        HStack(spacing: 6) {
                            ProgressView()
                                .controlSize(.small)
                            Text("Translating...")
                                .font(.system(size: 13))
                                .foregroundColor(.secondary)
                        }
                    } else {
                        Text(streamedText)
                            .textSelection(.enabled)
                            .font(.system(size: 14))
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    Divider().padding(.vertical, 4)
                    infoRow(label: "Source", content: inputText)
                    infoRow(label: "To", content: selectedLanguage)
                    infoRow(label: "Model", content: appState.anthropicService.model)
                } else if let entry = selectedEntry {
                    Text(entry.translatedText)
                        .textSelection(.enabled)
                        .font(.system(size: 14))
                        .frame(maxWidth: .infinity, alignment: .leading)

                    Divider().padding(.vertical, 4)
                    infoRow(label: "Source", content: entry.sourceText)
                    if let lang = entry.sourceLang {
                        infoRow(label: "From", content: lang)
                    }
                    infoRow(label: "To", content: entry.targetLang)
                    infoRow(label: "Model", content: entry.model)
                    infoRow(label: "Created", content: formatDateTime(entry.createdAt))
                }
            }
            .padding(16)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    private func infoRow(label: String, content: String) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.system(size: 12))
                .foregroundColor(.secondary)
                .frame(width: 60, alignment: .leading)
            Text(content)
                .font(.system(size: 12))
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Bottom Bar

    private var bottomBar: some View {
        HStack(spacing: 16) {
            if showActions {
                keyboardHint(key: "\u{23CE}", label: "Select")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Back")
            } else {
                keyboardHint(key: "\u{23CE}", label: "Translate")
                keyboardHint(key: "\u{2318}K", label: "Actions")
                keyboardHint(key: "\u{2191}\u{2193}", label: "Navigate")
                keyboardHint(key: "esc", label: "Close")
            }
            Spacer()
            if !entries.isEmpty {
                Text("History \(entries.count)")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }
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
        VStack(spacing: 0) {
            if let entry = selectedEntry {
                HStack(spacing: 6) {
                    Image(systemName: "character.book.closed")
                        .font(.system(size: 11))
                    Text(String(entry.sourceText.prefix(40)))
                        .font(.system(size: 12, weight: .medium))
                    Spacer()
                }
                .foregroundColor(.secondary)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                Divider()
            }

            ForEach(Array(currentActions.enumerated()), id: \.offset) { index, action in
                actionRow(action: action, isSelected: index == actionIndex)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        action.action()
                        showActions = false
                    }
            }
        }
        .fixedSize(horizontal: false, vertical: true)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(.ultraThickMaterial)
                .shadow(color: .black.opacity(0.3), radius: 12, y: 4)
        )
        .clipShape(RoundedRectangle(cornerRadius: 8))
        .frame(width: 280)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .bottomTrailing)
        .padding(.trailing, 8)
        .padding(.bottom, 8)
        .transition(.opacity.combined(with: .scale(scale: 0.95, anchor: .bottomTrailing)))
    }

    private func actionRow(action: TranslateAction, isSelected: Bool) -> some View {
        HStack(spacing: 10) {
            Image(systemName: action.icon)
                .foregroundColor(isSelected ? .white.opacity(0.8) : .secondary)
                .font(.system(size: 13))
                .frame(width: 20)
            Text(action.label)
                .font(.system(size: 13))
            Spacer()
            Text(action.shortcut)
                .font(.system(size: 11))
                .foregroundColor(isSelected ? .white.opacity(0.6) : .secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : Color.clear)
                .padding(.horizontal, 4)
        )
        .foregroundColor(isSelected ? .white : .primary)
    }

    // MARK: - Actions

    private func translateCurrent() {
        let text = inputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        streamingTask?.cancel()
        isTranslating = true
        streamedText = ""
        selectedIndex = 0

        let lang = selectedLanguage
        let model = appState.anthropicService.model

        // Insert placeholder entry, update when done
        if let store = appState.translateStore,
           let id = try? store.insert(sourceText: text, translatedText: "", sourceLang: nil, targetLang: lang, model: model)
        {
            activeEntryId = id
        }

        streamingTask = Task { @MainActor in
            var full = ""
            for await chunk in appState.anthropicService.translate(text: text, targetLanguage: lang) {
                full += chunk
                streamedText = full
            }

            // Save completed translation
            if let id = activeEntryId, let store = appState.translateStore {
                try? store.updateTranslation(id: id, translatedText: full)
            }

            isTranslating = false
            activeEntryId = nil
            loadEntries()
        }
    }

    private func retranslate(_ entry: TranslationEntry) {
        showActions = false
        inputText = entry.sourceText
        selectedLanguage = entry.targetLang
        translateCurrent()
    }

    private func copyTranslation(_ entry: TranslationEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.translatedText, forType: .string)
        showActions = false
    }

    private func deleteEntry(_ entry: TranslationEntry) {
        try? appState.translateStore?.delete(id: entry.id)
        loadEntries()
        if selectedIndex >= entries.count {
            selectedIndex = max(0, entries.count - 1)
        }
        showActions = false
    }

    private func loadEntries() {
        entries = appState.translateStore?.fetchAll() ?? []
    }

    private func formatTime(_ date: Date) -> String {
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }

    private func formatDateTime(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .medium
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: - Supporting Types

private struct TranslateAction {
    let label: String
    let icon: String
    let shortcut: String
    let action: () -> Void
}
```

**Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 3: Commit**

```
git add Sources/Relux/UI/TranslateView.swift
git commit -m "feat: add TranslateView with two-pane UI and streaming"
```

---

### Task 6: Route PanelRootView to TranslateView

**Context:** `PanelRootView` in `OverlayView.swift` switches on `panelMode`. Add the `.translate` case.

**Files:**
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Add translate case to PanelRootView**

In `Sources/Relux/UI/OverlayView.swift`, find `PanelRootView` (lines 2-13). Change the switch to:

```swift
struct PanelRootView: View {
    @Environment(AppState.self) private var appState

    var body: some View {
        switch appState.panelMode {
        case .search:
            OverlayView()
        case .clipboard:
            ClipboardHistoryView()
        case .translate:
            TranslateView()
        }
    }
}
```

**Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 3: Commit**

```
git add Sources/Relux/UI/OverlayView.swift
git commit -m "feat: route translate panel mode to TranslateView"
```

---

### Task 7: Translate Settings Tab

**Context:** Add a "Translate" tab to `SettingsView` with API key (Keychain), model name, system prompt, editable language list, and clear history. Follow the existing tab patterns (General, Notes, Scripts, Clipboard).

**Files:**
- Modify: `Sources/Relux/UI/SettingsView.swift`

**Step 1: Add state variables**

At the top of `SettingsView` struct, after the existing `@State` properties, add:

```swift
    @State private var anthropicApiKey: String = ""
    @State private var translateModel: String = AnthropicService.defaultModel
    @State private var translateSystemPrompt: String = AnthropicService.defaultSystemPrompt
    @State private var translateLanguages: [String] = ["English"]
    @State private var newLanguage: String = ""
    @State private var showClearTranslateConfirmation: Bool = false
```

**Step 2: Add the tab to the TabView body**

In the `body` property, find the TabView and add after the clipboard tab:

```swift
            translateTab
                .tabItem { Label("Translate", systemImage: "character.book.closed") }
```

**Step 3: Create the translateTab computed property**

Add before the `// MARK: - Helpers` section:

```swift
    // MARK: - Translate Tab

    private var translateTab: some View {
        Form {
            Section("Anthropic API") {
                SecureField("API Key", text: $anthropicApiKey)
                    .onChange(of: anthropicApiKey) { _, newValue in
                        if newValue.isEmpty {
                            KeychainHelper.delete(key: "anthropicApiKey")
                        } else {
                            KeychainHelper.save(key: "anthropicApiKey", value: newValue)
                        }
                    }

                TextField("Model", text: $translateModel)
                    .onChange(of: translateModel) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "translateModel")
                    }
            }

            Section("System Prompt") {
                TextEditor(text: $translateSystemPrompt)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 80)
                    .onChange(of: translateSystemPrompt) { _, newValue in
                        UserDefaults.standard.set(newValue, forKey: "translateSystemPrompt")
                    }

                Button("Reset to Default") {
                    translateSystemPrompt = AnthropicService.defaultSystemPrompt
                    UserDefaults.standard.removeObject(forKey: "translateSystemPrompt")
                }
                .font(.system(size: 12))
            }

            Section("Languages") {
                List {
                    ForEach(translateLanguages, id: \.self) { lang in
                        HStack {
                            Text(lang)
                            Spacer()
                            if lang == translateLanguages.first {
                                Text("Default")
                                    .font(.system(size: 11))
                                    .foregroundColor(.secondary)
                            }
                        }
                    }
                    .onMove { from, to in
                        translateLanguages.move(fromOffsets: from, toOffset: to)
                        UserDefaults.standard.set(translateLanguages, forKey: "translateLanguages")
                    }
                    .onDelete { offsets in
                        guard translateLanguages.count > 1 else { return }
                        translateLanguages.remove(atOffsets: offsets)
                        UserDefaults.standard.set(translateLanguages, forKey: "translateLanguages")
                    }
                }
                .frame(minHeight: 80)

                HStack {
                    TextField("Add language...", text: $newLanguage)
                        .textFieldStyle(.roundedBorder)
                    Button("Add") {
                        let trimmed = newLanguage.trimmingCharacters(in: .whitespaces)
                        guard !trimmed.isEmpty, !translateLanguages.contains(trimmed) else { return }
                        translateLanguages.append(trimmed)
                        UserDefaults.standard.set(translateLanguages, forKey: "translateLanguages")
                        newLanguage = ""
                    }
                    .disabled(newLanguage.trimmingCharacters(in: .whitespaces).isEmpty)
                }

                Text("Top language is the default for quick translation. Drag to reorder.")
                    .font(.system(size: 11))
                    .foregroundColor(.secondary)
            }

            Section("History") {
                Button("Clear Translation History", role: .destructive) {
                    showClearTranslateConfirmation = true
                }
                .confirmationDialog("Clear all translation history?", isPresented: $showClearTranslateConfirmation) {
                    Button("Clear All", role: .destructive) {
                        try? appState.translateStore?.clearAll()
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            anthropicApiKey = KeychainHelper.load(key: "anthropicApiKey") ?? ""
            translateModel = UserDefaults.standard.string(forKey: "translateModel") ?? AnthropicService.defaultModel
            translateSystemPrompt = UserDefaults.standard.string(forKey: "translateSystemPrompt") ?? AnthropicService.defaultSystemPrompt
            translateLanguages = UserDefaults.standard.stringArray(forKey: "translateLanguages") ?? ["English"]
        }
    }
```

**Step 4: Build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 5: Commit**

```
git add Sources/Relux/UI/SettingsView.swift
git commit -m "feat: add Translate settings tab with API key, model, prompt, languages"
```

---

### Task 8: Register Translate Extension

**Context:** Register in `ExtensionRegistry` so it can be toggled. Wire into `AppState.setup()`.

**Files:**
- Modify: `Sources/Relux/AppState.swift`

**Step 1: Register translate extension**

In `Sources/Relux/AppState.swift`, inside the `setup()` method, before the `let vectorStore` line (line 55), add:

```swift
        extensionRegistry.register(id: "translate", name: "Translate", icon: "character.book.closed", defaultEnabled: true)
```

**Step 2: Build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | tail -3`

**Step 3: Commit**

```
git add Sources/Relux/AppState.swift
git commit -m "feat: register translate extension in ExtensionRegistry"
```

---

### Task 9: Final Integration Build and Smoke Test

**Files:** None new — integration verification only.

**Step 1: Clean build**

Run: `xcodegen generate && xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug clean build 2>&1 | tail -5`

**Step 2: Verify no warnings in new files**

Run: `xcodebuild -project Relux.xcodeproj -scheme Relux -configuration Debug build 2>&1 | grep -i "warning:" | grep -i "translate\|anthropic\|keychain"`

Expected: no output (no warnings in our new files).

**Step 3: Commit any fixups**

If there are build errors or warnings, fix them and commit:

```
git add -u
git commit -m "fix: resolve build issues in translate extension"
```

---

## File Summary

| File | Role |
|------|------|
| `Sources/Relux/Translate/TranslateStore.swift` | SQLite CRUD for translation history |
| `Sources/Relux/Translate/AnthropicService.swift` | Streaming HTTP client + Keychain helper |
| `Sources/Relux/UI/TranslateView.swift` | Two-pane translate UI with streaming |
| `Sources/Relux/AppState.swift` | PanelMode.translate, TranslateStore init, extension registration |
| `Sources/Relux/Extensions/ExtensionProtocol.swift` | SearchItemKind.translate |
| `Sources/Relux/UI/OverlayView.swift` | PanelRootView routing, translate search item injection, openSelectedItem handler |
| `Sources/Relux/UI/SettingsView.swift` | Translate settings tab |
| `Sources/Relux/UI/ClipboardHistoryView.swift` | Focus fix (back button `.focusable(false)`) |
