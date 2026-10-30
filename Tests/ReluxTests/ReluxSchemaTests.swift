import ReluxCore
import XCTest

final class ReluxSchemaTests: XCTestCase {
    /// Verbatim copy of the ORDER BY the clipboard history view issues (`ClipboardStore.fetchAll`).
    private static let clipboardFetchAllSQL = """
    SELECT id, content_type, text_content, NULL, image_path, \
    image_width, image_height, image_size, source_app, \
    source_name, char_count, word_count, created_at, updated_at, pinned_at \
    FROM clipboard_history \
    ORDER BY CASE WHEN pinned_at IS NOT NULL THEN 0 ELSE 1 END, pinned_at ASC, updated_at DESC \
    LIMIT ?
    """

    /// Verbatim copy of the ORDER BY the translate history view issues (`TranslateStore.fetchAll`).
    private static let translationFetchAllSQL = """
        SELECT id, source_text, translated_text, source_lang, target_lang,
            model, created_at, updated_at, content_hash
        FROM translation_history ORDER BY COALESCE(updated_at, created_at) DESC LIMIT ?
    """

    private func makeDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try ReluxSchema.migrate(database)
        return database
    }

    private func queryPlan(_ sql: String, database: SQLiteDatabase) throws -> [String] {
        let statement = try database.prepare("EXPLAIN QUERY PLAN \(sql)")
        var details: [String] = []
        while try statement.step() {
            details.append(statement.columnText(3) ?? "")
        }
        return details
    }

    private func columnNames(of table: String, database: SQLiteDatabase) throws -> [String] {
        let statement = try database.prepare("PRAGMA table_info(\(table))")
        var names: [String] = []
        while try statement.step() {
            if let name = statement.columnText(1) {
                names.append(name)
            }
        }
        return names
    }

    private func isNullable(_ column: String, in table: String, database: SQLiteDatabase) throws -> Bool? {
        let statement = try database.prepare("PRAGMA table_info(\(table))")
        while try statement.step() {
            if statement.columnText(1) == column {
                return statement.columnInt(3) == 0
            }
        }
        return nil
    }

    // MARK: - Versioning

    func testMigrationRecordsVersion() throws {
        let database = try makeDatabase()
        XCTAssertEqual(try database.userVersion, ReluxSchema.version)
        XCTAssertEqual(ReluxSchema.version, 1)
    }

    func testMigrationIsIdempotent() throws {
        let database = try makeDatabase()
        try ReluxSchema.migrate(database)
        try ReluxSchema.migrate(database)

        XCTAssertEqual(try database.userVersion, ReluxSchema.version)
        let columns = try columnNames(of: "clipboard_history", database: database)
        XCTAssertEqual(columns.filter { $0 == "updated_at" }.count, 1)
        XCTAssertEqual(columns.filter { $0 == "pinned_at" }.count, 1)
    }

    // MARK: - Migrating a pre-existing database

    /// Databases created before this refactor have `user_version` 0 but already carry some of
    /// the columns migration 1 introduces, so the ALTER steps have to be skipped, not duplicated.
    func testExistingColumnsAreNotRewritten() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
            CREATE TABLE clipboard_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT, content_type TEXT NOT NULL, text_content TEXT,
                raw_data BLOB, image_path TEXT, image_width INTEGER, image_height INTEGER,
                image_size INTEGER, source_app TEXT, source_name TEXT, char_count INTEGER,
                word_count INTEGER, created_at REAL NOT NULL, updated_at REAL, pinned_at REAL
            )
        """)
        try database.execute("INSERT INTO clipboard_history (content_type, created_at, updated_at, pinned_at) " +
            "VALUES ('text', 1000, 2000, 3000)")

        try ReluxSchema.migrate(database)

        let statement = try database.prepare("SELECT created_at, updated_at, pinned_at FROM clipboard_history")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnDouble(1), 2000, "backfill must not touch an existing updated_at")
        XCTAssertEqual(statement.columnDouble(2), 3000)
        XCTAssertEqual(try database.userVersion, 1)
    }

    func testOldSchemaGetsMissingColumnsAndBackfill() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
            CREATE TABLE clipboard_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT, content_type TEXT NOT NULL, text_content TEXT,
                raw_data BLOB, image_path TEXT, image_width INTEGER, image_height INTEGER,
                image_size INTEGER, source_app TEXT, source_name TEXT, char_count INTEGER,
                word_count INTEGER, created_at REAL NOT NULL
            )
        """)
        try database.execute("INSERT INTO clipboard_history (content_type, created_at) VALUES ('text', 1000)")

        try ReluxSchema.migrate(database)

        let columns = try columnNames(of: "clipboard_history", database: database)
        XCTAssertTrue(columns.contains("updated_at"))
        XCTAssertTrue(columns.contains("pinned_at"))

        let statement = try database.prepare("SELECT updated_at, pinned_at FROM clipboard_history")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnDouble(0), 1000, "updated_at must be backfilled from created_at")
        XCTAssertTrue(statement.isNull(1), "pinned_at must stay NULL")
    }

    /// The live database declares `translation_history` with a different physical column order
    /// (`updated_at` last, added by an old ALTER) than a freshly created one. Migration must
    /// leave that table alone instead of rebuilding it.
    func testLiveShapedTranslationTableIsNotRebuilt() throws {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute("""
            CREATE TABLE translation_history (
                id INTEGER PRIMARY KEY AUTOINCREMENT, source_text TEXT NOT NULL, translated_text TEXT NOT NULL,
                source_lang TEXT, target_lang TEXT NOT NULL, model TEXT NOT NULL, created_at REAL NOT NULL,
                content_hash TEXT, updated_at REAL
            )
        """)
        try database.execute("""
            INSERT INTO translation_history (source_text, translated_text, target_lang, model, created_at, content_hash)
            VALUES ('legacy', 'legacy translated', 'ja', 'claude', 1000, 'hash')
        """)

        try ReluxSchema.migrate(database)

        XCTAssertEqual(
            try columnNames(of: "translation_history", database: database),
            ["id", "source_text", "translated_text", "source_lang", "target_lang", "model", "created_at",
             "content_hash", "updated_at"],
            "the table must not be recreated"
        )
        let statement = try database.prepare("SELECT source_text, updated_at FROM translation_history")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnText(0), "legacy")
        XCTAssertTrue(statement.isNull(1))
        XCTAssertEqual(try database.userVersion, 1)
    }

    func testTranslationUpdatedAtIsNullable() throws {
        let database = try makeDatabase()
        XCTAssertEqual(try isNullable("updated_at", in: "translation_history", database: database), true)

        let insert = try database.prepare("""
            INSERT INTO translation_history
                (source_text, translated_text, source_lang, target_lang, model, created_at, updated_at, content_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """)
        try insert.bind(1, "source")
        try insert.bind(2, "translated")
        let sourceLang: String? = nil
        try insert.bind(3, sourceLang)
        try insert.bind(4, "ja")
        try insert.bind(5, "model")
        try insert.bind(6, 1000.0)
        let updatedAt: Double? = nil
        try insert.bind(7, updatedAt)
        try insert.bind(8, "hash")
        try insert.stepToCompletion()
    }

    // MARK: - Indexes

    func testClipboardOrderIndexIsUsed() throws {
        let database = try makeDatabase()
        let insert = try database.prepare(
            "INSERT INTO clipboard_history (content_type, created_at, updated_at) VALUES (?, ?, ?)"
        )
        for index in 0 ..< 30 {
            try insert.bind(1, "text")
            try insert.bind(2, 1000.0 + Double(index))
            try insert.bind(3, 1000.0 + Double(index))
            try insert.stepToCompletion()
            try insert.reset()
        }

        let plan = try queryPlan(Self.clipboardFetchAllSQL, database: database)
        XCTAssertTrue(
            plan.contains { $0.contains("USING INDEX idx_clipboard_history_order") },
            "index not used, plan: \(plan)"
        )
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "sort not eliminated, plan: \(plan)")
    }

    func testTranslationOrderIndexIsUsed() throws {
        let database = try makeDatabase()
        let insert = try database.prepare("""
            INSERT INTO translation_history
                (source_text, translated_text, target_lang, model, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?)
        """)
        for index in 0 ..< 30 {
            try insert.bind(1, "source \(index)")
            try insert.bind(2, "translated \(index)")
            try insert.bind(3, "ja")
            try insert.bind(4, "model")
            try insert.bind(5, 1000.0 + Double(index))
            try insert.bind(6, 1000.0 + Double(index))
            try insert.stepToCompletion()
            try insert.reset()
        }

        let plan = try queryPlan(Self.translationFetchAllSQL, database: database)
        XCTAssertTrue(
            plan.contains { $0.contains("USING INDEX idx_translation_history_order") },
            "index not used, plan: \(plan)"
        )
        XCTAssertFalse(plan.contains { $0.contains("TEMP B-TREE") }, "sort not eliminated, plan: \(plan)")
    }

    /// The expression index must not change the ordering the views rely on: pinned entries
    /// first (oldest pin first), then everything else by descending update time.
    func testClipboardOrderingWithIndexMatchesExpectedOrder() throws {
        let database = try makeDatabase()
        let insert = try database.prepare("""
            INSERT INTO clipboard_history (id, content_type, created_at, updated_at, pinned_at)
            VALUES (?, ?, ?, ?, ?)
        """)
        struct Row {
            let id: Int
            let updated: Double
            let pinned: Double?
        }
        let rows = [
            Row(id: 1, updated: 3000, pinned: nil),
            Row(id: 2, updated: 1000, pinned: 1500),
            Row(id: 3, updated: 2000, pinned: 1200),
            Row(id: 4, updated: 4000, pinned: nil),
        ]
        for row in rows {
            try insert.bind(1, row.id)
            try insert.bind(2, "text")
            try insert.bind(3, row.updated)
            try insert.bind(4, row.updated)
            try insert.bind(5, row.pinned)
            try insert.stepToCompletion()
            try insert.reset()
        }

        let statement = try database.prepare(Self.clipboardFetchAllSQL)
        try statement.bind(1, 500)
        var ids: [Int] = []
        while try statement.step() {
            ids.append(statement.columnInt(0) ?? -1)
        }
        XCTAssertEqual(ids, [3, 2, 4, 1])
    }
}
