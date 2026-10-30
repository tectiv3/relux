public enum FuzzyMatch {
    /// Indices of the tightest in-order subsequence match of `query` in `target`.
    /// Returns `nil` when there is no match or when the match would span more than
    /// `maxSpan` characters (`nil` = unbounded).
    public static func matchedIndices(
        of query: String,
        in target: String,
        maxSpan: Int? = nil
    ) -> [String.Index]? {
        tightestMatch(of: query, in: target, maxSpan: maxSpan)
    }

    /// Subsequence test used by the searchers. Case folding is the caller's job:
    /// the app and script searchers pass an already lowercased query and target.
    public static func matches(_ query: String, in target: String, maxSpan: Int? = nil) -> Bool {
        tightestMatch(of: query, in: target, maxSpan: maxSpan) != nil
    }

    private static func tightestMatch(
        of query: String,
        in target: String,
        maxSpan: Int?
    ) -> [String.Index]? {
        let queryChars = Array(query)
        guard let firstChar = queryChars.first else { return nil }
        let spanLimit = maxSpan ?? Int.max

        var bestIndices: [String.Index]?
        var bestSpan = Int.max

        var startSearch = target.startIndex
        while let anchor = target[startSearch...].firstIndex(of: firstChar) {
            var indices = [anchor]
            var idx = target.index(after: anchor)
            var matched = true
            for char in queryChars.dropFirst() {
                guard let found = target[idx...].firstIndex(of: char) else {
                    matched = false
                    break
                }
                indices.append(found)
                idx = target.index(after: found)
            }
            if matched, let last = indices.last {
                let span = target.distance(from: anchor, to: last) + 1
                if span <= spanLimit, span < bestSpan {
                    bestSpan = span
                    bestIndices = indices
                }
            }
            startSearch = target.index(after: anchor)
        }
        return bestIndices
    }
}
