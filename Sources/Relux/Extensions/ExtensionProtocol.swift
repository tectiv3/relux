import Foundation

enum SearchItemKind: Sendable {
    case app
    case webSearch
    case script
    case translate
    case calculator
    case jwt
    case systemSettings
}

struct SearchItem: Identifiable, Sendable {
    let id: String
    let title: String
    let subtitle: String
    let icon: String
    let kind: SearchItemKind
    let meta: [String: String]
    var isNew: Bool = false
}
