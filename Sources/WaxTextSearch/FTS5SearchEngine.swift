import Foundation
@preconcurrency import GRDB
import WaxCore

#if canImport(Glibc)
import Glibc
#endif

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
    private static let flushThreshold = 2_048
    static let structuredFlushThreshold = 512
    /// Internal (not `private`) only because the engine is split across `FTS5SearchEngine+*.swift`
    /// files. Use it only from actor-isolated code paths of this engine.
    let dbQueue: DatabaseQueue
    /// Internal (not `private`) only because the engine is split across `FTS5SearchEngine+*.swift`
    /// files. Use it only from actor-isolated code paths of this engine.
    let io: BlockingIOExecutor
    private let backingStoreDirectory: URL?
    private var docCount: UInt64
    /// Set through `markDirty()`, so every mutation also bumps `mutationGeneration`.
    private(set) var dirty: Bool
    /// Bumped on every mutation, so `stageForCommit` can tell whether one landed while it was
    /// suspended and must leave the engine dirty.
    private var mutationGeneration: UInt64 = 0
    private var pendingOps: [Int64: PendingOp] = [:]
    private var pendingKeys: [Int64] = []
    var pendingStructuredOps: [QueuedStructuredOp] = []
    var nextStructuredOpId: UInt64 = 0
    /// Ops whose caller is still waiting for the flush that applies them.
    var awaitedStructuredOpIds: Set<UInt64> = []
    /// Errors for awaited ops that a flush rejected and dropped, until their caller takes them.
    var structuredOpRejections: [UInt64: WaxError] = [:]
    /// Flushes are mutually exclusive. The queues are snapshotted before an `await`, so a flush
    /// that overlapped another would re-apply the in-flight snapshot; see `acquireFlushGate()`.
    private var flushGateHeld = false
    private var flushGateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Every text-indexable frame below this id is indexed (or was when it was staged).
    /// Frames at or above it may be durable without postings; see `FTS5SearchEngine+Coverage.swift`.
    var coveredBelowFrameId: UInt64
    /// `false` until the blob stores a watermark. A blob written before the watermark existed
    /// vouches for nothing, so catch-up scans every frame once and the next commit records it.
    var coverageRecorded: Bool

    private init(
        dbQueue: DatabaseQueue,
        io: BlockingIOExecutor,
        backingStoreDirectory: URL?,
        docCount: UInt64,
        dirty: Bool,
        coveredBelowFrameId: UInt64? = nil
    ) {
        self.dbQueue = dbQueue
        self.io = io
        self.backingStoreDirectory = backingStoreDirectory
        self.docCount = docCount
        self.dirty = dirty
        self.coveredBelowFrameId = coveredBelowFrameId ?? 0
        self.coverageRecorded = coveredBelowFrameId != nil
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
        // The copy holds the full text of every memory: owner-only from the moment it exists,
        // since a shared /tmp (Linux) is readable by other local users.
        guard mkdir(storeDirectory.path, 0o700) == 0 else {
            throw WaxError.io("failed to create text index directory: errno \(errno)")
        }
        let opened: (queue: DatabaseQueue, count: Int64, coveredBelowFrameId: UInt64?)
        do {
            opened = try openBackingStore(
                at: storeDirectory.appendingPathComponent("fts.sqlite"),
                data: data,
                configuration: config
            )
        } catch {
            // Do not leave a plaintext copy of a blob that failed to open. The helper's queue,
            // if any, is already closed, so the file is not unlinked while SQLite holds it.
            try? FileManager.default.removeItem(at: storeDirectory)
            throw error
        }
        let (queue, count, coveredBelowFrameId) = opened
        let docCount = UInt64(max(0, count))
        return FTS5SearchEngine(
            dbQueue: queue,
            io: io,
            backingStoreDirectory: storeDirectory,
            docCount: docCount,
            dirty: false,
            coveredBelowFrameId: coveredBelowFrameId
        )
    }

    /// Writes `data` to a new owner-only file at `dbURL`, opens it, and validates the schema.
    private static func openBackingStore(
        at dbURL: URL,
        data: Data,
        configuration: Configuration
    ) throws -> (queue: DatabaseQueue, count: Int64, coveredBelowFrameId: UInt64?) {
        guard FileManager.default.createFile(
            atPath: dbURL.path,
            contents: nil,
            attributes: [.posixPermissions: 0o600]
        ) else {
            throw WaxError.io("failed to create text index file")
        }
        let handle = try FileHandle(forWritingTo: dbURL)
        try handle.write(contentsOf: data)
        try handle.close()

        let queue = try DatabaseQueue(path: dbURL.path, configuration: configuration)
        try queue.writeWithoutTransaction { db in
            try FTS5Schema.validateOrUpgrade(in: db)
        }
        let (count, coveredBelowFrameId) = try queue.read { db in
            let count = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_mapping") ?? 0
            return (count, try FTS5Coverage.coveredBelowFrameId(in: db))
        }
        return (queue, count, coveredBelowFrameId)
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

    package func index(frameId: UInt64, text: String) async throws {
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
    package func indexBatch(frameIds: [UInt64], texts: [String]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == texts.count else {
            throw WaxError.encodingError(reason: "indexBatch: frameIds.count != texts.count")
        }

        for (frameId, text) in zip(frameIds, texts) {
            let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
            let frameIdValue = try Self.toInt64(frameId)
            if trimmed.isEmpty {
                enqueuePendingOp(frameIdValue: frameIdValue, op: .delete)
            } else {
                enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(trimmed))
            }
        }
        try await flushPendingOpsIfThresholdExceeded()
    }

    package func remove(frameId: UInt64) async throws {
        let frameIdValue = try Self.toInt64(frameId)
        enqueuePendingOp(frameIdValue: frameIdValue, op: .delete)
        try await flushPendingOpsIfThresholdExceeded()
    }

    package func removeInactiveFrames(_ metas: [FrameMeta]) async throws {
        let inactiveFrameIds = try metas.compactMap { meta -> Int64? in
            guard meta.status == .deleted || meta.supersededBy != nil else { return nil }
            return try Self.toInt64(meta.id)
        }
        guard !inactiveFrameIds.isEmpty else { return }

        try await flushPendingOpsIfNeeded()
        let dbQueue = self.dbQueue
        let removedCount = try await io.run {
            try dbQueue.write { db in
                let deleteFramesStmt = try db.makeStatement(sql: """
                    DELETE FROM frames_fts
                    WHERE rowid IN (SELECT rowid_ref FROM frame_mapping WHERE frame_id = ?)
                    """)
                let deleteMappingStmt = try db.makeStatement(sql: """
                    DELETE FROM frame_mapping
                    WHERE frame_id = ?
                    """)
                var removed = 0
                for frameId in inactiveFrameIds {
                    try deleteFramesStmt.execute(arguments: [frameId])
                    try deleteMappingStmt.execute(arguments: [frameId])
                    if db.changesCount > 0 { removed += 1 }
                }
                return removed
            }
        }

        if removedCount > 0 {
            let removedU = UInt64(removedCount)
            docCount = docCount > removedU ? (docCount &- removedU) : 0
            markDirty()
        }
    }

    package func search(matchQuery: String, topK: Int) async throws -> [TextSearchResult] {
        try await flushPendingOpsIfNeeded()
        let trimmed = matchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = try Self.validatedTopK(topK)
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = """
                    SELECT m.frame_id AS frame_id,
                           bm25(frames_fts) AS rank,
                           snippet(frames_fts, 0, '\(Self.snippetOpenMarker)', '\(Self.snippetCloseMarker)', '...', 10) AS snippet
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
        // Every mutation before this point is flushed by `serialize` and is in the blob.
        let stagedGeneration = mutationGeneration
        try await recordCoverage(of: metas)
        let blob = try await serialize(compact: compact)
        try await wax.stageLexIndexForNextCommit(bytes: blob, docCount: docCount)
        if mutationGeneration == stagedGeneration {
            dirty = false
        }
    }

    private enum PendingOp: Sendable, Equatable {
        case upsert(String)
        case delete
    }

    struct QueuedStructuredOp: Sendable {
        let id: UInt64
        let op: StructuredOp
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

    /// Queues an upsert unless the frame already has a queued op. Returns whether it queued one.
    func enqueueCatchUpUpsert(frameIdValue: Int64, text: String) -> Bool {
        guard pendingOps[frameIdValue] == nil else { return false }
        enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(text))
        return true
    }

    private func enqueuePendingOp(frameIdValue: Int64, op: PendingOp) {
        if pendingOps[frameIdValue] == nil {
            pendingKeys.append(frameIdValue)
        }
        pendingOps[frameIdValue] = op
        markDirty()
    }

    func markDirty() {
        dirty = true
        mutationGeneration &+= 1
    }

    private func flushPendingOpsIfThresholdExceeded() async throws {
        guard pendingOps.count >= Self.flushThreshold else { return }
        try await flushPendingOpsIfNeeded()
    }

    /// Waits until no other flush is in flight, then takes the gate. Pair with `releaseFlushGate()`.
    func acquireFlushGate() async {
        guard flushGateHeld else {
            flushGateHeld = true
            return
        }
        // The releasing flush hands the gate straight to the first waiter.
        await withCheckedContinuation { flushGateWaiters.append($0) }
    }

    func releaseFlushGate() {
        if flushGateWaiters.isEmpty {
            flushGateHeld = false
        } else {
            flushGateWaiters.removeFirst().resume()
        }
    }

    func flushPendingOpsIfNeeded() async throws {
        try await flushPendingTextOpsIfNeeded()
        if !pendingStructuredOps.isEmpty {
            try await flushPendingStructuredOpsIfNeeded()
        }
    }

    /// Writes a snapshot of the queued text ops. Ops queued while the write is in flight, or
    /// that replace a snapshotted op, stay queued; on a throw the whole snapshot stays queued.
    private func flushPendingTextOpsIfNeeded() async throws {
        guard !pendingOps.isEmpty else { return }
        await acquireFlushGate()
        defer { releaseFlushGate() }
        // The flush this one waited for may have written everything.
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

        for frameIdValue in keys where pendingOps[frameIdValue] == ops[frameIdValue] {
            pendingOps.removeValue(forKey: frameIdValue)
        }
        pendingKeys.removeAll { pendingOps[$0] == nil }
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

    private static func scoreFromBM25Rank(_ rank: Double) -> Double {
        // SQLite FTS5 bm25() rank is "lower is better" (often negative).
        guard rank.isFinite else { return 0 }
        let relevance = max(0, -rank)
        guard relevance > 0 else { return 0 }
        return min(1, relevance / (relevance + bm25ScoreSaturation))
    }

    private static func validatedTopK(_ topK: Int) throws -> Int {
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
