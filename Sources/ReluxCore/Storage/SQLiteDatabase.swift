import Foundation
import SQLite3

/// A single SQLite connection shared by every store.
///
/// The handle is owned here and nowhere else. `SQLITE_OPEN_FULLMUTEX` only makes the handle safe
/// to *call* from several threads; every store is `@MainActor`, and the type is not `Sendable`, so
/// the real contract is: main-actor-owned, transactions flat (a nested `BEGIN` fails and
/// `busy_timeout` waits out a competing *connection*, not yourself).
public final class SQLiteDatabase {
    private var handle: OpaquePointer?

    public init(path: String) throws {
        var connection: OpaquePointer?
        let flags = SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX
        guard sqlite3_open_v2(path, &connection, flags, nil) == SQLITE_OK, let connection else {
            sqlite3_close(connection)
            throw StoreError.cannotOpen
        }
        handle = connection
        do {
            // Only a competing connection (another process, another handle) can make this one busy:
            // it cannot deadlock against itself, so this is not what makes nested transactions or
            // concurrent use from several threads safe.
            try execute("PRAGMA busy_timeout=5000")
        } catch {
            sqlite3_close(connection)
            handle = nil
            throw error
        }
    }

    deinit {
        sqlite3_close(handle)
    }

    /// Runs one or more statements, ignoring any rows they produce. Mirrors the historical
    /// `sqlite3_exec` wrapper: the failure message is the one SQLite generates.
    public func execute(_ sql: String) throws {
        var errorMessage: UnsafeMutablePointer<CChar>?
        guard sqlite3_exec(handle, sql, nil, nil, &errorMessage) == SQLITE_OK else {
            let message = errorMessage.map { String(cString: $0) } ?? "unknown"
            sqlite3_free(errorMessage)
            throw StoreError.exec(message)
        }
    }

    /// `BEGIN IMMEDIATE` … `COMMIT`, rolled back when `body` throws. Not reentrant: a nested call
    /// would start a second transaction and fail, so keep transactions flat. Entrants are
    /// serialised by the callers' main-actor isolation, not by this type.
    public func transaction(_ body: () throws -> Void) throws {
        try execute("BEGIN IMMEDIATE")
        do {
            try body()
            try execute("COMMIT")
        } catch {
            try? execute("ROLLBACK")
            throw error
        }
    }

    public func prepare(_ sql: String) throws -> Statement {
        var statement: OpaquePointer?
        guard sqlite3_prepare_v2(handle, sql, -1, &statement, nil) == SQLITE_OK, let statement else {
            throw StoreError.exec(lastErrorMessage)
        }
        return Statement(database: self, handle: statement)
    }

    public var lastInsertRowID: Int64 {
        sqlite3_last_insert_rowid(handle)
    }

    public var userVersion: Int {
        get throws {
            let statement = try prepare("PRAGMA user_version")
            guard try statement.step() else { return 0 }
            return statement.columnInt(0) ?? 0
        }
    }

    /// Applies every pending migration in order, each in its own transaction, and records the
    /// version it reached in `PRAGMA user_version`.
    ///
    /// Refuses to run against a database written by a newer schema instead of guessing.
    public func migrate(to target: Int, apply: (Int, SQLiteDatabase) throws -> Void) throws {
        let current = try userVersion
        guard current <= target else {
            throw StoreError.exec("database schema version \(current) is newer than supported version \(target)")
        }
        guard current < target else { return }
        for version in (current + 1) ... target {
            try transaction {
                try apply(version, self)
                try execute("PRAGMA user_version = \(version)")
            }
        }
    }

    fileprivate var lastErrorMessage: String {
        guard let handle, let cString = sqlite3_errmsg(handle) else { return "unknown" }
        return String(cString: cString)
    }
}

/// A prepared statement. Finalized in `deinit`, so call sites never write `sqlite3_finalize`.
public final class Statement {
    private let database: SQLiteDatabase
    private var handle: OpaquePointer?

