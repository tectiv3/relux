# Relux Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Build a pure Swift menu bar app that indexes Apple Notes locally and answers natural language queries via MLX-powered RAG, displayed in a Raycast-style floating overlay.

**Architecture:** Shell (menu bar + floating panel + hotkey) → ExtensionProtocol → NotesExtension (NoteExtractor + VectorStore + QueryEngine) + shared MLXService. All on-device, zero cloud dependencies.

**Tech Stack:** Swift, SwiftUI, AppKit (NSPanel, NSStatusItem, NSVisualEffectView), mlx-swift + mlx-swift-lm, KeyboardShortcuts, sqlite3 C API, NSAppleScript, Accelerate framework.

---

## Task 1: Project Scaffold — Swift Package + Xcode Project

**Files:**
- Create: `Package.swift`
- Create: `Sources/Relux/ReluxApp.swift`
- Create: `Sources/Relux/Info.plist`

**Step 1: Initialize Swift package with Xcode project**

Configure as menu bar app.

`Package.swift` dependencies:
```swift
// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Relux",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/ml-explore/mlx-swift", from: "0.21.0"),
        .package(url: "https://github.com/ml-explore/mlx-swift-lm", from: "0.2.0"),
        .package(url: "https://github.com/sindresorhus/KeyboardShortcuts", from: "2.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "Relux",
            dependencies: [
                .product(name: "MLX", package: "mlx-swift"),
                .product(name: "MLXNN", package: "mlx-swift"),
                .product(name: "MLXRandom", package: "mlx-swift"),
                .product(name: "MLXLLM", package: "mlx-swift-lm"),
                .product(name: "MLXLMCommon", package: "mlx-swift-lm"),
                .product(name: "MLXEmbedders", package: "mlx-swift-lm"),
                "KeyboardShortcuts",
            ]
        ),
    ]
)
```

Note: Since mlx-swift requires Xcode for Metal shader compilation, this project should be built via Xcode (or `xcodebuild`), not `swift build`. The Package.swift defines dependencies but the actual project will use an `.xcodeproj`.

**Step 2: Create minimal app entry point**

```swift
// Sources/Relux/ReluxApp.swift
import SwiftUI

@main
struct ReluxApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        Settings {
            Text("Relux Settings")
        }
    }
}
```

**Step 3: Create AppDelegate stub**

```swift
// Sources/Relux/AppDelegate.swift
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    var statusItem: NSStatusItem?

    func applicationDidFinishLaunching(_ notification: Notification) {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        statusItem?.button?.image = NSImage(systemSymbolName: "note.text", accessibilityDescription: "Relux")

        let menu = NSMenu()
        menu.addItem(NSMenuItem(title: "Re-index Notes", action: #selector(reindex), keyEquivalent: ""))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Settings...", action: #selector(openSettings), keyEquivalent: ","))
        menu.addItem(NSMenuItem.separator())
        menu.addItem(NSMenuItem(title: "Quit Relux", action: #selector(quit), keyEquivalent: "q"))
        statusItem?.menu = menu
    }

    @objc func reindex() {}
    @objc func openSettings() {}
    @objc func quit() { NSApp.terminate(nil) }
}
```

**Step 4: Set Info.plist for menu bar app**

Add `LSUIElement = YES` so the app runs as an agent (menu bar only, no dock icon).

**Step 5: Build and verify**

Run: `xcodebuild build` or build via Xcode.
Expected: App launches, shows menu bar icon with note icon, menu items visible. No dock icon.

**Step 6: Commit**

```
feat: initial project scaffold with menu bar app
```

---

## Task 2: Floating Panel — Raycast-Style Overlay

**Files:**
- Create: `Sources/Relux/UI/FloatingPanel.swift`
- Create: `Sources/Relux/UI/OverlayView.swift`
- Modify: `Sources/Relux/AppDelegate.swift`

**Step 1: Create NSPanel subclass with vibrancy**

```swift
// Sources/Relux/UI/FloatingPanel.swift
import AppKit

final class FloatingPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(
            contentRect: contentRect,
            styleMask: [.nonactivatingPanel, .fullSizeContentView, .titled],
            backing: .buffered,
            defer: false
        )

        isFloatingPanel = true
        level = .floating
        titleVisibility = .hidden
        titlebarAppearsTransparent = true
        isMovableByWindowBackground = true
        hidesOnDeactivate = false
        isOpaque = false
        backgroundColor = .clear
        collectionBehavior = [.canJoinAllSpaces, .fullScreenNone]

        // Vibrancy background (frosted glass like Raycast)
        let visualEffect = NSVisualEffectView(frame: contentRect)
        visualEffect.material = .hudWindow
        visualEffect.state = .active
        visualEffect.blendingMode = .behindWindow
        visualEffect.wantsLayer = true
        visualEffect.layer?.cornerRadius = 12
        visualEffect.layer?.masksToBounds = true
        contentView = visualEffect
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }

    // Dismiss on Esc
    override func cancelOperation(_ sender: Any?) {
        close()
    }

    // Dismiss on click outside
    override func resignKey() {
        super.resignKey()
        close()
    }
}
```

