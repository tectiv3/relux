import Foundation

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

    /// Case- and diacritic-insensitive form used by every scoring path.
    public static func fold(_ string: String, locale: Locale = .current) -> String {
        string.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: locale)
    }

    /// First letter of each word plus every uppercase character that follows a
    /// lowercase one, folded: `"Visual Studio Code"` -> `"vsc"`, `"WebStorm"` -> `"ws"`.
    public static func initials(_ string: String) -> String {
        var result = ""
        var insideWord = false
        var previousIsLowercase = false
        for char in string {
            guard char.isLetter || char.isNumber else {
                insideWord = false
                continue
            }
            if !insideWord {
                result.append(char)
            } else if char.isUppercase, previousIsLowercase {
                result.append(char)
            }
            insideWord = true
            previousIsLowercase = char.isLowercase
        }
        return fold(result)
    }

    /// Higher-is-better tiered score for `query` against a display `name`.
    /// Tiers subtract a length penalty (`min(count, 60)`); the subsequence tier
    /// does not, because it is already penalised by its gaps.
    public static func score(
        query: String,
        name: String,
        locale: Locale = .current
    ) -> Int? {
        let foldedQuery = fold(query, locale: locale)
        let foldedName = fold(name, locale: locale)
        guard !foldedQuery.isEmpty, !foldedName.isEmpty else { return nil }

        let penalty = min(foldedName.count, 60)
        if foldedName == foldedQuery {
            return 1000 - penalty
        }
        if foldedName.hasPrefix(foldedQuery) {
            return 900 - penalty
        }
        if initials(name).hasPrefix(foldedQuery) {
            return 800 - penalty
        }
        if words(of: foldedName).contains(where: { $0.hasPrefix(foldedQuery) }) {
            return 700 - penalty
        }
        if foldedName.contains(foldedQuery) {
            return 500 - penalty
        }

        guard let indices = matchedIndices(of: foldedQuery, in: foldedName),
              let first = indices.first, let last = indices.last
        else { return nil }
        let span = foldedName.distance(from: first, to: last) + 1
        let gaps = span - foldedQuery.count
        return max(1, 300 - gaps * 8)
    }

    private static func words(of folded: String) -> [String] {
        folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }).map(String.init)
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
