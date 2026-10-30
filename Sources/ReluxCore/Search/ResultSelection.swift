/// Index bookkeeping for the overlay's result list.
///
/// The overlay re-runs its search on every keystroke and on every selection-capture bump,
/// and the displayed array is a re-grouped copy, so the highlight has to survive a refresh
/// by item identity rather than by position.
public enum ResultSelection {
    /// Index of the first item with `id`, or `nil` when no item has that id.
    ///
    /// Duplicate ids resolve to the first occurrence: results are deduplicated upstream, and
    /// preferring the first keeps the highlight from jumping to a later duplicate after a re-group.
    public static func index(of id: String?, in items: [SearchItem]) -> Int? {
        guard let id else { return nil }
        return items.firstIndex { $0.id == id }
    }

    /// Index to select after a results refresh: the previous selection's new position, or 0
    /// when it is gone (the historical "snap to top when nothing matches" behaviour).
    public static func restoredIndex(of id: String?, in items: [SearchItem]) -> Int {
        index(of: id, in: items) ?? 0
    }

    /// Next row for Tab/Down-style forward movement, wrapping past the end. An empty list or
    /// an out-of-range index falls back to 0 so callers never index outside the array.
    public static func advanced(_ index: Int, count: Int) -> Int {
        guard count > 0, index >= 0, index < count else { return 0 }
        return index >= count - 1 ? 0 : index + 1
    }

    /// 0-based row for the Cmd+N shortcut: `number` is the 1-based key cap, only 1...9 exist,
    /// and a key beyond the last row is a no-op (`nil`).
    public static func rowIndex(forCommandKey number: Int, rowCount: Int) -> Int? {
        guard (1 ... 9).contains(number), number <= rowCount else { return nil }
        return number - 1
    }
}
