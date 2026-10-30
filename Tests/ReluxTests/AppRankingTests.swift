import Foundation
import ReluxCore
import XCTest

final class AppRankingTests: XCTestCase {
    /// Pinned clock: every model call takes `now`, so the arithmetic is exact.
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func days(_ count: Double) -> TimeInterval {
        count * 86400
    }

    private func boost(opens: Int, ageDays: Double, lastPick: Bool = false) -> Double {
        UsageBoost.value(
            for: AppUsage(opens: opens, lastUsed: Self.now.addingTimeInterval(-Self.days(ageDays)), lastPick: lastPick),
            now: Self.now
        )
    }

    func testUsageBoostCapsOpensBeforeDecay() {
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 0), now: Self.now), 0)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 9, lastUsed: Self.now), now: Self.now), 180)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 10, lastUsed: Self.now), now: Self.now), 200)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 50, lastUsed: Self.now), now: Self.now), 200)
        XCTAssertEqual(
            UsageBoost.value(for: AppUsage(opens: 2, lastUsed: Self.now, lastPick: true), now: Self.now),
            40 + 300
        )
        // No timestamp means no age information: nothing to decay.
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 50), now: Self.now), 200)
    }

    /// A saturated entry keeps the same curve whether it got there via 10 or 139 opens.
    func testSaturatedEntriesHalveEveryHalfLife() {
        for opens in [10, 139] {
            XCTAssertEqual(boost(opens: opens, ageDays: 0), 200, accuracy: 1e-9)
            XCTAssertEqual(boost(opens: opens, ageDays: 30), 100, accuracy: 1e-9)
            XCTAssertEqual(boost(opens: opens, ageDays: 60), 50, accuracy: 1e-9)
            XCTAssertEqual(boost(opens: opens, ageDays: 90), 25, accuracy: 1e-9)
        }
    }

    func testUncappedOpensDecayProportionally() {
        XCTAssertEqual(boost(opens: 5, ageDays: 0), 100, accuracy: 1e-9)
        XCTAssertEqual(boost(opens: 5, ageDays: 30), 50, accuracy: 1e-9)

        XCTAssertEqual(boost(opens: 1, ageDays: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(boost(opens: 1, ageDays: 30), 10, accuracy: 1e-9)
        XCTAssertEqual(boost(opens: 1, ageDays: 60), 5, accuracy: 1e-9)
    }

    func testLearnedPickDoesNotDecay() {
        // Old usage loses its opens bonus but the learned pick keeps its full weight.
        XCTAssertEqual(boost(opens: 10, ageDays: 90, lastPick: true), 25 + 300, accuracy: 1e-9)
    }

    func testFutureTimestampIsTreatedAsAgeZero() {
        XCTAssertEqual(UsageBoost.value(for: AppUsage(opens: 10, lastUsed: Self.now), now: Self.now), 200)
        XCTAssertEqual(
            UsageBoost.value(
                for: AppUsage(opens: 10, lastUsed: Self.now.addingTimeInterval(Self.days(5))),
                now: Self.now
            ),
            200
        )
    }

    func testLastPickOutweighsTheTwoHundredPointTierGap() {
        // The widest gap the ladder can produce between adjacent name tiers.
        XCTAssertEqual(900 - 700, 200)
        XCTAssertGreaterThan(Double(UsageBoost.lastPick), 200)
    }

    func testNewlyDetectedAppKeepsItsFlatBonus() throws {
        let plain = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", now: Self.now))
        let fresh = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", isNew: true, now: Self.now))
        XCTAssertEqual(fresh - plain, Double(AppRanking.newAppBonus))
    }

    func testScoreIsNilWhenTheNameDoesNotMatch() {
        XCTAssertNil(AppRanking.score(query: "zzz", name: "Reminders", now: Self.now))
    }

    /// Acceptance scenario: query `rem` after learning that Remote Desktop is the
    /// last pick for `rem` and has been opened 11 times versus 2 for Reminders.
    /// Both are used right now, so decay is 1.0 and the tiers are unchanged.
    func testLearnedPickPromotesRemoteDesktopOverReminders() throws {
        let reminders = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Reminders",
            usage: AppUsage(opens: 2, lastUsed: Self.now, lastPick: false),
            now: Self.now
        ))
        let remoteWithoutLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(opens: 11, lastUsed: Self.now, lastPick: false),
            now: Self.now
        ))
        let remoteWithLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(opens: 11, lastUsed: Self.now, lastPick: true),
            now: Self.now
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

    /// Same scenario a month later: both opens bonuses halve, so the learned pick
    /// still flips the order but the total gap narrows.
    func testDecayShrinksTheUsageGapButKeepsTheLearnedOrder() throws {
        let monthAgo = Self.now.addingTimeInterval(-Self.days(30))
        let reminders = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Reminders",
            usage: AppUsage(opens: 2, lastUsed: monthAgo, lastPick: false),
            now: Self.now
        ))
        let remoteWithoutLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(opens: 11, lastUsed: monthAgo, lastPick: false),
            now: Self.now
        ))
        let remoteWithLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(opens: 11, lastUsed: monthAgo, lastPick: true),
            now: Self.now
        ))

        XCTAssertEqual(reminders, 900 - 9 + 20)
        XCTAssertEqual(remoteWithoutLearning, 700 - 24 + 100)
        XCTAssertEqual(remoteWithLearning, remoteWithoutLearning + Double(UsageBoost.lastPick))
        XCTAssertGreaterThan(remoteWithLearning, reminders)
    }

    func testEqualInputsTieAndTheRankerKnowsNothingAboutItemKind() throws {
        let usage = AppUsage(opens: 2, lastUsed: Self.now)
        let first = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", usage: usage, now: Self.now))
        let second = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", usage: usage, now: Self.now))
        XCTAssertEqual(first, second)
        // AppState orders by score alone (`all.sort { $0.score > $1.score }`), so a
        // tie between an app row and a non-app row is decided by source order, not
        // by kind. The ranker deliberately has no kind input; nothing to assert here.
    }
}
