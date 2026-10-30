import ReluxCore
import XCTest

final class FormattingTests: XCTestCase {
    func testBytesBelowOneKilobyte() {
        XCTAssertEqual(Formatting.bytes(0), "0 KB")
        XCTAssertEqual(Formatting.bytes(1), "0 KB")
        XCTAssertEqual(Formatting.bytes(512), "0 KB")
        XCTAssertEqual(Formatting.bytes(1023), "1 KB")
    }

    /// 1023 and 1024 bytes both render as kilobytes: the MB branch starts at 1 MiB.
    func testByteBoundary() {
        XCTAssertEqual(Formatting.bytes(1024), "1 KB")
        XCTAssertEqual(Formatting.bytes(1_048_575), "1024 KB")
        XCTAssertEqual(Formatting.bytes(1_048_576), "1.0 MB")
    }

    func testMegabyteAndGigabyteValues() {
        XCTAssertEqual(Formatting.bytes(1536 * 1024), "1.5 MB")
        XCTAssertEqual(Formatting.bytes(1_073_741_824), "1024.0 MB")
        XCTAssertEqual(Formatting.bytes(3_221_225_472), "3072.0 MB")
    }

    func testNegativeAndHugeValues() {
        XCTAssertEqual(Formatting.bytes(-1), "-0 KB")
        XCTAssertEqual(Formatting.bytes(-1024), "-1 KB")
        XCTAssertEqual(Formatting.bytes(Int.min), "-9007199254740992 KB")
        XCTAssertEqual(Formatting.bytes(Int.max), "8796093022208.0 MB")
    }

    func testTimeForTodayUsesTodayClockFormat() {
        let text = Formatting.time(Date())
        XCTAssertTrue(text.hasPrefix("Today at "), "unexpected format: \(text)")

        let clock = text.dropFirst("Today at ".count)
        XCTAssertEqual(clock.count, 8, "unexpected clock: \(text)")
        XCTAssertEqual(clock.filter { $0 == ":" }.count, 2, "unexpected clock: \(text)")
        XCTAssertTrue(clock.filter { $0 != ":" }.allSatisfy(\.isNumber), "unexpected clock: \(text)")
    }

    func testTimeForAnotherDayUsesMediumDateAndShortTime() {
        let date = Date(timeIntervalSince1970: 1_579_084_200) // 2020-01-15 10:30:00 UTC
        XCTAssertFalse(Calendar.current.isDateInToday(date))

        let reference = DateFormatter()
        reference.dateStyle = .medium
        reference.timeStyle = .short

        let text = Formatting.time(date)
        XCTAssertEqual(text, reference.string(from: date))
        XCTAssertFalse(text.hasPrefix("Today at "))
    }
}