**Step 2: Create SwiftUI overlay content**

```swift
// Sources/Relux/UI/OverlayView.swift
import SwiftUI

struct OverlayView: View {
    @State private var query = ""
    @State private var answer = ""
    @State private var sources: [SourceNote] = []
    @State private var isGenerating = false

    var body: some View {
        VStack(spacing: 0) {
            // Search bar
            HStack {
                Image(systemName: "magnifyingglass")
                    .foregroundColor(.secondary)
                TextField("Ask about your notes...", text: $query)
                    .textFieldStyle(.plain)
                    .font(.title3)
                    .onSubmit { submitQuery() }
            }
            .padding(16)

            if !answer.isEmpty || isGenerating {
                Divider()

                // Answer area
                ScrollView {
                    Text(answer)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(16)
                }
                .frame(maxHeight: 300)

                if !sources.isEmpty {
                    Divider()

                    // Source notes
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Sources")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .padding(.horizontal, 16)
                            .padding(.top, 8)

                        ForEach(sources) { source in
                            HStack {
                                Image(systemName: "note.text")
                                    .foregroundColor(.secondary)
                                Text(source.title)
                                    .lineLimit(1)
                                Spacer()
                                Text(source.folder)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 4)
                        }
                        .padding(.bottom, 8)
                    }
                }
            }

            // Bottom bar
            Divider()
            HStack {
                Spacer()
                Text("⏎ Ask")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("esc Close")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .frame(width: 680)
    }

    private func submitQuery() {
        guard !query.isEmpty else { return }
        isGenerating = true
        answer = ""
        sources = []
        // Will be wired to QueryEngine in Task 8
    }
}

struct SourceNote: Identifiable {
    let id: String
    let title: String
    let folder: String
}
```

**Step 3: Wire panel into AppDelegate**

Add to `AppDelegate`:
```swift
var panel: FloatingPanel?

func setupPanel() {
    let screenFrame = NSScreen.main?.frame ?? .zero
    let panelWidth: CGFloat = 680
    let panelX = (screenFrame.width - panelWidth) / 2
    let panelY = screenFrame.height * 0.65

    panel = FloatingPanel(contentRect: NSRect(x: panelX, y: panelY, width: panelWidth, height: 80))

    let hostingView = NSHostingView(rootView: OverlayView())
    hostingView.translatesAutoresizingMaskIntoConstraints = false

    if let contentView = panel?.contentView {
        contentView.addSubview(hostingView)
        NSLayoutConstraint.activate([
            hostingView.topAnchor.constraint(equalTo: contentView.topAnchor),
            hostingView.bottomAnchor.constraint(equalTo: contentView.bottomAnchor),
            hostingView.leadingAnchor.constraint(equalTo: contentView.leadingAnchor),
            hostingView.trailingAnchor.constraint(equalTo: contentView.trailingAnchor),
        ])
    }
}

func togglePanel() {
    guard let panel else { return }
    if panel.isVisible {
        panel.close()
    } else {
        panel.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
}
```

Call `setupPanel()` from `applicationDidFinishLaunching`.

**Step 4: Build and verify**

Expected: Panel appears centered in upper third of screen with frosted glass background, search field visible, dismisses on Esc and click outside.

**Step 5: Commit**

```
feat: add Raycast-style floating panel with vibrancy
```

---

## Task 3: Global Hotkey

**Files:**
- Modify: `Sources/Relux/AppDelegate.swift`
- Create: `Sources/Relux/HotkeyManager.swift`

**Step 1: Define hotkey name**

```swift
// Sources/Relux/HotkeyManager.swift
import KeyboardShortcuts

extension KeyboardShortcuts.Name {
    static let toggleRelux = Self("toggleRelux", default: .init(.space, modifiers: [.option]))
}
```

**Step 2: Register hotkey listener in AppDelegate**

Add to `applicationDidFinishLaunching`:
```swift
KeyboardShortcuts.onKeyUp(for: .toggleRelux) { [weak self] in
    self?.togglePanel()
}
```

**Step 3: Build and verify**

Expected: Press `⌥+Space` → panel appears. Press again or Esc → panel dismisses.

**Step 4: Commit**

```
feat: add global hotkey (⌥+Space) to toggle overlay
```

---

## Task 4: Extension Protocol

**Files:**
- Create: `Sources/Relux/Extensions/ExtensionProtocol.swift`

**Step 1: Define protocol and result types**

```swift
// Sources/Relux/Extensions/ExtensionProtocol.swift
import Foundation

struct ExtensionResult: Sendable {
    enum Kind: Sendable {
        case token(String)
        case sources([SourceNote])
        case error(String)
        case done
    }
    let kind: Kind
}

protocol ReluxExtension: Sendable {
    var name: String { get }
    func handle(query: String) -> AsyncStream<ExtensionResult>
}
```

**Step 2: Commit**

```
feat: define ReluxExtension protocol
```

---

## Task 5: Note Extractor — AppleScript Bridge

