@testable import Relux
import XCTest

final class CalculatorServiceTests: XCTestCase {
    func testDivisionReplacementParentheses() async throws {
        let service = CalculatorService()
        // These expressions should evaluate as expected, not be broken by /1.0/ replacement
        let cases: [(String, Double)] = [
            ("(10+2)/3", 4.0),
            ("6/(2+1)", 2.0),
            ("(8-2)/(2+1)", 2.0),
            ("(a+b)/(c+d)", Double.nan), // Should fail gracefully if variables
        ]
        for (expr, expected) in cases {
            let result = await service.evaluate(expr)
            if expr.contains("a") {
                XCTAssertNil(result, "Should return nil for variables")
            } else {
                XCTAssertNotNil(result)
                XCTAssertEqual(try Double(XCTUnwrap(result?.answer)), expected, accuracy: 0.0001)
            }
        }
    }
}
