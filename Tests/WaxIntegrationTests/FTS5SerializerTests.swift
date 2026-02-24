import Foundation
import Testing
@testable import WaxTextSearch
@testable import WaxCore

// SQLite3 C API tests are only compiled where the system SQLite3 module is
// available (macOS/iOS). On Linux the CI only runs WaxCoreTests, so these
// tests are excluded at compile time rather than at runtime.
#if canImport(SQLite3)
import SQLite3

@Test func fts5SerializerRoundTrip() throws {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK, let conn = db else {
        Issue.record("Failed to open in-memory SQLite database")
        return
    }
    defer { sqlite3_close(conn) }

    // Create a table with some data
    let sql = "CREATE TABLE test(id INTEGER PRIMARY KEY, name TEXT); INSERT INTO test VALUES(1, 'hello'); INSERT INTO test VALUES(2, 'world');"
    guard sqlite3_exec(conn, sql, nil, nil, nil) == SQLITE_OK else {
        Issue.record("Failed to create test table")
        return
    }

    // Serialize
    let blob = try FTS5Serializer.serialize(connection: conn)
    #expect(!blob.isEmpty)

    // Deserialize into a fresh connection
    var db2: OpaquePointer?
    guard sqlite3_open(":memory:", &db2) == SQLITE_OK, let conn2 = db2 else {
        Issue.record("Failed to open second in-memory database")
        return
    }
    defer { sqlite3_close(conn2) }

    try FTS5Serializer.deserialize(blob, into: conn2)

    // Verify data was restored
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(conn2, "SELECT count(*) FROM test", -1, &stmt, nil) == SQLITE_OK else {
        Issue.record("Failed to prepare SELECT")
        return
    }
    defer { sqlite3_finalize(stmt) }

    guard sqlite3_step(stmt) == SQLITE_ROW else {
        Issue.record("Expected row from SELECT")
        return
    }
    let count = sqlite3_column_int(stmt, 0)
    #expect(count == 2)
}

@Test func fts5SerializerDeserializeEmptyDataThrows() throws {
    var db: OpaquePointer?
    guard sqlite3_open(":memory:", &db) == SQLITE_OK, let conn = db else {
        Issue.record("Failed to open database")
        return
    }
    defer { sqlite3_close(conn) }

    #expect(throws: WaxError.self) {
        try FTS5Serializer.deserialize(Data(), into: conn)
    }
}

#endif // canImport(SQLite3)