**Files:**
- Create: `Sources/Relux/Notes/NoteExtractor.swift`
- Create: `Sources/Relux/Notes/NoteRecord.swift`

**Step 1: Define NoteRecord model**

```swift
// Sources/Relux/Notes/NoteRecord.swift
import Foundation

struct NoteRecord: Sendable {
    let id: String
    let title: String
    let plainText: String
    let folder: String
    let modifiedDate: Date
}
```

**Step 2: Implement NoteExtractor**

```swift
// Sources/Relux/Notes/NoteExtractor.swift
import AppKit

final class NoteExtractor {
    enum ExtractionError: Error {
        case scriptFailed(String)
        case notesAppUnavailable
    }

    /// Ensures Notes.app is running
    private func ensureNotesRunning() {
        let workspace = NSWorkspace.shared
        let runningApps = workspace.runningApplications
        let notesRunning = runningApps.contains { $0.bundleIdentifier == "com.apple.Notes" }
        if !notesRunning {
            workspace.open(
                URL(fileURLWithPath: "/System/Applications/Notes.app"),
                configuration: .init(),
                completionHandler: nil
            )
            // Brief wait for app to launch
            Thread.sleep(forTimeInterval: 2.0)
        }
    }

    /// Fetches all notes via AppleScript
    func fetchAllNotes() throws -> [NoteRecord] {
        ensureNotesRunning()

        // Get note count first, then fetch each note's properties
        // Using JXA-style AppleScript for structured data extraction
        let script = """
        set output to ""
        tell application "Notes"
            repeat with eachNote in every note
                set noteId to id of eachNote
                set noteTitle to name of eachNote
                set noteBody to body of eachNote
                set noteFolder to name of container of eachNote
                set modDate to modification date of eachNote
                set output to output & "<<<NOTE>>>" & noteId & "<<<SEP>>>" & noteTitle & "<<<SEP>>>" & noteBody & "<<<SEP>>>" & noteFolder & "<<<SEP>>>" & (modDate as string)
            end repeat
        end tell
        return output
        """

        let appleScript = NSAppleScript(source: script)
        var errorDict: NSDictionary?
        guard let result = appleScript?.executeAndReturnError(&errorDict) else {
            let msg = errorDict?.description ?? "Unknown error"
            throw ExtractionError.scriptFailed(msg)
        }

        let raw = result.stringValue ?? ""
        return parseNotes(raw)
    }

    private func parseNotes(_ raw: String) -> [NoteRecord] {
        let noteBlocks = raw.components(separatedBy: "<<<NOTE>>>").filter { !$0.isEmpty }
        return noteBlocks.compactMap { block in
            let parts = block.components(separatedBy: "<<<SEP>>>")
            guard parts.count >= 5 else { return nil }

            let htmlBody = parts[2]
            let plainText = htmlToPlainText(htmlBody)

            return NoteRecord(
                id: parts[0],
                title: parts[1],
                plainText: plainText,
                folder: parts[3],
                modifiedDate: parseDate(parts[4])
            )
        }
    }

    private func htmlToPlainText(_ html: String) -> String {
        guard let data = html.data(using: .utf8),
              let attributed = try? NSAttributedString(
                  data: data,
                  options: [.documentType: NSAttributedString.DocumentType.html],
                  documentAttributes: nil
              ) else { return html }
        return attributed.string
    }

    private func parseDate(_ str: String) -> Date {
        let formatter = DateFormatter()
        formatter.dateStyle = .long
        formatter.timeStyle = .long
        return formatter.date(from: str.trimmingCharacters(in: .whitespaces)) ?? Date()
    }
}
```

**Step 3: Test manually**

Build and add a temporary call in `applicationDidFinishLaunching` to test extraction:
```swift
Task {
    let extractor = NoteExtractor()
    let notes = try extractor.fetchAllNotes()
    print("Extracted \(notes.count) notes")
    for note in notes.prefix(3) {
        print("  \(note.title) — \(note.folder) — \(note.plainText.prefix(100))")
    }
}
```
Expected: Prints note titles from your Notes.app. May see system auth prompt first time.

**Step 4: Remove test code, commit**

```
feat: add NoteExtractor with AppleScript bridge
```

---

## Task 6: Vector Store — SQLite + Cosine Similarity

**Files:**
- Create: `Sources/Relux/Store/VectorStore.swift`
- Create: `Sources/Relux/Store/TextChunker.swift`

**Step 1: Implement TextChunker**

