import Foundation
import SQLite3

public struct ChunkEntry: Sendable {
    public let noteId: String
    public let chunkIndex: Int
    public let chunkText: String
    public let embedding: [Float]
    public let title: String
    public let folder: String
}

public struct SearchHit: Sendable {
    public let title: String
    public let folder: String
    public let chunkText: String
    public let score: Float
    public let semanticScore: Float
    public let keywordScore: Float
}

/// Read-only access to the Notty SQLite database, for use by CLI tools.
public final class ReadOnlyStore {
    private var db: OpaquePointer?
    public private(set) var cache: [ChunkEntry] = []

    public init?() {
        let appSupport = FileManager.default.urls(
            for: .applicationSupportDirectory, in: .userDomainMask
        ).first!
        let dbPath = appSupport.appendingPathComponent("Notty/notty.db").path
        guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
            return nil
        }
    }

    deinit {
        sqlite3_close(db)
    }

    public func loadCache() {
        guard let db else { return }
        let sql = "SELECT note_id, chunk_index, chunk_text, embedding, title, folder FROM chunks"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        var entries: [ChunkEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            let noteId = String(cString: sqlite3_column_text(stmt, 0))
            let chunkIndex = Int(sqlite3_column_int(stmt, 1))
            let chunkText = String(cString: sqlite3_column_text(stmt, 2))
            let blobPtr = sqlite3_column_blob(stmt, 3)
            let blobSize = Int(sqlite3_column_bytes(stmt, 3))
            let floatCount = blobSize / MemoryLayout<Float>.size
            var embedding = [Float](repeating: 0, count: floatCount)
            if let blobPtr { memcpy(&embedding, blobPtr, blobSize) }
            let title = String(cString: sqlite3_column_text(stmt, 4))
            let folder = String(cString: sqlite3_column_text(stmt, 5))
            entries.append(ChunkEntry(
                noteId: noteId, chunkIndex: chunkIndex, chunkText: chunkText,
                embedding: embedding, title: title, folder: folder
            ))
        }
        cache = entries
    }

    public func hybridSearch(queryText: String, queryEmbedding: [Float]?, topK: Int = 10) -> [SearchHit] {
        let terms = queryText.lowercased().split(separator: " ").map(String.init)

        var scored: [(entry: ChunkEntry, score: Float, semantic: Float, keyword: Float)] = []
        for entry in cache {
            let semantic: Float = queryEmbedding.map {
                SearchMath.cosineSimilarity($0, entry.embedding)
            } ?? 0
            let kw = SearchMath.keywordScore(terms: terms, title: entry.title, text: entry.chunkText)

            let score: Float = kw > 0 ? 0.4 * semantic + 0.6 * kw : semantic
            scored.append((entry, score, semantic, kw))
        }

        var best: [String: (entry: ChunkEntry, score: Float, semantic: Float, keyword: Float)] = [:]
        for item in scored {
            if let existing = best[item.entry.noteId] {
                guard item.score > existing.score else { continue }
            }
            best[item.entry.noteId] = item
        }

        return best.values
            .sorted { $0.score > $1.score }
            .prefix(topK)
            .map { SearchHit(
                title: $0.entry.title, folder: $0.entry.folder,
                chunkText: String($0.entry.chunkText.prefix(120)),
                score: $0.score, semanticScore: $0.semantic, keywordScore: $0.keyword
            )}
    }
}
