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
        Task { @MainActor in
            for await progress in indexer.index() {
                indexProgress = progress
            }
            isIndexing = false
        }
    }
}
