public enum SearchItemKind: Hashable, Sendable {
    case app
    case webSearch
    case script
    case translate
    case calculator
    case jwt
    case systemSettings
}

public struct SearchItem: Identifiable, Sendable {
    public let id: String
    public let title: String
    public var subtitle: String
    public let icon: String
    public let kind: SearchItemKind
    public var meta: [String: String]
    public var isNew: Bool
    public var score: Double

    public init(
        id: String,
        title: String,
        subtitle: String,
        icon: String,
        kind: SearchItemKind,
        meta: [String: String],
        isNew: Bool = false,
        score: Double = 0
    ) {
        self.id = id
        self.title = title
        self.subtitle = subtitle
        self.icon = icon
        self.kind = kind
        self.meta = meta
        self.isNew = isNew
        self.score = score
    }
}
