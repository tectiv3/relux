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

        if let llmPath = savedLLMPath,
           let model = models.first(where: { $0.path.path == llmPath }) {
            try? await mlx.loadLLM(model: model)
        }
        if let embedderPath = savedEmbedderPath,
           let model = models.first(where: { $0.path.path == embedderPath }) {
            try? await mlx.loadEmbedder(model: model)
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
