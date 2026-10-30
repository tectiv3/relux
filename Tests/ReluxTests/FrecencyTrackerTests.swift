import Foundation
import ReluxCore
import XCTest

@MainActor
final class FrecencyTrackerTests: XCTestCase {
    private static let remindersPath = "/System/Applications/Reminders.app"
    private static let remoteDesktopPath = "/Applications/Microsoft Remote Desktop.app"
    private static let scriptID = "script:61CBAD42-1E8F-4B6F-84FE-756AE3B2D439"
    private static let settingsID = "settings:x-apple.systempreferences:com.apple.GeneralSettings"

    /// Pinned clock; every tracker/model call is given an explicit instant.
    private static let now = Date(timeIntervalSinceReferenceDate: 800_000_000)

    private static func days(_ count: Double) -> TimeInterval {
        count * 86400
    }

    private struct StoredUsage: Decodable {
        var opens: Int
        var lastUsed: Date
    }

    private struct StoredPick: Decodable {
        var path: String
        var pickedAt: Date
    }

    private struct StoredState: Decodable {
        var usage: [String: StoredUsage]
        var learned: [String: StoredPick]
    }

    private func makeDirectory() -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("ReluxFrecencyTests-\(UUID().uuidString)", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    private func appItem(path: String, title: String) -> SearchItem {
        SearchItem(
            id: "app:\(path)",
            title: title,
            subtitle: (path as NSString).deletingLastPathComponent,
            icon: "app.dashed",
            kind: .app,
            meta: ["path": path, "bundleID": ""]
        )
    }

    private func nonAppItem(id: String, kind: SearchItemKind) -> SearchItem {
        SearchItem(id: id, title: id, subtitle: "", icon: "terminal", kind: kind, meta: [:])
    }

    private func storedState(in dir: URL) throws -> StoredState {
        try JSONDecoder().decode(StoredState.self, from: Data(contentsOf: dir.appendingPathComponent("frecency.json")))
    }

    /// Reference-date doubles, exactly like the live legacy file.
    private func legacyJSON(_ entries: [String: (count: Int, lastUsed: Date)]) throws -> Data {
        let payload: [String: [String: Any]] = entries.mapValues {
            ["count": $0.count, "lastUsed": $0.lastUsed.timeIntervalSinceReferenceDate]
        }
        return try JSONSerialization.data(withJSONObject: payload)
    }

    private func writeRecents(_ dir: URL, ids: [String], lastUsed: Date) throws {
        let items: [String: [String: Any]] = ids.reduce(into: [:]) { result, id in
            result[id] = [
                "id": id,
                "title": id,
                "subtitle": "",
                "icon": "app.dashed",
                "kind": "app",
                "meta": [String: String](),
                "lastUsed": lastUsed.timeIntervalSinceReferenceDate,
            ]
        }
        try JSONSerialization.data(withJSONObject: items)
            .write(to: dir.appendingPathComponent("recents.json"), options: .atomic)
    }

    // MARK: - Migration

    func testLegacyMigrationSumsCountsPerIdentityAndPreservesLatestTimestamp() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let oldest = Self.now.addingTimeInterval(-Self.days(120))
        let middle = Self.now.addingTimeInterval(-Self.days(60))
        let newest = Self.now.addingTimeInterval(-Self.days(10))

        // Shape of the real pre-migration file: query prefix, colon, item id.
        try legacyJSON([
            "rem:app:\(Self.remoteDesktopPath)": (12, newest),
            "remo:app:\(Self.remoteDesktopPath)": (12, oldest),
            "rmeo:app:\(Self.remoteDesktopPath)": (1, middle),
            "rem:app:\(Self.remindersPath)": (2, newest),
            "iclo:\(Self.settingsID)": (1, middle),
            "deploy:\(Self.scriptID)": (7, oldest),
        ]).write(to: dir.appendingPathComponent("frecency.json"), options: .atomic)
        try writeRecents(dir, ids: ["app:\(Self.remindersPath)"], lastUsed: newest)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).opens, 25)
        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remindersPath, now: Self.now).opens, 2)
        // Legacy entries carry no query -> identity preference.
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).lastPick)

        let stored = try storedState(in: dir)

        // Timestamps are preserved as reference dates, not stamped "now".
        XCTAssertEqual(stored.usage[Self.remoteDesktopPath]?.opens, 25)
        let preservedLastUsed = try XCTUnwrap(stored.usage[Self.remoteDesktopPath]?.lastUsed)
        XCTAssertEqual(
            preservedLastUsed.timeIntervalSinceReferenceDate,
            newest.timeIntervalSinceReferenceDate,
            accuracy: 1e-6
        )
        XCTAssertEqual(stored.usage[Self.remindersPath]?.opens, 2)

        // Non-app ids survive under their item id rather than being dropped.
        XCTAssertEqual(stored.usage[Self.settingsID]?.opens, 1)
        XCTAssertEqual(stored.usage[Self.scriptID]?.opens, 7)
        XCTAssertEqual(stored.usage.count, 4)
        XCTAssertEqual(stored.usage.values.reduce(0) { $0 + $1.opens }, 35)
        XCTAssertTrue(stored.learned.isEmpty)

        // A migration must not clobber recents.json before it has been read.
        XCTAssertEqual(tracker.recentItems().map(\.id), ["app:\(Self.remindersPath)"])
    }

    func testPreviousUnitShapeCarriesCountsOverAndStampsNow() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let previous: [String: Any] = [
            "usage": [Self.remoteDesktopPath: 3],
            "learned": ["rem": Self.remoteDesktopPath],
        ]
        try JSONSerialization.data(withJSONObject: previous)
            .write(to: dir.appendingPathComponent("frecency.json"), options: .atomic)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        let state = tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now)

        XCTAssertEqual(state.opens, 3)
        XCTAssertEqual(state.lastUsed, Self.now)
        XCTAssertTrue(state.lastPick)
        XCTAssertEqual(
            tracker.usageBoost(query: "rem", itemId: "app:\(Self.remoteDesktopPath)", now: Self.now),
            60 + 300
        )

        // Rewritten once in the new shape, with the only timestamp available.
        let stored = try storedState(in: dir)
        XCTAssertEqual(stored.usage[Self.remoteDesktopPath]?.opens, 3)
        let migratedLastUsed = try XCTUnwrap(stored.usage[Self.remoteDesktopPath]?.lastUsed)
        XCTAssertEqual(
            migratedLastUsed.timeIntervalSinceReferenceDate,
            Self.now.timeIntervalSinceReferenceDate,
            accuracy: 1e-6
        )
        XCTAssertEqual(stored.learned["rem"]?.path, Self.remoteDesktopPath)
        XCTAssertEqual(stored.learned["rem"]?.pickedAt, Self.now)
    }

    // MARK: - Decay

    func testReadTimeDecayHalvesTheBonusEveryThirtyDays() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        tracker.recordSelection(
            query: "deploy",
            item: nonAppItem(id: Self.scriptID, kind: .script),
            now: Self.now
        )

        for (ageDays, expected) in [(0.0, 20.0), (30.0, 10.0), (60.0, 5.0), (90.0, 2.5)] {
            XCTAssertEqual(
                tracker.usageBoost(
                    query: "other",
                    itemId: Self.scriptID,
                    now: Self.now.addingTimeInterval(Self.days(ageDays))
                ),
                expected,
                accuracy: 1e-9
            )
        }
        // The learned pick keeps its weight while it is inside the TTL.
        XCTAssertEqual(
            tracker.usageBoost(query: "deploy", itemId: Self.scriptID, now: Self.now.addingTimeInterval(Self.days(30))),
            10 + 300,
            accuracy: 1e-9
        )
    }

    // MARK: - Learned-pick TTL (inclusive at 90 days)

    func testLearnedPickExpiresAfterNinetyDays() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        tracker.recordSelection(
            query: "rem",
            item: appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop"),
            now: Self.now
        )

        func lastPick(afterDays days: Double, seconds extra: Double = 0) -> Bool {
            tracker.appUsage(
                query: "rem",
                path: Self.remoteDesktopPath,
                now: Self.now.addingTimeInterval(Self.days(days) + extra)
            ).lastPick
        }

        XCTAssertTrue(lastPick(afterDays: 89))
        // Boundary is inclusive: exactly 90 days old still counts.
        XCTAssertTrue(lastPick(afterDays: 90))
        XCTAssertFalse(lastPick(afterDays: 90, seconds: 1))
        XCTAssertFalse(lastPick(afterDays: 91))
    }

    func testExpiredLearnedPickIsPrunedOnWrite() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        tracker.recordSelection(
            query: "rem",
            item: appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop"),
            now: Self.now
        )
        let written = try storedState(in: dir)
        XCTAssertEqual(written.learned["rem"]?.path, Self.remoteDesktopPath)

        let later = Self.now.addingTimeInterval(Self.days(91))
        tracker.recordSelection(
            query: "remind",
            item: appItem(path: Self.remindersPath, title: "Reminders"),
            now: later
        )

        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: later).lastPick)
        let stored = try storedState(in: dir)
        XCTAssertNil(stored.learned["rem"])
        XCTAssertEqual(stored.learned["remind"]?.path, Self.remindersPath)
    }

    func testExpiredLearnedPickIsPrunedOnLoad() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let fresh = Self.now.addingTimeInterval(-1)
        let stale = Self.now.addingTimeInterval(-Self.days(100))
        let state: [String: Any] = [
            "usage": [Self
                .remoteDesktopPath: ["opens": 2, "lastUsed": fresh.timeIntervalSinceReferenceDate] as [String: Any]],
            "learned": [
                "rem": ["path": Self.remoteDesktopPath,
                        "pickedAt": fresh.timeIntervalSinceReferenceDate] as [String: Any],
                "remx": ["path": Self.remoteDesktopPath,
                         "pickedAt": stale.timeIntervalSinceReferenceDate] as [String: Any],
            ],
        ]
        try JSONSerialization.data(withJSONObject: state)
            .write(to: dir.appendingPathComponent("frecency.json"), options: .atomic)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        XCTAssertFalse(tracker.appUsage(query: "remx", path: Self.remoteDesktopPath, now: Self.now).lastPick)
        let stored = try storedState(in: dir)
        XCTAssertEqual(stored.learned.keys.sorted(), ["rem"])
    }

    // MARK: - Recording and persistence

    func testLearnedPreferenceIsPerFoldedQuery() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")
        tracker.recordSelection(query: "  Rem  ", item: remote, now: Self.now)

        // Trailing whitespace and case are normalised in one place.
        XCTAssertTrue(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).lastPick)
        XCTAssertTrue(tracker.appUsage(query: " REM ", path: Self.remoteDesktopPath, now: Self.now).lastPick)
        XCTAssertEqual(tracker.appUsage(query: "RÉM", path: Self.remoteDesktopPath, now: Self.now).opens, 1)
        XCTAssertFalse(tracker.appUsage(query: "remo", path: Self.remoteDesktopPath, now: Self.now).lastPick)
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remindersPath, now: Self.now).lastPick)

        tracker.recordSelection(
            query: "rem",
            item: appItem(path: Self.remindersPath, title: "Reminders"),
            now: Self.now
        )
        XCTAssertTrue(tracker.appUsage(query: "rem", path: Self.remindersPath, now: Self.now).lastPick)
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).lastPick)
    }

    func testPersistenceRoundTripKeepsTimestamps() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let firstUsed = Self.now.addingTimeInterval(-Self.days(45))
        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")

        let first = FrecencyTracker(directory: dir, now: firstUsed)
        first.recordSelection(query: "rem", item: remote, now: firstUsed)
        first.recordSelection(query: "remote", item: remote, now: firstUsed)

        let second = FrecencyTracker(directory: dir, now: Self.now)

        let state = second.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now)
        XCTAssertEqual(state.opens, 2)
        XCTAssertEqual(state.lastUsed, firstUsed)
        XCTAssertTrue(second.appUsage(query: "remote", path: Self.remoteDesktopPath, now: Self.now).lastPick)
        XCTAssertTrue(second.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).lastPick)
        // 2 opens * 20 = 40, decayed by the 45 days since the last use.
        XCTAssertEqual(
            second.usageBoost(query: "x", itemId: "app:\(Self.remoteDesktopPath)", now: Self.now),
            40 * pow(0.5, 1.5),
            accuracy: 1e-9
        )

        let stored = try storedState(in: dir)
        XCTAssertEqual(stored.usage[Self.remoteDesktopPath]?.opens, 2)
        let roundTrippedLastUsed = try XCTUnwrap(stored.usage[Self.remoteDesktopPath]?.lastUsed)
        XCTAssertEqual(
            roundTrippedLastUsed.timeIntervalSinceReferenceDate,
            firstUsed.timeIntervalSinceReferenceDate,
            accuracy: 1e-6
        )
        XCTAssertEqual(stored.learned["rem"]?.pickedAt, firstUsed)
        XCTAssertEqual(stored.learned["remote"]?.pickedAt, firstUsed)
    }

    func testSaveWritesBothFilesAtomicallyAndLeavesNoTemporaryFiles() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        tracker.recordSelection(
            query: "rem",
            item: appItem(path: Self.remindersPath, title: "Reminders"),
            now: Self.now
        )

        let names = try Set(FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["frecency.json", "recents.json"])

        let stored = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("frecency.json")))
                as? [String: Any]
        )
        let usage = try XCTUnwrap(stored["usage"] as? [String: [String: Any]])
        XCTAssertEqual(usage[Self.remindersPath]?["opens"] as? Int, 1)
        let storedLastUsed = try XCTUnwrap(usage[Self.remindersPath]?["lastUsed"] as? Double)
        XCTAssertEqual(storedLastUsed, Self.now.timeIntervalSinceReferenceDate, accuracy: 1e-6)
        let learned = try XCTUnwrap(stored["learned"] as? [String: [String: Any]])
        XCTAssertEqual(learned["rem"]?["path"] as? String, Self.remindersPath)
    }

    func testRemoveItemDropsUsageAndLearningForThePath() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")
        tracker.recordSelection(query: "rem", item: remote, now: Self.now)

        tracker.removeItem(id: "app:\(Self.remoteDesktopPath)", now: Self.now)

        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).opens, 0)
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).lastPick)
    }

    func testWebSearchAndCalculatorSelectionsAreNotRecorded() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        tracker.recordSelection(
            query: "rem",
            item: nonAppItem(id: "web-search-ddg", kind: .webSearch),
            now: Self.now
        )
        tracker.recordSelection(
            query: "1+1",
            item: nonAppItem(id: "calculator-result", kind: .calculator),
            now: Self.now
        )

        XCTAssertEqual(tracker.usageBoost(query: "rem", itemId: "web-search-ddg", now: Self.now), 0)
        XCTAssertEqual(tracker.usageBoost(query: "1+1", itemId: "calculator-result", now: Self.now), 0)
    }

    func testNonAppRowsStillLearnByItemId() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        let script = nonAppItem(id: Self.scriptID, kind: .script)

        tracker.recordSelection(query: "deploy", item: script, now: Self.now)

        XCTAssertEqual(tracker.usageBoost(query: "deploy", itemId: script.id, now: Self.now), 20 + 300)
        XCTAssertEqual(tracker.usageBoost(query: "other", itemId: script.id, now: Self.now), 20)
    }
}