```swift
// Sources/Relux/Store/TextChunker.swift
import Foundation

struct TextChunk: Sendable {
    let index: Int
    let text: String
}

enum TextChunker {
    /// Splits text into chunks of ~maxTokens words, overlapping by overlapTokens, preferring paragraph boundaries.
    static func chunk(_ text: String, maxTokens: Int = 500, overlapTokens: Int = 50) -> [TextChunk] {
        let paragraphs = text.components(separatedBy: "\n\n").filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }

        var chunks: [TextChunk] = []
        var currentChunk = ""
        var currentWordCount = 0
        var index = 0

        for paragraph in paragraphs {
            let words = paragraph.split(separator: " ")
            if currentWordCount + words.count > maxTokens && !currentChunk.isEmpty {
                chunks.append(TextChunk(index: index, text: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)))
                index += 1

                // Overlap: keep last overlapTokens words
                let allWords = currentChunk.split(separator: " ")
                let overlapWords = allWords.suffix(overlapTokens)
                currentChunk = overlapWords.joined(separator: " ") + "\n\n"
                currentWordCount = overlapWords.count
            }
            currentChunk += paragraph + "\n\n"
            currentWordCount += words.count
        }

        if !currentChunk.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            chunks.append(TextChunk(index: index, text: currentChunk.trimmingCharacters(in: .whitespacesAndNewlines)))
        }

        return chunks
    }
}
```

**Step 2: Implement VectorStore**

```swift
// Sources/Relux/Store/VectorStore.swift
import Foundation
import SQLite3
import Accelerate

final class VectorStore {
    private var db: OpaquePointer?
    private var cachedEmbeddings: [EmbeddingEntry] = []

    struct EmbeddingEntry {
        let noteId: String
        let chunkIndex: Int
        let chunkText: String
        let embedding: [Float]
        let title: String
        let folder: String
    }

    struct SearchResult {
        let noteId: String
        let chunkText: String
        let title: String
        let folder: String
        let score: Float
    }

    init() throws {
        let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let reluxDir = appSupport.appendingPathComponent("Relux")
        try FileManager.default.createDirectory(at: reluxDir, withIntermediateDirectories: true)
        let dbPath = reluxDir.appendingPathComponent("relux.db").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StoreError.cannotOpen
        }
        try createTables()
    }

    deinit { sqlite3_close(db) }

    private func createTables() throws {
        let sql = """
        CREATE TABLE IF NOT EXISTS chunks (
            note_id TEXT NOT NULL,
            chunk_index INTEGER NOT NULL,
            chunk_text TEXT NOT NULL,
            embedding BLOB NOT NULL,
            title TEXT NOT NULL,
            folder TEXT NOT NULL,
            modified_date REAL NOT NULL,
            PRIMARY KEY (note_id, chunk_index)
        );
        CREATE TABLE IF NOT EXISTS meta (
            key TEXT PRIMARY KEY,
            value TEXT NOT NULL
        );
        """
        try exec(sql)
    }

    /// Upsert chunks for a note. Deletes old chunks first.
    func upsertNote(noteId: String, title: String, folder: String, modifiedDate: Date, chunks: [(text: String, embedding: [Float])]) throws {
        try exec("DELETE FROM chunks WHERE note_id = '\(noteId)'")

        let sql = "INSERT INTO chunks (note_id, chunk_index, chunk_text, embedding, title, folder, modified_date) VALUES (?, ?, ?, ?, ?, ?, ?)"
        for (i, chunk) in chunks.enumerated() {
            var stmt: OpaquePointer?
            guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { continue }
            defer { sqlite3_finalize(stmt) }

            let embData = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }

            sqlite3_bind_text(stmt, 1, noteId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_int(stmt, 2, Int32(i))
            sqlite3_bind_text(stmt, 3, chunk.text, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_blob(stmt, 4, (embData as NSData).bytes, Int32(embData.count), unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 5, title, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_text(stmt, 6, folder, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
            sqlite3_bind_double(stmt, 7, modifiedDate.timeIntervalSinceReferenceDate)

            sqlite3_step(stmt)
        }
    }

    /// Get stored modified_date for a note (nil if not indexed)
    func getModifiedDate(noteId: String) -> Date? {
        var stmt: OpaquePointer?
        let sql = "SELECT modified_date FROM chunks WHERE note_id = ? LIMIT 1"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, noteId, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let interval = sqlite3_column_double(stmt, 0)
        return Date(timeIntervalSinceReferenceDate: interval)
    }

    /// Load all embeddings into memory for fast search
    func loadEmbeddings() throws {
        var stmt: OpaquePointer?
        let sql = "SELECT note_id, chunk_index, chunk_text, embedding, title, folder FROM chunks"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        cachedEmbeddings.removeAll()
        while sqlite3_step(stmt) == SQLITE_ROW {
            let noteId = String(cString: sqlite3_column_text(stmt, 0))
            let chunkIndex = Int(sqlite3_column_int(stmt, 1))
            let chunkText = String(cString: sqlite3_column_text(stmt, 2))
            let title = String(cString: sqlite3_column_text(stmt, 4))
            let folder = String(cString: sqlite3_column_text(stmt, 5))

            let blobPtr = sqlite3_column_blob(stmt, 3)
            let blobSize = Int(sqlite3_column_bytes(stmt, 3))
            let floatCount = blobSize / MemoryLayout<Float>.size
            var embedding = [Float](repeating: 0, count: floatCount)
            if let ptr = blobPtr {
                memcpy(&embedding, ptr, blobSize)
            }

            cachedEmbeddings.append(EmbeddingEntry(
                noteId: noteId, chunkIndex: chunkIndex, chunkText: chunkText,
                embedding: embedding, title: title, folder: folder
            ))
        }
    }

    /// Cosine similarity search via Accelerate
    func search(queryEmbedding: [Float], topK: Int = 5) -> [SearchResult] {
        guard !cachedEmbeddings.isEmpty else { return [] }

        let dim = queryEmbedding.count
        var queryNorm: Float = 0
        vDSP_svesq(queryEmbedding, 1, &queryNorm, vDSP_Length(dim))
        queryNorm = sqrt(queryNorm)

        var scored: [(index: Int, score: Float)] = []
        for (i, entry) in cachedEmbeddings.enumerated() {
            guard entry.embedding.count == dim else { continue }
            var dot: Float = 0
            vDSP_dotpr(queryEmbedding, 1, entry.embedding, 1, &dot, vDSP_Length(dim))
            var entryNorm: Float = 0
            vDSP_svesq(entry.embedding, 1, &entryNorm, vDSP_Length(dim))
            entryNorm = sqrt(entryNorm)

            let score = (queryNorm * entryNorm) > 0 ? dot / (queryNorm * entryNorm) : 0
            scored.append((i, score))
        }

        scored.sort { $0.score > $1.score }

        // Deduplicate by note_id, keep best chunk per note
        var seen = Set<String>()
        var results: [SearchResult] = []
        for item in scored {
            let entry = cachedEmbeddings[item.index]
            guard !seen.contains(entry.noteId) else { continue }
            seen.insert(entry.noteId)
            results.append(SearchResult(
                noteId: entry.noteId, chunkText: entry.chunkText,
                title: entry.title, folder: entry.folder, score: item.score
            ))
            if results.count >= topK { break }
        }
        return results
    }

    /// Delete all chunks (for re-indexing after model change)
    func clear() throws {
        try exec("DELETE FROM chunks")
        cachedEmbeddings.removeAll()
    }

    // MARK: - Meta

    func setMeta(key: String, value: String) throws {
        try exec("INSERT OR REPLACE INTO meta (key, value) VALUES ('\(key)', '\(value)')")
    }

    func getMeta(key: String) -> String? {
        var stmt: OpaquePointer?
        let sql = "SELECT value FROM meta WHERE key = ?"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, key, -1, unsafeBitCast(-1, to: sqlite3_destructor_type.self))
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return String(cString: sqlite3_column_text(stmt, 0))
    }

    // MARK: - Helpers

    private func exec(_ sql: String) throws {
        guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
            throw StoreError.exec(String(cString: sqlite3_errmsg(db)))
        }
    }

    enum StoreError: Error {
        case cannotOpen
        case query
        case exec(String)
    }
}
```

