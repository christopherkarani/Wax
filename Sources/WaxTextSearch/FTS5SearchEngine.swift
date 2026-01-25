import Foundation
@preconcurrency import GRDB
import WaxCore

public actor FTS5SearchEngine {
    private static let maxResults = 10_000
    /// Upper bound on queued writes before forcing a flush to SQLite.
    ///
    /// Too small => many transactions (slow). Too large => unbounded memory.
    /// Tuned to collapse typical ingestion loops into a handful of transactions.
    private static let flushThreshold = 2_048
    private let dbQueue: DatabaseQueue
    private let io: BlockingIOExecutor
    private var docCount: UInt64
    private var dirty: Bool
    private var pendingOps: [Int64: PendingOp] = [:]
    private var pendingKeys: [Int64] = []

    private init(dbQueue: DatabaseQueue, io: BlockingIOExecutor, docCount: UInt64, dirty: Bool) {
        self.dbQueue = dbQueue
        self.io = io
        self.docCount = docCount
        self.dirty = dirty
    }

    public static func inMemory() throws -> FTS5SearchEngine {
        let io = BlockingIOExecutor(label: "com.wax.fts", qos: .userInitiated)
        let config = makeConfiguration()
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { db in
            try FTS5Schema.create(in: db)
        }
        return FTS5SearchEngine(dbQueue: queue, io: io, docCount: 0, dirty: false)
    }

    public static func deserialize(from data: Data) throws -> FTS5SearchEngine {
        let io = BlockingIOExecutor(label: "com.wax.fts", qos: .userInitiated)
        let config = makeConfiguration()
        let queue = try DatabaseQueue(configuration: config)
        try queue.writeWithoutTransaction { db in
            let connection = try requireConnection(db)
            try FTS5Serializer.deserialize(data, into: connection)
            try applyPragmas(db)
            try FTS5Schema.validateOrUpgrade(in: db)
        }
        let count = try queue.read { db in
            try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_mapping") ?? 0
        }
        let docCount = UInt64(max(0, count))
        return FTS5SearchEngine(dbQueue: queue, io: io, docCount: docCount, dirty: false)
    }

    public static func load(from wax: Wax) async throws -> FTS5SearchEngine {
        if let bytes = try await wax.readCommittedLexIndexBytes() {
            return try FTS5SearchEngine.deserialize(from: bytes)
        }
        return try FTS5SearchEngine.inMemory()
    }

    public func count() async throws -> Int {
        try await flushPendingOpsIfNeeded()
        return Int(docCount)
    }

    public func index(frameId: UInt64, text: String) async throws {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty {
            try await remove(frameId: frameId)
            return
        }
        let frameIdValue = try Self.toInt64(frameId)
        enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(trimmed))
        try await flushPendingOpsIfThresholdExceeded()
    }

    /// Batch index multiple frames in a single database transaction.
    /// This amortizes transaction overhead and actor hops across all documents.
    public func indexBatch(frameIds: [UInt64], texts: [String]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == texts.count else {
            throw WaxError.encodingError(reason: "indexBatch: frameIds.count != texts.count")
        }

        for (frameId, text) in zip(frameIds, texts) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            let frameIdValue = try Self.toInt64(frameId)
            enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(trimmed))
        }
        try await flushPendingOpsIfThresholdExceeded()
    }

    public func remove(frameId: UInt64) async throws {
        let frameIdValue = try Self.toInt64(frameId)
        enqueuePendingOp(frameIdValue: frameIdValue, op: .delete)
        try await flushPendingOpsIfThresholdExceeded()
    }

    public func search(query: String, topK: Int) async throws -> [TextSearchResult] {
        try await flushPendingOpsIfNeeded()
        let trimmed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = Self.clampTopK(topK)
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = """
                    SELECT m.frame_id AS frame_id,
                           bm25(frames_fts) AS rank,
                           snippet(frames_fts, 0, '[', ']', '...', 10) AS snippet
                    FROM frames_fts
                    JOIN frame_mapping m ON m.rowid_ref = frames_fts.rowid
                    WHERE frames_fts MATCH ?
                    ORDER BY rank ASC, m.frame_id ASC
                    LIMIT ?
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [trimmed, limit])
                return rows.compactMap { row in
                    guard let frameIdValue: Int64 = row["frame_id"], frameIdValue >= 0 else { return nil }
                    let rank: Double = row["rank"] ?? 0
                    let snippet: String? = row["snippet"]
                    return TextSearchResult(
                        frameId: UInt64(frameIdValue),
                        score: Self.scoreFromBM25Rank(rank),
                        snippet: snippet
                    )
                }
            }
        }
    }

    public func serialize(compact: Bool = false) async throws -> Data {
        try await flushPendingOpsIfNeeded()
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.writeWithoutTransaction { db in
                if compact {
                    try db.execute(sql: "VACUUM")
                }
                let connection = try Self.requireConnection(db)
                return try FTS5Serializer.serialize(connection: connection)
            }
        }
    }

    public func stageForCommit(into wax: Wax, compact: Bool = false) async throws {
        try await flushPendingOpsIfNeeded()
        if !dirty, !compact { return }
        let blob = try await serialize(compact: compact)
        try await wax.stageLexIndexForNextCommit(bytes: blob, docCount: docCount)
        dirty = false
    }

    private enum PendingOp: Sendable, Equatable {
        case upsert(String)
        case delete
    }

    private func enqueuePendingOp(frameIdValue: Int64, op: PendingOp) {
        if pendingOps[frameIdValue] == nil {
            pendingKeys.append(frameIdValue)
        }
        pendingOps[frameIdValue] = op
        dirty = true
    }

    private func flushPendingOpsIfThresholdExceeded() async throws {
        guard pendingOps.count >= Self.flushThreshold else { return }
        try await flushPendingOpsIfNeeded()
    }

    private func flushPendingOpsIfNeeded() async throws {
        guard !pendingOps.isEmpty else { return }

        let ops = pendingOps
        let keys = pendingKeys
        let dbQueue = self.dbQueue

        let (addedCount, removedCount) = try await io.run { () throws -> (added: Int, removed: Int) in
            var added = 0
            var removed = 0

            try dbQueue.write { db in
                let deleteFramesStmt = try db.makeStatement(sql: """
                    DELETE FROM frames_fts
                    WHERE rowid IN (SELECT rowid_ref FROM frame_mapping WHERE frame_id = ?)
                    """)
                let deleteMappingStmt = try db.makeStatement(sql: """
                    DELETE FROM frame_mapping
                    WHERE frame_id = ?
                    """)
                let insertFrameStmt = try db.makeStatement(sql: """
                    INSERT INTO frames_fts(content) VALUES (?)
                    """)
                let insertMappingStmt = try db.makeStatement(sql: """
                    INSERT INTO frame_mapping(frame_id, rowid_ref) VALUES (?, ?)
                    """)

                for frameIdValue in keys {
                    guard let op = ops[frameIdValue] else { continue }

                    switch op {
                    case .upsert(let text):
                        try deleteFramesStmt.execute(arguments: [frameIdValue])
                        try deleteMappingStmt.execute(arguments: [frameIdValue])
                        let existed = db.changesCount > 0
                        if !existed { added += 1 }

                        try insertFrameStmt.execute(arguments: [text])
                        let rowid = db.lastInsertedRowID
                        try insertMappingStmt.execute(arguments: [frameIdValue, rowid])

                    case .delete:
                        try deleteFramesStmt.execute(arguments: [frameIdValue])
                        try deleteMappingStmt.execute(arguments: [frameIdValue])
                        if db.changesCount > 0 { removed += 1 }
                    }
                }
            }

            return (added, removed)
        }

        if addedCount > 0 {
            docCount &+= UInt64(addedCount)
        }
        if removedCount > 0 {
            let removedU = UInt64(removedCount)
            docCount = docCount > removedU ? (docCount &- removedU) : 0
        }

        pendingOps.removeAll(keepingCapacity: true)
        pendingKeys.removeAll(keepingCapacity: true)
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
    }

    private static func requireConnection(_ db: Database) throws -> OpaquePointer {
        guard let connection = db.sqliteConnection else {
            throw WaxError.io("sqlite connection unavailable")
        }
        return connection
    }

    private static func scoreFromBM25Rank(_ rank: Double) -> Double {
        // SQLite FTS5 bm25() rank is "lower is better" (often negative).
        // Expose a score where "higher is better".
        guard rank.isFinite else { return 0 }
        return -rank
    }

    private static func clampTopK(_ topK: Int) -> Int {
        if topK < 1 { return 1 }
        if topK > maxResults { return maxResults }
        return topK
    }

    private static func toInt64(_ value: UInt64) throws -> Int64 {
        guard value <= UInt64(Int64.max) else {
            throw WaxError.io("frameId exceeds sqlite int64 range: \(value)")
        }
        return Int64(value)
    }
}
