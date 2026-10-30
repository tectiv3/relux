import Foundation

/// What the usage log knows about one app at ranking time.
public struct AppUsage: Sendable, Equatable {
    /// Total opens of the app, independent of query.
    public var opens: Int
    /// The app was the last pick for this exact folded query.
    public var lastPick: Bool

    public init(opens: Int = 0, lastPick: Bool = false) {
        self.opens = opens
        self.lastPick = lastPick
    }
}

/// Additive usage weights applied on top of the fuzzy score.
public enum UsageBoost {
    public static let perOpen = 20
    public static let openCap = 200
    public static let lastPick = 300

    public static func value(for usage: AppUsage) -> Int {
        min(openCap, max(0, usage.opens) * perOpen) + (usage.lastPick ? lastPick : 0)
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
        locale: Locale = .current
    ) -> Double? {
        guard let fuzzy = FuzzyMatch.score(query: query, name: name, locale: locale) else { return nil }
        return Double(fuzzy + (isNew ? newAppBonus : 0) + UsageBoost.value(for: usage))
    }
}