**Step 3: Build and verify**

Create a quick test: insert fake embeddings, search, verify top-K returns correctly.

**Step 4: Commit**

```
feat: add VectorStore with SQLite storage and BLAS cosine search
```

---

## Task 7: MLX Service — Embeddings + LLM

**Files:**
- Create: `Sources/Relux/MLX/MLXService.swift`
- Create: `Sources/Relux/MLX/ModelDiscovery.swift`

**Step 1: Implement ModelDiscovery**

```swift
// Sources/Relux/MLX/ModelDiscovery.swift
import Foundation

struct LocalModel: Identifiable, Hashable {
    let id: String   // e.g. "mlx-community/Qwen3-8B-4bit"
    let path: URL
    let name: String  // human-readable, derived from directory name
    let sizeBytes: UInt64
}

enum ModelDiscovery {
    static let searchPaths: [String] = [
        "~/.swama/models",
        "~/.cache/huggingface/hub",
        "~/Library/Application Support/Relux/models",
    ]

    static func discoverModels() -> [LocalModel] {
        var models: [LocalModel] = []
        let fm = FileManager.default

        for basePath in searchPaths {
            let expanded = NSString(string: basePath).expandingTildeInPath
            guard let enumerator = fm.enumerator(atPath: expanded) else { continue }

            while let relativePath = enumerator.nextObject() as? String {
                // Look for directories containing config.json (MLX model indicator)
                if relativePath.hasSuffix("config.json") {
                    let configURL = URL(fileURLWithPath: expanded).appendingPathComponent(relativePath)
                    let modelDir = configURL.deletingLastPathComponent()
                    let dirName = modelDir.lastPathComponent

                    // Handle HuggingFace cache structure: models--org--name/snapshots/hash/
                    let modelName: String
                    let modelId: String
                    if modelDir.path.contains("snapshots") {
                        let parts = modelDir.deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
                        modelName = parts.replacingOccurrences(of: "models--", with: "").replacingOccurrences(of: "--", with: "/")
                        modelId = modelName
                    } else {
                        // Direct model directory (swama, etc.)
                        let parent = modelDir.deletingLastPathComponent().lastPathComponent
                        modelName = "\(parent)/\(dirName)"
                        modelId = modelName
                    }

                    let size = directorySize(modelDir)
                    models.append(LocalModel(id: modelId, path: modelDir, name: modelName, sizeBytes: size))
                    enumerator.skipDescendants()
                }
            }
        }

        return models.sorted { $0.name < $1.name }
    }

    private static func directorySize(_ url: URL) -> UInt64 {
        let fm = FileManager.default
        guard let enumerator = fm.enumerator(at: url, includingPropertiesForKeys: [.fileSizeKey]) else { return 0 }
        var total: UInt64 = 0
        for case let fileURL as URL in enumerator {
            if let size = try? fileURL.resourceValues(forKeys: [.fileSizeKey]).fileSize {
                total += UInt64(size)
            }
        }
        return total
    }
}
```

