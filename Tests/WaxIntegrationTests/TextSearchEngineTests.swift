import Foundation
import Testing
@testable import Wax

// SQLite3 C API inspector: only available where the system SQLite3 module
// exists (macOS/iOS). On Linux, tests that require direct SQLite3 C calls
// are excluded at compile time; the CI only runs WaxCoreTests on Linux.
#if canImport(SQLite3)
import SQLite3
import WaxCore
import WaxTextSearch
import WaxVectorSearch

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

    static func schemaSQL(table: String, fromSerialized data: Data) throws -> String {
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
        let escapedTable = table.replacingOccurrences(of: "'", with: "''")
        let sql = "SELECT sql FROM sqlite_master WHERE name = '\(escapedTable)'"
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            throw WaxError.io("sqlite3_prepare_v2 failed for \(sql)")
        }
        guard sqlite3_step(stmt) == SQLITE_ROW, let raw = sqlite3_column_text(stmt, 0) else {
            throw WaxError.io("schema SQL not found for \(table)")
        }
        return String(cString: raw)
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

    static func makeFakeFTS5NamedTableBlob() throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let statements = [
            "CREATE TABLE frames_fts(content TEXT CHECK('fts5' = 'fts5'));",
            """
            CREATE TABLE frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            );
            """,
            "PRAGMA application_id = 0x57415854;",
            "PRAGMA user_version = 3;",
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

    static func makeCurrentVersionPorterUnicode61Blob() throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let statements = [
            "CREATE VIRTUAL TABLE frames_fts USING fts5(content, tokenize = 'porter unicode61');",
            """
            CREATE TABLE frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            );
            """,
            "PRAGMA application_id = 0x57415854;",
            "PRAGMA user_version = 4;",
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

    static func makeCurrentVersionCommentSpoofedTokenizerBlob() throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let statements = [
            "CREATE VIRTUAL TABLE frames_fts USING fts5(content, tokenize = 'porter' /* tokenize='unicode61' */);",
            """
            CREATE TABLE frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            );
            """,
            "PRAGMA application_id = 0x57415854;",
            "PRAGMA user_version = 4;",
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

    static func makeCurrentVersionWrongContentColumnBlob() throws -> Data {
        var db: OpaquePointer?
        guard sqlite3_open(":memory:", &db) == SQLITE_OK else {
            throw WaxError.io("sqlite3_open failed")
        }
        defer { sqlite3_close(db) }

        let statements = [
            "CREATE VIRTUAL TABLE frames_fts USING fts5(notcontent, tokenize = 'unicode61');",
            """
            CREATE TABLE frame_mapping (
                frame_id INTEGER PRIMARY KEY,
                rowid_ref INTEGER UNIQUE NOT NULL
            );
            """,
            "PRAGMA application_id = 0x57415854;",
            "PRAGMA user_version = 4;",
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
#endif // canImport(SQLite3)

@Test func ftsSchemaCreates() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    let count = try await engine.count()
    #expect(count == 0)
}

@Test func indexAndSearchReturnsHitsAndSnippet() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Swift is safe and fast.")
    let results = try await engine.search(matchQuery: "\"Swift\"", topK: 10)
    #expect(results.count == 1)
    #expect(results[0].frameId == 0)
    #expect(results[0].snippet?.isEmpty == false)
}

@Test func searchTreatsFTS5SyntaxAndPunctuationAsLiteralText() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 42, text: "task F076 literal NEAR unclosed quote token survives")

    let plan = try #require(MatchPlan.plan(query: #"task:(F076) NEAR(unclosed "quote""#))
    let results = try await engine.search(matchQuery: plan.primaryMatch, topK: 10)

    #expect(results.map(\.frameId) == [42])
}

@Test func searchWithControlCharacterInQueryDoesNotThrow() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 9, text: "abc def")

    let plan = try #require(MatchPlan.plan(query: "abc\u{0}def"))
    let primary = try await engine.search(matchQuery: plan.primaryMatch, topK: 10)
    #expect(primary.map(\.frameId) == [9])
    if let fallback = plan.fallbackMatch {
        let results = try await engine.search(matchQuery: fallback, topK: 10)
        #expect(results.map(\.frameId) == [9])
    }
}

@Test func searchRejectsNonPositiveTopK() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 7, text: "topK validation")

    await #expect(throws: WaxError.self) {
        _ = try await engine.search(matchQuery: "\"topK\"", topK: 0)
    }
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

    let results = try await engine.search(matchQuery: "\"Swift\"", topK: 10)
    #expect(results.count == 2)
    #expect(Set(results.map(\.frameId)) == Set([0, 1]))
    #expect(results.allSatisfy { ($0.snippet ?? "").isEmpty == false })
}

