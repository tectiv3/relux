import AppKit
import Foundation
import os
import ReluxCore

private let log = Logger(subsystem: "com.relux.app", category: "clipboardstore")

// swiftformat:disable:next redundantSendable
struct ClipboardEntry: Identifiable, Equatable, Sendable {
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
    let pinnedAt: Date?
    var isPinned: Bool {
        pinnedAt != nil
    }
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
    private let database: SQLiteDatabase

    /// Directory for clipboard image files
    let imageDir: URL

    init(db database: SQLiteDatabase) throws {
        self.database = database
        let fileManager = FileManager.default
        let appSupport = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let dir = appSupport.appendingPathComponent("Relux", isDirectory: true)
        imageDir = dir.appendingPathComponent("clipboard", isDirectory: true)
        try fileManager.createDirectory(at: imageDir, withIntermediateDirectories: true)
    }

    // MARK: - Insert

    // swiftlint:disable:next function_parameter_count
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
        let statement = try database.prepare(sql)

        try statement.bind(1, contentType)
        try statement.bind(2, textContent)
        try statement.bind(3, rawData)
        try statement.bind(4, imagePath)
        try statement.bind(5, imageWidth)
        try statement.bind(6, imageHeight)
        try statement.bind(7, imageSize)
        try statement.bind(8, sourceApp)
        try statement.bind(9, sourceName)
        try statement.bind(10, charCount)
        try statement.bind(11, wordCount)
        let now = Date().timeIntervalSince1970
        try statement.bind(12, now)
        try statement.bind(13, now)

