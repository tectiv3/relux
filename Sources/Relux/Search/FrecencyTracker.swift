import Foundation

/// Tracks which search results the user selects, boosting frequently/recently chosen items.
@MainActor
final class FrecencyTracker {
    private struct Entry: Codable {
        var count: Int
        var lastUsed: Date
    }

    /// Stored item data for showing recents
    private struct StoredItem: Codable {
        let id: String
        let title: String
        let subtitle: String
        let icon: String
        let kind: String // "note" or "app"
        let meta: [String: String]
        var lastUsed: Date
    }

    /// key = "query_prefix:item_id"
    private var entries: [String: Entry] = [:]
    /// key = item_id, stores full item info for recents
    private var items: [String: StoredItem] = [:]
    private let storePath: URL
    private let itemsPath: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Relux", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("frecency.json")
        itemsPath = dir.appendingPathComponent("recents.json")
        load()
    }

    /// Record that the user selected this item after typing `query`
    func recordSelection(query: String, item: SearchItem) {
        let key = Self.key(query: query, itemId: item.id)
        var entry = entries[key] ?? Entry(count: 0, lastUsed: .distantPast)
        entry.count += 1
        entry.lastUsed = Date()
        entries[key] = entry

        items[item.id] = StoredItem(
            id: item.id,
            title: item.title,
            subtitle: item.subtitle,
            icon: item.icon,
            kind: {
                switch item.kind {
                case .app: "app"
                case .script: "script"
                case .translate: "translate"
                case .jwt: "jwt"
                case .systemSettings: "systemSettings"
                default: "app"
                }
            }(),
            meta: item.meta,
            lastUsed: Date()
        )

        save()
    }

    /// Returns a boost score (0...) for this item given the current query.
    func boost(query: String, itemId: String) -> Double {
        let key = Self.key(query: query, itemId: itemId)
        guard let entry = entries[key] else { return 0 }
        let recency = max(0, 1.0 - Date().timeIntervalSince(entry.lastUsed) / (30 * 86400))
        return Double(entry.count) * 10.0 + recency * 5.0
    }

    /// Returns recently used items, sorted by most recent first
    func recentItems(limit: Int = 8) -> [SearchItem] {
        let sorted = items.values.sorted { $0.lastUsed > $1.lastUsed }
        return sorted.prefix(limit).map { stored in
            SearchItem(
                id: stored.id,
                title: stored.title,
                subtitle: stored.subtitle,
                icon: stored.icon,
                kind: {
                    switch stored.kind {
                    case "app": .app
                    case "script": .script
                    case "translate": .translate
                    case "jwt": .jwt
                    case "systemSettings": .systemSettings
                    default: .app
                    }
                }(),
                meta: stored.meta
            )
        }
    }

    /// Remove an item from history (both frecency entries and recents)
    func removeItem(id: String) {
        items.removeValue(forKey: id)
        entries = entries.filter { !$0.key.hasSuffix(":\(id)") }
        save()
    }

    private static func key(query: String, itemId: String) -> String {
        let prefix = String(query.lowercased().prefix(4))
        return "\(prefix):\(itemId)"
    }

    private func load() {
        if let data = try? Data(contentsOf: storePath),
           let decoded = try? JSONDecoder().decode([String: Entry].self, from: data)
        {
            entries = decoded
        }
        if let data = try? Data(contentsOf: itemsPath),
           let decoded = try? JSONDecoder().decode([String: StoredItem].self, from: data)
        {
            items = decoded
        }
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            try? data.write(to: storePath, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: itemsPath, options: .atomic)
        }
    }
}
