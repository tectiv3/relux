import AppKit
import os
import SwiftUI

private let log = Logger(subsystem: "com.relux.app", category: "appstate")

enum PanelMode: Sendable {
    case search
    case clipboard
}

@MainActor
@Observable
final class AppState {
    let mlx = MLXService()
    var store: VectorStore?
    var indexer: Indexer?
    var queryEngine: QueryEngine?
    let appSearcher = AppSearcher()
    let scriptSearcher = ScriptSearcher()
    let frecency = FrecencyTracker()
    let extensionRegistry = ExtensionRegistry()

    var clipboardStore: ClipboardStore?
    var clipboardMonitor: ClipboardMonitor?
    var panelMode: PanelMode = .search
    var previousApp: NSRunningApplication?

    var isReady: Bool {
        if extensionRegistry.isEnabled("notes") {
            return mlx.hasLLMModel && store != nil
        }
        return store != nil
    }

    var indexProgress: IndexProgress?
    var isIndexing = false
    var currentSelection: String?
    var needsFirstRun: Bool {
        !UserDefaults.standard.bool(forKey: "hasCompletedSetup")
    }

    /// Persisted model selections
    var savedLLMPath: String? {
        get { UserDefaults.standard.string(forKey: "selectedLLMPath") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLLMPath") }
    }

    var savedEmbedderPath: String? {
        get { UserDefaults.standard.string(forKey: "selectedEmbedderPath") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedEmbedderPath") }
    }

    func setup() throws {
        let vectorStore = try VectorStore()
        store = vectorStore
        queryEngine = QueryEngine(store: vectorStore, mlx: mlx)
        indexer = Indexer(store: vectorStore, mlx: mlx)
        try vectorStore.loadEmbeddings()

        let clipStore = try ClipboardStore()
        clipboardStore = clipStore
        let monitor = ClipboardMonitor(store: clipStore)
        clipboardMonitor = monitor
        monitor.start()

        // Clean up expired clipboard entries
        let retentionMonths = UserDefaults.standard.object(forKey: "clipboardRetentionMonths") as? Int ?? 3
        if let cutoffDate = Calendar.current.date(byAdding: .month, value: -retentionMonths, to: Date()) {
            try? clipStore.deleteExpired(before: cutoffDate)
        }
    }

    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
    }

    var maxSearchResults: Int {
        UserDefaults.standard.object(forKey: "maxSearchResults") as? Int ?? 10
    }

    /// Combined search: notes (keyword) + apps, grouped by kind, ranked by frecency within each group
    func performSearch(query: String) -> [SearchItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let limit = maxSearchResults
        var noteResults: [SearchItem] = []
        if extensionRegistry.isEnabled("notes") {
            noteResults = queryEngine?.searchOnly(query, topK: limit) ?? []
        }
        var appResults = appSearcher.search(query, limit: limit)
        var scriptResults = scriptSearcher.search(query, limit: limit)

        let term = query
        appResults.sort { frecency.boost(query: term, itemId: $0.id) > frecency.boost(query: term, itemId: $1.id) }
        scriptResults.sort { frecency.boost(query: term, itemId: $0.id) > frecency.boost(query: term, itemId: $1.id) }
        noteResults.sort { frecency.boost(query: term, itemId: $0.id) > frecency.boost(query: term, itemId: $1.id) }

        return Array((appResults + scriptResults + noteResults).prefix(limit))
    }

    func recordSelection(query: String, item: SearchItem) {
        frecency.recordSelection(query: query, item: item)
    }

    func recentItems() -> [SearchItem] {
        frecency.recentItems()
    }

    /// Restore previously selected models on launch (deferred — actual loading happens on first use)
    func restoreModels() {
        guard extensionRegistry.isEnabled("notes") else { return }
        let models = ModelDiscovery.discoverModels()
        let llmPath = savedLLMPath
        let embedderPath = savedEmbedderPath
        let llmDesc = llmPath ?? "nil"
        let embedDesc = embedderPath ?? "nil"
        log.info("Restore: \(models.count) models, LLM=\(llmDesc), embedder=\(embedDesc)")

        if let llmPath {
            if let model = LocalModel.matching(path: llmPath, in: models) {
                mlx.setLLMModel(model)
                log.info("Registered LLM for lazy loading: \(model.name)")
            } else {
                log.warning("LLM path not found in discovered models: \(llmPath)")
            }
        }

        if let embedderPath {
            if let model = LocalModel.matching(path: embedderPath, in: models) {
                mlx.setEmbedderModel(model)
                log.info("Registered embedder for lazy loading: \(model.name)")
            } else {
                log.warning("Embedder path not found in discovered models: \(embedderPath)")
            }
        }
    }

    func setNotesEnabled(_ enabled: Bool) {
        extensionRegistry.setEnabled("notes", enabled: enabled)
        if enabled {
            restoreModels()
        } else {
            mlx.unloadAll()
        }
    }

    func reindex(full: Bool = true) {
        guard let indexer, !isIndexing else { return }
        isIndexing = true
        Task { @MainActor in
            for await progress in indexer.index(full: full) {
                indexProgress = progress
            }
            isIndexing = false
        }
    }
}
