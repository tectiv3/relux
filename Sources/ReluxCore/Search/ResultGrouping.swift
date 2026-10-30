public enum ResultGrouping {
    /// Stable grouping: kinds appear in first-seen order, items keep their relative
    /// order inside a kind. OverlayView navigates by index, so order is observable.
    public static func groupByKind(_ items: [SearchItem]) -> [SearchItem] {
        var kindOrder: [SearchItemKind] = []
        var buckets: [SearchItemKind: [SearchItem]] = [:]
        for item in items {
            if buckets[item.kind] == nil {
                kindOrder.append(item.kind)
            }
            buckets[item.kind, default: []].append(item)
        }
        return kindOrder.flatMap { buckets[$0] ?? [] }
    }
}
