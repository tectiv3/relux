import Foundation
import os
import ReluxCore

private let log = Logger(subsystem: "com.relux.app", category: "translatestore")

struct TranslationEntry: Identifiable {
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
        var hashValue: UInt64 = 5381
        for byte in input.utf8 {
            hashValue = 127 &* hashValue &+ UInt64(byte)
        }
        return String(hashValue, radix: 36)
    }
}

@MainActor
final class TranslateStore {
    private let database: SQLiteDatabase

    init(db database: SQLiteDatabase) {
        self.database = database
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
        let statement = try database.prepare(sql)

        try statement.bind(1, sourceText)
        try statement.bind(2, translatedText)
        try statement.bind(3, sourceLang)
        try statement.bind(4, targetLang)
        try statement.bind(5, model)
        let now = Date().timeIntervalSince1970
        try statement.bind(6, now)
        try statement.bind(7, now)
        try statement.bind(8, hash)

        try statement.stepToCompletion()
        return database.lastInsertRowID
    }

    // MARK: - Update

    func updateTranslation(id: Int64, translatedText: String) throws {
        let sql = "UPDATE translation_history SET translated_text = ? WHERE id = ?"
        let statement = try database.prepare(sql)

        try statement.bind(1, translatedText)
        try statement.bind(2, id)

        try statement.stepToCompletion()
    }

    // MARK: - Query

    func fetchAll(limit: Int = 500) -> [TranslationEntry] {
        let sql = """
            SELECT id, source_text, translated_text, source_lang, target_lang,
                model, created_at, updated_at, content_hash
            FROM translation_history ORDER BY COALESCE(updated_at, created_at) DESC LIMIT ?
        """
        let statement: Statement
        do {
            statement = try database.prepare(sql)
        } catch {
            // Keeps the "empty history" contract for the panel (a missing table used to read as no
            // translations at all), but the cause is no longer swallowed.
            log.error("fetchAll: could not prepare the history query: \(error)")
            return []
        }

        var entries: [TranslationEntry] = []
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

    func findByHash(_ hash: String) -> TranslationEntry? {
        let sql = """
            SELECT id, source_text, translated_text, source_lang, target_lang,
                model, created_at, updated_at, content_hash
            FROM translation_history WHERE content_hash = ? AND translated_text != '' LIMIT 1
        """
        let statement: Statement
        do {
            statement = try database.prepare(sql)
        } catch {
            log.error("findByHash: could not prepare the lookup: \(error)")
            return nil
        }

        do {
            try statement.bind(1, hash)
            guard try statement.step() else { return nil }
            return readRow(statement)
        } catch {
            log.error("findByHash: lookup failed: \(error)")
            return nil
        }
    }

    /// Fire-and-forget: a failed bump only costs ordering in the history list.
    func bumpTimestamp(id: Int64) {
        let sql = "UPDATE translation_history SET updated_at = ? WHERE id = ?"
        guard let statement = try? database.prepare(sql) else {
            log.warning("bumpTimestamp: failed to prepare statement")
            return
        }
        try? statement.bind(1, Date().timeIntervalSince1970)
        try? statement.bind(2, id)
        _ = try? statement.stepToCompletion()
    }

    // MARK: - Delete

    func delete(id: Int64) throws {
        let sql = "DELETE FROM translation_history WHERE id = ?"
        let statement = try database.prepare(sql)

        try statement.bind(1, id)
        try statement.stepToCompletion()
    }

    func clearAll() throws {
        try database.execute("DELETE FROM translation_history")
    }

    // MARK: - Private

    private func readRow(_ statement: Statement) -> TranslationEntry {
        let id = statement.columnInt64(0) ?? 0
        // NOT NULL columns: a NULL here means the row is corrupt, which used to trap on
        // `String(cString:)`; the forced unwrap keeps that behaviour instead of inventing "".
        let sourceText = statement.columnText(1)!
        let translatedText = statement.columnText(2)!
        let sourceLang = statement.columnText(3)
        let targetLang = statement.columnText(4)!
        let model = statement.columnText(5)!

        let createdAt = Date(timeIntervalSince1970: statement.columnDouble(6) ?? 0)
        let updatedAt: Date = if let raw = statement.columnDouble(7) {
            Date(timeIntervalSince1970: raw)
        } else {
            createdAt
        }
        let contentHash: String = statement.columnText(8)
            ?? TranslationEntry.hash(source: sourceText, target: targetLang)

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
}
