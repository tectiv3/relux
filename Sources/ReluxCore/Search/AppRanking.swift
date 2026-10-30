import Foundation

/// What the usage log knows about one app at ranking time.
public struct AppUsage: Sendable, Equatable {
    /// Total opens of the app, independent of query.
    public var opens: Int
    /// When the app was last opened. `nil` means the log has no record, so
    /// nothing is decayed.
    public var lastUsed: Date?
    /// The app was the last pick for this exact folded query and that pick is
    /// still inside `UsageBoost.lastPickTTLDays`.
    public var lastPick: Bool

    public init(opens: Int = 0, lastUsed: Date? = nil, lastPick: Bool = false) {
        self.opens = opens
        self.lastUsed = lastUsed
        self.lastPick = lastPick
    }
}

/// Additive usage weights applied on top of the fuzzy score. The opens bonus
/// decays with recency; the learned pick is either live or expired.
public enum UsageBoost {
    public static let perOpen = 20
    public static let openCap = 200
    public static let lastPick = 300

    /// Half-life of the whole opens bonus. Because the bonus decays as one unit,
    /// this is the calibrated compromise: 14 days halves everything every
    /// fortnight, which forgets a weekly-used app too eagerly.
    public static let halfLifeDays = 30.0

    /// Hard expiry for the learned pick. Older picks are ignored at read time
    /// and pruned from the store on the next write.
    public static let lastPickTTLDays = 90.0

    private static let secondsPerDay = 86400.0

    /// Recency factor in (0, 1]: 1 at age 0, 0.5 after one half-life, 0.25
    /// after two. A future timestamp (clock skew) is treated as age 0.
    public static func decay(lastUsed: Date?, now: Date) -> Double {
        guard let lastUsed else { return 1 }
        let age = max(0, now.timeIntervalSince(lastUsed))
        return pow(0.5, age / secondsPerDay / halfLifeDays)
    }

    /// A learned pick is live up to and including the TTL boundary.
    public static func isLive(lastPickAt: Date, now: Date) -> Bool {
        now.timeIntervalSince(lastPickAt) <= lastPickTTLDays * secondsPerDay
    }

    public static func value(for usage: AppUsage, now: Date) -> Double {
        let capped = Double(min(openCap, max(0, usage.opens) * perOpen))
        let opensBonus = capped * decay(lastUsed: usage.lastUsed, now: now)
        return opensBonus + (usage.lastPick ? Double(lastPick) : 0)
    }
}

/// Score ladder for app rows: `FuzzyMatch.score` plus usage learning.
public enum AppRanking {
    /// Apps surfaced by the directory watcher but not yet indexed by Spotlight.
    public static let newAppBonus = 50

    public static func score(
        query: String,
        name: String,
        isNew: Bool = false,
        usage: AppUsage = AppUsage(),
        now: Date,
        locale: Locale = .current
    ) -> Double? {
        guard let fuzzy = FuzzyMatch.score(query: query, name: name, locale: locale) else { return nil }
        return Double(fuzzy + (isNew ? newAppBonus : 0)) + UsageBoost.value(for: usage, now: now)
    }
}