**Step 2: Implement MLXService**

```swift
// Sources/Relux/MLX/MLXService.swift
import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXEmbedders

@MainActor
final class MLXService: ObservableObject {
    @Published var isLLMLoaded = false
    @Published var isEmbedderLoaded = false
    @Published var loadingStatus = ""

    private var llmContainer: ModelContainer?
    private var embedderContainer: EmbeddingModelContainer?

    // MARK: - LLM

    func loadLLM(model: LocalModel) async throws {
        loadingStatus = "Loading \(model.name)..."
        let config = ModelConfiguration(id: model.name, directory: model.path)
        llmContainer = try await LLMModelFactory.shared.loadContainer(configuration: config)
        isLLMLoaded = true
        loadingStatus = ""
    }

    func generate(prompt: String, maxTokens: Int = 1024) -> AsyncStream<String> {
        AsyncStream { continuation in
            Task {
                guard let container = llmContainer else {
                    continuation.finish()
                    return
                }
                do {
                    let input = UserInput(prompt: prompt)
                    let params = GenerateParameters(temperature: 0.7)
                    let output = try await container.perform { context in
                        try context.generate(input: input, parameters: params)
                    }
                    for try await token in output {
                        continuation.yield(token)
                    }
                } catch {
                    continuation.yield("[Error: \(error.localizedDescription)]")
                }
                continuation.finish()
            }
        }
    }

    // MARK: - Embeddings

    func loadEmbedder(model: LocalModel) async throws {
        loadingStatus = "Loading embedder \(model.name)..."
        let config = ModelConfiguration(id: model.name, directory: model.path)
        embedderContainer = try await EmbeddingModelFactory.shared.loadContainer(configuration: config)
        isEmbedderLoaded = true
        loadingStatus = ""
    }

    func embed(_ texts: [String]) async throws -> [[Float]] {
        guard let container = embedderContainer else {
            // Fallback: NaturalLanguage framework
            return texts.map { embedWithNL($0) }
        }
        return try await container.perform { context in
            try context.encode(texts)
        }
    }

    // MARK: - NaturalLanguage fallback

    private func embedWithNL(_ text: String) -> [Float] {
        import NaturalLanguage
        guard let embedding = NLEmbedding.wordEmbedding(for: .english) else {
            return []
        }
        // NL framework provides word-level embeddings; average them for sentence
        let words = text.split(separator: " ").map(String.init)
        var sum = [Double](repeating: 0, count: embedding.dimension)
        var count = 0
        for word in words {
            if let vec = embedding.vector(for: word) {
                for (i, v) in vec.enumerated() { sum[i] += v }
                count += 1
            }
        }
        guard count > 0 else { return [Float](repeating: 0, count: embedding.dimension) }
        return sum.map { Float($0 / Double(count)) }
    }
}
```

**Important note:** The exact API for `MLXEmbedders` and `LLMModelFactory` may need adjustment based on the actual mlx-swift-lm version at build time. The container pattern (`loadContainer` → `perform`) is the established pattern. Check the mlx-swift-lm repo for current signatures during implementation.

**Step 3: Build and verify**

Test model discovery prints your local models. Test loading a small model.

**Step 4: Commit**

```
feat: add MLXService with model discovery, embedding, and LLM generation
```

---

## Task 8: Query Engine + Indexer — RAG Orchestration

**Files:**
- Create: `Sources/Relux/Engine/QueryEngine.swift`
- Create: `Sources/Relux/Engine/Indexer.swift`

**Step 1: Implement Indexer**