@Test func indexBatchEmptyTextRemovesStaleRow() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 7, text: "Stale searchable text")

    let before = try await engine.search(matchQuery: "\"Stale\"", topK: 10)
    #expect(before.map(\.frameId) == [7])

    try await engine.indexBatch(frameIds: [7], texts: ["  \n\t  "])

    let after = try await engine.search(matchQuery: "\"Stale\"", topK: 10)
    #expect(after.isEmpty)
    let count = try await engine.count()
    #expect(count == 0)
}

@Test func searchScoresAreOrderedAndNonConstant() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Swift")
    try await engine.index(frameId: 1, text: "Swift is safe and fast.")

    let results = try await engine.search(matchQuery: "\"Swift\"", topK: 10)
    #expect(results.count == 2)
    #expect(results[0].score >= results[1].score)
    #expect(results[0].score != results[1].score)
}

@Test func textSearchScoresAreNormalizedForThresholds() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Swift Swift Swift concurrency actors")
    try await engine.index(frameId: 1, text: "Swift concurrency")

    let results = try await engine.search(matchQuery: "\"Swift\"", topK: 10)

    #expect(results.count == 2)
    #expect(results.allSatisfy { (0...1).contains($0.score) })
    #expect(results[0].score > 0.9)
    #expect(results[0].score > results[1].score)
    #expect(results[1].score < 0.9)
}

@Test func textSearchSingleWeakMatchDoesNotBecomePerfectScore() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 1, text: "Swift concurrency")

    let results = try await engine.search(matchQuery: "\"Swift\"", topK: 10)

    #expect(results.map(\.frameId) == [1])
    #expect(results[0].score < 0.9)
}

@Test func textSearchScoresDoNotDependOnReturnedWindow() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Swift Swift Swift concurrency actors")
    try await engine.index(frameId: 1, text: "Swift concurrency")
    try await engine.index(frameId: 2, text: "Swift concurrency concurrency concurrency concurrency concurrency")

    let narrow = try await engine.search(matchQuery: "\"Swift\"", topK: 2)
    let wide = try await engine.search(matchQuery: "\"Swift\"", topK: 10)

    let narrowMiddle = try #require(narrow.first { $0.frameId == 1 })
    let wideMiddle = try #require(wide.first { $0.frameId == 1 })
    #expect(abs(narrowMiddle.score - wideMiddle.score) < 0.000_000_000_001)
}

@Test func searchTieBreaksOnFrameIdForDeterminism() async throws {
    let engine = try FTS5SearchEngine.inMemory()

    // Insert in reverse frameId order to detect nondeterministic or insertion-ordered ties.
    try await engine.index(frameId: 2, text: "Swift concurrency uses actors and tasks.")
    try await engine.index(frameId: 1, text: "Swift concurrency uses actors and tasks.")

    let results = try await engine.search(matchQuery: "\"Swift\"", topK: 10)
    #expect(results.count == 2)
    #expect(results.map(\.frameId) == [1, 2])
}

@Test func serializeDeserializeRoundtripPreservesSearch() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Hello, World!")
    let blob = try await engine.serialize()
    let engine2 = try FTS5SearchEngine.deserialize(from: blob)
    let results = try await engine2.search(matchQuery: "\"Hello\"", topK: 10)
    #expect(results.map(\.frameId) == [0])
}

#if canImport(SQLite3)
@Test func serializedBlobHasSchemaIdentityPragmas() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 0, text: "Hello, World!")
    let blob = try await engine.serialize()

    let appId = try SQLiteBlobInspector.int32Pragma("application_id", fromSerialized: blob)
    let userVersion = try SQLiteBlobInspector.int32Pragma("user_version", fromSerialized: blob)

    #expect(appId == 0x5741_5854) // "WAXT"
    #expect(userVersion == 9)
}

@Test func serializedBlobPinsFTS5Tokenizer() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    let blob = try await engine.serialize()

    let sql = try SQLiteBlobInspector.schemaSQL(table: "frames_fts", fromSerialized: blob).lowercased()
    #expect(sql.contains("create virtual table"))
    #expect(sql.contains("using fts5"))
    #expect(sql.contains("tokenize"))
    #expect(sql.contains("unicode61"))
}

@Test func deserializeRejectsFakeFTS5TableName() throws {
    let fake = try SQLiteBlobInspector.makeFakeFTS5NamedTableBlob()

    #expect(throws: WaxError.self) {
        _ = try FTS5SearchEngine.deserialize(from: fake)
    }
}