    /// Text and blob arguments are copied on bind (`SQLITE_TRANSIENT`): a Swift `String`'s
    /// buffer does not outlive the call, so `SQLITE_STATIC` would be a use-after-free.
    private static let transient = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    fileprivate init(database: SQLiteDatabase, handle: OpaquePointer) {
        self.database = database
        self.handle = handle
    }

    deinit {
        sqlite3_finalize(handle)
    }

    // MARK: - Binding

    public func bind(_ index: Int32, _ value: String?) throws {
        let result = if let value {
            sqlite3_bind_text(handle, index, value, -1, Self.transient)
        } else {
            sqlite3_bind_null(handle, index)
        }
        try check(result)
    }

    /// `Int` is 64-bit here, so it binds as a 64-bit `INTEGER` instead of being narrowed (which
    /// trapped above `Int32.max`); read those columns back with `columnInt64`.
    public func bind(_ index: Int32, _ value: Int?) throws {
        let result = if let value {
            sqlite3_bind_int64(handle, index, Int64(value))
        } else {
            sqlite3_bind_null(handle, index)
        }
        try check(result)
    }

    /// Row identifiers exceed `Int32`, so they get their own overload rather than being forced
    /// through the 32-bit one above.
    public func bind(_ index: Int32, _ value: Int64?) throws {
        let result = if let value {
            sqlite3_bind_int64(handle, index, value)
        } else {
            sqlite3_bind_null(handle, index)
        }
        try check(result)
    }

    public func bind(_ index: Int32, _ value: Double?) throws {
        let result = if let value {
            sqlite3_bind_double(handle, index, value)
        } else {
            sqlite3_bind_null(handle, index)
        }
        try check(result)
    }

    public func bind(_ index: Int32, _ value: Data?) throws {
        let result = if let value {
            value.withUnsafeBytes { buffer in
                sqlite3_bind_blob(handle, index, buffer.baseAddress, Int32(value.count), Self.transient)
            }
        } else {
            sqlite3_bind_null(handle, index)
        }
        try check(result)
    }

    // MARK: - Stepping

    /// `true` when a row is available, `false` at `SQLITE_DONE`; anything else throws.
    public func step() throws -> Bool {
        switch sqlite3_step(handle) {
        case SQLITE_ROW: return true
        case SQLITE_DONE: return false
        default: throw StoreError.exec(database.lastErrorMessage)
        }
    }

    /// For statements that must finish without producing rows.
    public func stepToCompletion() throws {
        guard sqlite3_step(handle) == SQLITE_DONE else {
            throw StoreError.exec(database.lastErrorMessage)
        }
    }

    public func reset() throws {
        guard sqlite3_reset(handle) == SQLITE_OK else {
            throw StoreError.exec(database.lastErrorMessage)
        }
    }

    // MARK: - Columns

    public func isNull(_ index: Int32) -> Bool {
        sqlite3_column_type(handle, index) == SQLITE_NULL
    }

    public func columnText(_ index: Int32) -> String? {
        guard let cString = sqlite3_column_text(handle, index) else { return nil }
        return String(cString: cString)
    }

    /// 32-bit read: anything outside `Int32` is truncated, so this is only for schema-sized values
    /// (`PRAGMA user_version`); counts and sizes go through `columnInt64`.
    public func columnInt(_ index: Int32) -> Int? {
        guard !isNull(index) else { return nil }
        return Int(sqlite3_column_int(handle, index))
    }

    public func columnInt64(_ index: Int32) -> Int64? {
        guard !isNull(index) else { return nil }
        return sqlite3_column_int64(handle, index)
    }

    public func columnDouble(_ index: Int32) -> Double? {
        guard !isNull(index) else { return nil }
        return sqlite3_column_double(handle, index)
    }

    public func columnBlob(_ index: Int32) -> Data? {
        guard let pointer = sqlite3_column_blob(handle, index) else { return nil }
        let size = Int(sqlite3_column_bytes(handle, index))
        return Data(bytes: pointer, count: size)
    }

    private func check(_ result: Int32) throws {
        guard result == SQLITE_OK else {
            throw StoreError.exec(database.lastErrorMessage)
        }
    }
}
