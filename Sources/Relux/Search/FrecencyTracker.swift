import Foundation
import ReluxCore

/// Learns which apps the user opens and which app they pick for a given query.
///
/// Two stores, both persisted atomically to `frecency.json`:
/// - `usage`: opens plus the last-use timestamp, keyed by stable identity — the
///   bundle path for apps (not the `app:`-prefixed `SearchItem.id`), the item id
///   for everything else;
/// - `learned`: folded query -> identity of the last pick for that query.
///
/// `recents.json` keeps the richer item snapshots shown for an empty query.
///
/// Every date this type handles is injected: ranking reads a caller-supplied
/// `now` so decay and the learned-pick TTL are exact rather than wall-clock
/// dependent.
@MainActor
final class FrecencyTracker {
    private struct LegacyEntry: Codable {
        var count: Int
        var lastUsed: Date
    }

    /// One identity's usage record. `opens` is the undecayed numerator; the
    /// bonus is derived from `lastUsed` on every read.
    private struct UsageEntry: Codable {
        var opens: Int
        var lastUsed: Date
    }

    private struct LearnedPick: Codable {
        var path: String
        var pickedAt: Date
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
        var usage: [String: UsageEntry]
        var learned: [String: LearnedPick]
    }

    /// Shape written by the previous unit: plain counts and bare paths, no
    /// timestamps.
    private struct PreviousUsage: Codable {
        var usage: [String: Int]
        var learned: [String: String]
    }

    private static let appIdPrefix = "app:"
    private static let storeFileName = "frecency.json"

    private var usage: [String: UsageEntry] = [:]
    private var learned: [String: LearnedPick] = [:]
    /// key = item_id, stores full item info for recents
    private var items: [String: StoredItem] = [:]
    private let storePath: URL
    private let itemsPath: URL

    init(directory: URL? = nil, now: Date) {
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
        load(now: now)
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

    /// Legacy keys were `"<query prefix>:<item id>"`; the item id may itself
    /// contain colons (`app:`, `settings:`, `script:`), so only the first
    /// separator is stripped.
    private static func itemId(fromLegacyKey key: String) -> String {
        guard let separator = key.firstIndex(of: ":") else { return key }
        return String(key[key.index(after: separator)...])
    }

    /// Record that the user selected this item after typing `query`.
    /// Web-search and calculator results are skipped: they carry no stable identity.
    func recordSelection(query: String, item: SearchItem, now: Date) {
        guard item.kind != .webSearch, item.kind != .calculator else { return }

        let foldedQuery = Self.normalizedQuery(query)
        let identity = Self.identity(of: item)
        let opens = usage[identity]?.opens ?? 0
        usage[identity] = UsageEntry(opens: opens + 1, lastUsed: now)
        if !foldedQuery.isEmpty {
            learned[foldedQuery] = LearnedPick(path: identity, pickedAt: now)
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
            lastUsed: now
        )

        save(now: now)
    }

    /// Usage state for one app path under the given query.
    func appUsage(query: String, path: String, now: Date) -> AppUsage {
        usageState(query: query, identity: path, now: now)
    }

    /// Usage boost for a non-app row, keyed by its `SearchItem.id`.
    func usageBoost(query: String, itemId: String, now: Date) -> Double {
        let identity = Self.appPath(forItemId: itemId) ?? itemId
        return UsageBoost.value(for: usageState(query: query, identity: identity, now: now), now: now)
    }

    private func usageState(query: String, identity: String, now: Date) -> AppUsage {
        let entry = usage[identity]
        return AppUsage(
            opens: entry?.opens ?? 0,
            lastUsed: entry?.lastUsed,
            lastPick: isLastPick(query: query, identity: identity, now: now)
        )
    }

    private func isLastPick(query: String, identity: String, now: Date) -> Bool {
        let foldedQuery = Self.normalizedQuery(query)
        guard !foldedQuery.isEmpty, let pick = learned[foldedQuery] else { return false }
        return pick.path == identity && UsageBoost.isLive(lastPickAt: pick.pickedAt, now: now)
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
    func removeItem(id: String, now: Date = Date()) {
        items.removeValue(forKey: id)
        let identity = Self.appPath(forItemId: id) ?? id
        usage.removeValue(forKey: identity)
        learned = learned.filter { $0.value.path != identity }
        save(now: now)
    }

    private func load(now: Date) {
        var needsRewrite = false

        if let data = try? Data(contentsOf: storePath) {
            if let decoded = try? JSONDecoder().decode(PersistedUsage.self, from: data) {
                usage = decoded.usage
                learned = decoded.learned
            } else if let previous = try? JSONDecoder().decode(PreviousUsage.self, from: data) {
                migrate(previous: previous, now: now)
                needsRewrite = true
            } else if let legacy = try? JSONDecoder().decode([String: LegacyEntry].self, from: data) {
                migrate(legacy: legacy, now: now)
                needsRewrite = true
            }
        }

        // Reads ignore an expired pick anyway; pruning here keeps the file bounded.
        let live = learned.filter { UsageBoost.isLive(lastPickAt: $0.value.pickedAt, now: now) }
        if live.count != learned.count {
            learned = live
            needsRewrite = true
        }

        if let data = try? Data(contentsOf: itemsPath),
           let decoded = try? JSONDecoder().decode([String: StoredItem].self, from: data)
        {
            items = decoded
        }

        // Rewrite only after recents are loaded, otherwise a migration would
        // overwrite `recents.json` with an empty snapshot.
        if needsRewrite {
            save(now: now)
        }
    }

    /// Previous-unit shape: `usage: [path: Int]`, `learned: [query: path]`.
    /// The timestamps were never stored, so "now" is the only defensible value.
    private func migrate(previous: PreviousUsage, now: Date) {
        usage = previous.usage.mapValues { UsageEntry(opens: $0, lastUsed: now) }
        learned = previous.learned.mapValues { LearnedPick(path: $0, pickedAt: now) }
    }

    /// Legacy format was `"<query prefix>:<itemId>": { count, lastUsed }`.
    /// Group by item id (the new identity), summing counts and keeping the most
    /// recent timestamp — the real dates exist, so they must survive.
    private func migrate(legacy: [String: LegacyEntry], now _: Date) {
        for (key, entry) in legacy {
            let itemId = Self.itemId(fromLegacyKey: key)
            let identity = Self.appPath(forItemId: itemId) ?? itemId
            let existing = usage[identity]
            usage[identity] = UsageEntry(
                opens: (existing?.opens ?? 0) + entry.count,
                lastUsed: max(existing?.lastUsed ?? entry.lastUsed, entry.lastUsed)
            )
        }
        // `learned` stays empty: a 4-character query prefix is not a full folded
        // query, so a prefix -> path record could never match at read time.
        learned = [:]
    }

    private func save(now: Date) {
        learned = learned.filter { UsageBoost.isLive(lastPickAt: $0.value.pickedAt, now: now) }
        let persisted = PersistedUsage(usage: usage, learned: learned)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: storePath, options: .atomic)
        }
        if let data = try? JSONEncoder().encode(items) {
            try? data.write(to: itemsPath, options: .atomic)
        }
    }
}
