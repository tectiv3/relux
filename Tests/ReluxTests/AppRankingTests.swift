import Foundation
import ReluxCore
import XCTest

final class AppRankingTests: XCTestCase {
    /// Pinned clock: every model call takes `now`, so the arithmetic is exact.
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func days(_ count: Double) -> TimeInterval {
        count * 86400
    }

    private func boost(
        explicitOpens: Int,
        ambientOpens: Int = 0,
        ageDays: Double,
        ambientAgeDays: Double? = nil,
        lastPick: Bool = false
    ) -> Double {
        UsageBoost.value(
            for: AppUsage(
                explicitOpens: explicitOpens,
                ambientOpens: ambientOpens,
                lastUsed: Self.now.addingTimeInterval(-Self.days(ageDays)),
                ambientLastUsed: ambientOpens > 0
                    ? Self.now.addingTimeInterval(-Self.days(ambientAgeDays ?? ageDays))
                    : nil,
                lastPick: lastPick
            ),
            now: Self.now
        )
    }

    /// Both counters are bounded, and each bounds only its own term.
    func testAmbientCannotSatiateTheOpenCapOnItsOwn() {
        XCTAssertEqual(boost(explicitOpens: 9, ageDays: 0), 180, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 10, ageDays: 0), 200, accuracy: 1e-9)
        // Ambient saturates at one explicit pick, not at the 200-point cap.
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 1, ageDays: 0), 4, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 5, ageDays: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 50, ageDays: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 500, ageDays: 0), 20, accuracy: 1e-9)
        // Ambient is added after the explicit cap, so mixed usage tops out at 200 + 20.
        XCTAssertEqual(boost(explicitOpens: 5, ambientOpens: 25, ageDays: 0), 100 + 20, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 10, ambientOpens: 500, ageDays: 0), 200 + 20, accuracy: 1e-9)
    }

    func testAmbientBonusDecaysByTheSameCurve() {
        // 10 ambient events already reach the ambient ceiling of 20.
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 50, ageDays: 30), 10, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 10, ageDays: 30), 10, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 10, ageDays: 90), 2.5, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 50, ageDays: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 50, ageDays: 60), 5, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 1, ageDays: 30), 2, accuracy: 1e-9)
    }

    // MARK: - Ambient and explicit weight interaction

    /// The review's failure case, one level up from the write site: a large stale explicit
    /// history is worth 3.1, and its ambient event today may add 4 — never the 200 the shared
    /// anchor used to mint — so an app picked last week still wins.
    func testFreshAmbientAnchorDoesNotRestoreStaleExplicitWeight() throws {
        let abandoned = AppUsage(
            explicitOpens: 139,
            ambientOpens: 1,
            lastUsed: Self.now.addingTimeInterval(-Self.days(180)),
            ambientLastUsed: Self.now
        )
        let pickedLastWeek = AppUsage(
            explicitOpens: 3,
            lastUsed: Self.now.addingTimeInterval(-Self.days(7))
        )
        XCTAssertEqual(UsageBoost.value(for: abandoned, now: Self.now), 200 * 0.015625 + 4, accuracy: 1e-9)
        XCTAssertLessThan(
            UsageBoost.value(for: abandoned, now: Self.now),
            UsageBoost.value(for: pickedLastWeek, now: Self.now)
        )

        // Same name and query, so the fuzzy term cancels and the order is the usage order.
        let stale = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", usage: abandoned, now: Self.now))
        let recent = try XCTUnwrap(
            AppRanking.score(query: "rem", name: "Reminders", usage: pickedLastWeek, now: Self.now)
        )
        XCTAssertLessThan(stale, recent)
    }

    /// No amount of background activity may out-earn two deliberate picks: ambient alone
    /// saturates at the weight of a single explicit open, at any count.
    func testAmbientOnlyAccumulationNeverOutEarnsARecentExplicitPick() throws {
        let picked = AppUsage(explicitOpens: 2, lastUsed: Self.now)
        for ambient in [1, 5, 10, 49, 50, 51, 200, 500, 5000] {
            let ambientOnly = AppUsage(ambientOpens: ambient, ambientLastUsed: Self.now)
            let value = UsageBoost.value(for: ambientOnly, now: Self.now)
            XCTAssertLessThan(value, UsageBoost.value(for: picked, now: Self.now), "\(ambient) ambient events")
            XCTAssertLessThanOrEqual(value, Double(UsageBoost.perExplicitOpen), "\(ambient) ambient events")

            // Through the ranker too: the ambient-only app must not reach the explicit one.
            let ambientRow = try XCTUnwrap(
                AppRanking.score(query: "rem", name: "Reminders", usage: ambientOnly, now: Self.now)
            )
            let pickedRow = try XCTUnwrap(
                AppRanking.score(query: "rem", name: "Reminders", usage: picked, now: Self.now)
            )
            XCTAssertLessThan(ambientRow, pickedRow, "\(ambient) ambient events")
        }
    }

    /// The fix must not zero ambient learning: it still contributes, monotonically, while it
    /// has not saturated, and it still decays on its own anchor.
    func testAmbientContributionRemainsPositiveAndMonotonic() {
        let none = boost(explicitOpens: 0, ageDays: 0)
        let one = boost(explicitOpens: 0, ambientOpens: 1, ageDays: 0)
        let four = boost(explicitOpens: 0, ambientOpens: 4, ageDays: 0)
        let pastCeiling = boost(explicitOpens: 0, ambientOpens: 500, ageDays: 0)

        XCTAssertEqual(none, 0, accuracy: 1e-9)
        XCTAssertGreaterThan(one, none)
        XCTAssertGreaterThan(four, one)
        XCTAssertGreaterThan(pastCeiling, 0)
        XCTAssertEqual(pastCeiling, 20, accuracy: 1e-9)

        // Ambient recency still matters: the same count a half-life ago is worth half.
        XCTAssertLessThan(boost(explicitOpens: 0, ambientOpens: 4, ageDays: 30), four)
        // Ambient recency is independent of the explicit anchor on the same entry.
        XCTAssertEqual(
            boost(explicitOpens: 10, ambientOpens: 4, ageDays: 90, ambientAgeDays: 0),
            200 * 0.125 + 16,
            accuracy: 1e-9
        )
    }

    func testUsageBoostCapsOpensBeforeDecay() {
        XCTAssertEqual(UsageBoost.value(for: AppUsage(explicitOpens: 0), now: Self.now), 0)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(explicitOpens: 9, lastUsed: Self.now), now: Self.now), 180)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(explicitOpens: 10, lastUsed: Self.now), now: Self.now), 200)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(explicitOpens: 50, lastUsed: Self.now), now: Self.now), 200)
        XCTAssertEqual(
            UsageBoost.value(for: AppUsage(explicitOpens: 2, lastUsed: Self.now, lastPick: true), now: Self.now),
            40 + 300
        )
        // No timestamp means no age information: nothing to decay.
        XCTAssertEqual(UsageBoost.value(for: AppUsage(explicitOpens: 50), now: Self.now), 200)
    }

    /// A saturated entry keeps the same curve whether it got there via 10 or 139 opens.
    func testSaturatedEntriesHalveEveryHalfLife() {
        for opens in [10, 139] {
            XCTAssertEqual(boost(explicitOpens: opens, ageDays: 0), 200, accuracy: 1e-9)
            XCTAssertEqual(boost(explicitOpens: opens, ageDays: 30), 100, accuracy: 1e-9)
            XCTAssertEqual(boost(explicitOpens: opens, ageDays: 60), 50, accuracy: 1e-9)
            XCTAssertEqual(boost(explicitOpens: opens, ageDays: 90), 25, accuracy: 1e-9)
        }
    }

    func testUncappedOpensDecayProportionally() {
        XCTAssertEqual(boost(explicitOpens: 5, ageDays: 0), 100, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 5, ageDays: 30), 50, accuracy: 1e-9)

        XCTAssertEqual(boost(explicitOpens: 1, ageDays: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 1, ageDays: 30), 10, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 1, ageDays: 60), 5, accuracy: 1e-9)
    }

    /// Per event an ambient observation is worth a fifth of an explicit pick, and the two
    /// terms are capped separately, so neither drowns the other.
    func testAmbientUsageIsWeightedOneFifthOfAnExplicitPick() {
        XCTAssertEqual(UsageBoost.value(for: AppUsage(ambientOpens: 1, lastUsed: Self.now), now: Self.now), 4)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(ambientOpens: 5, lastUsed: Self.now), now: Self.now), 20)
        XCTAssertEqual(UsageBoost.value(for: AppUsage(explicitOpens: 1, lastUsed: Self.now), now: Self.now), 20)
        XCTAssertEqual(
            UsageBoost.value(
                for: AppUsage(explicitOpens: 2, ambientOpens: 5, lastUsed: Self.now, ambientLastUsed: Self.now),
                now: Self.now
            ),
            40 + 20
        )
    }

    /// The old `testBothCountersSaturateTheSameCap` pinned the defect: 50 ambient events scored
    /// the same 200 as 10 explicit picks, so ambient could satiate the cap alone.
    /// Both counters still reach their own ceiling.
    func testBothCountersReachTheCapOnTheirOwn() {
        XCTAssertEqual(boost(explicitOpens: 9, ageDays: 0), 180, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 10, ageDays: 0), 200, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 5, ageDays: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 50, ageDays: 0), 20, accuracy: 1e-9)
        XCTAssertEqual(boost(explicitOpens: 0, ambientOpens: 500, ageDays: 0), 20, accuracy: 1e-9)
    }

    func testLearnedPickDoesNotDecay() {
        // Old usage loses its opens bonus but the learned pick keeps its full weight.
        XCTAssertEqual(boost(explicitOpens: 10, ageDays: 90, lastPick: true), 25 + 300, accuracy: 1e-9)
    }

    func testFutureTimestampIsTreatedAsAgeZero() {
        XCTAssertEqual(UsageBoost.value(for: AppUsage(explicitOpens: 10, lastUsed: Self.now), now: Self.now), 200)
        XCTAssertEqual(
            UsageBoost.value(
                for: AppUsage(explicitOpens: 10, lastUsed: Self.now.addingTimeInterval(Self.days(5))),
                now: Self.now
            ),
            200
        )
    }

    /// A learned pick must be worth more than the widest gap between two name tiers,
    /// otherwise learning could never override the ladder. Asserted through the ranker:
    /// the ladder alone puts Reminders first, and marking Remote Desktop as the last pick
    /// for the query must invert that order.
    func testLearnedPickFlipsTheWidestTierGap() throws {
        // Name-prefix tier (900) against word-prefix tier (700): a 200-point tier gap
        // before the length penalty, which widens it further. Neither app has usage.
        let reminders = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", now: Self.now))
        let remote = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            now: Self.now
        ))
        XCTAssertGreaterThan(reminders, remote)

        let remoteAfterPick = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(lastPick: true),
            now: Self.now
        ))
        XCTAssertGreaterThan(remoteAfterPick, reminders)
        XCTAssertEqual(remoteAfterPick - remote, Double(UsageBoost.lastPick))
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
            usage: AppUsage(explicitOpens: 2, lastUsed: Self.now, lastPick: false),
            now: Self.now
        ))
        let remoteWithoutLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(explicitOpens: 11, lastUsed: Self.now, lastPick: false),
            now: Self.now
        ))
        let remoteWithLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(explicitOpens: 11, lastUsed: Self.now, lastPick: true),
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
            usage: AppUsage(explicitOpens: 2, lastUsed: monthAgo, lastPick: false),
            now: Self.now
        ))
        let remoteWithoutLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(explicitOpens: 11, lastUsed: monthAgo, lastPick: false),
            now: Self.now
        ))
        let remoteWithLearning = try XCTUnwrap(AppRanking.score(
            query: "rem",
            name: "Microsoft Remote Desktop",
            usage: AppUsage(explicitOpens: 11, lastUsed: monthAgo, lastPick: true),
            now: Self.now
        ))

        XCTAssertEqual(reminders, 900 - 9 + 20)
        XCTAssertEqual(remoteWithoutLearning, 700 - 24 + 100)
        XCTAssertEqual(remoteWithLearning, remoteWithoutLearning + Double(UsageBoost.lastPick))
        XCTAssertGreaterThan(remoteWithLearning, reminders)
    }

    func testEqualInputsTieAndTheRankerKnowsNothingAboutItemKind() throws {
        let usage = AppUsage(explicitOpens: 2, lastUsed: Self.now)
        let first = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", usage: usage, now: Self.now))
        let second = try XCTUnwrap(AppRanking.score(query: "rem", name: "Reminders", usage: usage, now: Self.now))
        XCTAssertEqual(first, second)
        // AppState orders by score alone (`all.sort { $0.score > $1.score }`), so a
        // tie between an app row and a non-app row is decided by source order, not
        // by kind. The ranker deliberately has no kind input; nothing to assert here.
    }

    // MARK: - App display name

    func testAppDisplayNameStripsOnlyTheBundleExtension() {
        XCTAssertEqual(
            AppDisplayName.from(bundleName: "Microsoft Remote Desktop.app"),
            "Microsoft Remote Desktop"
        )
        XCTAssertEqual(AppDisplayName.from(bundleName: "Reminders.app"), "Reminders")
        XCTAssertEqual(AppDisplayName.from(bundleName: "Reminders"), "Reminders")
        XCTAssertEqual(AppDisplayName.from(bundleName: "com.apple.Safari.app"), "com.apple.Safari")
        // A bundle literally named `.app` keeps its name; there is nothing to strip.
        XCTAssertEqual(AppDisplayName.from(bundleName: ".app"), ".app")
    }

    /// The name the ranker sees is the name the row shows: `rem` against Remote Desktop is a
    /// word-prefix hit scored against 24 characters, not 28.
    func testScoredNameIsTheStrippedDisplayName() throws {
        let displayed = AppDisplayName.from(bundleName: "Microsoft Remote Desktop.app")
        let stripped = try XCTUnwrap(AppRanking.score(query: "rem", name: displayed, now: Self.now))
        XCTAssertEqual(stripped, 700 - 24)

        // Scoring the bundle name instead charges every app for 4 invisible characters.
        let withExtension = try XCTUnwrap(
            AppRanking.score(query: "rem", name: "Microsoft Remote Desktop.app", now: Self.now)
        )
        XCTAssertEqual(withExtension, 700 - 28)
    }

    /// With the extension attached no app could ever reach the exact-name tier, and any query
    /// matching `app` inside `.app` (substring tier) would surface apps whose name lacks it.
    func testExtensionHidTheExactTierAndPollutedMatches() throws {
        let exact = try XCTUnwrap(AppRanking.score(query: "Reminders", name: "Reminders", now: Self.now))
        XCTAssertEqual(exact, 1000 - 9)

        let polluted = try XCTUnwrap(
            AppRanking.score(query: "Reminders", name: "Reminders.app", now: Self.now)
        )
        XCTAssertEqual(polluted, 900 - 13)

        XCTAssertNil(FuzzyMatch.score(query: "app", name: "Reminders"))
        XCTAssertNotNil(FuzzyMatch.score(query: "app", name: "Reminders.app"))
    }
}
