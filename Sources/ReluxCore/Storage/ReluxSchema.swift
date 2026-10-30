import Foundation

/// Schema definition and migrations for `relux.db`.
///
/// Versioning is driven by `PRAGMA user_version`. Migration 1 is written to be idempotent
/// against databases created by older builds: an existing column is detected through
/// `PRAGMA table_info` and its `ALTER TABLE` is skipped, because databases in the wild
/// already carry some of the columns this migration introduces while still reporting
/// version 0.
public enum ReluxSchema {
    public static let version = 2

    public static func migrate(_ database: SQLiteDatabase) throws {
        try database.migrate(to: version) { version, database in
            switch version {
            case 1: try applyInitial(database)
            case 2: try applyClipboardFTS(database)
            default: throw StoreError.exec("no migration defined for schema version \(version)")
            }
        }
    }

    /// External-content FTS5 index over `clipboard_history.text_content`, so clipboard search
    /// covers the whole retention window instead of the 500 rows the panel loads.
    ///
    /// `content=` keeps the text out of the index: the FTS table stores only the inverted index
    /// and reads column values back from `clipboard_history`. SQLite does not maintain that for
    /// external content, so all three triggers are required — and the delete/update cases must
    /// replay the *old* row through the special `'delete'` command, otherwise rows that are gone
    /// leave their tokens behind and search returns ids that no longer exist.
    private static func applyClipboardFTS(_ database: SQLiteDatabase) throws {
        try database.execute("""
            CREATE VIRTUAL TABLE IF NOT EXISTS clipboard_fts USING fts5(
                text_content,
                content='clipboard_history',
                content_rowid='id',
                tokenize='unicode61 remove_diacritics 2'
            )
        """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS clipboard_fts_ai AFTER INSERT ON clipboard_history BEGIN
                INSERT INTO clipboard_fts(rowid, text_content) VALUES (new.id, new.text_content);
            END
        """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS clipboard_fts_ad AFTER DELETE ON clipboard_history BEGIN
                INSERT INTO clipboard_fts(clipboard_fts, rowid, text_content)
                VALUES ('delete', old.id, old.text_content);
            END
        """)
        try database.execute("""
            CREATE TRIGGER IF NOT EXISTS clipboard_fts_au AFTER UPDATE ON clipboard_history BEGIN
                INSERT INTO clipboard_fts(clipboard_fts, rowid, text_content)
                VALUES ('delete', old.id, old.text_content);
                INSERT INTO clipboard_fts(rowid, text_content) VALUES (new.id, new.text_content);
            END
        """)
        // A virtual table created on a database that already holds rows starts empty, and the
        // triggers only see writes from here on: 'rebuild' indexes the existing 5k-odd rows.
        // It is a full re-index, so running it twice is harmless.
        try database.execute("INSERT INTO clipboard_fts(clipboard_fts) VALUES('rebuild')")
    }

    private static func applyInitial(_ database: SQLiteDatabase) throws {
        try database.execute("""
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
        """)

        if try addColumn("updated_at", definition: "REAL", to: "clipboard_history", database: database) {
            try database.execute("UPDATE clipboard_history SET updated_at = created_at")
        }
        _ = try addColumn("pinned_at", definition: "REAL", to: "clipboard_history", database: database)

        // `updated_at` is nullable here even though older builds declared it NOT NULL: the live
        // database already has the nullable form, and rebuilding the table to match the old
        // declaration would be a data migration with no behavioural gain.
        try database.execute("""
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
        """)

        if try addColumn("updated_at", definition: "REAL", to: "translation_history", database: database) {
            try database.execute("UPDATE translation_history SET updated_at = created_at")
        }
        _ = try addColumn("content_hash", definition: "TEXT", to: "translation_history", database: database)

        // Expression indexes matching the two history views' ORDER BY clauses. Both are used by
        // the planner (asserted with EXPLAIN QUERY PLAN in SQLiteDatabaseTests); they remove the
        // temp B-tree sort that these queries otherwise need.
        try database.execute("""
            CREATE INDEX IF NOT EXISTS idx_clipboard_history_order
                ON clipboard_history (CASE WHEN pinned_at IS NOT NULL THEN 0 ELSE 1 END, pinned_at, updated_at DESC)
        """)
        try database.execute("""
            CREATE INDEX IF NOT EXISTS idx_translation_history_order
                ON translation_history (COALESCE(updated_at, created_at) DESC)
        """)
    }

    /// Returns `true` when the column had to be added.
    @discardableResult
    private static func addColumn(
        _ column: String,
        definition: String,
        to table: String,
        database: SQLiteDatabase
    ) throws -> Bool {
        // The PRAGMA statement must be finished before the ALTER runs on the same connection.
        let existing = try columns(of: table, database: database)
        guard !existing.contains(column) else { return false }
        try database.execute("ALTER TABLE \(table) ADD COLUMN \(column) \(definition)")
        return true
    }

    private static func columns(of table: String, database: SQLiteDatabase) throws -> [String] {
        let statement = try database.prepare("PRAGMA table_info(\(table))")
        var names: [String] = []
        while try statement.step() {
            if let name = statement.columnText(1) {
                names.append(name)
            }
        }
        return names
    }
}
