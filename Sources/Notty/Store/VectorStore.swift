import Foundation
import NottyCore
import SQLite3
import os

private let log = Logger(subsystem: "com.notty.app", category: "vectorstore")

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

enum StoreError: Error {
    case cannotOpen
    case query
    case exec(String)
}

@MainActor
final class VectorStore {
    private var db: OpaquePointer?
    private var cache: [EmbeddingEntry] = []

    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Notty", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)
        let dbPath = dir.appendingPathComponent("notty.db").path

        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StoreError.cannotOpen
        }

        try execute("""
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
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Note Operations

    func upsertNote(
        noteId: String,
        title: String,
        folder: String,
        modifiedDate: Date,
        chunks: [(text: String, embedding: [Float])]
    ) throws {
        try deleteChunks(noteId: noteId)

        let sql = """
            INSERT INTO chunks (note_id, chunk_index, chunk_text, embedding, title, folder, modified_date)
            VALUES (?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        let timestamp = modifiedDate.timeIntervalSinceReferenceDate

        for (index, chunk) in chunks.enumerated() {
            sqlite3_reset(stmt)
            sqlite3_bind_text(stmt, 1, noteId, -1, Self.transient)
            sqlite3_bind_int(stmt, 2, Int32(index))
            sqlite3_bind_text(stmt, 3, chunk.text, -1, Self.transient)

            let embeddingData = chunk.embedding.withUnsafeBufferPointer { Data(buffer: $0) }
            _ = embeddingData.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 4, ptr.baseAddress, Int32(embeddingData.count), Self.transient)
            }

            sqlite3_bind_text(stmt, 5, title, -1, Self.transient)
            sqlite3_bind_text(stmt, 6, folder, -1, Self.transient)
            sqlite3_bind_double(stmt, 7, timestamp)

            guard sqlite3_step(stmt) == SQLITE_DONE else {
                throw StoreError.query
            }
        }
    }

    func getModifiedDate(noteId: String) -> Date? {
        let sql = "SELECT modified_date FROM chunks WHERE note_id = ? LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, noteId, -1, Self.transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        let timestamp = sqlite3_column_double(stmt, 0)
        return Date(timeIntervalSinceReferenceDate: timestamp)
    }

    // MARK: - Search

    func loadEmbeddings() throws {
        let sql = "SELECT note_id, chunk_index, chunk_text, embedding, title, folder FROM chunks"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        var entries: [EmbeddingEntry] = []

        while sqlite3_step(stmt) == SQLITE_ROW {
            let noteId = String(cString: sqlite3_column_text(stmt, 0))
            let chunkIndex = Int(sqlite3_column_int(stmt, 1))
            let chunkText = String(cString: sqlite3_column_text(stmt, 2))

            let blobPtr = sqlite3_column_blob(stmt, 3)
            let blobSize = Int(sqlite3_column_bytes(stmt, 3))
            let floatCount = blobSize / MemoryLayout<Float>.size
            var embedding = [Float](repeating: 0, count: floatCount)
            if let blobPtr {
                memcpy(&embedding, blobPtr, blobSize)
            }

            let title = String(cString: sqlite3_column_text(stmt, 4))
            let folder = String(cString: sqlite3_column_text(stmt, 5))

            entries.append(EmbeddingEntry(
                noteId: noteId,
                chunkIndex: chunkIndex,
                chunkText: chunkText,
                embedding: embedding,
                title: title,
                folder: folder
            ))
        }

        cache = entries
    }

    func search(queryEmbedding: [Float], queryText: String = "", topK: Int = 5, minScore: Float = 0.1) -> [SearchResult] {
        log.info("Search: cache has \(self.cache.count) entries, query embedding dim=\(queryEmbedding.count)")

        let queryTerms = queryText.lowercased().split(separator: " ").map(String.init)
        var scored: [(entry: EmbeddingEntry, score: Float)] = []

        for entry in cache {
            let semantic = cosineSimilarity(queryEmbedding, entry.embedding)
            let keyword = keywordScore(terms: queryTerms, title: entry.title, text: entry.chunkText)

            var score: Float
            if keyword > 0 {
                score = 0.4 * semantic + 0.6 * keyword
            } else {
                score = semantic
            }

            score = applyFolderPenalty(score, folder: entry.folder)
            scored.append((entry, score))
        }

        let topAll = scored.sorted { $0.score > $1.score }.prefix(10)
        for item in topAll {
            log.info("  score=\(item.score) dim=\(item.entry.embedding.count) title=\(item.entry.title) chunk=\(item.entry.chunkIndex)")
        }

        scored = scored.filter { $0.score >= minScore }
        return deduplicateAndRank(scored, topK: topK)
    }

    /// Keyword-only search — no embedding needed, instant results
    func keywordSearch(queryText: String, topK: Int = 5) -> [SearchResult] {
        let queryTerms = queryText.lowercased().split(separator: " ").map(String.init)
        guard !queryTerms.isEmpty else { return [] }

        var scored: [(entry: EmbeddingEntry, score: Float)] = []
        for entry in cache {
            let score = keywordScore(terms: queryTerms, title: entry.title, text: entry.chunkText)
            guard score > 0 else { continue }
            let adjusted = applyFolderPenalty(score, folder: entry.folder)
            scored.append((entry, adjusted))
        }

        return deduplicateAndRank(scored, topK: topK)
    }

    // MARK: - Maintenance

    func clear() throws {
        try execute("DELETE FROM chunks")
        cache = []
    }

    // MARK: - Private

    private func applyFolderPenalty(_ score: Float, folder: String) -> Float {
        let lower = folder.lowercased()
        if lower == "archive" || lower == "recently deleted" {
            return score * 0.5
        }
        return score
    }

    private func deduplicateAndRank(_ scored: [(entry: EmbeddingEntry, score: Float)], topK: Int) -> [SearchResult] {
        var bestByNote: [String: (entry: EmbeddingEntry, score: Float)] = [:]
        for item in scored {
            if let existing = bestByNote[item.entry.noteId] {
                guard item.score > existing.score else { continue }
            }
            bestByNote[item.entry.noteId] = item
        }

        return bestByNote.values
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { item in
                SearchResult(
                    noteId: item.entry.noteId,
                    chunkText: item.entry.chunkText,
                    title: item.entry.title,
                    folder: item.entry.folder,
                    score: item.score
                )
            }
    }

    private func deleteChunks(noteId: String) throws {
        let sql = "DELETE FROM chunks WHERE note_id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_text(stmt, 1, noteId, -1, Self.transient)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    private func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StoreError.exec(msg)
        }
    }

    private func keywordScore(terms: [String], title: String, text: String) -> Float {
        SearchMath.keywordScore(terms: terms, title: title, text: text)
    }

    private func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        SearchMath.cosineSimilarity(a, b)
    }
}
