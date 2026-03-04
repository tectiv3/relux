import Foundation

struct SourceNote: Identifiable, Sendable {
    let id: String
    let title: String
    let folder: String
    let snippet: String
}

struct ExtensionResult: Sendable {
    enum Kind: Sendable {
        case token(String)
        case sources([SourceNote])
        case error(String)
        case done
    }
    let kind: Kind
}

protocol NottyExtension: Sendable {
    var name: String { get }
    func handle(query: String) async -> AsyncStream<ExtensionResult>
}