@Test func deserializeRejectsCurrentVersionTokenizerDrift() throws {
    let drifted = try SQLiteBlobInspector.makeCurrentVersionPorterUnicode61Blob()

    #expect(throws: WaxError.self) {
        _ = try FTS5SearchEngine.deserialize(from: drifted)
    }
}

@Test func deserializeRejectsCommentSpoofedTokenizerDrift() throws {
    let drifted = try SQLiteBlobInspector.makeCurrentVersionCommentSpoofedTokenizerBlob()

    #expect(throws: WaxError.self) {
        _ = try FTS5SearchEngine.deserialize(from: drifted)
    }
}

@Test func deserializeRejectsCurrentVersionWrongFTSColumn() throws {
    let drifted = try SQLiteBlobInspector.makeCurrentVersionWrongContentColumnBlob()

    #expect(throws: WaxError.self) {
        _ = try FTS5SearchEngine.deserialize(from: drifted)
    }
}

@Test func deserializeUpgradesLegacyBlobSchemaIdentity() async throws {
    let legacy = try SQLiteBlobInspector.makeLegacyFTS5Blob()
    let engine = try FTS5SearchEngine.deserialize(from: legacy)
    let upgraded = try await engine.serialize()

    let appId = try SQLiteBlobInspector.int32Pragma("application_id", fromSerialized: upgraded)
    let userVersion = try SQLiteBlobInspector.int32Pragma("user_version", fromSerialized: upgraded)
    let sql = try SQLiteBlobInspector.schemaSQL(table: "frames_fts", fromSerialized: upgraded).lowercased()

    #expect(appId == 0x5741_5854) // "WAXT"
    #expect(userVersion == 9)
    #expect(sql.contains("tokenize"))
    #expect(sql.contains("unicode61"))
}
#endif // canImport(SQLite3)

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

    let fileURL = tempDir.appendingPathComponent("sample.wax")
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

@Test func waxLexIndexPersistsWithoutSidecars() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.wax")
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
    let results = try await engine2.search(matchQuery: "\"hello\"", topK: 10)
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

@Test func openSessionCommitsPersistedTextIndex() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.wax")
    let wax = try await Wax.create(at: fileURL)
    let payload = Data("payload".utf8)
    let frameId = try await wax.put(payload, options: FrameMetaSubset(searchText: "hello from wax"))

    let session = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
    try await session.indexText(frameId: frameId, text: "hello from wax")
    try await session.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let session2 = try await reopened.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
    let results = try await session2.searchText(query: "hello", topK: 10)
    #expect(results.map(\.frameId) == [frameId])
    try await reopened.close()

    try FileManager.default.removeItem(at: tempDir)
}

@Test func openSessionCommitRemovesDeletedAndSupersededFramesFromFTSIndex() async throws {
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)

    let fileURL = tempDir.appendingPathComponent("sample.wax")
    let wax = try await Wax.create(at: fileURL)
    let session = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))

    let deletedId = try await wax.put(Data("delete payload".utf8))
    let supersededId = try await wax.put(Data("old payload".utf8))
    try await session.indexText(frameId: deletedId, text: "obsolete delete marker")
    try await session.indexText(frameId: supersededId, text: "obsolete supersede marker")
    try await session.commit()

    let replacementId = try await wax.put(Data("new payload".utf8))
    try await session.indexText(frameId: replacementId, text: "fresh replacement marker")
    try await wax.delete(frameId: deletedId)
    try await wax.supersede(supersededId: supersededId, supersedingId: replacementId)
    try await session.commit()
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let reopenedSession = try await reopened.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
    let deleteResults = try await reopenedSession.searchText(query: "obsolete delete", topK: 10)
    let supersedeResults = try await reopenedSession.searchText(query: "obsolete supersede", topK: 10)
    let replacementResults = try await reopenedSession.searchText(query: "fresh replacement", topK: 10)

    #expect(!deleteResults.contains(where: { $0.frameId == deletedId }))
    #expect(!supersedeResults.contains(where: { $0.frameId == supersededId }))
    #expect(replacementResults.contains(where: { $0.frameId == replacementId }))
    try await reopened.close()

    try FileManager.default.removeItem(at: tempDir)
}

/// Set once by the task under test; polled by the task racing it.
private final class CompletionFlag: @unchecked Sendable {
    private let lock = NSLock()
    private var done = false

    func markDone() {
        lock.lock()
        done = true
        lock.unlock()
    }

    var isDone: Bool {
        lock.lock()
        defer { lock.unlock() }
        return done
    }
}

