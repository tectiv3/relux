import ReluxCore
import XCTest

final class ClipboardFTSQueryTests: XCTestCase {
    func testTermsAreQuotedAndAndJoined() {
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "foo bar"), "\"foo\" AND \"bar\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "foo"), "\"foo\"*")
    }

    func testOnlyTheLastTermGetsThePrefixMarker() {
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: "foo foo"),
            "\"foo\" AND \"foo\"*",
            "repeating a term must not promote it to a prefix on both occurrences"
        )
    }

    func testEmbeddedQuotesAreDoubled() {
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "\"quoted\""), "\"\"\"quoted\"\"\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "say \"hi\""), "\"say\" AND \"\"\"hi\"\"\"*")
    }

    func testOperatorsAndPunctuationStayInsideQuotes() {
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "OR"), "\"OR\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "NEAR"), "\"NEAR\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "a OR b"), "\"a\" AND \"OR\" AND \"b\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "a - b"), "\"a\" AND \"b\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "x*"), "\"x*\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "(d)"), "\"(d)\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "col:value"), "\"col:value\"*")
    }

    func testInputWithoutADigitOrLetterHasNoExpression() {
        for input in ["", "   ", "-", "*", "**", "\"", "(", "🚀", "—", "***"] {
            XCTAssertNil(ClipboardFTSQuery.matchExpression(for: input), "\(input.debugDescription) has no token")
        }
        XCTAssertEqual(
            ClipboardFTSQuery.matchExpression(for: "ship 🚀"),
            "\"ship\"*",
            "an unindexable term next to a word is dropped instead of poisoning the query"
        )
    }

    func testCJKAndDiacriticsAreKeptVerbatim() {
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "中文 测试"), "\"中文\" AND \"测试\"*")
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: "Café"), "\"Café\"*")
    }

    func testWhitespaceRunsAndNewlinesSplitTerms() {
        XCTAssertEqual(ClipboardFTSQuery.matchExpression(for: " \t foo\n\nbar  "), "\"foo\" AND \"bar\"*")
    }
}