        try statement.stepToCompletion()
    }

    // MARK: - Query

    func fetchRawData(id: Int64) -> Data? {
        let sql = "SELECT raw_data FROM clipboard_history WHERE id = ?"
        guard let statement = try? database.prepare(sql) else { return nil }
        try? statement.bind(1, id)
        guard (try? statement.step()) == true else { return nil }
        return statement.columnBlob(0)
    }

    func fetchAll(limit: Int = 500) -> [ClipboardEntry] {
        let sql = """
        SELECT id, content_type, text_content, NULL, image_path, \
        image_width, image_height, image_size, source_app, \
        source_name, char_count, word_count, created_at, updated_at, pinned_at \
        FROM clipboard_history \
        ORDER BY CASE WHEN pinned_at IS NOT NULL THEN 0 ELSE 1 END, pinned_at ASC, updated_at DESC \
        LIMIT ?
        """
        let statement: Statement
        do {
            statement = try database.prepare(sql)
        } catch {
            // The list keeps its "no history" contract (a missing table would otherwise read as an
            // empty history with no trace), but the cause is no longer swallowed.
            log.error("fetchAll: could not prepare the history query: \(error)")
            return []
        }

        var entries: [ClipboardEntry] = []
        do {
            try statement.bind(1, limit)
            while try statement.step() {
                entries.append(readRow(statement))
            }
        } catch {
            // A read that fails mid-way still shows the rows it produced, as it did when the
            // failure was swallowed; only the silence is gone.
            log.error("fetchAll: history read stopped after \(entries.count) rows: \(error)")
        }
        return entries
    }

    /// Check if the most recent entry or any pinned entry has the same text content (dedup)
    func isDuplicate(textContent: String) -> Bool {
        // Check pinned entries first — bump updated_at if matched
        let pinnedSql = "SELECT id FROM clipboard_history WHERE pinned_at IS NOT NULL AND text_content = ? LIMIT 1"
        if let pinnedStatement = try? database.prepare(pinnedSql) {
            try? pinnedStatement.bind(1, textContent)
            if (try? pinnedStatement.step()) == true, let pinnedID = pinnedStatement.columnInt64(0) {
                bumpTimestamp(id: pinnedID)
                return true
            }
        }

        // Check most recent entry
        let sql = "SELECT text_content FROM clipboard_history WHERE pinned_at IS NULL ORDER BY updated_at DESC LIMIT 1"
        guard let statement = try? database.prepare(sql) else { return false }
        guard (try? statement.step()) == true else { return false }
        return statement.columnText(0) == textContent
    }

    func bumpTimestamp(id: Int64) {
        let sql = "UPDATE clipboard_history SET updated_at = ? WHERE id = ?"
        do {
            let statement = try database.prepare(sql)
            try statement.bind(1, Date().timeIntervalSince1970)
            try statement.bind(2, id)
            try statement.stepToCompletion()
        } catch {
            log.warning("bumpTimestamp failed for id \(id): \(error)")
        }
    }

    func pin(id: Int64) {
        let sql = "UPDATE clipboard_history SET pinned_at = ? WHERE id = ?"
        do {
            let statement = try database.prepare(sql)
            try statement.bind(1, Date().timeIntervalSince1970)
            try statement.bind(2, id)
            try statement.stepToCompletion()
        } catch {
            log.warning("pin failed for id \(id): \(error)")
        }
    }

    func unpin(id: Int64) {
        let sql = "UPDATE clipboard_history SET pinned_at = NULL WHERE id = ?"
        do {
            let statement = try database.prepare(sql)
            try statement.bind(1, id)
            try statement.stepToCompletion()
        } catch {
            log.warning("unpin failed for id \(id): \(error)")
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
        let statement = try database.prepare(sql)
        try statement.bind(1, id)
        try statement.stepToCompletion()
    }

    func clearAll() throws {
        // Delete image files for unpinned entries only
        let sql = "SELECT image_path FROM clipboard_history WHERE pinned_at IS NULL AND image_path IS NOT NULL"
        let statement = try database.prepare(sql)

        var paths: [String] = []
        while try statement.step() {
            if let path = statement.columnText(0) {
                paths.append(path)
            }
        }

        for path in paths {
            let fullPath = imageDir.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: fullPath)
        }

        try database.execute("DELETE FROM clipboard_history WHERE pinned_at IS NULL")
    }

    /// Delete entries older than the given date and their associated image files
    func deleteExpired(before date: Date) throws {
        // Collect image paths first
        let sql = """
        SELECT image_path FROM clipboard_history \
        WHERE created_at < ? AND pinned_at IS NULL AND image_path IS NOT NULL
        """
        let statement = try database.prepare(sql)
        try statement.bind(1, date.timeIntervalSince1970)

        var paths: [String] = []
        while try statement.step() {
            if let path = statement.columnText(0) {
                paths.append(path)
            }
        }

        for path in paths {
            let fullPath = imageDir.appendingPathComponent(path)
            try? FileManager.default.removeItem(at: fullPath)
        }

        let deleteSql = "DELETE FROM clipboard_history WHERE created_at < ? AND pinned_at IS NULL"
        let deleteStatement = try database.prepare(deleteSql)
        try deleteStatement.bind(1, date.timeIntervalSince1970)
        try deleteStatement.stepToCompletion()
    }

    // MARK: - Private

    private func fetchById(id: Int64) -> ClipboardEntry? {
        let sql = """
        SELECT id, content_type, text_content, raw_data, image_path, \
        image_width, image_height, image_size, source_app, \
        source_name, char_count, word_count, created_at, updated_at, pinned_at \
        FROM clipboard_history WHERE id = ?
        """
        guard let statement = try? database.prepare(sql) else { return nil }
        try? statement.bind(1, id)
        guard (try? statement.step()) == true else { return nil }
        return readRow(statement)
    }

    private func readRow(_ statement: Statement) -> ClipboardEntry {
        let createdAt = statement.columnDouble(12) ?? 0
        let updatedRaw = statement.columnDouble(13) ?? 0
        return ClipboardEntry(
            id: statement.columnInt64(0) ?? 0,
            // NOT NULL columns: a NULL here means the row is corrupt, which used to trap on
            // `String(cString:)`; the forced unwrap keeps that behaviour instead of inventing "".
            contentType: statement.columnText(1)!,
            textContent: statement.columnText(2),
            rawData: statement.columnBlob(3),
            imagePath: statement.columnText(4),
            imageWidth: intColumn(statement, 5),
            imageHeight: intColumn(statement, 6),
            imageSize: intColumn(statement, 7),
            sourceApp: statement.columnText(8),
            sourceName: statement.columnText(9),
            charCount: intColumn(statement, 10),
            wordCount: intColumn(statement, 11),
            createdAt: Date(timeIntervalSince1970: createdAt),
            updatedAt: Date(timeIntervalSince1970: updatedRaw > 0 ? updatedRaw : createdAt),
            pinnedAt: statement.columnDouble(14).map { Date(timeIntervalSince1970: $0) }
        )
    }

    /// Counts and sizes are bound as 64-bit `INTEGER`s, so they are read back the same way:
    /// `columnInt` truncates anything above `Int32.max`.
    private func intColumn(_ statement: Statement, _ index: Int32) -> Int? {
        statement.columnInt64(index).map(Int.init)
    }
}
