import ReluxCore
import XCTest

/// `ClipboardStore` lives in the app target but has no AppKit/UI dependency beyond
/// `Foundation`, so it is compiled into the test bundle (see `project.yml`) and exercised
/// host-free here against the real store code and the real schema.
final class ClipboardStoreTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> (database: SQLiteDatabase, store: ClipboardStore) {
        let database = try SQLiteDatabase(path: ":memory:")
        try ReluxSchema.migrate(database)
        return try (database, ClipboardStore(db: database))
    }

    @MainActor
    private func insertText(_ text: String, into store: ClipboardStore) throws {
        try store.insert(
            contentType: ContentType.text,
            textContent: text,
            rawData: nil,
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
            imageSize: nil,
            sourceApp: nil,
            sourceName: nil
        )
    }

    @MainActor
    private func entries(in store: ClipboardStore) -> [ClipboardEntry] {
        store.fetchAll()
    }

    // MARK: - Insert / read

    @MainActor
    func testInsertRecordsTextEntry() throws {
        let (_, store) = try makeStore()
        try store.insert(
            contentType: ContentType.text,
            textContent: "hello world",
            rawData: nil,
            imagePath: nil,
            imageWidth: nil,
            imageHeight: nil,
            imageSize: nil,
            sourceApp: "Safari",
            sourceName: "Safari"
        )

        let entry = try XCTUnwrap(entries(in: store).first)
        XCTAssertEqual(entry.contentType, "text")
        XCTAssertEqual(entry.textContent, "hello world")
        XCTAssertEqual(entry.charCount, 11)
        XCTAssertEqual(entry.wordCount, 2)
        XCTAssertEqual(entry.sourceApp, "Safari")
        XCTAssertNil(entry.pinnedAt)
        XCTAssertFalse(entry.isPinned)
        XCTAssertEqual(
            entry.createdAt.timeIntervalSince1970,
            entry.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001,
            "created_at and updated_at are written from the same timestamp on insert"
        )
        XCTAssertGreaterThan(
            entry.createdAt.timeIntervalSince1970,
            1_600_000_000,
            "timestamps are stored as REAL epoch seconds, not milliseconds"
        )
    }

    @MainActor
    func testRawDataRoundTrip() throws {
        let (_, store) = try makeStore()
        let payload = Data([0x01, 0x02, 0x03, 0xFF])
        try store.insert(
            contentType: ContentType.image,
            textContent: nil,
            rawData: payload,
            imagePath: "image.png",
            imageWidth: 10,
            imageHeight: 20,
            imageSize: payload.count,
            sourceApp: nil,
            sourceName: nil
        )

        let entry = try XCTUnwrap(entries(in: store).first)
        XCTAssertEqual(entry.imageWidth, 10)
        XCTAssertEqual(entry.imageHeight, 20)
        XCTAssertEqual(entry.imageSize, 4)
        XCTAssertEqual(store.fetchRawData(id: entry.id), payload)
        XCTAssertNil(store.fetchRawData(id: 9999), "missing rows return nil, not an error")
    }

    // MARK: - Ordering

    @MainActor
    func testFetchAllOrdersPinnedFirstThenByUpdateTime() throws {
        let (database, store) = try makeStore()
        try insertText("newest", into: store)
        try insertText("oldest", into: store)
        try insertText("pinned", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 5000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 2")
        try database.execute("UPDATE clipboard_history SET updated_at = 100, pinned_at = 200 WHERE id = 3")

        XCTAssertEqual(entries(in: store).map(\.textContent), ["pinned", "newest", "oldest"])

        try database.execute("UPDATE clipboard_history SET pinned_at = 50 WHERE id = 2")
        XCTAssertEqual(
            entries(in: store).map(\.textContent),
            ["oldest", "pinned", "newest"],
            "multiple pinned rows order by pinned_at ASC"
        )
    }

    @MainActor
    func testBumpTimestampMovesEntryToTheTop() throws {
        let (database, store) = try makeStore()
        try insertText("first", into: store)
        try insertText("second", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 5000 WHERE id = 2")
        XCTAssertEqual(entries(in: store).map(\.textContent), ["second", "first"])

        store.bumpTimestamp(id: 1)
        XCTAssertEqual(entries(in: store).map(\.textContent), ["first", "second"])

        // The two error policies: bump on a missing id logs and returns instead of throwing.
        store.bumpTimestamp(id: 9999)
    }

    @MainActor
    func testPinAndUnpin() throws {
        let (database, store) = try makeStore()
        try insertText("first", into: store)
        try insertText("second", into: store)
        try database.execute("UPDATE clipboard_history SET updated_at = 1000 WHERE id = 1")
        try database.execute("UPDATE clipboard_history SET updated_at = 5000 WHERE id = 2")
        XCTAssertEqual(entries(in: store).map(\.textContent), ["second", "first"])

        store.pin(id: 1)
        let pinned = try XCTUnwrap(entries(in: store).first)
        XCTAssertEqual(pinned.id, 1)
        XCTAssertTrue(pinned.isPinned)
        XCTAssertNotNil(pinned.pinnedAt)

        store.unpin(id: 1)
        let unpinned = try XCTUnwrap(entries(in: store).last)
        XCTAssertEqual(unpinned.id, 1)
        XCTAssertFalse(unpinned.isPinned)
        XCTAssertNil(unpinned.pinnedAt)
        XCTAssertEqual(entries(in: store).map(\.textContent), ["second", "first"])

        // pin/unpin on a missing id must not throw.
        store.pin(id: 9999)
        store.unpin(id: 9999)
    }

    @MainActor
    func testIsDuplicateUsesMostRecentAndPinnedEntries() throws {
        let (_, store) = try makeStore()
        try insertText("alpha", into: store)
        XCTAssertTrue(store.isDuplicate(textContent: "alpha"))
        XCTAssertFalse(store.isDuplicate(textContent: "beta"))

        try insertText("gamma", into: store)
        let gamma = try XCTUnwrap(entries(in: store).first { $0.textContent == "gamma" })
        store.pin(id: gamma.id)
        try insertText("delta", into: store)

        XCTAssertTrue(store.isDuplicate(textContent: "gamma"), "pinned entries are matched even when not most recent")
        XCTAssertTrue(store.isDuplicate(textContent: "delta"))
        XCTAssertFalse(store.isDuplicate(textContent: "alpha"))
    }

    // MARK: - Delete / retention

    @MainActor
    func testDeleteRemovesRowAndImageFile() throws {
        let (_, store) = try makeStore()
        let fileName = "delete-\(UUID().uuidString).png"
        let fileURL = store.imageDir.appendingPathComponent(fileName)
        try Data([0x89, 0x50]).write(to: fileURL)

        try store.insert(
            contentType: ContentType.image,
            textContent: nil,
            rawData: nil,
            imagePath: fileName,
            imageWidth: 1,
            imageHeight: 1,
            imageSize: 2,
            sourceApp: nil,
            sourceName: nil
        )
        let id = try XCTUnwrap(entries(in: store).first?.id)

        try store.delete(id: id)
        XCTAssertTrue(entries(in: store).isEmpty)
        XCTAssertFalse(FileManager.default.fileExists(atPath: fileURL.path), "image file must be unlinked with the row")
    }

    @MainActor
    func testClearAllKeepsPinnedEntries() throws {
        let (_, store) = try makeStore()
        try insertText("keep", into: store)
        try insertText("drop", into: store)
        let keepID = try XCTUnwrap(entries(in: store).first { $0.textContent == "keep" }?.id)
        store.pin(id: keepID)

        try store.clearAll()
        XCTAssertEqual(entries(in: store).map(\.textContent), ["keep"])
    }

    @MainActor
    func testDeleteExpiredKeepsPinnedEntriesAndTheirImages() throws {
        let (database, store) = try makeStore()
        let expiredImage = "expired-\(UUID().uuidString).png"
        let pinnedImage = "pinned-\(UUID().uuidString).png"
        let expiredURL = store.imageDir.appendingPathComponent(expiredImage)
        let pinnedURL = store.imageDir.appendingPathComponent(pinnedImage)
        try Data([0x01]).write(to: expiredURL)
        try Data([0x02]).write(to: pinnedURL)
        // `imageDir` is the real clipboard image directory, so never leave fixtures behind.
        defer { try? FileManager.default.removeItem(at: pinnedURL) }

        try store.insert(
            contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: expiredImage,
            imageWidth: 1, imageHeight: 1, imageSize: 1, sourceApp: nil, sourceName: nil
        )
        try store.insert(
            contentType: ContentType.image, textContent: nil, rawData: nil, imagePath: pinnedImage,
            imageWidth: 1, imageHeight: 1, imageSize: 1, sourceApp: nil, sourceName: nil
        )
        try insertText("recent", into: store)

        // Everything inserted is "old" except the last row, and the second row is pinned.
        try database.execute("UPDATE clipboard_history SET created_at = 1000 WHERE id IN (1, 2)")
        store.pin(id: 2)

        try store.deleteExpired(before: Date(timeIntervalSince1970: 5000))

        XCTAssertEqual(entries(in: store).map(\.textContent), [nil, "recent"], "the pinned row must survive")
        XCTAssertEqual(entries(in: store).first?.imagePath, pinnedImage)
        XCTAssertFalse(FileManager.default.fileExists(atPath: expiredURL.path))
        XCTAssertTrue(FileManager.default.fileExists(atPath: pinnedURL.path))
    }
}
