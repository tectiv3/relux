import Foundation

@MainActor
final class QueryEngine {
    private let store: VectorStore
    private let mlx: MLXService

    init(store: VectorStore, mlx: MLXService) {
        self.store = store
        self.mlx = mlx
    }

    func query(_ text: String) -> AsyncStream<ExtensionResult> {
        AsyncStream { continuation in
            Task { @MainActor in
                do {
                    let queryEmbedding = try await mlx.embed([text]).first ?? []
                    guard !queryEmbedding.isEmpty else {
                        continuation.yield(ExtensionResult(kind: .error("Failed to embed query")))
                        continuation.finish()
                        return
                    }

                    let results = store.search(queryEmbedding: queryEmbedding, topK: 5)

                    let sources = results.map {
                        SourceNote(id: $0.noteId, title: $0.title, folder: $0.folder)
                    }
                    continuation.yield(ExtensionResult(kind: .sources(sources)))

                    let context = results.map { "[\($0.title)]\n\($0.chunkText)" }
                        .joined(separator: "\n\n---\n\n")

                    let prompt = """
                    You are a helpful assistant that answers questions based on the user's Apple Notes.
                    Use ONLY the provided note excerpts to answer. Be concise and direct.
                    If the notes don't contain relevant information, say so.

                    --- Notes ---
                    \(context)

                    --- Question ---
                    \(text)
                    """

                    for await token in mlx.generate(prompt: prompt) {
                        continuation.yield(ExtensionResult(kind: .token(token)))
                    }

                    continuation.yield(ExtensionResult(kind: .done))
                } catch {
                    continuation.yield(ExtensionResult(kind: .error(error.localizedDescription)))
                }
                continuation.finish()
            }
        }
    }
}