@Test func indexDuringInFlightFlushIsNotDropped() async throws {
    // A search flushes the queued ops and awaits the SQLite write. Index calls that land
    // during that await must stay queued and reach SQLite on a later flush.
    let engine = try FTS5SearchEngine.inMemory()
    let filler = Array(repeating: "filler", count: 64).joined(separator: " ")
    // Below the auto-flush threshold, so the whole seed stays queued for one long write.
    let seedCount = 1_000
    for i in 0..<seedCount {
        try await engine.index(frameId: UInt64(i), text: "seed \(filler)")
    }

    let flushDone = CompletionFlag()
    let flushing = Task {
        defer { flushDone.markDone() }
        _ = try await engine.search(matchQuery: "\"seed\"", topK: 1)
    }
    // Keep indexing, paced, until the flush returns, so some calls land while it is in flight.
    // The cap keeps the queue below the auto-flush threshold, so this loop never flushes itself.
    var nextFrameId = UInt64(seedCount)
    let lastFrameId = UInt64(seedCount + 1_000)
    while !flushDone.isDone, nextFrameId < lastFrameId {
        try await engine.index(frameId: nextFrameId, text: "late arrival")
        nextFrameId += 1
        try await Task.sleep(nanoseconds: 1_000_000)
    }
    try await flushing.value

    let lateIds = Set(UInt64(seedCount)..<nextFrameId)
    let count = try await engine.count()
    #expect(count == Int(nextFrameId))
    let lateHits = try await engine.search(matchQuery: "\"late\"", topK: 10_000)
    let missing = lateIds.subtracting(lateHits.map(\.frameId))
    #expect(missing.isEmpty, "late frames missing from the text index: \(missing.count) of \(lateIds.count)")
}

@Test func indexDuringStageForCommitReachesTheNextCommittedIndex() async throws {
    // An index call that lands while stageForCommit is serializing or staging is not in that
    // blob. The engine must stay dirty so the next stage writes a blob that includes it.
    let tempDir = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent(UUID().uuidString)
    try FileManager.default.createDirectory(at: tempDir, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: tempDir) }

    let fileURL = tempDir.appendingPathComponent("sample.wax")
    let wax = try await Wax.create(at: fileURL)
    let engine = try await FTS5SearchEngine.load(from: wax)
    // A large index makes serializing and staging the blob slow, widening the race window.
    let corpusCount = 2_000
    let corpusIds: [UInt64] = (0..<corpusCount).map { UInt64($0) }
    let corpusTexts: [String] = (0..<corpusCount).map { (doc: Int) -> String in
        (0..<100).map { (word: Int) -> String in "c\(doc)w\(word)" }.joined(separator: " ")
    }
    try await engine.indexBatch(frameIds: corpusIds, texts: corpusTexts)
    let trials = 20
    let maxLatePerTrial = 400
    var nextFrameId = UInt64(corpusCount)
    var lateIds: Set<UInt64> = []
    var trialsMissingFrames = 0

    for trial in 0..<trials {
        try await engine.index(frameId: nextFrameId, text: "seed")
        nextFrameId += 1

        let stageDone = CompletionFlag()
        let staging = Task {
            defer { stageDone.markDone() }
            try await engine.stageForCommit(into: wax)
        }
        // Keep indexing, paced, until the stage returns, so the last call often lands mid-stage.
        var trialIds: Set<UInt64> = []
        while !stageDone.isDone, trialIds.count < maxLatePerTrial {
            try await engine.index(frameId: nextFrameId, text: "late trial\(trial)")
            trialIds.insert(nextFrameId)
            nextFrameId += 1
            try await Task.sleep(nanoseconds: 1_000_000)
        }
        try await staging.value
        lateIds.formUnion(trialIds)

        try await engine.stageForCommit(into: wax)
        try await wax.commit()
        let bytes = try #require(try await wax.readCommittedLexIndexBytes())
        let committed = try FTS5SearchEngine.deserialize(from: bytes)
        let hits = try await committed.search(matchQuery: "\"trial\(trial)\"", topK: 10_000)
        if !trialIds.isSubset(of: Set(hits.map(\.frameId))) { trialsMissingFrames += 1 }
    }
    try await wax.close()

    let reopened = try await Wax.open(at: fileURL)
    let reloaded = try await FTS5SearchEngine.load(from: reopened)
    let hits = try await reloaded.search(matchQuery: "\"late\"", topK: 10_000)
    try await reopened.close()

    let missing = lateIds.subtracting(hits.map(\.frameId))
    #expect(trialsMissingFrames == 0, "trials whose committed index lacked a frame: \(trialsMissingFrames) of \(trials)")
    #expect(missing.isEmpty, "frames missing after reopen: \(missing.count) of \(lateIds.count)")
}
