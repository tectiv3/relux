import Foundation

struct IndexProgress: Sendable {
    let current: Int
    let total: Int
    let currentTitle: String
}

@MainActor
final class Indexer {
    private let extractor = NoteExtractor()
    private let store: VectorStore
    private let mlx: MLXService

    init(store: VectorStore, mlx: MLXService) {
        self.store = store
        self.mlx = mlx
    }

    func index() -> AsyncStream<IndexProgress> {
        AsyncStream { continuation in
            Task { @MainActor in
                do {
                    let notes = try extractor.fetchAllNotes()
                    var indexed = 0

                    for note in notes {
                        if let stored = store.getModifiedDate(noteId: note.id),
                           abs(stored.timeIntervalSince(note.modifiedDate)) < 1.0 {
                            indexed += 1
                            continue
                        }

                        continuation.yield(IndexProgress(
                            current: indexed, total: notes.count, currentTitle: note.title
                        ))

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
                    continuation.yield(IndexProgress(
                        current: notes.count, total: notes.count, currentTitle: "Done"
                    ))
                } catch {
                    print("Indexing error: \(error)")
                }
                continuation.finish()
            }
        }
    }
}
