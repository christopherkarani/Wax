import Foundation
import Testing
import Wax

// SQLite3 C API tests are only compiled where the system SQLite3 module is
// available (macOS/iOS). On Linux the CI only runs WaxCoreTests, so these
// tests are excluded at compile time rather than at runtime.
#if canImport(SQLite3)
import SQLite3

private enum SQLiteBlobInspector {
    static func int32Pragma(_ pragma: String, fromSerialized data: Data) throws -> Int32 {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let size = data.count
        guard let buffer = sqlite3_malloc64(UInt64(size)) else {
            throw WaxError.io("sqlite3_malloc64 failed")
        }
        data.withUnsafeBytes { raw in
            if let base = raw.baseAddress {
                memcpy(buffer, base, size)
            }
        }
        let flags = UInt32(SQLITE_DESERIALIZE_FREEONCLOSE | SQLITE_DESERIALIZE_RESIZEABLE)
        let rc = sqlite3_deserialize(
            db,
            "main",
            buffer.assumingMemoryBound(to: UInt8.self),
            Int64(size),
            Int64(size),
            flags
        )
        guard rc == SQLITE_OK else {
            throw WaxError.io("sqlite3_deserialize failed")
        }

        var stmt: OpaquePointer?
        defer { sqlite3_finalize(stmt) }
        let sql = "PRAGMA \(pragma)"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WaxError.io("sqlite3_prepare_v2 failed for \(sql)")
        }
        guard sqlite3_step(stmt) == SQLITE_ROW else {
            throw WaxError.io("sqlite3_step failed for \(sql)")
        }
        return Int32(sqlite3_column_int(stmt, 0))
    }

    static func makeLegacyFTS5Blob() throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let statements = [
            "CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(content);",
            """
            CREATE TABLE IF NOT EXISTS frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS frame_mapping_rowid_idx ON frame_mapping(rowid_ref);",
            "INSERT INTO frames_fts(content) VALUES ('hello legacy');",
            "INSERT INTO frame_mapping(frame_id, rowid_ref) VALUES (0, 1);",
        ]

        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw WaxError.io("sqlite3_exec failed: \(sql)")
            }
        }

        var size: Int64 = 0
        guard let raw = sqlite3_serialize(db, "main", &size, 0) else {
            throw WaxError.io("sqlite3_serialize failed")
        }
        defer { sqlite3_free(raw) }
        return Data(bytes: raw, count: Int(size))
    }

    static func makeV1FTS5Blob() throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let statements = [
            "CREATE VIRTUAL TABLE IF NOT EXISTS frames_fts USING fts5(content);",
            """
            CREATE TABLE IF NOT EXISTS frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            );
            """,
            "CREATE INDEX IF NOT EXISTS frame_mapping_rowid_idx ON frame_mapping(rowid_ref);",
            "PRAGMA application_id = 0x57415854;",
            "PRAGMA user_version = 1;",
            "INSERT INTO frames_fts(content) VALUES ('hello v1');",
            "INSERT INTO frame_mapping(frame_id, rowid_ref) VALUES (0, 1);",
        ]

        for sql in statements {
            guard sqlite3_exec(db, sql, nil, nil, nil) == SQLITE_OK else {
                throw WaxError.io("sqlite3_exec failed: \(sql)")
            }
        }

        var size: Int64 = 0
        guard let raw = sqlite3_serialize(db, "main", &size, 0) else {
            throw WaxError.io("sqlite3_serialize failed")
        }
        defer { sqlite3_free(raw) }
        return Data(bytes: raw, count: Int(size))
    }
}

@Test func structuredSchemaCreatesWithIdentityPragmas() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    let blob = try await engine.serialize()

    let appId = try SQLiteBlobInspector.int32Pragma("application_id", fromSerialized: blob)
    let userVersion = try SQLiteBlobInspector.int32Pragma("user_version", fromSerialized: blob)

    #expect(appId == 0x5741_5854)
    #expect(userVersion == 2)
}

@Test func deserializeUpgradesLegacyBlobSchemaIdentityToV2() async throws {
    let legacy = try SQLiteBlobInspector.makeLegacyFTS5Blob()
    let engine = try FTS5SearchEngine.deserialize(from: legacy)
    let upgraded = try await engine.serialize()

    let appId = try SQLiteBlobInspector.int32Pragma("application_id", fromSerialized: upgraded)
    let userVersion = try SQLiteBlobInspector.int32Pragma("user_version", fromSerialized: upgraded)

    #expect(appId == 0x5741_5854)
    #expect(userVersion == 2)
}

@Test func deserializeUpgradesV1BlobToV2() async throws {
    let v1 = try SQLiteBlobInspector.makeV1FTS5Blob()
    let engine = try FTS5SearchEngine.deserialize(from: v1)
    let upgraded = try await engine.serialize()

    let userVersion = try SQLiteBlobInspector.int32Pragma("user_version", fromSerialized: upgraded)
    #expect(userVersion == 2)
}

@Test func migrationPreservesFTSSearchResults() async throws {
    let v1 = try SQLiteBlobInspector.makeV1FTS5Blob()
    let engine = try FTS5SearchEngine.deserialize(from: v1)
    let results = try await engine.search(query: "hello", topK: 10)

    #expect(results.count == 1)
    #expect(results[0].frameId == 0)
}

#endif // canImport(SQLite3)
