import Foundation

@MainActor
final class NotesExtension: NottyExtension {
    nonisolated let name = "Notes"
    private let engine: QueryEngine

    init(engine: QueryEngine) {
        self.engine = engine
    }

    func handle(query: String) async -> AsyncStream<ExtensionResult> {
        engine.query(query)
    }
}
