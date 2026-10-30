import Foundation
import os
import ReluxCore

private let log = Logger(subsystem: "com.relux.app", category: "FrecencyTracker")

/// Coding keys for `FrecencyTracker.UsageEntry`: the entry also has to read the
/// pre-ambient `{ opens, lastUsed }` shape that is still on disk.
private enum UsageEntryKey: String, CodingKey {
    case explicitOpens
    case ambientOpens
    case lastUsed
    case opens
}

/// Learns which apps the user opens and which app they pick for a given query.
///
/// Two stores, both persisted atomically to `frecency.json`:
/// - `usage`: explicit panel picks plus ambient launches/activations, and the last-use
///   timestamp, keyed by stable identity — the bundle path for apps (not the
///   `app:`-prefixed `SearchItem.id`), the item id for everything else;
/// - `learned`: folded query -> identity of the last pick for that query. Written only
///   from `recordSelection`; ambient observations never touch it.
///
/// `recents.json` keeps the richer item snapshots shown for an empty query.
///
/// A file that exists but cannot be read or decoded is never rewritten: the tracker keeps running
/// on empty state for the session instead of replacing bytes it failed to understand.
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

    /// One identity's usage record. The two counters stay separate because they
    /// are weighted differently (see `UsageBoost.perExplicitOpen`); `lastUsed` is
    /// the undecayed recency anchor for the whole bonus.
    private struct UsageEntry: Codable {
        var explicitOpens: Int
        var ambientOpens: Int
        var lastUsed: Date

        init(explicitOpens: Int, ambientOpens: Int, lastUsed: Date) {
            self.explicitOpens = explicitOpens
            self.ambientOpens = ambientOpens
            self.lastUsed = lastUsed
        }

        /// Ambient observations did not exist when `{ opens, lastUsed }` was written,
        /// so an old count can only be explicit. No file is rewritten to migrate it;
        /// the entry re-encodes in the new shape on the next write.
        init(from decoder: Decoder) throws {
            let container = try decoder.container(keyedBy: UsageEntryKey.self)
            lastUsed = try container.decode(Date.self, forKey: .lastUsed)
            if let explicit = try container.decodeIfPresent(Int.self, forKey: .explicitOpens) {
                explicitOpens = explicit
                ambientOpens = try container.decodeIfPresent(Int.self, forKey: .ambientOpens) ?? 0
            } else {
                explicitOpens = try container.decode(Int.self, forKey: .opens)
                ambientOpens = 0
            }
        }

        func encode(to encoder: Encoder) throws {
            var container = encoder.container(keyedBy: UsageEntryKey.self)
            try container.encode(explicitOpens, forKey: .explicitOpens)
            try container.encode(ambientOpens, forKey: .ambientOpens)
            try container.encode(lastUsed, forKey: .lastUsed)
        }
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
    /// `StoredItem.kind` value for app snapshots; the recents discriminator.
    private static let appKind = "app"

    /// Ambient observations arrive in bursts and are worth little individually, so
    /// `frecency.json` is rewritten at most once per this interval. `flush(now:)`
    /// forces the pending write out; the app calls it on terminate and every
    /// explicit pick already writes immediately.
    static let ambientSaveInterval: TimeInterval = 60

    private var usage: [String: UsageEntry] = [:]
    private var learned: [String: LearnedPick] = [:]
    /// key = item_id, stores full item info for recents
    private var items: [String: StoredItem] = [:]
    private let storePath: URL
    private let itemsPath: URL
    /// Instant of the last `frecency.json` write, for the ambient debounce.
    private var lastUsageSaveAt: Date?
    /// Ambient observations recorded since that write.
    private var hasUnsavedAmbient = false
    /// Cleared when a store file exists but nobody could read it: absent files are fair game for
    /// `save`, unreadable ones are not. Writing an in-memory fallback over bytes that may still be
    /// recoverable would destroy the user's ranking history with no trace of the original.
    private var canWriteUsage = true
    private var canWriteRecents = true

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
        let existing = usage[identity]
        usage[identity] = UsageEntry(
            explicitOpens: (existing?.explicitOpens ?? 0) + 1,
            ambientOpens: existing?.ambientOpens ?? 0,
            lastUsed: now
        )
        if !foldedQuery.isEmpty {
            learned[foldedQuery] = LearnedPick(path: identity, pickedAt: now)
        }

        let storedKind: String = switch item.kind {
        case .app: Self.appKind
        case .script: "script"
        case .translate: "translate"
        case .jwt: "jwt"
        case .systemSettings: "systemSettings"
        default: Self.appKind
        }
        items[item.id] = StoredItem(
            id: item.id,
            title: Self.displayTitle(kind: storedKind, id: item.id, title: item.title),
            subtitle: item.subtitle,
            icon: item.icon,
            kind: storedKind,
            meta: item.meta,
            lastUsed: now
        )

        save(now: now)
    }

    /// Usage state for one app path under the given query.
    func appUsage(query: String, path: String, now: Date) -> AppUsage {
        usageState(query: query, identity: path, now: now)
    }

    /// Record an app launch/activation observed outside the panel.
    ///
    /// Ambient events must never teach a query preference: they carry no query, and
    /// inferring one from "the app named `rem` was opened" would let a background
    /// launch outvote a real pick. Only `explicitOpens` and `lastUsed` move here.
    func recordAmbient(path: String, now: Date) {
        let existing = usage[path]
        usage[path] = UsageEntry(
            explicitOpens: existing?.explicitOpens ?? 0,
            ambientOpens: (existing?.ambientOpens ?? 0) + 1,
            lastUsed: now
        )

        // The debounce is driven by the injected clock so the write rate is a pure
        // function of the events the caller reports.
        if let lastUsageSaveAt, now.timeIntervalSince(lastUsageSaveAt) < Self.ambientSaveInterval {
            hasUnsavedAmbient = true
            return
        }
        saveUsage(now: now)
    }

    /// Write out ambient observations held back by the debounce.
    func flush(now: Date) {
        guard hasUnsavedAmbient else { return }
        saveUsage(now: now)
    }

    /// Usage boost for a non-app row, keyed by its `SearchItem.id`.
    func usageBoost(query: String, itemId: String, now: Date) -> Double {
        let identity = Self.appPath(forItemId: itemId) ?? itemId
        return UsageBoost.value(for: usageState(query: query, identity: identity, now: now), now: now)
    }

    private func usageState(query: String, identity: String, now: Date) -> AppUsage {
        let entry = usage[identity]
        return AppUsage(
            explicitOpens: entry?.explicitOpens ?? 0,
            ambientOpens: entry?.ambientOpens ?? 0,
            lastUsed: entry?.lastUsed,
            lastPick: isLastPick(query: query, identity: identity, now: now)
        )
    }

    private func isLastPick(query: String, identity: String, now: Date) -> Bool {
        let foldedQuery = Self.normalizedQuery(query)
        guard !foldedQuery.isEmpty, let pick = learned[foldedQuery] else { return false }
        return pick.path == identity && UsageBoost.isLive(lastPickAt: pick.pickedAt, now: now)
    }

    /// The title a stored snapshot is shown under.
    ///
    /// Snapshots written before `AppDisplayName` existed keep Spotlight's
    /// `kMDItemDisplayName`, extension included, so recents rendered
    /// `"Microsoft Remote Desktop.app"` while a fresh scan rendered the stripped
    /// name. Normalising at the two boundaries where a title enters or leaves the
    /// store — instead of rewriting `recents.json` — fixes that without touching
    /// the user's file, and keeps one implementation. Both halves of the test are
    /// required: a non-app snapshot legitimately titled `"deploy.app"` must keep
    /// its name, so `kind` alone is not enough, and the `app:` id prefix is the
    /// discriminator every written entry carries.
    private static func displayTitle(kind: String, id: String, title: String) -> String {
        guard kind == appKind, id.hasPrefix(appIdPrefix) else { return title }
        return AppDisplayName.from(bundleName: title)
    }

    /// Returns recently used items, sorted by most recent first
    func recentItems(limit: Int = 8) -> [SearchItem] {
        let sorted = items.values.sorted { $0.lastUsed > $1.lastUsed }
        return sorted.prefix(limit).map { stored in
            SearchItem(
                id: stored.id,
                title: Self.displayTitle(kind: stored.kind, id: stored.id, title: stored.title),
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

        let usageFile = existingBytes(at: storePath, label: Self.storeFileName)
        if let data = usageFile.data {
            if let decoded = try? JSONDecoder().decode(PersistedUsage.self, from: data) {
                usage = decoded.usage
                learned = decoded.learned
            } else if let previous = try? JSONDecoder().decode(PreviousUsage.self, from: data) {
                migrate(previous: previous, now: now)
                needsRewrite = true
            } else if let legacy = try? JSONDecoder().decode([String: LegacyEntry].self, from: data) {
                migrate(legacy: legacy, now: now)
                needsRewrite = true
            } else {
                // None of the three known shapes decoded it. Keep the session usable with an empty
                // ranking and leave the file alone: the next save must not replace it with that
                // emptiness.
                canWriteUsage = false
                log.error("frecency.json matched no known schema; preserving the file untouched")
            }
        } else {
            canWriteUsage = usageFile.writable
        }

        // Reads ignore an expired pick anyway; pruning here keeps the file bounded.
        let live = learned.filter { UsageBoost.isLive(lastPickAt: $0.value.pickedAt, now: now) }
        if live.count != learned.count {
            learned = live
            needsRewrite = true
        }

        let recentsFile = existingBytes(at: itemsPath, label: "recents.json")
        if let data = recentsFile.data {
            if let decoded = try? JSONDecoder().decode([String: StoredItem].self, from: data) {
                items = decoded
            } else {
                canWriteRecents = false
                log.error("recents.json did not decode; preserving the file untouched")
            }
        } else {
            canWriteRecents = recentsFile.writable
        }

        // Rewrite only after recents are loaded, otherwise a migration would
        // overwrite `recents.json` with an empty snapshot.
        if needsRewrite {
            save(now: now)
        }
    }

    /// Bytes of a store file, plus whether writing it is safe afterwards.
    ///
    /// A missing file yields no data and is writable; a file that exists but cannot be read yields
    /// no data either, but is not writable — the distinction the old `try? Data(contentsOf:)` threw
    /// away, which made an unreadable file indistinguishable from a first run.
    private func existingBytes(at url: URL, label: String) -> (data: Data?, writable: Bool) {
        guard FileManager.default.fileExists(atPath: url.path) else { return (nil, true) }
        guard let data = try? Data(contentsOf: url) else {
            let name = label
            log.error("\(name) exists but could not be read; preserving it untouched")
            return (nil, false)
        }
        return (data, true)
    }

    /// Previous-unit shape: `usage: [path: Int]`, `learned: [query: path]`.
    /// The timestamps were never stored, so "now" is the only defensible value.
    private func migrate(previous: PreviousUsage, now: Date) {
        usage = previous.usage.mapValues {
            UsageEntry(explicitOpens: $0, ambientOpens: 0, lastUsed: now)
        }
        learned = previous.learned.mapValues { LearnedPick(path: $0, pickedAt: now) }
    }

    /// Legacy format was `"<query prefix>:<itemId>"` → `{ count, lastUsed }`.
    /// Group by item id (the new identity), summing counts and keeping the most
    /// recent timestamp — the real dates exist, so they must survive.
    private func migrate(legacy: [String: LegacyEntry], now _: Date) {
        for (key, entry) in legacy {
            let itemId = Self.itemId(fromLegacyKey: key)
            let identity = Self.appPath(forItemId: itemId) ?? itemId
            let existing = usage[identity]
            usage[identity] = UsageEntry(
                explicitOpens: (existing?.explicitOpens ?? 0) + entry.count,
                ambientOpens: existing?.ambientOpens ?? 0,
                lastUsed: max(existing?.lastUsed ?? entry.lastUsed, entry.lastUsed)
            )
        }
        // `learned` stays empty: a 4-character query prefix is not a full folded
        // query, so a prefix -> path record could never match at read time.
        learned = [:]
    }

    private func save(now: Date) {
        saveUsage(now: now)
        if canWriteRecents {
            if let data = try? JSONEncoder().encode(items) {
                try? data.write(to: itemsPath, options: .atomic)
            }
        }
    }

    /// `frecency.json` only. Ambient observations take this path so a background
    /// launch never rewrites the recents snapshots the user curated.
    private func saveUsage(now: Date) {
        learned = learned.filter { UsageBoost.isLive(lastPickAt: $0.value.pickedAt, now: now) }
        lastUsageSaveAt = now
        hasUnsavedAmbient = false
        guard canWriteUsage else { return }
        let persisted = PersistedUsage(usage: usage, learned: learned)
        if let data = try? JSONEncoder().encode(persisted) {
            try? data.write(to: storePath, options: .atomic)
        }
    }
}
