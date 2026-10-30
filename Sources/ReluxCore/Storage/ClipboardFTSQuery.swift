import Foundation

/// Builds the FTS5 `MATCH` expression for clipboard search input.
///
/// User text never reaches `MATCH` unquoted, so no FTS5 operator is reachable from it: inside a
/// phrase `-`, `*`, `(`, `)`, `:`, `^`, `AND`, `OR`, `NOT` and `NEAR` are literal characters, and
/// a `"` is escaped the way FTS5 requires — by doubling it. Terms are joined with `AND`, and only
/// the last one carries a `*`, so the word currently being typed still matches its prefixes.
///
/// A term with no letter or digit (an emoji, or a run of punctuation) is dropped: `unicode61`
/// indexes no token for it, so keeping it would turn a query the panel can answer by substring
/// into a guaranteed empty result. When nothing indexable is left this returns `nil` and the
/// caller falls back to filtering the loaded page.
public enum ClipboardFTSQuery {
    public static func matchExpression(for raw: String) -> String? {
        let terms = raw.split(whereSeparator: { $0.isWhitespace }).filter { term in
            term.contains { $0.isLetter || $0.isNumber }
        }
        guard !terms.isEmpty else { return nil }

        return terms.enumerated().map { index, term in
            let quoted = "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
            return index == terms.count - 1 ? quoted + "*" : quoted
        }.joined(separator: " AND ")
    }
}
