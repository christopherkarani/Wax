import Foundation
@preconcurrency import GRDB
import WaxCore

package actor FTS5SearchEngine {
    static let maxResults = 10_000
    private static let bm25ScoreSaturation = 0.000_000_14
    /// FTS5 snippet highlight markers. Private-use codepoints (not '[' ']')
    /// so matched-token highlights never collide with user brackets.
    /// Consumers strip these via the shared dehighlight helper, which
    /// preserves legitimate user brackets.
    package static let snippetOpenMarker = "\u{E000}"
    package static let snippetCloseMarker = "\u{E001}"
    /// Upper bound on queued writes before forcing a flush to SQLite.
    ///
    /// Too small => many transactions (slow). Too large => unbounded memory.
    /// Tuned to collapse typical ingestion loops into a handful of transactions.
    static let flushThreshold = 2_048
    static let structuredFlushThreshold = 512
    let dbQueue: DatabaseQueue
    let io: BlockingIOExecutor
    private let backingStoreDirectory: URL?
    var docCount: UInt64
    var dirty: Bool
    var pendingOps: [Int64: PendingOp] = [:]
    var pendingKeys: [Int64] = []
    var pendingStructuredOps: [StructuredOp] = []

    private init(
        dbQueue: DatabaseQueue,
        io: BlockingIOExecutor,
        backingStoreDirectory: URL?,
        docCount: UInt64,
        dirty: Bool
    ) {
        self.dbQueue = dbQueue
        self.io = io
        self.backingStoreDirectory = backingStoreDirectory
        self.docCount = docCount
        self.dirty = dirty
    }

    deinit {
        guard let url = backingStoreDirectory else { return }
        try? FileManager.default.removeItem(at: url)
    }

    package static func inMemory() throws -> FTS5SearchEngine {
        let io = BlockingIOExecutor(label: "com.wax.fts", qos: .userInitiated)
        let config = makeConfiguration()
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { db in
            try FTS5Schema.create(in: db)
        }
        return FTS5SearchEngine(dbQueue: queue, io: io, backingStoreDirectory: nil, docCount: 0, dirty: false)
    }

    package static func deserialize(from data: Data) throws -> FTS5SearchEngine {
        let io = BlockingIOExecutor(label: "com.wax.fts", qos: .userInitiated)
        let config = makeConfiguration()
        let storeDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("wax-fts5-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: storeDirectory, withIntermediateDirectories: true)
        let dbURL = storeDirectory.appendingPathComponent("fts.sqlite")
        FileManager.default.createFile(atPath: dbURL.path, contents: nil)
        let handle = try FileHandle(forWritingTo: dbURL)
        try handle.write(contentsOf: data)
        try handle.close()

        let queue = try DatabaseQueue(path: dbURL.path, configuration: config)
        try queue.writeWithoutTransaction { db in
            try FTS5Schema.validateOrUpgrade(in: db)
        }
        let count = try queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_mapping") ?? 0
        }
        let docCount = UInt64(max(0, count))
        return FTS5SearchEngine(
            dbQueue: queue,
            io: io,
            backingStoreDirectory: storeDirectory,
            docCount: docCount,
            dirty: false
        )
    }

    package static func load(from wax: Wax) async throws -> FTS5SearchEngine {
        if let bytes = try await wax.readCommittedLexIndexBytes() {
            return try FTS5SearchEngine.deserialize(from: bytes)
        }
        return try FTS5SearchEngine.inMemory()
    }

    package func count() async throws -> Int {
        try await flushPendingOpsIfNeeded()
        return Int(docCount)
    }

    package func serialize(compact: Bool = false) async throws -> Data {
        try await flushPendingOpsIfNeeded()
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.writeWithoutTransaction { db in
                if compact {
                    let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
                    if freelistCount > 0 {
                        try db.execute(sql: "VACUUM")
                    }
                }
                let connection = try Self.requireConnection(db)
                return try FTS5Serializer.serialize(connection: connection)
            }
        }
    }

    package func stageForCommit(into wax: Wax, compact: Bool = false) async throws {
        let metas = await wax.frameMetasIncludingPending()
        try await removeInactiveFrames(metas)
        try await flushPendingOpsIfNeeded()
        if !dirty, !compact { return }
        let blob = try await serialize(compact: compact)
        try await wax.stageLexIndexForNextCommit(bytes: blob, docCount: docCount)
        dirty = false
    }

    enum PendingOp: Sendable, Equatable {
        case upsert(String)
        case delete
    }

    enum StructuredOp: Sendable, Equatable {
        case upsertEntity(key: EntityKey, kind: String, aliases: [String], nowMs: Int64)
        case assertFact(
            subject: EntityKey,
            predicate: PredicateKey,
            object: FactValue,
            relation: VersionRelation,
            valid: StructuredTimeRange,
            system: StructuredTimeRange,
            evidence: [StructuredEvidence],
            factHash: Data
        )
        case retractFact(factId: FactRowID, atMs: Int64)
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        config.prepareDatabase { db in
            try applyPragmas(db)
        }
        return config
    }

    private static func applyPragmas(_ db: Database) throws {
        try db.execute(sql: "PRAGMA journal_mode=DELETE")
        try db.execute(sql: "PRAGMA temp_store=MEMORY")
        try db.execute(sql: "PRAGMA foreign_keys=ON")
    }

    private static func requireConnection(_ db: Database) throws -> OpaquePointer {
        guard let connection = db.sqliteConnection else {
            throw WaxError.io("sqlite connection unavailable")
        }
        return connection
    }

    static func scoreFromBM25Rank(_ rank: Double) -> Double {
        // SQLite FTS5 bm25() rank is "lower is better" (often negative).
        guard rank.isFinite else { return 0 }
        let relevance = max(0, -rank)
        guard relevance > 0 else { return 0 }
        return min(1, relevance / (relevance + bm25ScoreSaturation))
    }

    static func validatedTopK(_ topK: Int) throws -> Int {
        if topK < 1 {
            throw WaxError.encodingError(reason: "topK must be greater than zero")
        }
        if topK > maxResults { return maxResults }
        return topK
    }

    static func toInt64(_ value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else {
            throw WaxError.io("frameId exceeds sqlite int64 range: \(value)")
        }
        return Int64(value)
    }
}
