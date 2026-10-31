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
        var explicitOpens: Int
        var ambientOpens: Int
        var lastUsed: Date
        var ambientLastUsed: Date?
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

    /// One hand-written `recents.json` snapshot, including the fields the app-kind
    /// title normalisation has to respect.
    private struct RecentSeed {
        var id: String
        var title: String
        var kind: String
        var age: TimeInterval = 0
    }

    @discardableResult
    private func writeRecents(_ dir: URL, seeds: [RecentSeed]) throws -> Data {
        let entries: [String: [String: Any]] = seeds.reduce(into: [:]) { result, seed in
            result[seed.id] = [
                "id": seed.id,
                "title": seed.title,
                "subtitle": "",
                "icon": "app.dashed",
                "kind": seed.kind,
                "meta": [String: String](),
                "lastUsed": Self.now.addingTimeInterval(-seed.age).timeIntervalSinceReferenceDate,
            ]
        }
        let data = try JSONSerialization.data(withJSONObject: entries, options: [.sortedKeys])
        try data.write(to: dir.appendingPathComponent("recents.json"), options: .atomic)
        return data
    }

    private func recentTitles(in dir: URL, limit: Int) -> [String] {
        FrecencyTracker(directory: dir, now: Self.now).recentItems(limit: limit).map(\.title)
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

        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).explicitOpens, 25)
        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remindersPath, now: Self.now).explicitOpens, 2)
        // Legacy entries carry no query -> identity preference.
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).lastPick)

        let stored = try storedState(in: dir)

        // Timestamps are preserved as reference dates, not stamped "now".
        XCTAssertEqual(stored.usage[Self.remoteDesktopPath]?.explicitOpens, 25)
        let preservedLastUsed = try XCTUnwrap(stored.usage[Self.remoteDesktopPath]?.lastUsed)
        XCTAssertEqual(
            preservedLastUsed.timeIntervalSinceReferenceDate,
            newest.timeIntervalSinceReferenceDate,
            accuracy: 1e-6
        )
        XCTAssertEqual(stored.usage[Self.remindersPath]?.explicitOpens, 2)

        // Non-app ids survive under their item id rather than being dropped.
        XCTAssertEqual(stored.usage[Self.settingsID]?.explicitOpens, 1)
        XCTAssertEqual(stored.usage[Self.scriptID]?.explicitOpens, 7)
        XCTAssertEqual(stored.usage.count, 4)
        XCTAssertEqual(stored.usage.values.reduce(0) { $0 + $1.explicitOpens }, 35)
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

        XCTAssertEqual(state.explicitOpens, 3)
        XCTAssertEqual(state.lastUsed, Self.now)
        XCTAssertTrue(state.lastPick)
        XCTAssertEqual(
            tracker.usageBoost(query: "rem", itemId: "app:\(Self.remoteDesktopPath)", now: Self.now),
            60 + 300
        )

        // Rewritten once in the new shape, with the only timestamp available.
        let stored = try storedState(in: dir)
        XCTAssertEqual(stored.usage[Self.remoteDesktopPath]?.explicitOpens, 3)
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
        XCTAssertEqual(tracker.appUsage(query: "RÉM", path: Self.remoteDesktopPath, now: Self.now).explicitOpens, 1)
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
        XCTAssertEqual(state.explicitOpens, 2)
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
        XCTAssertEqual(stored.usage[Self.remoteDesktopPath]?.explicitOpens, 2)
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
        XCTAssertEqual(usage[Self.remindersPath]?["explicitOpens"] as? Int, 1)
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

        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).explicitOpens, 0)
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

    // MARK: - Unreadable stores

    /// The reported data-loss path: an undecodable `frecency.json` decoded to nothing, so `usage`
    /// and `learned` stayed empty, and the next `recordSelection` rewrote the file with that empty
    /// state. The old bytes are the only copy of the user's ranking history.
    func testUndecodableFrecencyFileIsNotOverwritten() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("frecency.json")

        // Valid JSON, no known shape: `opens` is a string and `lastUsed` is missing, so neither the
        // current schema nor either migration shape decodes it.
        let corrupt = Data(
            #"{"usage":{"\/Applications\/X.app":{"opens":"many"}},"learned":{}}"#.utf8
        )
        try corrupt.write(to: path)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        // The session stays usable: it ranks from empty state rather than refusing to run.
        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).explicitOpens, 0)

        tracker.recordSelection(
            query: "rem",
            item: appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop"),
            now: Self.now
        )

        // Recording still works in memory for this session...
        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).explicitOpens, 1)
        XCTAssertEqual(tracker.recentItems().map(\.id), ["app:\(Self.remoteDesktopPath)"])
        // ...but the bytes nobody could read are left exactly as they were.
        XCTAssertEqual(try Data(contentsOf: path), corrupt)
    }

    /// Same class of bug for recents: the guard was “a read was attempted”, not “a read
    /// succeeded”, so an undecodable `recents.json` was replaced with `{}` on the next save.
    func testUndecodableRecentsFileIsNotOverwritten() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("recents.json")

        // A snapshot missing every persisted field except `id`.
        let corrupt = Data(#"{"app:\/Applications\/X.app":{"id":"app:\/Applications\/X.app"}}"#.utf8)
        try corrupt.write(to: path)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        XCTAssertTrue(tracker.recentItems().isEmpty)

        tracker.recordSelection(
            query: "gho",
            item: appItem(path: "/Applications/Ghostty.app", title: "Ghostty"),
            now: Self.now
        )

        XCTAssertEqual(try Data(contentsOf: path), corrupt, "the undecodable recents file must keep its bytes")
        // The session still shows what it recorded, so recents are not blind for the whole run.
        XCTAssertEqual(tracker.recentItems().map(\.id), ["app:/Applications/Ghostty.app"])
        // `frecency.json` was absent, so it is still maintained as usual.
        XCTAssertEqual(try storedState(in: dir).usage["/Applications/Ghostty.app"]?.explicitOpens, 1)
    }

    /// The partially valid case: one bad entry fails the whole-file decode. Salvaging the readable
    /// entries and writing them back would silently drop the rest, so the file is preserved.
    func testPartiallyValidFrecencyFileIsPreserved() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("frecency.json")
        // Two entries of the pre-ambient schema, one of which has a non-numeric `opens`.
        let payload: [String: Any] = [
            "usage": [
                "/Applications/Good.app": ["opens": 4, "lastUsed": Self.now.timeIntervalSinceReferenceDate],
                "/Applications/Bad.app": ["opens": "many", "lastUsed": Self.now.timeIntervalSinceReferenceDate],
            ],
            "learned": [String: String](),
        ]
        let corrupt = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        try corrupt.write(to: path)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        XCTAssertEqual(tracker.appUsage(query: "rem", path: "/Applications/Good.app", now: Self.now).explicitOpens, 0)

        tracker.recordSelection(
            query: "gho",
            item: appItem(path: "/Applications/Ghostty.app", title: "Ghostty"),
            now: Self.now
        )

        XCTAssertEqual(try Data(contentsOf: path), corrupt, "no partial salvage is written back")
    }

    // MARK: - Recents display name

    func testStoredAppRecentsAreShownWithoutTheBundleExtension() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Shape of the live pre-normalisation file: Spotlight's display name.
        try writeRecents(dir, seeds: [
            .init(id: "app:\(Self.remoteDesktopPath)", title: "Microsoft Remote Desktop.app", kind: "app"),
            .init(id: "app:/Applications/Ghostty.app", title: "Ghostty.APP", kind: "app", age: 60),
            .init(id: "app:\(Self.remindersPath)", title: "Reminders", kind: "app", age: 120),
        ])

        // Case-insensitive suffix, and an already-stripped title passes through.
        XCTAssertEqual(
            recentTitles(in: dir, limit: 8),
            ["Microsoft Remote Desktop", "Ghostty", "Reminders"]
        )
    }

    func testStoredNonAppRecentsKeepATitleThatEndsInBundleExtension() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        try writeRecents(dir, seeds: [
            // A script legitimately named `deploy.app` must not be renamed.
            .init(id: Self.scriptID, title: "deploy.app", kind: "script"),
            .init(id: Self.settingsID, title: "Wi-Fi.app", kind: "systemSettings", age: 60),
            // Defensive: a snapshot whose kind says app but whose id is not
            // app-shaped has no path to corroborate it, so it is left alone.
            .init(id: "legacy-unscoped", title: "Odd.app", kind: "app", age: 120),
        ])

        XCTAssertEqual(recentTitles(in: dir, limit: 8), ["deploy.app", "Wi-Fi.app", "Odd.app"])
    }

    func testReadingRecentsDoesNotRewriteTheStoredFile() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let original = try writeRecents(dir, seeds: [
            .init(id: "app:\(Self.remoteDesktopPath)", title: "Microsoft Remote Desktop.app", kind: "app"),
        ])
        let path = dir.appendingPathComponent("recents.json")
        let mtimeBefore = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        XCTAssertNotNil(mtimeBefore)

        XCTAssertEqual(recentTitles(in: dir, limit: 8), ["Microsoft Remote Desktop"])

        // Read-time normalisation, not a migration: the file is left byte-identical.
        XCTAssertEqual(try Data(contentsOf: path), original)
        let mtimeAfter = try FileManager.default.attributesOfItem(atPath: path.path)[.modificationDate] as? Date
        XCTAssertEqual(mtimeAfter, mtimeBefore)
    }

    func testRecordingAnAppSelectionStoresTheStrippedTitle() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        // The scan path now strips the extension, but the tracker must not depend
        // on its caller for the snapshot it persists.
        tracker.recordSelection(
            query: "gho",
            item: appItem(path: "/Applications/Ghostty.app", title: "Ghostty.app"),
            now: Self.now
        )

        let stored = try XCTUnwrap(
            try JSONSerialization.jsonObject(
                with: Data(contentsOf: dir.appendingPathComponent("recents.json"))
            ) as? [String: [String: Any]]
        )
        XCTAssertEqual(stored["app:/Applications/Ghostty.app"]?["title"] as? String, "Ghostty")
        XCTAssertEqual(recentTitles(in: dir, limit: 8), ["Ghostty"])
    }

    // MARK: - Ambient usage

    /// The shape every entry had before ambient observation existed: `{ opens, lastUsed }`.
    /// It loads as explicit opens with no ambient, without rewriting the file for the sake
    /// of the rename.
    func testPreAmbientEntryLoadsAsExplicitOpens() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lastUsed = Self.now.addingTimeInterval(-Self.days(45))
        // Byte-for-byte the live reference: a reference-date double and a bare count.
        let payload: [String: Any] = [
            "usage": [
                Self.remoteDesktopPath: ["opens": 7, "lastUsed": lastUsed.timeIntervalSinceReferenceDate],
                Self.remindersPath: ["opens": 0, "lastUsed": lastUsed.timeIntervalSinceReferenceDate],
            ],
            "learned": [String: String](),
        ]
        let original = try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
        let path = dir.appendingPathComponent("frecency.json")
        try original.write(to: path)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        let state = tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now)

        XCTAssertEqual(state.explicitOpens, 7)
        XCTAssertEqual(state.ambientOpens, 0)
        XCTAssertEqual(state.lastUsed, lastUsed)
        // A pure load never rewrites the user's file.
        XCTAssertEqual(try Data(contentsOf: path), original)

        // 7 * 20 = 140, halved once for the 45 days.
        XCTAssertEqual(
            tracker.usageBoost(query: "rem", itemId: "app:\(Self.remoteDesktopPath)", now: Self.now),
            140 * pow(0.5, 1.5),
            accuracy: 1e-9
        )
    }

    /// A file written by the one-anchor code has ambient counts but no ambient anchor. Its
    /// `lastUsed` is the best timestamp such a file contains, so the ambient term decays on it.
    func testOneAnchorEntryAnchorsAmbientOnLastUsed() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let lastUsed = Self.now.addingTimeInterval(-Self.days(30))
        let payload: [String: Any] = [
            "usage": [
                Self.remoteDesktopPath: [
                    "explicitOpens": 2,
                    "ambientOpens": 3,
                    "lastUsed": lastUsed.timeIntervalSinceReferenceDate,
                ],
            ],
            "learned": [String: String](),
        ]
        try JSONSerialization.data(withJSONObject: payload, options: [.sortedKeys])
            .write(to: dir.appendingPathComponent("frecency.json"))

        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        let state = tracker.appUsage(query: "", path: Self.remoteDesktopPath, now: Self.now)
        XCTAssertEqual(state.explicitOpens, 2)
        XCTAssertEqual(state.ambientOpens, 3)
        // 40 explicit + 12 ambient, both halved once by the 30-day-old anchor.
        XCTAssertEqual(
            tracker.usageBoost(query: "", itemId: "app:\(Self.remoteDesktopPath)", now: Self.now),
            52 * 0.5,
            accuracy: 1e-9
        )
    }

    /// Ambient events carry no query, so they must never set or move a learned pick —
    /// otherwise a background launch would outvote the panel choice for that query.
    func testAmbientRecordNeverTouchesLearned() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        tracker.recordSelection(query: "rem", item: remote, now: Self.now)

        tracker.recordAmbient(path: Self.remindersPath, now: Self.now.addingTimeInterval(1))
        tracker.recordAmbient(path: Self.remoteDesktopPath, now: Self.now.addingTimeInterval(2))
        tracker.flush(now: Self.now.addingTimeInterval(2))

        let stored = try storedState(in: dir)
        XCTAssertEqual(stored.learned.keys.sorted(), ["rem"])
        XCTAssertEqual(stored.learned["rem"]?.path, Self.remoteDesktopPath)
        XCTAssertEqual(stored.learned["rem"]?.pickedAt, Self.now)

        // Still a live pick for the explicitly chosen app, and never a pick for the ambient one.
        XCTAssertTrue(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath, now: Self.now).lastPick)
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remindersPath, now: Self.now).lastPick)

        let reminders = tracker.appUsage(query: "rem", path: Self.remindersPath, now: Self.now)
        XCTAssertEqual(reminders.explicitOpens, 0)
        XCTAssertEqual(reminders.ambientOpens, 1)
    }

    /// The review's concrete failure: 139 explicit picks 180 days ago are worth 3.1, and one
    /// ambient launch today used to re-anchor the whole bonus at `now` and mint 204, outranking
    /// an app the user picked last week. The ambient write must not move the explicit anchor.
    func testAmbientEventDoesNotRestoreStaleExplicitWeight() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")
        let reminders = appItem(path: Self.remindersPath, title: "Reminders")
        let longAgo = Self.now.addingTimeInterval(-Self.days(180))
        let lastWeek = Self.now.addingTimeInterval(-Self.days(7))

        // No query, so no learned pick inflates either score: this is the opens bonus alone.
        for _ in 0 ..< 139 {
            tracker.recordSelection(query: "", item: remote, now: longAgo)
        }
        for _ in 0 ..< 3 {
            tracker.recordSelection(query: "", item: reminders, now: lastWeek)
        }

        let remoteID = "app:\(Self.remoteDesktopPath)"
        let remindersID = "app:\(Self.remindersPath)"
        let beforeAmbient = tracker.usageBoost(query: "", itemId: remoteID, now: Self.now)
        tracker.recordAmbient(path: Self.remoteDesktopPath, now: Self.now)
        let afterAmbient = tracker.usageBoost(query: "", itemId: remoteID, now: Self.now)
        let recentPick = tracker.usageBoost(query: "", itemId: remindersID, now: Self.now)

        // 200 capped, six half-lives old; one ambient observation adds its own 4 points.
        XCTAssertEqual(beforeAmbient, 200 * 0.015625, accuracy: 1e-9)
        XCTAssertEqual(afterAmbient - beforeAmbient, Double(UsageBoost.perAmbientOpen), accuracy: 1e-9)
        XCTAssertEqual(recentPick, 60 * pow(0.5, 7.0 / 30.0), accuracy: 1e-9)
        XCTAssertLessThan(afterAmbient, recentPick)
    }

    /// Ambient alone, read back through the tracker: no count may out-earn two deliberate picks.
    func testAmbientOnlyHistoryNeverOutEarnsARecentExplicitPick() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        let picked = appItem(path: Self.remindersPath, title: "Reminders")

        for index in 0 ..< 500 {
            tracker.recordAmbient(
                path: Self.remoteDesktopPath,
                now: Self.now.addingTimeInterval(-Double(500 - index))
            )
        }
        tracker.recordSelection(query: "", item: picked, now: Self.now)
        tracker.recordSelection(query: "", item: picked, now: Self.now)

        let ambientOnly = tracker.usageBoost(query: "", itemId: "app:\(Self.remoteDesktopPath)", now: Self.now)
        let recentPick = tracker.usageBoost(query: "", itemId: "app:\(Self.remindersPath)", now: Self.now)
        XCTAssertGreaterThan(ambientOnly, 0)
        XCTAssertLessThan(ambientOnly, recentPick)
        XCTAssertLessThanOrEqual(ambientOnly, Double(UsageBoost.ambientCap))
    }

    /// `frecency.json` is not rewritten per activation: at most one write per
    /// `ambientSaveInterval`, and `flush` is what gets the rest onto disk.
    func testAmbientWritesAreDebouncedAndFlushed() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("frecency.json")
        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        tracker.recordAmbient(path: Self.remindersPath, now: Self.now)
        XCTAssertEqual(try storedState(in: dir).usage[Self.remindersPath]?.ambientOpens, 1)
        XCTAssertEqual(
            try XCTUnwrap(try storedState(in: dir).usage[Self.remindersPath]?.lastUsed),
            Self.now
        )
        XCTAssertEqual(
            try XCTUnwrap(try storedState(in: dir).usage[Self.remindersPath]?.ambientLastUsed),
            Self.now
        )
        // Ambient observations do not create recents snapshots.
        XCTAssertFalse(FileManager.default.fileExists(atPath: dir.appendingPathComponent("recents.json").path))

        let later = Self.now.addingTimeInterval(FrecencyTracker.ambientSaveInterval / 2)
        tracker.recordAmbient(path: Self.remindersPath, now: later)
        // Inside the window: memory moved, the file did not.
        XCTAssertEqual(try storedState(in: dir).usage[Self.remindersPath]?.ambientOpens, 1)
        XCTAssertEqual(
            try XCTUnwrap(try storedState(in: dir).usage[Self.remindersPath]?.lastUsed),
            Self.now
        )
        XCTAssertEqual(
            tracker.appUsage(query: "rem", path: Self.remindersPath, now: later).ambientOpens,
            2
        )

        tracker.flush(now: later)
        XCTAssertEqual(try storedState(in: dir).usage[Self.remindersPath]?.ambientOpens, 2)
        // Ambient moves only its own anchor: the explicit anchor is still the first observation.
        XCTAssertEqual(try storedState(in: dir).usage[Self.remindersPath]?.lastUsed, Self.now)
        XCTAssertEqual(try storedState(in: dir).usage[Self.remindersPath]?.ambientLastUsed, later)
        // A full interval after the last write, the next observation writes immediately.
        let muchLater = later.addingTimeInterval(FrecencyTracker.ambientSaveInterval + 1)
        tracker.recordAmbient(path: Self.remindersPath, now: muchLater)
        XCTAssertEqual(try storedState(in: dir).usage[Self.remindersPath]?.ambientOpens, 3)
        XCTAssertEqual(try Data(contentsOf: path).count > 0, true)
    }

    /// An explicit pick flushes whatever ambient state was held back, so the file the
    /// user's next launch reads contains both.
    func testExplicitRecordFlushesPendingAmbientState() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir, now: Self.now)

        tracker.recordAmbient(path: Self.remindersPath, now: Self.now)
        let held = Self.now.addingTimeInterval(10)
        tracker.recordAmbient(path: Self.remindersPath, now: held)
        tracker.recordSelection(
            query: "gho",
            item: appItem(path: "/Applications/Ghostty.app", title: "Ghostty"),
            now: held
        )

        let stored = try storedState(in: dir)
        XCTAssertEqual(stored.usage[Self.remindersPath]?.ambientOpens, 2)
        XCTAssertEqual(stored.usage[Self.remindersPath]?.ambientLastUsed, held)
        XCTAssertEqual(stored.usage["/Applications/Ghostty.app"]?.explicitOpens, 1)
    }

    /// Migration must not turn the write guard off: an undecodable file stays untouched
    /// even when the only activity in the session is ambient.
    func testUndecodableFileSurvivesAnAmbientOnlySession() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let path = dir.appendingPathComponent("frecency.json")
        let corrupt = Data(#"{"usage":{"\/Applications\/X.app":{"explicitOpens":"many"}},"learned":{}}"#.utf8)
        try corrupt.write(to: path)

        let tracker = FrecencyTracker(directory: dir, now: Self.now)
        tracker.recordAmbient(path: Self.remindersPath, now: Self.now)
        tracker.flush(now: Self.now.addingTimeInterval(120))

        XCTAssertEqual(try Data(contentsOf: path), corrupt)
        XCTAssertEqual(
            tracker.appUsage(query: "rem", path: Self.remindersPath, now: Self.now).ambientOpens,
            1
        )
    }
}
