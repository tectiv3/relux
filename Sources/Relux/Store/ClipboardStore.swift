import AppKit
import Foundation
import os
import SQLite3

private let log = Logger(subsystem: "com.relux.app", category: "clipboardstore")

// swiftformat:disable:next redundantSendable
struct ClipboardEntry: Identifiable, Sendable {
    let id: Int64
    let contentType: String
    let textContent: String?
    let rawData: Data?
    let imagePath: String?
    let imageWidth: Int?
    let imageHeight: Int?
    let imageSize: Int?
    let sourceApp: String?
    let sourceName: String?
    let charCount: Int?
    let wordCount: Int?
    let createdAt: Date
    let updatedAt: Date
}

enum ContentType {
    static let text = "text"
    static let image = "image"
    static let rtf = "rtf"
    static let html = "html"
    static let color = "color"
}

@MainActor
final class ClipboardStore {
    // swiftlint:disable:next identifier_name
    private nonisolated(unsafe) var db: OpaquePointer?
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    /// Directory for clipboard image files
    let imageDir: URL

    init() throws {
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Relux", isDirectory: true)
        imageDir = dir.appendingPathComponent("clipboard", isDirectory: true)
        try fileManager.createDirectory(at: imageDir, withIntermediateDirectories: true)

        let dbPath = dir.appendingPathComponent("relux.db").path
        guard sqlite3_open(dbPath, &db) == SQLITE_OK else {
            throw StoreError.cannotOpen
        }

        try execute("""
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
                created_at    REAL NOT NULL
            )
        """)

        // Migrate: add updated_at column if missing
        let pragmaSql = "PRAGMA table_info(clipboard_history)"
        var pragmaStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, pragmaSql, -1, &pragmaStmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(pragmaStmt) }
        var hasUpdatedAt = false
        while sqlite3_step(pragmaStmt) == SQLITE_ROW {
            if let name = sqlite3_column_text(pragmaStmt, 1) {
                if String(cString: name) == "updated_at" {
                    hasUpdatedAt = true
                    break
                }
            }
        }
        if !hasUpdatedAt {
            try execute("BEGIN")
            try execute("ALTER TABLE clipboard_history ADD COLUMN updated_at REAL")
            try execute("UPDATE clipboard_history SET updated_at = created_at")
            try execute("COMMIT")
        }
    }

    deinit {
        sqlite3_close(db)
    }

    // MARK: - Insert

    func insert(
        contentType: String,
        textContent: String?,
        rawData: Data?,
        imagePath: String?,
        imageWidth: Int?,
        imageHeight: Int?,
        imageSize: Int?,
        sourceApp: String?,
        sourceName: String?
    ) throws {
        let charCount = textContent?.count
        let wordCount = textContent?.split(whereSeparator: { $0.isWhitespace || $0.isNewline }).count

        let sql = """
            INSERT INTO clipboard_history
                (content_type, text_content, raw_data, image_path, image_width, image_height, image_size,
                 source_app, source_name, char_count, word_count, created_at, updated_at)
            VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_text(stmt, 1, contentType, -1, Self.transient)
        bindOptionalText(stmt, 2, textContent)
        if let rawData {
            rawData.withUnsafeBytes { ptr in
                sqlite3_bind_blob(stmt, 3, ptr.baseAddress, Int32(rawData.count), Self.transient)
            }
        } else {
            sqlite3_bind_null(stmt, 3)
        }
        bindOptionalText(stmt, 4, imagePath)
        bindOptionalInt(stmt, 5, imageWidth)
        bindOptionalInt(stmt, 6, imageHeight)
        bindOptionalInt(stmt, 7, imageSize)
        bindOptionalText(stmt, 8, sourceApp)
        bindOptionalText(stmt, 9, sourceName)
        bindOptionalInt(stmt, 10, charCount)
        bindOptionalInt(stmt, 11, wordCount)
        let now = Date().timeIntervalSince1970
        sqlite3_bind_double(stmt, 12, now)
        sqlite3_bind_double(stmt, 13, now)

        guard sqlite3_step(stmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    // MARK: - Query

    func fetchRawData(id: Int64) -> Data? {
        let sql = "SELECT raw_data FROM clipboard_history WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        guard let ptr = sqlite3_column_blob(stmt, 0) else { return nil }
        let size = Int(sqlite3_column_bytes(stmt, 0))
        return Data(bytes: ptr, count: size)
    }

    func fetchAll(limit: Int = 500) -> [ClipboardEntry] {
        let sql = """
        SELECT id, content_type, text_content, NULL, image_path, \
        image_width, image_height, image_size, source_app, \
        source_name, char_count, word_count, created_at, updated_at \
        FROM clipboard_history ORDER BY updated_at DESC LIMIT ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
        defer { sqlite3_finalize(stmt) }

        sqlite3_bind_int(stmt, 1, Int32(limit))

        var entries: [ClipboardEntry] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            entries.append(readRow(stmt))
        }
        return entries
    }

    /// Check if the most recent entry has the same text content (dedup)
    func isDuplicate(textContent: String) -> Bool {
        let sql = "SELECT text_content FROM clipboard_history ORDER BY updated_at DESC LIMIT 1"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return false }
        defer { sqlite3_finalize(stmt) }

        guard sqlite3_step(stmt) == SQLITE_ROW else { return false }
        guard let ptr = sqlite3_column_text(stmt, 0) else { return false }
        return String(cString: ptr) == textContent
    }

    func bumpTimestamp(id: Int64) {
        let sql = "UPDATE clipboard_history SET updated_at = ? WHERE id = ?"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.warning("bumpTimestamp: failed to prepare statement")
            return
        }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_double(stmt, 1, Date().timeIntervalSince1970)
        sqlite3_bind_int64(stmt, 2, id)
        if sqlite3_step(stmt) != SQLITE_DONE {
            log.warning("bumpTimestamp: failed to update id \(id)")
        }
    }

    // MARK: - Delete

    func delete(id: Int64) throws {
        // First get image path to clean up file
        let entry = fetchById(id: id)
        if let imagePath = entry?.imagePath {
            let fullPath = imageDir.appendingPathComponent(imagePath)
            try? FileManager.default.removeItem(at: fullPath)
        }

        let sql = "DELETE FROM clipboard_history WHERE id = ?"
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
        // Delete all image files
        let fileManager = FileManager.default
        if let files = try? fileManager.contentsOfDirectory(at: imageDir, includingPropertiesForKeys: nil) {
            for file in files {
                try? fileManager.removeItem(at: file)
            }
        }
        try execute("DELETE FROM clipboard_history")
    }

    /// Delete entries older than the given date and their associated image files
    func deleteExpired(before date: Date) throws {
        // Collect image paths first
        let sql = "SELECT image_path FROM clipboard_history WHERE created_at < ? AND image_path IS NOT NULL"
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }

        sqlite3_bind_double(stmt, 1, date.timeIntervalSince1970)

        var paths: [String] = []
        while sqlite3_step(stmt) == SQLITE_ROW {
            if let ptr = sqlite3_column_text(stmt, 0) {
                paths.append(String(cString: ptr))
            }
        }
        sqlite3_finalize(stmt)

        for path in paths {
            let fullPath = imageDir.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: fullPath)
        }

        let delSql = "DELETE FROM clipboard_history WHERE created_at < ?"
        var delStmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, delSql, -1, &delStmt, nil) == SQLITE_OK else {
            throw StoreError.query
        }
        defer { sqlite3_finalize(delStmt) }
        sqlite3_bind_double(delStmt, 1, date.timeIntervalSince1970)
        guard sqlite3_step(delStmt) == SQLITE_DONE else {
            throw StoreError.query
        }
    }

    // MARK: - Private

    private func fetchById(id: Int64) -> ClipboardEntry? {
        let sql = """
        SELECT id, content_type, text_content, raw_data, image_path, \
        image_width, image_height, image_size, source_app, \
        source_name, char_count, word_count, created_at, updated_at \
        FROM clipboard_history WHERE id = ?
        """
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
        defer { sqlite3_finalize(stmt) }
        sqlite3_bind_int64(stmt, 1, id)
        guard sqlite3_step(stmt) == SQLITE_ROW else { return nil }
        return readRow(stmt)
    }

    private func readRow(_ stmt: OpaquePointer?) -> ClipboardEntry {
        ClipboardEntry(
            id: sqlite3_column_int64(stmt, 0),
            contentType: String(cString: sqlite3_column_text(stmt, 1)),
            textContent: sqlite3_column_text(stmt, 2).map { String(cString: $0) },
            rawData: {
                guard let ptr = sqlite3_column_blob(stmt, 3) else { return nil }
                let size = Int(sqlite3_column_bytes(stmt, 3))
                return Data(bytes: ptr, count: size)
            }(),
            imagePath: sqlite3_column_text(stmt, 4).map { String(cString: $0) },
            imageWidth: sqlite3_column_type(stmt, 5) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 5)) : nil,
            imageHeight: sqlite3_column_type(stmt, 6) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 6)) : nil,
            imageSize: sqlite3_column_type(stmt, 7) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 7)) : nil,
            sourceApp: sqlite3_column_text(stmt, 8).map { String(cString: $0) },
            sourceName: sqlite3_column_text(stmt, 9).map { String(cString: $0) },
            charCount: sqlite3_column_type(stmt, 10) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 10)) : nil,
            wordCount: sqlite3_column_type(stmt, 11) != SQLITE_NULL ? Int(sqlite3_column_int(stmt, 11)) : nil,
            createdAt: Date(timeIntervalSince1970: sqlite3_column_double(stmt, 12)),
            updatedAt: Date(timeIntervalSince1970: {
                let val = sqlite3_column_double(stmt, 13)
                return val > 0 ? val : sqlite3_column_double(stmt, 12)
            }())
        )
    }

    private func bindOptionalText(_ stmt: OpaquePointer?, _ index: Int32, _ value: String?) {
        if let value {
            sqlite3_bind_text(stmt, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(stmt, index)
        }
    }

    private func bindOptionalInt(_ stmt: OpaquePointer?, _ index: Int32, _ value: Int?) {
        if let value {
            sqlite3_bind_int(stmt, index, Int32(value))
        } else {
            sqlite3_bind_null(stmt, index)
        }
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
