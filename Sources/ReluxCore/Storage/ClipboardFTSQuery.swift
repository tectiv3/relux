import Foundation

/// Builds the FTS5 `MATCH` argument for clipboard search input.
///
/// The index is tokenized with `trigram` (schema version 3), so a quoted phrase matches any
/// substring of three characters or more — not just a whole token or a token prefix. That has
/// three consequences for the expression:
///
/// - no term carries a `*`; trigram indexes fixed-width windows, a prefix marker is redundant, and
///   FTS5 rejects it after a quoted phrase;
/// - every term is a quoted phrase, so no FTS5 operator is reachable from user text (inside a
///   phrase `-`, `*`, `(`, `)`, `:`, `^`, `AND`, `OR`, `NOT` and `NEAR` are literal characters) and
///   an embedded `"` is escaped the way FTS5 requires, by doubling it;
/// - the term is matched literally, punctuation included: `"plain)"` finds the substring `plain)`,
///   where the old word tokenizer would have searched only for `plain`.
///
/// A term shorter than three characters cannot be matched by a trigram index at all, and *one*
/// such term makes the whole query unanswerable: silently dropping it would search for something
/// the user did not ask for, so the caller falls back to filtering the loaded page instead. That
/// is also why `nil` — rather than an expression that matches nothing — is the failure signal.
///
/// The column filter is part of the expression so user text can never be read as a column name or
/// an operator. `source_name` is searched alongside the body because text-less rows (images) and
/// the app a clip came from are otherwise unreachable.
public enum ClipboardFTSQuery {
    /// Trigram tokenization indexes three-character windows, so a shorter term matches nothing.
    public static let minimumTermLength = 3

    /// The external-content index's textual columns, in `ReluxSchema`'s declaration order.
    public static let searchedColumns = "text_content source_name"

    public static func matchExpression(for raw: String) -> String? {
        // `sqlite3_bind_text` truncates at the first NUL, so an expression containing one would
        // reach SQLite cut in half — an unterminated phrase, i.e. a syntax error. Such a query is
        // unanswerable by construction instead.
        guard !raw.contains("\u{0}") else { return nil }

        let terms = raw.split(whereSeparator: { $0.isWhitespace })
        guard !terms.isEmpty, terms.allSatisfy({ $0.count >= minimumTermLength }) else { return nil }

        let phrases = terms.map { term in
            "\"" + term.replacingOccurrences(of: "\"", with: "\"\"") + "\""
        }
        return "{\(searchedColumns)} : (\(phrases.joined(separator: " AND ")))"
    }
}
