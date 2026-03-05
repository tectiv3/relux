import Accelerate
import Foundation
import SQLite3

// MARK: - Minimal VectorStore (standalone, no app dependencies)

private let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

struct CachedEntry {
    let noteId: String
    let chunkIndex: Int
    let chunkText: String
    let embedding: [Float]
    let title: String
    let folder: String
}

struct Hit {
    let title: String
    let folder: String
    let chunkText: String
    let score: Float
    let semanticScore: Float
    let keywordScore: Float
}

func openDB() -> OpaquePointer? {
    let appSupport = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
    let dbPath = appSupport.appendingPathComponent("Notty/notty.db").path
    var db: OpaquePointer?
    guard sqlite3_open_v2(dbPath, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else {
        print("ERROR: Cannot open DB at \(dbPath)")
        return nil
    }
    print("Opened DB: \(dbPath)")
    return db
}

func loadCache(db: OpaquePointer) -> [CachedEntry] {
    let sql = "SELECT note_id, chunk_index, chunk_text, embedding, title, folder FROM chunks"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
        print("ERROR: Failed to prepare SELECT"); return []
    }
    defer { sqlite3_finalize(stmt) }

    var entries: [CachedEntry] = []
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
        entries.append(CachedEntry(
            noteId: noteId, chunkIndex: chunkIndex, chunkText: chunkText,
            embedding: embedding, title: title, folder: folder
        ))
    }
    return entries
}

func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
    guard a.count == b.count, !a.isEmpty else { return 0 }
    var dot: Float = 0, normA: Float = 0, normB: Float = 0
    let n = vDSP_Length(a.count)
    vDSP_dotpr(a, 1, b, 1, &dot, n)
    vDSP_svesq(a, 1, &normA, n)
    vDSP_svesq(b, 1, &normB, n)
    let denom = sqrt(normA) * sqrt(normB)
    guard denom > 0 else { return 0 }
    return dot / denom
}

func keywordScore(terms: [String], title: String, text: String) -> Float {
    guard !terms.isEmpty else { return 0 }
    let lowerTitle = title.lowercased()
    let lowerText = text.lowercased()
    var matched: Float = 0
    for term in terms {
        if lowerTitle.contains(term) {
            matched += 1.5
        } else if lowerText.contains(term) {
            matched += 1.0
        }
    }
    return min(matched / Float(terms.count), 1.0)
}

func hybridSearch(cache: [CachedEntry], queryText: String, queryEmbedding: [Float]?, topK: Int = 10) -> [Hit] {
    let terms = queryText.lowercased().split(separator: " ").map(String.init)

    var scored: [(entry: CachedEntry, score: Float, semantic: Float, keyword: Float)] = []
    for entry in cache {
        let semantic: Float = queryEmbedding.map { cosineSimilarity($0, entry.embedding) } ?? 0
        let kw = keywordScore(terms: terms, title: entry.title, text: entry.chunkText)

        let score: Float
        if kw > 0 {
            score = 0.4 * semantic + 0.6 * kw
        } else {
            score = semantic
        }
        scored.append((entry, score, semantic, kw))
    }

    // Deduplicate by noteId
    var best: [String: (entry: CachedEntry, score: Float, semantic: Float, keyword: Float)] = [:]
    for item in scored {
        if best[item.entry.noteId] == nil || item.score > best[item.entry.noteId]!.score {
            best[item.entry.noteId] = item
        }
    }

    return best.values
        .sorted { $0.score > $1.score }
        .prefix(topK)
        .map { Hit(title: $0.entry.title, folder: $0.entry.folder,
                    chunkText: String($0.entry.chunkText.prefix(120)),
                    score: $0.score, semanticScore: $0.semantic, keywordScore: $0.keyword) }
}

// MARK: - Main

guard let db = openDB() else { exit(1) }
defer { sqlite3_close(db) }

let cache = loadCache(db: db)
print("Loaded \(cache.count) chunks from DB")
if let first = cache.first {
    print("Embedding dim: \(first.embedding.count)")
}

let args = CommandLine.arguments
let query = args.count > 1 ? args[1...].joined(separator: " ") : "todo"

print("\n=== Keyword-only search for: \"\(query)\" ===\n")
let kwResults = hybridSearch(cache: cache, queryText: query, queryEmbedding: nil, topK: 10)
for (i, hit) in kwResults.enumerated() {
    let snippet = hit.chunkText.replacingOccurrences(of: "\n", with: " ")
    print("  \(i+1). [\(String(format: "%.3f", hit.score))] kw=\(String(format: "%.2f", hit.keywordScore)) \"\(hit.title)\" (\(hit.folder))")
    print("     \(snippet)")
}
if kwResults.isEmpty { print("  (no keyword matches)") }

// For hybrid search we need a query embedding — use the first chunk's embedding as a dummy
// to at least test the scoring logic. Real embedding requires MLX.
print("\n=== Hybrid search (semantic from DB + keyword) for: \"\(query)\" ===\n")

// Find a chunk whose text contains the query to use as a pseudo query embedding
let pseudoEmbedding = cache.first { $0.chunkText.lowercased().contains(query.lowercased()) }?.embedding
    ?? cache.first?.embedding

if let emb = pseudoEmbedding {
    let hybridResults = hybridSearch(cache: cache, queryText: query, queryEmbedding: emb, topK: 10)
    for (i, hit) in hybridResults.enumerated() {
        let snippet = hit.chunkText.replacingOccurrences(of: "\n", with: " ")
        print("  \(i+1). [\(String(format: "%.3f", hit.score))] sem=\(String(format: "%.3f", hit.semanticScore)) kw=\(String(format: "%.2f", hit.keywordScore)) \"\(hit.title)\" (\(hit.folder))")
        print("     \(snippet)")
    }
} else {
    print("  (no embeddings in DB)")
}

// Stats
print("\n=== DB Stats ===")
let uniqueNotes = Set(cache.map(\.noteId)).count
let dims = Set(cache.map { $0.embedding.count })
print("  Chunks: \(cache.count)")
print("  Unique notes: \(uniqueNotes)")
print("  Embedding dims: \(dims)")

// Sanity check: verify embeddings aren't all zeros or identical
if cache.count >= 2 {
    let sim = cosineSimilarity(cache[0].embedding, cache[1].embedding)
    let isZero = cache[0].embedding.allSatisfy { $0 == 0 }
    print("  First embedding all-zeros: \(isZero)")
    print("  Similarity between first two chunks: \(String(format: "%.4f", sim))")

    // Check overall similarity distribution
    var sims: [Float] = []
    let sampleCount = min(50, cache.count)
    for i in 0..<sampleCount {
        for j in (i+1)..<min(i+5, sampleCount) {
            sims.append(cosineSimilarity(cache[i].embedding, cache[j].embedding))
        }
    }
    sims.sort()
    if !sims.isEmpty {
        print("  Pairwise similarity (sample): min=\(String(format: "%.3f", sims.first!)) median=\(String(format: "%.3f", sims[sims.count/2])) max=\(String(format: "%.3f", sims.last!))")
    }
}
