import SwiftUI
import os

private let log = Logger(subsystem: "com.notty.app", category: "appstate")

@MainActor
@Observable
final class AppState {
    let mlx = MLXService()
    var store: VectorStore?
    var indexer: Indexer?
    var queryEngine: QueryEngine?
    var notesExtension: NotesExtension?
    let appSearcher = AppSearcher()
    let frecency = FrecencyTracker()

    var isReady: Bool { mlx.isLLMLoaded && store != nil }
    var indexProgress: IndexProgress?
    var isIndexing = false
    var needsFirstRun: Bool { !UserDefaults.standard.bool(forKey: "hasCompletedSetup") }

    // Persisted model selections
    var savedLLMPath: String? {
        get { UserDefaults.standard.string(forKey: "selectedLLMPath") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedLLMPath") }
    }
    var savedEmbedderPath: String? {
        get { UserDefaults.standard.string(forKey: "selectedEmbedderPath") }
        set { UserDefaults.standard.set(newValue, forKey: "selectedEmbedderPath") }
    }

    func setup() throws {
        store = try VectorStore()
        indexer = Indexer(store: store!, mlx: mlx)
        queryEngine = QueryEngine(store: store!, mlx: mlx)
        notesExtension = NotesExtension(engine: queryEngine!)
        try store!.loadEmbeddings()
    }

    func markSetupComplete() {
        UserDefaults.standard.set(true, forKey: "hasCompletedSetup")
    }

    /// Combined search: notes (keyword) + apps, ranked by frecency
    func performSearch(query: String) -> [SearchItem] {
        guard !query.trimmingCharacters(in: .whitespaces).isEmpty else { return [] }

        let noteResults = queryEngine?.searchOnly(query) ?? []
        let appResults = appSearcher.search(query)

        var merged: [SearchItem] = []
        merged.append(contentsOf: appResults)
        merged.append(contentsOf: noteResults)

        // Re-sort by frecency boost
        let q = query
        merged.sort { a, b in
            frecency.boost(query: q, itemId: a.id) > frecency.boost(query: q, itemId: b.id)
        }

        return merged
    }

    func recordSelection(query: String, item: SearchItem) {
        frecency.recordSelection(query: query, item: item)
    }

    func recentItems() -> [SearchItem] {
        frecency.recentItems()
    }

    /// Restore previously selected models on launch
    func restoreModels() async {
        let models = ModelDiscovery.discoverModels()
        log.info("Restore: discovered \(models.count) models, savedLLM=\(self.savedLLMPath ?? "nil"), savedEmbedder=\(self.savedEmbedderPath ?? "nil")")

        if let llmPath = savedLLMPath {
            let standardized = URL(fileURLWithPath: llmPath).standardizedFileURL.path
            if let model = models.first(where: { $0.path.standardizedFileURL.path == standardized }) {
                do {
                    try await mlx.loadLLM(model: model)
                    log.info("Restored LLM: \(model.name)")
                } catch {
                    log.error("Failed to restore LLM: \(error.localizedDescription)")
                }
            } else {
                log.warning("LLM path not found in discovered models: \(llmPath)")
                for m in models {
                    log.debug("  discovered: \(m.path.path)")
                }
            }
        }

        if let embedderPath = savedEmbedderPath {
            let standardized = URL(fileURLWithPath: embedderPath).standardizedFileURL.path
            if let model = models.first(where: { $0.path.standardizedFileURL.path == standardized }) {
                do {
                    try await mlx.loadEmbedder(model: model)
                    log.info("Restored embedder: \(model.name)")
                } catch {
                    log.error("Failed to restore embedder: \(error.localizedDescription)")
                }
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
