import Foundation
import NottyCore

guard let store = ReadOnlyStore() else {
    print("ERROR: Cannot open DB")
    exit(1)
}

store.loadCache()
let cache = store.cache
print("Loaded \(cache.count) chunks from DB")
if let first = cache.first {
    print("Embedding dim: \(first.embedding.count)")
}

let args = CommandLine.arguments
let query = args.count > 1 ? args[1...].joined(separator: " ") : "todo"

print("\n=== Keyword-only search for: \"\(query)\" ===\n")
let kwResults = store.hybridSearch(queryText: query, queryEmbedding: nil, topK: 10)
for (i, hit) in kwResults.enumerated() {
    let snippet = hit.chunkText.replacingOccurrences(of: "\n", with: " ")
    print("  \(i+1). [\(String(format: "%.3f", hit.score))] kw=\(String(format: "%.2f", hit.keywordScore)) \"\(hit.title)\" (\(hit.folder))")
    print("     \(snippet)")
}
if kwResults.isEmpty { print("  (no keyword matches)") }

print("\n=== Hybrid search (semantic from DB + keyword) for: \"\(query)\" ===\n")

let pseudoEmbedding = cache.first { $0.chunkText.lowercased().contains(query.lowercased()) }?.embedding
    ?? cache.first?.embedding

if let emb = pseudoEmbedding {
    let hybridResults = store.hybridSearch(queryText: query, queryEmbedding: emb, topK: 10)
    for (i, hit) in hybridResults.enumerated() {
        let snippet = hit.chunkText.replacingOccurrences(of: "\n", with: " ")
        print("  \(i+1). [\(String(format: "%.3f", hit.score))] sem=\(String(format: "%.3f", hit.semanticScore)) kw=\(String(format: "%.2f", hit.keywordScore)) \"\(hit.title)\" (\(hit.folder))")
        print("     \(snippet)")
    }
} else {
    print("  (no embeddings in DB)")
}

print("\n=== DB Stats ===")
let uniqueNotes = Set(cache.map(\.noteId)).count
let dims = Set(cache.map { $0.embedding.count })
print("  Chunks: \(cache.count)")
print("  Unique notes: \(uniqueNotes)")
print("  Embedding dims: \(dims)")

if cache.count >= 2 {
    let sim = SearchMath.cosineSimilarity(cache[0].embedding, cache[1].embedding)
    let isZero = cache[0].embedding.allSatisfy { $0 == 0 }
    print("  First embedding all-zeros: \(isZero)")
    print("  Similarity between first two chunks: \(String(format: "%.4f", sim))")

    var sims: [Float] = []
    let sampleCount = min(50, cache.count)
    for i in 0..<sampleCount {
        for j in (i+1)..<min(i+5, sampleCount) {
            sims.append(SearchMath.cosineSimilarity(cache[i].embedding, cache[j].embedding))
        }
    }
    sims.sort()
    if !sims.isEmpty {
        print("  Pairwise similarity (sample): min=\(String(format: "%.3f", sims.first!)) median=\(String(format: "%.3f", sims[sims.count/2])) max=\(String(format: "%.3f", sims.last!))")
    }
}
