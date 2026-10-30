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

    // MARK: - Freshly created shape

    /// The `CREATE TABLE` statements exactly as `ReluxSchema.applyInitial` declares them. A fresh
    /// install gets this shape, and it differs from the ALTER-era one in `content_hash`'s position
    /// (declared 5th, before `target_lang`), not in nullability: `updated_at` is `REAL` — nullable —
    /// in both tables, and no statement in `ReluxSchema` produces `NOT NULL`.
    private static let freshClipboardCreateTable = """
    CREATE TABLE IF NOT EXISTS clipboard_history (
        id            INTEGER PRIMARY KEY AUTOINCREMENT,
        content_type  TEXT NOT NULL,
        text_content  TEXT,
        raw_data      BLOB,
        image_path    TEXT,
        image_width   INTEGER,
        image_height  INTEGER,
        image_size    INTEGER,
        source_app    TEXT,
        source_name   TEXT,
        char_count    INTEGER,
        word_count    INTEGER,
        created_at    REAL NOT NULL,
        updated_at    REAL,
        pinned_at     REAL
    )
    """

    private static let freshTranslationCreateTable = """
    CREATE TABLE IF NOT EXISTS translation_history (
        id              INTEGER PRIMARY KEY AUTOINCREMENT,
        source_text     TEXT NOT NULL,
        translated_text TEXT NOT NULL,
        source_lang     TEXT,
        content_hash    TEXT,
        target_lang     TEXT NOT NULL,
        model           TEXT NOT NULL,
        created_at      REAL NOT NULL,
        updated_at      REAL
    )
    """

    private struct MasterRow: Equatable {
        let type: String
        let name: String
        let table: String
        let rootPage: Int
        let sql: String?
    }

    private struct TranslationRow {
        let id: Int
        let createdAt: Double
        let updatedAt: Double?
    }

    private func makeFreshShapedDatabase() throws -> SQLiteDatabase {
        let database = try SQLiteDatabase(path: ":memory:")
        try database.execute(Self.freshClipboardCreateTable)
        try database.execute(Self.freshTranslationCreateTable)
        return database
    }

    private func masterRows(_ database: SQLiteDatabase) throws -> [MasterRow] {
        let statement = try database.prepare(
            "SELECT type, name, tbl_name, rootpage, sql FROM sqlite_master ORDER BY type, name"
        )
        var rows: [MasterRow] = []
        while try statement.step() {
            rows.append(MasterRow(
                type: statement.columnText(0) ?? "",
                name: statement.columnText(1) ?? "",
                table: statement.columnText(2) ?? "",
                rootPage: statement.columnInt(3) ?? -1,
                sql: statement.columnText(4)
            ))
        }
        return rows
    }

    private func translationOrder(of database: SQLiteDatabase, rows: [TranslationRow]) throws -> [Int] {
        let insert = try database.prepare("""
        INSERT INTO translation_history
            (id, source_text, translated_text, target_lang, model, created_at, updated_at)
        VALUES (?, ?, ?, ?, ?, ?, ?)
        """)
        for row in rows {
            try insert.bind(1, row.id)
            try insert.bind(2, "source \(row.id)")
            try insert.bind(3, "translated \(row.id)")
            try insert.bind(4, "ja")
            try insert.bind(5, "model")
            try insert.bind(6, row.createdAt)
            try insert.bind(7, row.updatedAt)
            try insert.stepToCompletion()
            try insert.reset()
        }

        let select = try database.prepare(Self.translationFetchAllSQL)
        try select.bind(1, 100)
        var ids: [Int] = []
        while try select.step() {
            ids.append(select.columnInt(0) ?? -1)
        }
        return ids
    }

    /// The shape the current `CREATE TABLE` produces is only ever exercised as migration *output*
    /// by every other test. Here it is the migration *input*, which is what an upgraded-from-fresh
    /// database looks like: the tables already exist, `user_version` is 0, and nothing may be
    /// rebuilt, rewritten or backfilled.
    func testFreshCreateTableShapeIsMigratedInPlace() throws {
        let database = try makeFreshShapedDatabase()
        try database.execute("""
        INSERT INTO clipboard_history (id, content_type, created_at, updated_at, pinned_at)
        VALUES (7, 'text', 1000, 2000, NULL)
        """)
        try database.execute("""
        INSERT INTO translation_history
            (id, source_text, translated_text, source_lang, content_hash, target_lang, model,
             created_at, updated_at)
        VALUES (42, 'source', 'translated', 'en', 'hash', 'ja', 'model', 1000, 2000)
        """)

        let before = try masterRows(database)

        try ReluxSchema.migrate(database)

        XCTAssertEqual(ReluxSchema.version, 1)
        XCTAssertEqual(try database.userVersion, ReluxSchema.version)

        let after = try masterRows(database)
        // Lossless rebuild detection: a table's `rootpage` only changes when it is dropped and
        // recreated, so comparing the table rows whole (sql *and* rootpage) also catches a rebuild
        // that a `CREATE TABLE IF NOT EXISTS` would otherwise hide behind an identical schema text.
        XCTAssertEqual(
            after.filter { $0.type == "table" },
            before.filter { $0.type == "table" },
            "migration must not rebuild or rewrite either table"
        )
        XCTAssertEqual(
            Set(after.map(\.name)).subtracting(before.map(\.name)),
            ["idx_clipboard_history_order", "idx_translation_history_order"],
            "migration must add exactly the two ordering indexes"
        )
        XCTAssertEqual(
            try columnNames(of: "translation_history", database: database),
            ["id", "source_text", "translated_text", "source_lang", "content_hash", "target_lang",
             "model", "created_at", "updated_at"],
            "the fresh shape keeps content_hash in its declared position"
        )
        XCTAssertEqual(
            try isNullable("updated_at", in: "translation_history", database: database),
            true,
            "the fresh shape declares updated_at nullable, like the live database"
        )

        let clipboard = try database.prepare(
            "SELECT id, content_type, created_at, updated_at, pinned_at FROM clipboard_history"
        )
        XCTAssertTrue(try clipboard.step())
        XCTAssertEqual(clipboard.columnInt64(0), 7)
        XCTAssertEqual(clipboard.columnText(1), "text")
        XCTAssertEqual(clipboard.columnDouble(2), 1000)
        XCTAssertEqual(clipboard.columnDouble(3), 2000, "backfill must not touch an existing updated_at")
        XCTAssertTrue(clipboard.isNull(4))
        XCTAssertFalse(try clipboard.step())

        let translation = try database.prepare(
            "SELECT id, source_text, updated_at, content_hash FROM translation_history"
        )
        XCTAssertTrue(try translation.step())
        XCTAssertEqual(translation.columnInt64(0), 42)
        XCTAssertEqual(translation.columnText(1), "source")
        XCTAssertEqual(translation.columnDouble(2), 2000)
        XCTAssertEqual(translation.columnText(3), "hash")
        XCTAssertFalse(try translation.step())

        try ReluxSchema.migrate(database)
        XCTAssertEqual(try masterRows(database), after, "a second run must be a no-op")
        XCTAssertEqual(try database.userVersion, ReluxSchema.version)
    }

    /// `TranslateStore.fetchAll` orders by `COALESCE(updated_at, created_at) DESC`. Both creation
    /// paths — migration creating the tables, and the tables pre-existing in the fresh shape — must
    /// order identically, including rows whose `updated_at` is NULL.
    ///
    /// Unreachable-query note: under a `NOT NULL updated_at` column (which no current `CREATE TABLE`
    /// declares) the COALESCE could never fall back — it would degenerate to `updated_at DESC` and
    /// the NULL branch asserted below would be dead. Nullability, not column position, is what the
    /// ordering query actually depends on.
    func testTranslationOrderingIsIdenticalForBothCreatePaths() throws {
        let migrationCreated = try makeDatabase()
        let preCreated = try makeFreshShapedDatabase()
        try ReluxSchema.migrate(preCreated)

        let rows = [
            TranslationRow(id: 1, createdAt: 5000, updatedAt: nil),
            TranslationRow(id: 2, createdAt: 1000, updatedAt: 1000),
            TranslationRow(id: 3, createdAt: 2000, updatedAt: 4000),
            TranslationRow(id: 4, createdAt: 9000, updatedAt: nil),
        ]

        let expected = try translationOrder(of: migrationCreated, rows: rows)
        XCTAssertEqual(
            expected,
            [4, 1, 3, 2],
            "COALESCE must fall back to created_at for rows without an update time"
        )
        XCTAssertEqual(try translationOrder(of: preCreated, rows: rows), expected)
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
