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
    var subtitle: String
    let icon: String
    let kind: SearchItemKind
    var meta: [String: String]
    var isNew: Bool = false
    var score: Double = 0
}
