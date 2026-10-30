import ReluxCore
import XCTest

final class AppRankingTests: XCTestCase {
    private static let remindersPath = "/System/Applications/Reminders.app"
    private static let remoteDesktopPath = "/Applications/Microsoft Remote Desktop.app"

    func testUsageBoostCapsOpensAtTwoHundred() {
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 0)), 0)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 9)), 180)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 10)), 200)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 50)), 200)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 2, lastPick: true)), 40 + 300)
    }

    func testLastPickOutweighsTheTwoHundredPointTierGap() {
        // The widest gap the ladder can produce between adjacent name tiers.
        XCTAssertEqual(900 - 700, 200)
        XCTAssertGreaterThan(UsageBoost.lastPick, 200)
    }

    func testNewlyDetectedAppKeepsItsFlatBonus() throws {
        let plain = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders"))
        let fresh = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", isNew: true))
        XCTAssertEqual(fresh - plain, Double(AppRanking.newAppBonus))
    }

    func testScoreIsNilWhenTheNameDoesNotMatch() {
        XCTAssertNil(AppRanking.score(query: "zzz", name: "Reminders"))
    }

    /// Acceptance scenario: query `rem` after learning that Remote Desktop is the
    /// last pick for `rem` and has been opened 11 times versus 2 for Reminders.
    func testLearnedPickPromotesRemoteDesktopOverReminders() throws {
        let reminders = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Reminders",
            usage: AppUsage(opens: 2, lastPick: false)
        ))
        let remoteWithoutLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(opens: 11, lastPick: false)
        ))
        let remoteWithLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(opens: 11, lastPick: true)
        ))

        // Reminders: name prefix 900, minus its 9 characters, plus 2 opens * 20.
        XCTAssertEqual(reminders, 900 - 9 + 40)
        // Remote Desktop: word prefix 700, minus 24 characters, plus capped 11 * 20.
        XCTAssertEqual(remoteWithoutLearning, 700 - 24 + 200)
        XCTAssertEqual(remoteWithLearning, remoteWithoutLearning + Double(UsageBoost.lastPick))

        // The name ladder alone keeps Reminders first; the learned last pick flips it.
        XCTAssertGreaterThan(reminders, remoteWithoutLearning)
        XCTAssertGreaterThan(remoteWithLearning, reminders)
    }

    func testEqualInputsTieAndTheRankerKnowsNothingAboutItemKind() throws {
        let first = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", usage: AppUsage(opens: 2)))
        let second = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", usage: AppUsage(opens: 2)))
        XCTAssertEqual(first, second)
        // AppState orders by score alone (`all.sort { $0.score > $1.score }`), so a
        // tie between an app row and a non-app row is decided by source order, not
        // by kind. The ranker deliberately has no kind input; nothing to assert here.
    }
}