```swift
// Sources/Relux/Engine/Indexer.swift
import Foundation

final class Indexer {
    private let extractor = NoteExtractor()
    private let store: VectorStore
    private let mlx: MLXService

    init(store: VectorStore, mlx: MLXService) {
        self.store = store
        self.mlx = mlx
    }

    struct IndexProgress: Sendable {
        let current: Int
        let total: Int
        let currentTitle: String
    }

    func index() -> AsyncStream<IndexProgress> {
        AsyncStream { continuation in
            Task {
                do {
                    let notes = try extractor.fetchAllNotes()
                    var indexed = 0

                    for note in notes {
                        // Skip unchanged notes
                        if let stored = store.getModifiedDate(noteId: note.id),
                           abs(stored.timeIntervalSince(note.modifiedDate)) < 1.0 {
                            indexed += 1
                            continue
                        }

                        continuation.yield(IndexProgress(current: indexed, total: notes.count, currentTitle: note.title))

                        let textChunks = TextChunker.chunk(note.plainText)
                        guard !textChunks.isEmpty else {
                            indexed += 1
                            continue
                        }

                        let embeddings = try await mlx.embed(textChunks.map(\.text))
                        let pairs = zip(textChunks, embeddings).map { ($0.text, $1) }

                        try store.upsertNote(
                            noteId: note.id,
                            title: note.title,
                            folder: note.folder,
                            modifiedDate: note.modifiedDate,
                            chunks: pairs
                        )
                        indexed += 1
                    }

                    try store.loadEmbeddings()
                    continuation.yield(IndexProgress(current: notes.count, total: notes.count, currentTitle: "Done"))
                } catch {
                    // Log error
                    print("Indexing error: \(error)")
                }
                continuation.finish()
            }
        }
    }
}
```

**Step 2: Implement QueryEngine**

```swift
// Sources/Relux/Engine/QueryEngine.swift
import Foundation

final class QueryEngine {
    private let store: VectorStore
    private let mlx: MLXService

    init(store: VectorStore, mlx: MLXService) {
        self.store = store
        self.mlx = mlx
    }

    func query(_ text: String) -> AsyncStream<ExtensionResult> {
        AsyncStream { continuation in
            Task {
                do {
                    // 1. Embed query
                    let queryEmbedding = try await mlx.embed([text]).first ?? []
                    guard !queryEmbedding.isEmpty else {
                        continuation.yield(ExtensionResult(kind: .error("Failed to embed query")))
                        continuation.finish()
                        return
                    }

                    // 2. Retrieve top-K
                    let results = store.search(queryEmbedding: queryEmbedding, topK: 5)

                    // 3. Send sources immediately
                    let sources = results.map { SourceNote(id: $0.noteId, title: $0.title, folder: $0.folder) }
                    continuation.yield(ExtensionResult(kind: .sources(sources)))

                    // 4. Build prompt
                    let context = results.map { "[\($0.title)]\n\($0.chunkText)" }.joined(separator: "\n\n---\n\n")
                    let prompt = """
                    You are a helpful assistant that answers questions based on the user's Apple Notes.
                    Use ONLY the provided note excerpts to answer. Be concise and direct.
                    If the notes don't contain relevant information, say so.

                    --- Notes ---
                    \(context)

                    --- Question ---
                    \(text)
                    """

                    // 5. Stream LLM response
                    for await token in mlx.generate(prompt: prompt) {
                        continuation.yield(ExtensionResult(kind: .token(token)))
                    }

                    continuation.yield(ExtensionResult(kind: .done))
                } catch {
                    continuation.yield(ExtensionResult(kind: .error(error.localizedDescription)))
                }
                continuation.finish()
            }
        }
    }
}
```

**Step 3: Commit**

```
feat: add Indexer and QueryEngine for RAG pipeline
```

---

## Task 9: NotesExtension — Wire It Together

**Files:**
- Create: `Sources/Relux/Extensions/NotesExtension.swift`

**Step 1: Implement NotesExtension conforming to protocol**

```swift
// Sources/Relux/Extensions/NotesExtension.swift
import Foundation

final class NotesExtension: ReluxExtension {
    let name = "Notes"
    private let engine: QueryEngine

    init(engine: QueryEngine) {
        self.engine = engine
    }

    func handle(query: String) -> AsyncStream<ExtensionResult> {
        engine.query(query)
    }
}
```

**Step 2: Commit**

```
feat: add NotesExtension conforming to ExtensionProtocol
```

---

## Task 10: Wire UI to Engine — Complete the Loop

**Files:**
- Modify: `Sources/Relux/AppDelegate.swift`
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: Create shared app state**

```swift
// Sources/Relux/AppState.swift
import SwiftUI

@MainActor
@Observable
final class AppState {
    let mlx = MLXService()
    var store: VectorStore?
    var indexer: Indexer?
    var queryEngine: QueryEngine?
    var notesExtension: NotesExtension?

    var isReady: Bool { mlx.isLLMLoaded && store != nil }
    var indexProgress: Indexer.IndexProgress?
    var isIndexing = false

    func setup() throws {
        store = try VectorStore()
        indexer = Indexer(store: store!, mlx: mlx)
        queryEngine = QueryEngine(store: store!, mlx: mlx)
        notesExtension = NotesExtension(engine: queryEngine!)
        try store!.loadEmbeddings()
    }

    func reindex() {
        guard let indexer, !isIndexing else { return }
        isIndexing = true
        Task {
            for await progress in indexer.index() {
                indexProgress = progress
            }
            isIndexing = false
        }
    }
}
```

**Step 2: Update OverlayView to use AppState**

Wire `submitQuery()` to call `appState.notesExtension?.handle(query:)` and consume the `AsyncStream` to update `answer` and `sources` state.

**Step 3: Update AppDelegate to initialize AppState and pass to views**

