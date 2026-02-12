import Foundation
import SQLite3
import Testing
import Wax

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
}

@Test func ftsSchemaCreates() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    let count = try await engine.count()
    #expect(count == 0)
}

@Test func indexAndSearchReturnsHitsAndSnippet() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Swift is safe and fast.")
    let results = try await engine.search(query: "Swift", topK: 10)
    #expect(results.count == 1)
    #expect(results[0].frameId == 0)
    #expect(results[0].snippet?.isEmpty == false)
}

@Test func indexBatchFlushesBeforeSearch() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.indexBatch(
        frameIds: [0, 1],
        texts: [
            "Swift concurrency uses actors and tasks.",
            "Swift is safe and fast.",
        ]
    )

    let results = try await engine.search(query: "Swift", topK: 10)
    #expect(results.count == 2)
    #expect(Set(results.map(\.frameId)) == Set([0, 1]))
    #expect(results.allSatisfy { ($0.snippet ?? "").isEmpty == false })
}

@Test func indexBatchEmptyTextRemovesStaleRow() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 7, text: "Stale searchable text")

    let before = try await engine.search(query: "Stale", topK: 10)
    #expect(before.map(\.frameId) == [7])

    try await engine.indexBatch(frameIds: [7], texts: ["  \n\t  "])

    let after = try await engine.search(query: "Stale", topK: 10)
    #expect(after.isEmpty)
    let count = try await engine.count()
    #expect(count == 0)
}

@Test func searchScoresAreOrderedAndNonConstant() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Swift")
    try await engine.index(frameId: 1, text: "Swift is safe and fast.")

    let results = try await engine.search(query: "Swift", topK: 10)
    #expect(results.count == 2)
    #expect(results[0].score >= results[1].score)
    #expect(results[0].score != results[1].score)
}

@Test func searchTieBreaksOnFrameIdForDeterminism() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    // Insert in reverse frameId order to detect nondeterministic or insertion-ordered ties.
    try await engine.index(frameId: 2, text: "Swift concurrency uses actors and tasks.")
    try await engine.index(frameId: 1, text: "Swift concurrency uses actors and tasks.")

    let results = try await engine.search(query: "Swift", topK: 10)
    #expect(results.count == 2)
    #expect(results.map(\.frameId) == [1, 2])
}

@Test func serializeDeserializeRoundtripPreservesSearch() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Hello, World!")
    let blob = try await engine.serialize()
    let engine2 = try FTS5SearchEngine.deserialize(from: blob)
    let results = try await engine2.search(query: "Hello", topK: 10)
    #expect(results.map(\.frameId) == [0])
}

@Test func serializedBlobHasSchemaIdentityPragmas() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Hello, World!")
    let blob = try await engine.serialize()

    let appId = try SQLiteBlobInspector.int32Pragma("application_id", fromSerialized: blob)
    let userVersion = try SQLiteBlobInspector.int32Pragma("user_version", fromSerialized: blob)

    #expect(appId == 0x5741_5854) // "WAXT"
    #expect(userVersion == 2)
}

@Test func deserializeUpgradesLegacyBlobSchemaIdentity() async throws {
    let legacy = try SQLiteBlobInspector.makeLegacyFTS5Blob()
    let engine = try FTS5SearchEngine.deserialize(from: legacy)
    let upgraded = try await engine.serialize()

    let appId = try SQLiteBlobInspector.int32Pragma("application_id", fromSerialized: upgraded)
    let userVersion = try SQLiteBlobInspector.int32Pragma("user_version", fromSerialized: upgraded)

    #expect(appId == 0x5741_5854) // "WAXT"
    #expect(userVersion == 2)
}

@Test func serializeSupportsOptionalCompaction() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Hello, World!")
    let blob = try await engine.serialize(compact: true)
    #expect(!blob.isEmpty)
}

@Test func stageLexIndexRejectsEmptyBytes() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)

    do {
        try await wax.stageLexIndexForNextCommit(bytes: Data(), docCount: 0)
        #expect(Bool(false))
    } catch {
        // Expected.
    }

    try await wax.close()
    try FileManager.default.removeItem(at: tempDir)
}

@Test func mv2sLexIndexPersistsWithoutSidecars() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let payload = Data("payload".utf8)
    let frameId = try await wax.put(payload, options: FrameMetaSubset(searchText: "hello from wax"))

    let engine = try await FTS5SearchEngine.load(from: wax)
    try await engine.index(frameId: frameId, text: "hello from wax")
    try await engine.stageForCommit(into: wax)
    try await wax.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let engine2 = try await FTS5SearchEngine.load(from: reopened)
    let results = try await engine2.search(query: "hello", topK: 10)
    #expect(results.map(\.frameId) == [frameId])
    try await reopened.close()

    let files = try FileManager.default.contentsOfDirectory(atPath: tempDir.path)
    let baseName = fileURL.lastPathComponent
    let forbidden = [
        "\(baseName)-wal",
        "\(baseName)-shm",
        "\(baseName)-journal",
        "\(baseName).db",
        "\(baseName).sqlite",
        "\(baseName).sqlite3",
    ]
    for name in forbidden {
        #expect(!files.contains(name))
    }
    try FileManager.default.removeItem(at: tempDir)
}

@Test func enableTextSearchSessionCommitsPersistedIndex() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.mv2s")
    let wax = try await Wax.create(at: fileURL)
    let payload = Data("payload".utf8)
    let frameId = try await wax.put(payload, options: FrameMetaSubset(searchText: "hello from wax"))

    let session = try await wax.enableTextSearch()
    try await session.index(frameId: frameId, text: "hello from wax")
    try await session.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let session2 = try await reopened.enableTextSearch()
    let results = try await session2.search(query: "hello", topK: 10)
    #expect(results.map(\.frameId) == [frameId])
    try await reopened.close()

    try FileManager.default.removeItem(at: tempDir)
}
