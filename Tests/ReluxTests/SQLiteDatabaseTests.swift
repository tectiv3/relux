import ReluxCore
import XCTest

final class SQLiteDatabaseTests: XCTestCase {
    private func makeDatabase() throws -> SQLiteDatabase {
        try SQLiteDatabase(path: ":memory:")
    }

    private func count(in database: SQLiteDatabase, table: String) throws -> Int? {
        let statement = try database.prepare("SELECT COUNT(*) FROM \(table)")
        guard try statement.step() else { return nil }
        return statement.columnInt(0)
    }

    private func execMessage(from error: Error, file: StaticString = #filePath, line: UInt = #line) -> String? {
        guard let storeError = error as? StoreError, case let .exec(message) = storeError else {
            XCTFail("unexpected error: \(error)", file: file, line: line)
            return nil
        }
        return message
    }

    // MARK: - Opening

    func testBusyTimeoutIsSet() throws {
        let database = try makeDatabase()
        let statement = try database.prepare("PRAGMA busy_timeout")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnInt(0), 5000)
    }

    /// The helper must not change the journal mode: the live database runs in `delete` mode and
    /// WAL was explicitly out of scope.
    func testJournalModeIsLeftAtDefault() throws {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("relux-sqlite-tests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: directory) }

        let database = try SQLiteDatabase(path: directory.appendingPathComponent("test.db").path)
        let statement = try database.prepare("PRAGMA journal_mode")
        XCTAssertTrue(try statement.step())
        XCTAssertEqual(statement.columnText(0)?.lowercased(), "delete")
    }

    func testCannotOpenUnwritablePath() {
        XCTAssertThrowsError(try SQLiteDatabase(path: "/nonexistent-dir-\(UUID().uuidString)/relux.db")) { error in
            guard let storeError = error as? StoreError, case .cannotOpen = storeError else {
                return XCTFail("unexpected error: \(error)")
            }
        }
    }

    // MARK: - Binding round trip

    func testBindRoundTripForAllTypes() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (text_value TEXT, int_value INTEGER, real_value REAL, blob BLOB)")

        let text: String? = "héllo"
        let number = 2_147_483_647
        let real = 1.5
        let blob: Data? = Data([0x00, 0xFF, 0x10])

        let insert = try database.prepare("INSERT INTO sample VALUES (?, ?, ?, ?)")
        try insert.bind(1, text)
        try insert.bind(2, number)
        try insert.bind(3, real)
        try insert.bind(4, blob)
        try insert.stepToCompletion()

        let select = try database.prepare("SELECT text_value, int_value, real_value, blob FROM sample")
        XCTAssertTrue(try select.step())
        XCTAssertEqual(select.columnText(0), "héllo")
        XCTAssertEqual(select.columnInt(1), 2_147_483_647)
        XCTAssertEqual(select.columnDouble(2), 1.5)
        XCTAssertEqual(select.columnBlob(3), Data([0x00, 0xFF, 0x10]))
        XCTAssertFalse(try select.step())
    }

    func testNilBindsStoreSQLNull() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (text_value TEXT, int_value INTEGER, real_value REAL, blob BLOB)")

        let missingText: String? = nil
        let missingInt: Int? = nil
        let missingReal: Double? = nil
        let missingBlob: Data? = nil

        let insert = try database.prepare("INSERT INTO sample VALUES (?, ?, ?, ?)")
        try insert.bind(1, missingText)
        try insert.bind(2, missingInt)
        try insert.bind(3, missingReal)
        try insert.bind(4, missingBlob)
        try insert.stepToCompletion()

        let select = try database.prepare("SELECT text_value, int_value, real_value, blob FROM sample")
        XCTAssertTrue(try select.step())
        for column: Int32 in 0 ..< 4 {
            XCTAssertTrue(select.isNull(column), "column \(column) should be NULL")
        }
        XCTAssertNil(select.columnText(0))
        XCTAssertNil(select.columnInt(1))
        XCTAssertNil(select.columnDouble(2))
        XCTAssertNil(select.columnBlob(3))
    }

    func testInt64BindingKeepsFullRowIdentifierRange() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY, name TEXT)")
        let huge: Int64 = 4_000_000_000
        let insert = try database.prepare("INSERT INTO sample VALUES (?, ?)")
        try insert.bind(1, huge)
        try insert.bind(2, "big")
        try insert.stepToCompletion()

        XCTAssertEqual(database.lastInsertRowID, huge)
        let select = try database.prepare("SELECT id FROM sample WHERE name = ?")
        try select.bind(1, "big")
        XCTAssertTrue(try select.step())
        XCTAssertEqual(select.columnInt64(0), huge)
    }

    /// `Int` above `Int32.max` must survive: the count and size columns are bound through this
    /// overload, and the old 32-bit conversion trapped instead of storing the value.
    func testIntBindingKeepsValuesAboveInt32Max() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (value INTEGER)")
        let big = Int(Int32.max) + 1
        let insert = try database.prepare("INSERT INTO sample VALUES (?)")
        try insert.bind(1, big)
        try insert.stepToCompletion()

        let select = try database.prepare("SELECT value FROM sample")
        XCTAssertTrue(try select.step())
        XCTAssertEqual(select.columnInt64(0), Int64(big))
    }

    func testLastInsertRowIDTracksInsertions() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
        for name in ["a", "b", "c"] {
            let insert = try database.prepare("INSERT INTO sample (name) VALUES (?)")
            try insert.bind(1, name)
            try insert.stepToCompletion()
        }
        XCTAssertEqual(database.lastInsertRowID, 3)
    }

    // MARK: - Stepping

    func testStepReportsNoRowWithoutThrowing() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (value INTEGER)")
        let select = try database.prepare("SELECT value FROM sample")
        XCTAssertFalse(try select.step())
    }

    func testPrepareAndExecuteReportSQLiteErrors() throws {
        let database = try makeDatabase()

        XCTAssertThrowsError(try database.prepare("SELECT * FROM missing_table")) { error in
            let message = self.execMessage(from: error) ?? ""
            XCTAssertTrue(message.contains("missing_table"), "unexpected message: \(message)")
        }

        XCTAssertThrowsError(try database.execute("NOT VALID SQL")) { error in
            let message = self.execMessage(from: error) ?? ""
            XCTAssertFalse(message.isEmpty)
        }
    }

    func testStepToCompletionThrowsForStatementReturningRows() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (value INTEGER)")
        let select = try database.prepare("SELECT value FROM sample")
        // No rows: `stepToCompletion` succeeds. With rows it must not silently swallow them.
        try select.stepToCompletion()

        let insert = try database.prepare("INSERT INTO sample VALUES (?)")
        let value = 1
        try insert.bind(1, value)
        try insert.stepToCompletion()

        try select.reset()
        XCTAssertThrowsError(try select.stepToCompletion())
    }

    /// Every statement that goes out of scope must finalize, otherwise later work on the same
    /// connection starts failing.
    func testStatementsAreFinalizedAfterDeinit() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (value INTEGER)")

        for value in 0 ..< 100 {
            let insert = try database.prepare("INSERT INTO sample VALUES (?)")
            let bound = value
            try insert.bind(1, bound)
            try insert.stepToCompletion()
        }

        XCTAssertEqual(try count(in: database, table: "sample"), 100)
        try database.execute("CREATE INDEX idx_sample ON sample (value)")
        XCTAssertEqual(try count(in: database, table: "sample"), 100)
    }

    // MARK: - Transactions

    func testTransactionCommits() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (value INTEGER)")

        try database.transaction {
            let insert = try database.prepare("INSERT INTO sample VALUES (?)")
            let value = 7
            try insert.bind(1, value)
            try insert.stepToCompletion()
        }

        XCTAssertEqual(try count(in: database, table: "sample"), 1)
    }

    func testTransactionRollsBackOnThrow() throws {
        let database = try makeDatabase()
        try database.execute("CREATE TABLE sample (value INTEGER)")

        struct Boom: Error {}
        XCTAssertThrowsError(try database.transaction {
            let insert = try database.prepare("INSERT INTO sample VALUES (?)")
            let value = 7
            try insert.bind(1, value)
            try insert.stepToCompletion()
            throw Boom()
        }) { error in
            XCTAssertTrue(error is Boom)
        }

        XCTAssertEqual(try count(in: database, table: "sample"), 0)
        // The connection must be usable again: no dangling open transaction.
        try database.transaction {
            let insert = try database.prepare("INSERT INTO sample VALUES (?)")
            let value = 8
            try insert.bind(1, value)
            try insert.stepToCompletion()
        }
        XCTAssertEqual(try count(in: database, table: "sample"), 1)
    }

    // MARK: - Migration runner

    func testMigrateAppliesEachVersionInOrder() throws {
        let database = try makeDatabase()
        var applied: [Int] = []

        try database.migrate(to: 3) { version, database in
            applied.append(version)
            try database.execute("CREATE TABLE version_\(version) (value INTEGER)")
        }

        XCTAssertEqual(applied, [1, 2, 3])
        XCTAssertEqual(try database.userVersion, 3)
        let tableInfo = try database.prepare("PRAGMA table_info(version_3)")
        XCTAssertTrue(try tableInfo.step())
    }

    func testMigrateIsANoOpWhenAlreadyAtTarget() throws {
        let database = try makeDatabase()
        var applied: [Int] = []
        let record: (Int, SQLiteDatabase) throws -> Void = { version, _ in applied.append(version) }

        try database.migrate(to: 2, apply: record)
        try database.migrate(to: 2, apply: record)

        XCTAssertEqual(applied, [1, 2])
        XCTAssertEqual(try database.userVersion, 2)
    }

    func testMigrateRollsBackFailingVersion() throws {
        let database = try makeDatabase()
        struct Boom: Error {}

        XCTAssertThrowsError(try database.migrate(to: 2) { version, database in
            try database.execute("CREATE TABLE version_\(version) (value INTEGER)")
            if version == 2 {
                throw Boom()
            }
        })

        XCTAssertEqual(try database.userVersion, 1)
        let rolledBack = try database.prepare("PRAGMA table_info(version_2)")
        XCTAssertFalse(try rolledBack.step(), "version 2 DDL should have been rolled back")
    }

    func testMigrateRejectsDatabaseFromNewerSchema() throws {
        let database = try makeDatabase()
        try database.execute("PRAGMA user_version = 9")
        XCTAssertThrowsError(try database.migrate(to: 1) { _, _ in })
        XCTAssertEqual(try database.userVersion, 9)
    }
}
