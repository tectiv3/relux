import Foundation

enum SearchItemKind: Sendable {
    case note
    case app
    case webSearch
}

struct SearchItem: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let kind: SearchItemKind
    let meta: [String: String]
}

struct ExtensionResult: Sendable {
    enum Kind: Sendable {
        case token(String)
        case sources([SearchItem])
        case error(String)
        case done
    }

    let kind: Kind
}
