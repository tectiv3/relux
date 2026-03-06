import Foundation
import os
import SQLite3

private let log = Logger(subsystem: "com.relux.app", category: "translatestore")

struct TranslationEntry: Identifiable, Sendable {
    let id: Int64
    let sourceText: String
    let translatedText: String
    let sourceLang: String?
    let targetLang: String
    let model: String
    let createdAt: Date
    let updatedAt: Date
    let contentHash: String

    static func hash(source: String, target: String) -> String {
        let input = "\(source)\n\(target)"
        var h: UInt64 = 5381
        for byte in input.utf8 {
            h = 127 &* h &+ UInt64(byte)
        }
        return String(h, radix: 36)
    }
}

@MainActor
final class TranslateStore {
    private nonisolated(unsafe) var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Relux", isDirectory: true)
        try fileManager.createDirectory(at: dir, withIntermediateDirectories: true)

        let dbPath = dir.appendingPathComponent("relux.db").path
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StoreError.cannotOpen
        }

        try execute("""
            CREATE TABLE IF NOT EXISTS translation_history (
                id              INTEGER PRIMARY KEY AUTOINCREMENT,
                source_text     TEXT NOT NULL,
                translated_text TEXT NOT NULL,
                source_lang     TEXT,
                content_hash    TEXT,
                target_lang     TEXT NOT NULL,
                model           TEXT NOT NULL,
                created_at      REAL NOT NULL,
                updated_at      REAL NOT NULL
            )
        """)
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Insert

    func insert(
        sourceText: String,
        translatedText: String,
        sourceLang: String?,
        targetLang: String,
        model: String
    ) throws -> Int64 {
        let hash = TranslationEntry.hash(source: sourceText, target: targetLang)
        let sql = """
            INSERT INTO translation_history
                (source_text, translated_text, source_lang, target_lang, model, created_at, updated_at, content_hash)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, sourceText, -1, Self.transient)
        sqlite3_bind_text(stmt, 2, translatedText, -1, Self.transient)
        if let sourceLang {
            sqlite3_bind_text(stmt, 3, sourceLang, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        sqlite3_bind_text(stmt, 4, targetLang, -1, Self.transient)
        sqlite3_bind_text(stmt, 5, model, -1, Self.transient)
        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(stmt, 6, now)
        sqlite3_bind_double(stmt, 7, now)
        sqlite3_bind_text(stmt, 8, hash, -1, Self.transient)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
        return sqlite3_last_insert_rowid(db)
    }

    // MARK: - Update

    func updateTranslation(id: Int64, translatedText: String) throws {
        let sql = "UPDATE translation_history SET translated_text = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, translatedText, -1, Self.transient)
        sqlite3_bind_int64(stmt, 2, id)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    // MARK: - Query

    func fetchAll(limit: Int = 500) -> [TranslationEntry] {
        let sql = """
            SELECT id, source_text, translated_text, source_lang, target_lang,
                model, created_at, updated_at, content_hash
            FROM translation_history ORDER BY COALESCE(updated_at, created_at) DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var entries: [TranslationEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(readRow(stmt))
        }
        return entries
    }

    func findByHash(_ hash: String) -> TranslationEntry? {
        let sql = """
            SELECT id, source_text, translated_text, source_lang, target_lang,
                model, created_at, updated_at, content_hash
            FROM translation_history WHERE content_hash = ? AND translated_text != '' LIMIT 1
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, hash, -1, Self.transient)

        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readRow(stmt)
    }

    func bumpTimestamp(id: Int64) {
        let sql = "UPDATE translation_history SET updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        sqlite3_step(stmt)
    }

    // MARK: - Delete

    func delete(id: Int64) throws {
        let sql = "DELETE FROM translation_history WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    func clearAll() throws {
        try execute("DELETE FROM translation_history")
    }

    // MARK: - Private

    private func readRow(_ stmt: OpaquePointer?) -> TranslationEntry {
        let id = sqlite3_column_int64(stmt, 0)
        let sourceText = String(cString: sqlite3_column_text(stmt, 1))
        let translatedText = String(cString: sqlite3_column_text(stmt, 2))
        let sourceLang: String? = sqlite3_column_type(stmt, 3) == SQLITE_NULL
            ? nil : String(cString: sqlite3_column_text(stmt, 3))
        let targetLang = String(cString: sqlite3_column_text(stmt, 4))
        let model = String(cString: sqlite3_column_text(stmt, 5))
        let createdAt = Date(timeIntervalSince1970: sqlite3_column_double(stmt, 6))
        let updatedAt: Date = sqlite3_column_type(stmt, 7) == SQLITE_NULL
            ? createdAt
            : Date(timeIntervalSince1970: sqlite3_column_double(stmt, 7))
        let contentHash: String = sqlite3_column_type(stmt, 8) == SQLITE_NULL
            ? TranslationEntry.hash(source: sourceText, target: targetLang)
            : String(cString: sqlite3_column_text(stmt, 8))

        return TranslationEntry(
            id: id,
            sourceText: sourceText,
            translatedText: translatedText,
            sourceLang: sourceLang,
            targetLang: targetLang,
            model: model,
            createdAt: createdAt,
            updatedAt: updatedAt,
            contentHash: contentHash
        )
    }

    private func execute(_ sql: String) throws {
        var errMsg: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(db, sql, nil, nil, &errMsg) == SQLITE_OK else {
            let msg = errMsg.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errMsg)
            throw StoreError.exec(msg)
        }
    }
}
