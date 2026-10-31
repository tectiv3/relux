import ReluxCore
import XCTest

final class ClipboardFTSQueryTests: XCTestCase {
    private let columnFilter = "{text_content source_name} : "

    func testTermsAreQuotedAndAndJoined() {
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: "desk top"),
            columnFilter + "(\"desk\" AND \"top\")"
        )
    }

    /// Trigram indexes fixed-width windows, so a prefix marker buys nothing and FTS5 rejects `*`
    /// after a quoted phrase. The builder must never emit one.
    func testNoTermCarriesAPrefixMarker() throws {
        let expression = try XCTUnwrap(ClipboardFTSQuery.matchExpression(for: "desktop"))
        XCTAssertEqual(expression, columnFilter + "(\"desktop\")")
        XCTAssertFalse(expression.contains("*"))
    }

    func testEmbeddedQuotesAreDoubled() {
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: "\"quoted\""),
            columnFilter + "(\"\"\"quoted\"\"\")"
        )
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: "say \"hi\""),
            columnFilter + "(\"say\" AND \"\"\"hi\"\"\")"
        )
    }

    func testOperatorsAndPunctuationStayInsideQuotes() {
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "AND"), columnFilter + "(\"AND\")")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "NEAR"), columnFilter + "(\"NEAR\")")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "(d)"), columnFilter + "(\"(d)\")")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "xyz*"), columnFilter + "(\"xyz*\")")
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: "desk --top"),
            columnFilter + "(\"desk\" AND \"--top\")",
            "dashes inside a phrase are literal characters, not negation"
        )
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "col:value"), columnFilter + "(\"col:value\")")
    }

    /// One term below the trigram width makes the query unanswerable — including when the other
    /// terms are long enough. Dropping the short term would search for something other than what
    /// the user typed, so the whole query falls back to the page filter instead.
    func testAnyTermShorterThanThreeCharactersMakesTheQueryUnanswerable() {
        for input in [
            "", "   ", "a", "ab", "OR", "-", "*", "()", "🚀", "🚀🚀",
            "ab cd", "desktop ab", "abc ab cd", "ネ",
        ] {
            XCTAssertNil(
                ClipboardFTSQuery.matchExpression(for: input),
                "\(input.debugDescription) has a term below the trigram width"
            )
        }
    }

    func testThreeCharactersIsEnough() {
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "abc"), columnFilter + "(\"abc\")")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "語のテ"), columnFilter + "(\"語のテ\")")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "日本語"), columnFilter + "(\"日本語\")")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "🚀🚀🚀"), columnFilter + "(\"🚀🚀🚀\")")
    }

    func testCJKAndDiacriticsAreKeptVerbatim() {
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: "日本語 测试内"),
            columnFilter + "(\"日本語\" AND \"测试内\")"
        )
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "Café"), columnFilter + "(\"Café\")")
    }

    func testWhitespaceRunsAndNewlinesSplitTerms() {
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: " \t desk\n\ntop  "),
            columnFilter + "(\"desk\" AND \"top\")"
        )
    }

    /// `sqlite3_bind_text` truncates at the first NUL, so an expression containing one would reach
    /// SQLite as an unterminated phrase.
    func testANulByteMakesTheQueryUnanswerable() {
        XCTAssertNil(ClipboardFTSQuery.matchExpression(for: "desk\u{0}top"))
        XCTAssertNil(ClipboardFTSQuery.matchExpression(for: "desktop\u{0}"))
        XCTAssertNil(ClipboardFTSQuery.matchExpression(for: "\u{0}desktop"))
    }

    // MARK: - Operator proof

    /// Every expression the builder can produce has to be a legal FTS5 `MATCH` argument: user
    /// text must never reach the parser as an operator, a column name or an unterminated phrase.
    /// Each expression is executed against a real trigram index, so a syntax error fails the test
    /// instead of being masked by the store's `nil`.
    func testHostileInputNeverProducesAnFTSSyntaxError() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try ReluxSchema.migrate(database)
        try database.execute("""
            INSERT INTO clipboard_history (content_type, text_content, source_name, created_at, updated_at)
            VALUES ('text', 'remote desktop connection notes', 'Safari', 1, 1)
        """)

        var executed = 0
        for input in Self.hostileInputs + Self.fuzzedInputs(count: 3000) {
            guard let expression = ClipboardFTSQuery.matchExpression(for: input) else { continue }
            executed += 1
            XCTAssertFalse(
                expression.contains("\u{0}"),
                "a NUL would truncate the expression: \(input.debugDescription)"
            )

            let statement = try database.prepare("SELECT count(*) FROM clipboard_fts WHERE clipboard_fts MATCH ?")
            try statement.bind(1, expression)
            // `step` throws on a malformed MATCH argument, which is the failure this test is for.
            XCTAssertTrue(try statement.step(), "no row for \(input.debugDescription)")
        }
        XCTAssertGreaterThan(executed, 1000, "the corpus has to reach the parser, not just the length check")
    }

    /// Hand-picked inputs: unbalanced and embedded quotes, operators, column-filter syntax, a
    /// very long term, emoji, combining marks, NUL and newlines.
    private static let hostileInputs: [String] = [
        "\"", "\"\"", "\"\"\"", "\"\"\"\"", "abc\"", "\"abc", "a\"b\"c", "\"a\" AND \"b\"",
        "*", "**", "***", "abc*", "* abc", "*abc*",
        "-", "--", "---", "abc-", "-abc", "NEAR", "NEAR(a b)", "NEAR/2", "AND", "OR", "NOT", "AND OR NOT",
        "(", ")", "()", "(abc", "abc)", "((abc))", "{}", "{text_content}", "{text_content source_name} : abc",
        "abc:text_content", "^abc", "abc^", ":", ":::", "abc:", "col:value",
        String(repeating: "a", count: 10000),
        String(repeating: "\"", count: 500), String(repeating: "*", count: 500),
        "🚀🚀🚀", "🚀 desk", "e\u{301}e\u{301}e\u{301}", "Cafe\u{301} latte",
        "desk\u{0}top", "\u{0}\u{0}\u{0}",
        "line one\nline two", "\ttabs\tand\tnewlines\n", "打 開 檔 案", "日本語のテキスト",
        "a%_b", "\\", "\\\\", "'", "''", "`", "abc\\", "abc'def",
    ]

    /// Deterministic pseudo-random strings over the same character set, so failures reproduce.
    private static func fuzzedInputs(count: Int) -> [String] {
        let fragments = [
            "a", "b", "abc", "desk", "\"", "\"\"", " ", "\n", "\t", "\u{0}", "*", "-", "(", ")", "{", "}",
            ":", "^", "NEAR", "AND", "OR", "é", "e\u{301}", "日本語", "語のテ", "🚀", "'", "\\", "%", "_", "]",
        ]
        // splitmix64: fixed seed, no Foundation RNG so the corpus is identical on every run.
        var state: UInt64 = 0x9E37_79B9_7F4A_7C15
        func next() -> UInt64 {
            state = state &+ 0x9E37_79B9_7F4A_7C15
            var mixed = state
            mixed = (mixed ^ (mixed >> 30)) &* 0xBF58_476D_1CE4_E5B9
            mixed = (mixed ^ (mixed >> 27)) &* 0x94D0_49BB_1331_11EB
            return mixed ^ (mixed >> 31)
        }

        return (0 ..< count).map { _ in
            let length = Int(next() % 12)
            var value = ""
            for _ in 0 ..< length {
                value += fragments[Int(next() % UInt64(fragments.count))]
            }
            return value
        }
    }
}
