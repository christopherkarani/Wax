import Foundation
import Testing
@testable import WaxTextSearch
@testable import WaxCore

// The SQLite C API comes from the SDK's SQLite3 module on Apple platforms and
// from GRDB's GRDBSQLite system library (libsqlite3) elsewhere.
#if canImport(SQLite3) || canImport(GRDBSQLite)
#if canImport(SQLite3)
import SQLite3
#else
import GRDBSQLite
#endif

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

/// With SQLITE_DESERIALIZE_FREEONCLOSE, sqlite3_deserialize frees the buffer itself
/// when it fails, so the caller must not free it again.
@Test func fts5SerializerDeserializeFailureDoesNotDoubleFree() throws {
    var source: OpaquePointer?
    guard sqlite3_open(":memory:", &source) == SQLITE_OK, let sourceConn = source else {
        Issue.record("Failed to open source database")
        return
    }
    defer { sqlite3_close(sourceConn) }
    guard sqlite3_exec(sourceConn, "CREATE TABLE t(x); INSERT INTO t VALUES(1);", nil, nil, nil) == SQLITE_OK else {
        Issue.record("Failed to seed source database")
        return
    }
    let blob = try FTS5Serializer.serialize(connection: sourceConn)

    var target: OpaquePointer?
    guard sqlite3_open(":memory:", &target) == SQLITE_OK, let targetConn = target else {
        Issue.record("Failed to open target database")
        return
    }
    defer { sqlite3_close(targetConn) }

    // sqlite3_deserialize reopens the schema through an internal ATTACH; denying it
    // forces the failure path deterministically.
    sqlite3_set_authorizer(targetConn, { _, action, _, _, _, _ in
        action == SQLITE_ATTACH ? SQLITE_DENY : SQLITE_OK
    }, nil)

    for _ in 0..<64 {
        #expect(throws: WaxError.self) {
            try FTS5Serializer.deserialize(blob, into: targetConn)
        }
    }

    // The connection is still usable after the failed deserialize.
    sqlite3_set_authorizer(targetConn, nil, nil)
    #expect(sqlite3_exec(targetConn, "CREATE TABLE ok(x);", nil, nil, nil) == SQLITE_OK)
}

#endif // canImport(SQLite3) || canImport(GRDBSQLite)