Pass `appState` into the overlay view via environment. Trigger `reindex()` from the menu bar item.

**Step 4: Build and test end-to-end**

1. Launch app → menu bar icon appears
2. Open settings → select LLM model
3. Trigger re-index → notes extracted and embedded
4. Press `⌥+Space` → overlay appears
5. Type question → streaming answer with sources

**Step 5: Commit**

```
feat: wire UI to RAG engine, complete end-to-end flow
```

---

## Task 11: Settings Window

**Files:**
- Create: `Sources/Relux/UI/SettingsView.swift`
- Modify: `Sources/Relux/ReluxApp.swift`

**Step 1: Implement SettingsView**

```swift
// Sources/Relux/UI/SettingsView.swift
import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Environment(AppState.self) var appState
    @State private var discoveredModels: [LocalModel] = []
    @State private var selectedLLM: LocalModel?
    @State private var selectedEmbedder: LocalModel?

    var body: some View {
        TabView {
            // Models tab
            Form {
                Section("LLM Model") {
                    Picker("Model", selection: $selectedLLM) {
                        Text("None").tag(nil as LocalModel?)
                        ForEach(discoveredModels) { model in
                            Text("\(model.name) (\(formatSize(model.sizeBytes)))")
                                .tag(model as LocalModel?)
                        }
                    }
                    .onChange(of: selectedLLM) { _, model in
                        guard let model else { return }
                        Task { try? await appState.mlx.loadLLM(model: model) }
                    }

                    if !appState.mlx.loadingStatus.isEmpty {
                        Text(appState.mlx.loadingStatus)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }

                Section("Index") {
                    Button("Re-index Notes") { appState.reindex() }
                        .disabled(appState.isIndexing)
                    if appState.isIndexing, let p = appState.indexProgress {
                        ProgressView(value: Double(p.current), total: Double(p.total))
                        Text("Indexing: \(p.currentTitle)")
                            .font(.caption)
                    }
                }
            }
            .tabItem { Label("Models", systemImage: "cpu") }

            // Hotkey tab
            Form {
                KeyboardShortcuts.Recorder("Toggle Relux:", name: .toggleRelux)
            }
            .tabItem { Label("Shortcuts", systemImage: "keyboard") }
        }
        .frame(width: 450, height: 300)
        .onAppear {
            discoveredModels = ModelDiscovery.discoverModels()
        }
    }

    private func formatSize(_ bytes: UInt64) -> String {
        let gb = Double(bytes) / 1_073_741_824
        return String(format: "%.1f GB", gb)
    }
}
```

**Step 2: Wire into ReluxApp scene**

```swift
Settings {
    SettingsView()
        .environment(appState)
}
```

**Step 3: Build and verify**

Expected: Settings window shows discovered models from `~/.swama/models/`, `~/.cache/huggingface/hub/`, etc. Hotkey is customizable.

**Step 4: Commit**

```
feat: add settings window with model picker and hotkey config
```

---

## Task 12: Polish + First Run Experience

**Files:**
- Modify: `Sources/Relux/AppDelegate.swift`
- Modify: `Sources/Relux/UI/OverlayView.swift`

**Step 1: First launch behavior**

If no LLM model is configured, open settings window automatically on first launch instead of requiring the user to find it in the menu.

**Step 2: Loading states in overlay**

Show "Indexing notes..." if index is in progress when user opens overlay. Show "Loading model..." if LLM not loaded yet. Show "No notes indexed" if vector store is empty.

**Step 3: Persist model selection**

Save selected LLM/embedder model ID to `UserDefaults`. Reload on next launch.

**Step 4: App icon**

Add a simple SF Symbol-based template image for the menu bar icon (already done with `note.text`). Add a basic app icon to Assets.

**Step 5: Build, test full flow end-to-end**

**Step 6: Commit**

```
feat: add first-run experience, loading states, persist settings
```

---

## Dependency Summary

| Package | URL | Products Used |
|---------|-----|---------------|
| mlx-swift | `https://github.com/ml-explore/mlx-swift` | MLX, MLXNN, MLXRandom |
| mlx-swift-lm | `https://github.com/ml-explore/mlx-swift-lm` | MLXLLM, MLXLMCommon, MLXEmbedders |
| KeyboardShortcuts | `https://github.com/sindresorhus/KeyboardShortcuts` | KeyboardShortcuts |

## File Structure

```
Sources/Relux/
├── ReluxApp.swift
├── AppDelegate.swift
├── AppState.swift
├── HotkeyManager.swift
├── UI/
│   ├── FloatingPanel.swift
│   ├── OverlayView.swift
│   └── SettingsView.swift
├── Extensions/
│   ├── ExtensionProtocol.swift
│   └── NotesExtension.swift
├── Notes/
│   ├── NoteExtractor.swift
│   └── NoteRecord.swift
├── Store/
│   ├── VectorStore.swift
│   └── TextChunker.swift
├── Engine/
│   ├── QueryEngine.swift
│   └── Indexer.swift
└── MLX/
    ├── MLXService.swift
    └── ModelDiscovery.swift
```
