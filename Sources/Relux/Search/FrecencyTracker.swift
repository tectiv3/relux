import Foundation
import ReluxCore

/// Learns which apps the user opens and which app they pick for a given query.
///
/// Two stores, both persisted atomically to `frecency.json`:
/// - `usage`: opens per stable identity — the bundle path for apps (not the
///   `app:`-prefixed `SearchItem.id`), the item id for everything else;
/// - `learned`: folded query -> identity of the last pick for that query.
///
/// `recents.json` keeps the richer item snapshots shown for an empty query.
@MainActor
final class FrecencyTracker {
    private struct LegacyEntry: Codable {
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

    private struct PersistedUsage: Codable {
        var usage: [String: Int]
        var learned: [String: String]
    }

    private static let appIdPrefix = "app:"
    private static let storeFileName = "frecency.json"

    private var usage: [String: Int] = [:]
    private var learned: [String: String] = [:]
    /// key = item_id, stores full item info for recents
    private var items: [String: StoredItem] = [:]
    private let storePath: URL
    private let itemsPath: URL

    init(directory: URL? = nil) {
        let dir: URL
        if let directory {
            dir = directory
        } else {
            let support = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
            dir = support.appendingPathComponent("Relux", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        storePath = dir.appendingPathComponent(Self.storeFileName)
        itemsPath = dir.appendingPathComponent("recents.json")
        load()
    }

    /// The single place a query is normalised: recording and ranking must agree,
    /// otherwise trailing whitespace or case orphans entries from the lookup.
    static func normalizedQuery(_ query: String) -> String {
        FuzzyMatch.fold(query.trimmingCharacters(in: .whitespacesAndNewlines))
    }

    /// "app:/Applications/X.app" -> "/Applications/X.app"
    static func appPath(forItemId id: String) -> String? {
        guard id.hasPrefix(appIdPrefix) else { return nil }
        return String(id.dropFirst(appIdPrefix.count))
    }

    /// Identity used as the `usage` key: the path for apps, the item id otherwise.
    private static func identity(of item: SearchItem) -> String {
        if item.kind == .app, let path = item.meta["path"] {
            return path
        }
        return appPath(forItemId: item.id) ?? item.id
    }

    /// Record that the user selected this item after typing `query`.
    /// Web-search and calculator results are skipped: they carry no stable identity.
    func recordSelection(query: String, item: SearchItem) {
        guard item.kind != .webSearch, item.kind != .calculator else { return }

        let foldedQuery = Self.normalizedQuery(query)
        let identity = Self.identity(of: item)
        usage[identity, default: 0] += 1
        if !foldedQuery.isEmpty {
            learned[foldedQuery] = identity
        }

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

    /// Usage state for one app path under the given query.
    func appUsage(query: String, path: String) -> AppUsage {
        AppUsage(opens: usage[path] ?? 0, lastPick: lastPick(query: query, identity: path))
    }

    /// Usage boost for a non-app row, keyed by its `SearchItem.id`.
    func usageBoost(query: String, itemId: String) -> Double {
        let identity = Self.appPath(forItemId: itemId) ?? itemId
        let state = AppUsage(opens: usage[identity] ?? 0, lastPick: lastPick(query: query, identity: identity))
        return Double(UsageBoost.value(for: state))
    }

    private func lastPick(query: String, identity: String) -> Bool {
        let foldedQuery = Self.normalizedQuery(query)
        guard !foldedQuery.isEmpty else { return false }
        return learned[foldedQuery] == identity
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

    /// Remove an item from history (both its usage record and its recents entry)
    func removeItem(id: String) {
        items.removeValue(forKey: id)
        let identity = Self.appPath(forItemId: id) ?? id
        usage.removeValue(forKey: identity)
        learned = learned.filter { $0.value != identity }
        save()
    }

    private func load() {
        if let data = try? Data(contentsOf: storePath) {
            if let decoded = try? JSONDecoder().decode(PersistedUsage.self, from: data) {
                usage = decoded.usage
                learned = decoded.learned
            } else if let legacy = try? JSONDecoder().decode([String: LegacyEntry].self, from: data) {
                migrate(legacy)
            }
        }
        if let data = try? Data(contentsOf: itemsPath),
           let decoded = try? JSONDecoder().decode([String: StoredItem].self, from: data)
        {
            items = decoded
        }
    }

    /// Legacy format was `"<query prefix>:<itemId>": { count, lastUsed }`.
    /// Sum the counts per app path and rewrite once in the new format.
    private func migrate(_ legacy: [String: LegacyEntry]) {
        for (key, entry) in legacy {
            guard let separator = key.firstIndex(of: ":") else { continue }
            let itemId = String(key[key.index(after: separator)...])
            guard let path = Self.appPath(forItemId: itemId) else { continue }
            usage[path, default: 0] += entry.count
        }
        save()
    }

    private func save() {
        let persisted = PersistedUsage(usage: usage, learned: learned)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: storePath, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: itemsPath, options: .atomic)
        }
    }
}
