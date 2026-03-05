import os
import SwiftUI

private let log = Logger(subsystem: "com.notty.app", category: "appstate")

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

    var isReady: Bool {
        mlx.hasLLMModel && store != nil
    }

    var indexProgress: IndexProgress?
    var isIndexing = false
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
        let s = try VectorStore()
        store = s
        let qe = QueryEngine(store: s, mlx: mlx)
        queryEngine = qe
        indexer = Indexer(store: s, mlx: mlx)
        try s.loadEmbeddings()
    }

    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
    }

    var maxSearchResults: Int {
        UserDefaults.standard.object(forKey: "maxSearchResults") as? Int ?? 10
    }

    /// Combined search: notes (keyword) + apps, ranked by frecency
    func performSearch(query: String) -> [SearchItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let limit = maxSearchResults
        let noteResults = queryEngine?.searchOnly(query, topK: limit) ?? []
        let appResults = appSearcher.search(query, limit: limit)
        let scriptResults = scriptSearcher.search(query, limit: limit)

        var merged: [SearchItem] = []
        merged.append(contentsOf: appResults)
        merged.append(contentsOf: scriptResults)
        merged.append(contentsOf: noteResults)

        let q = query
        merged.sort { a, b in
            frecency.boost(query: q, itemId: a.id) > frecency.boost(query: q, itemId: b.id)
        }

        return Array(merged.prefix(limit))
    }

    func recordSelection(query: String, item: SearchItem) {
        frecency.recordSelection(query: query, item: item)
    }

    func recentItems() -> [SearchItem] {
        frecency.recentItems()
    }

    /// Restore previously selected models on launch (deferred — actual loading happens on first use)
    func restoreModels() {
        let models = ModelDiscovery.discoverModels()
        let llmPath = savedLLMPath
        let embedderPath = savedEmbedderPath
        log.info("Restore: discovered \(models.count) models, savedLLM=\(llmPath ?? "nil"), savedEmbedder=\(embedderPath ?? "nil")")

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
