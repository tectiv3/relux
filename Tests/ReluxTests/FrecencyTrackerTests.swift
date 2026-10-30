import Foundation
import ReluxCore
import XCTest

@MainActor
final class FrecencyTrackerTests: XCTestCase {
    private static let remindersPath = "/System/Applications/Reminders.app"
    private static let remoteDesktopPath = "/Applications/Microsoft Remote Desktop.app"

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

    private func legacyJSON(_ entries: [String: Int]) throws -> Data {
        let legacy: [String: [String: Any]] = entries.mapValues { ["count": $0, "lastUsed": 0] }
        return try JSONSerialization.data(withJSONObject: legacy)
    }

    func testLegacyMigrationSumsCountsPerAppPath() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        // Shape of the real pre-migration file: query prefix, colon, item id.
        try legacyJSON([
            "rem:app:\(Self.remoteDesktopPath)": 12,
            "remo:app:\(Self.remoteDesktopPath)": 12,
            "rem:app:\(Self.remindersPath)": 2,
            "rem:script:61CBAD42-1E8F-4B6F-84FE-756AE3B2D439": 7,
        ]).write(to: dir.appendingPathComponent("frecency.json"), options: .atomic)

        let tracker = FrecencyTracker(directory: dir)

        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath).opens, 24)
        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remindersPath).opens, 2)
        // Legacy entries carry no query->path preference.
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath).lastPick)

        // The migration rewrites the file once in the new shape.
        let migrated = try JSONSerialization.jsonObject(
            with: Data(contentsOf: dir.appendingPathComponent("frecency.json"))
        ) as? [String: Any]
        XCTAssertNotNil(migrated?["usage"])
        XCTAssertNotNil(migrated?["learned"])
    }

    func testLearnedPreferenceIsPerFoldedQuery() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir)

        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")
        tracker.recordSelection(query: "  Rem  ", item: remote)

        // Trailing whitespace and case are normalised in one place.
        XCTAssertTrue(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath).lastPick)
        XCTAssertTrue(tracker.appUsage(query: " REM ", path: Self.remoteDesktopPath).lastPick)
        XCTAssertEqual(tracker.appUsage(query: "RÉM", path: Self.remoteDesktopPath).opens, 1)
        XCTAssertFalse(tracker.appUsage(query: "remo", path: Self.remoteDesktopPath).lastPick)
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remindersPath).lastPick)

        tracker.recordSelection(query: "rem", item: appItem(path: Self.remindersPath, title: "Reminders"))
        XCTAssertTrue(tracker.appUsage(query: "rem", path: Self.remindersPath).lastPick)
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath).lastPick)
    }

    func testPersistenceRoundTrip() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let first = FrecencyTracker(directory: dir)
        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")
        first.recordSelection(query: "rem", item: remote)
        first.recordSelection(query: "remote", item: remote)

        let second = FrecencyTracker(directory: dir)

        XCTAssertEqual(second.appUsage(query: "rem", path: Self.remoteDesktopPath).opens, 2)
        XCTAssertTrue(second.appUsage(query: "remote", path: Self.remoteDesktopPath).lastPick)
        XCTAssertTrue(second.appUsage(query: "rem", path: Self.remoteDesktopPath).lastPick)
    }

    func testSaveWritesBothFilesAtomicallyAndLeavesNoTemporaryFiles() throws {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir)
        tracker.recordSelection(query: "rem", item: appItem(path: Self.remindersPath, title: "Reminders"))

        let names = try Set(FileManager.default.contentsOfDirectory(atPath: dir.path))
        XCTAssertEqual(names, ["frecency.json", "recents.json"])

        let stored = try XCTUnwrap(
            try JSONSerialization.jsonObject(with: Data(contentsOf: dir.appendingPathComponent("frecency.json")))
                as? [String: Any]
        )
        let usage = try XCTUnwrap(stored["usage"] as? [String: Int])
        let learned = try XCTUnwrap(stored["learned"] as? [String: String])
        XCTAssertEqual(usage[Self.remindersPath], 1)
        XCTAssertEqual(learned["rem"], Self.remindersPath)
    }

    func testRemoveItemDropsUsageAndLearningForThePath() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir)
        let remote = appItem(path: Self.remoteDesktopPath, title: "Microsoft Remote Desktop")
        tracker.recordSelection(query: "rem", item: remote)

        tracker.removeItem(id: "app:\(Self.remoteDesktopPath)")

        XCTAssertEqual(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath).opens, 0)
        XCTAssertFalse(tracker.appUsage(query: "rem", path: Self.remoteDesktopPath).lastPick)
    }

    func testWebSearchAndCalculatorSelectionsAreNotRecorded() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir)

        tracker.recordSelection(query: "rem", item: nonAppItem(id: "web-search-ddg", kind: .webSearch))
        tracker.recordSelection(query: "1+1", item: nonAppItem(id: "calculator-result", kind: .calculator))

        XCTAssertEqual(tracker.usageBoost(query: "rem", itemId: "web-search-ddg"), 0)
        XCTAssertEqual(tracker.usageBoost(query: "1+1", itemId: "calculator-result"), 0)
    }

    func testNonAppRowsStillLearnByItemId() {
        let dir = makeDirectory()
        defer { try? FileManager.default.removeItem(at: dir) }
        let tracker = FrecencyTracker(directory: dir)
        let script = nonAppItem(id: "script:61CBAD42-1E8F-4B6F-84FE-756AE3B2D439", kind: .script)

        tracker.recordSelection(query: "deploy", item: script)

        XCTAssertEqual(tracker.usageBoost(query: "deploy", itemId: script.id), 20 + 300)
        XCTAssertEqual(tracker.usageBoost(query: "other", itemId: script.id), 20)
    }
}
