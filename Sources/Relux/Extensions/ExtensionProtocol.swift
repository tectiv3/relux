import Foundation

enum SearchItemKind {
    case app
    case webSearch
    case script
    case translate
    case calculator
    case jwt
    case systemSettings
}

struct SearchItem: Identifiable {
    let id: String
    let title: String
    var subtitle: String
    let icon: String
    let kind: SearchItemKind
    var meta: [String: String]
    var isNew: Bool = false
    var score: Double = 0
}
