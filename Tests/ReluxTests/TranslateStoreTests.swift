import ReluxCore
import XCTest

/// `TranslateStore` is compiled into the test bundle from the app target (see `project.yml`),
/// so these tests drive the store's real SQL rather than a copy of it.
final class TranslateStoreTests: XCTestCase {
    @MainActor
    private func makeStore() throws -> (database: SQLiteDatabase, store: TranslateStore) {
        let database = try SQLiteDatabase(path: ":memory:")
        try ReluxSchema.migrate(database)
        return (database, TranslateStore(db: database))
    }

    @MainActor
    private func insert(_ source: String, into store: TranslateStore) throws -> Int64 {
        try store.insert(
            sourceText: source,
            translatedText: "\(source) translated",
            sourceLang: "en",
            targetLang: "ja",
            model: "claude"
        )
    }

    // MARK: - Insert

    @MainActor
    func testInsertReturnsRowIdentifierAndMapsRow() throws {
        let (_, store) = try makeStore()
        let id = try insert("hello", into: store)
        XCTAssertEqual(id, 1)

        let entry = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(entry.id, id)
        XCTAssertEqual(entry.sourceText, "hello")
        XCTAssertEqual(entry.translatedText, "hello translated")
        XCTAssertEqual(entry.sourceLang, "en")
        XCTAssertEqual(entry.targetLang, "ja")
        XCTAssertEqual(entry.model, "claude")
        XCTAssertEqual(entry.contentHash, TranslationEntry.hash(source: "hello", target: "ja"))
        XCTAssertEqual(
            entry.createdAt.timeIntervalSince1970,
            entry.updatedAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
        XCTAssertGreaterThan(entry.createdAt.timeIntervalSince1970, 1_600_000_000)
    }

    /// The store uses a plain `INSERT INTO` (no `OR REPLACE` / `OR IGNORE`), so repeated
    /// translations of the same source are separate rows.
    @MainActor
    func testInsertDoesNotReplaceDuplicateContentHash() throws {
        let (_, store) = try makeStore()
        _ = try insert("same source", into: store)
        _ = try insert("same source", into: store)
        XCTAssertEqual(store.fetchAll().count, 2)
    }

    // MARK: - Query / update

    @MainActor
    func testFetchAllOrdersByCoalescedTimestamp() throws {
        let (database, store) = try makeStore()
        _ = try insert("first", into: store)
        _ = try insert("second", into: store)
        try database.execute("UPDATE translation_history SET updated_at = 1000 WHERE id = 1")
        try database.execute("UPDATE translation_history SET updated_at = 5000 WHERE id = 2")

        XCTAssertEqual(store.fetchAll().map(\.sourceText), ["second", "first"])

        // A NULL updated_at falls back to created_at in both the ORDER BY and the row mapping.
        try database.execute("UPDATE translation_history SET updated_at = NULL, created_at = 9000 WHERE id = 1")
        let entries = store.fetchAll()
        XCTAssertEqual(entries.map(\.sourceText), ["first", "second"])
        let first = try XCTUnwrap(entries.first)
        XCTAssertEqual(
            first.updatedAt.timeIntervalSince1970,
            first.createdAt.timeIntervalSince1970,
            accuracy: 0.000_001
        )
    }

    @MainActor
    func testFetchAllRespectsLimit() throws {
        let (_, store) = try makeStore()
        for index in 0 ..< 5 {
            _ = try insert("entry \(index)", into: store)
        }
        XCTAssertEqual(store.fetchAll(limit: 2).count, 2)
    }

    @MainActor
    func testFindByHashIgnoresEmptyTranslations() throws {
        let (database, store) = try makeStore()
        let id = try insert("source", into: store)
        let hash = TranslationEntry.hash(source: "source", target: "ja")
        XCTAssertEqual(store.findByHash(hash)?.id, id)

        try database.execute("UPDATE translation_history SET translated_text = '' WHERE id = \(id)")
        XCTAssertNil(store.findByHash(hash))

        XCTAssertNil(store.findByHash("missing"))
    }

    @MainActor
    func testMissingContentHashFallsBackToComputedHash() throws {
        let (database, store) = try makeStore()
        try database.execute("""
            INSERT INTO translation_history
                (source_text, translated_text, source_lang, target_lang, model, created_at, updated_at, content_hash)
            VALUES ('legacy', 'legacy translated', NULL, 'ja', 'claude', 1000, NULL, NULL)
        """)

        let entry = try XCTUnwrap(store.fetchAll().first)
        XCTAssertNil(entry.sourceLang)
        XCTAssertEqual(entry.contentHash, TranslationEntry.hash(source: "legacy", target: "ja"))
        XCTAssertEqual(entry.updatedAt.timeIntervalSince1970, 1000, accuracy: 0.000_001)
    }

    @MainActor
    func testUpdateTranslationOnlyChangesText() throws {
        let (_, store) = try makeStore()
        let id = try insert("source", into: store)
        try store.updateTranslation(id: id, translatedText: "revised")

        let entry = try XCTUnwrap(store.fetchAll().first)
        XCTAssertEqual(entry.translatedText, "revised")
        XCTAssertEqual(entry.sourceText, "source")
    }

    @MainActor
    func testBumpTimestampMovesEntryToTopAndIgnoresMissingRows() throws {
        let (database, store) = try makeStore()
        _ = try insert("first", into: store)
        _ = try insert("second", into: store)
        try database.execute("UPDATE translation_history SET updated_at = 1000 WHERE id = 1")
        try database.execute("UPDATE translation_history SET updated_at = 5000 WHERE id = 2")
        XCTAssertEqual(store.fetchAll().map(\.sourceText), ["second", "first"])

        store.bumpTimestamp(id: 1)
        XCTAssertEqual(store.fetchAll().map(\.sourceText), ["first", "second"])

        // bumpTimestamp ignores the step result: a missing row is not an error.
        store.bumpTimestamp(id: 9999)
    }

    // MARK: - Delete

    @MainActor
    func testDeleteAndClearAll() throws {
        let (_, store) = try makeStore()
        let id = try insert("first", into: store)
        _ = try insert("second", into: store)

        try store.delete(id: id)
        XCTAssertEqual(store.fetchAll().map(\.sourceText), ["second"])

        try store.clearAll()
        XCTAssertTrue(store.fetchAll().isEmpty)
    }
}
