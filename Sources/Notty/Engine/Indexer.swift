import Foundation
import os

private let log = Logger(subsystem: "com.notty.app", category: "indexer")

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

    func index(full: Bool = false) -> AsyncStream<IndexProgress> {
        AsyncStream { continuation in
            Task { @MainActor in
                do {
                    log.info("Starting note extraction\(full ? " (full rebuild)" : "")...")
                    let notes = try await extractor.fetchAllNotes()
                    log.info("Extracted \(notes.count) notes from Notes.app")

                    var indexed = 0
                    var skipped = 0

                    for note in notes {
                        if !full,
                           let stored = store.getModifiedDate(noteId: note.id),
                           abs(stored.timeIntervalSince(note.modifiedDate)) < 1.0
                        {
                            skipped += 1
                            indexed += 1
                            continue
                        }

                        continuation.yield(IndexProgress(
                            current: indexed, total: notes.count, currentTitle: note.title
                        ))

                        let textChunks = TextChunker.chunk(note.plainText)
                        if textChunks.isEmpty {
                            log.debug("Skipping empty note: \(note.title)")
                            indexed += 1
                            continue
                        }

                        log.info("Embedding \(note.title) (\(textChunks.count) chunks, folder: \(note.folder))")

                        let embeddings = try await mlx.embed(textChunks.map(\.text))

                        // Check embeddings are valid
                        if embeddings.isEmpty || embeddings.first?.isEmpty == true {
                            log.warning("Empty embeddings for \(note.title) — is an embedder model loaded?")
                            indexed += 1
                            continue
                        }

                        let pairs = zip(textChunks, embeddings).map { ($0.text, $1) }

                        try store.upsertNote(
                            noteId: note.id,
                            title: note.title,
                            folder: note.folder,
                            modifiedDate: note.modifiedDate,
                            chunks: pairs
                        )
                        log.debug("Stored \(pairs.count) chunks for \(note.title)")
                        indexed += 1
                    }

                    try store.loadEmbeddings()
                    log.info("Indexing complete: \(indexed) notes processed, \(skipped) unchanged")

                    continuation.yield(IndexProgress(
                        current: notes.count, total: notes.count, currentTitle: "Done"
                    ))
                } catch {
                    log.error("Indexing error: \(error.localizedDescription)")
                }
                continuation.finish()
            }
        }
    }
}
