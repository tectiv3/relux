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

    func reindex() {
        guard let indexer, !isIndexing else { return }
        isIndexing = true
        Task { @MainActor in
            for await progress in indexer.index() {
                indexProgress = progress
            }
            isIndexing = false
        }
    }
}
