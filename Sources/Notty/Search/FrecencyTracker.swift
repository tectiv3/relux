import Foundation

/// Tracks which search results the user selects, boosting frequently/recently chosen items.
@MainActor
final class FrecencyTracker {
    private struct Entry: Codable {
        var count: Int
        var lastUsed: Date
    }

    /// key = "query_prefix:item_id"
    private var entries: [String: Entry] = [:]
    private let storePath: URL

    init() {
        let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = support.appendingPathComponent("Notty", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent("frecency.json")
        load()
    }

    /// Record that the user selected `itemId` after typing `query`
    func recordSelection(query: String, itemId: String) {
        let key = Self.key(query: query, itemId: itemId)
        var entry = entries[key] ?? Entry(count: 0, lastUsed: .distantPast)
        entry.count += 1
        entry.lastUsed = Date()
        entries[key] = entry
        save()
    }

    /// Returns a boost score (0...) for this item given the current query.
    /// Higher = user picks this item more often for similar queries.
    func boost(query: String, itemId: String) -> Double {
        let key = Self.key(query: query, itemId: itemId)
        guard let entry = entries[key] else { return 0 }
        let recency = max(0, 1.0 - Date().timeIntervalSince(entry.lastUsed) / (30 * 86400))
        return Double(entry.count) * 10.0 + recency * 5.0
    }

    // Normalize query to first 4 chars lowercased — groups similar queries together
    private static func key(query: String, itemId: String) -> String {
        let prefix = String(query.lowercased().prefix(4))
        return "\(prefix):\(itemId)"
    }

    private func load() {
        guard let data = try? Data(contentsOf: storePath),
              let decoded = try? JSONDecoder().decode([String: Entry].self, from: data) else { return }
        entries = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(entries) else { return }
        try? data.write(to: storePath, options: .atomic)
    }
}
