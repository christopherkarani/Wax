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
    var dirty: Bool
    private var pendingOps: [Int64: PendingOp] = [:]
    private var pendingKeys: [Int64] = []
    var afterFlushWriteForTesting: (@Sendable () async throws -> Void)?
    var pendingStructuredOps: [StructuredOp] = []
    /// Every text-indexable frame below this id is indexed (or was when it was staged).
    /// Frames at or above it may be durable without postings; see `FTS5SearchEngine+Coverage.swift`.
    var coveredBelowFrameId: UInt64
    /// `false` until the blob stores a watermark. A blob written before the watermark existed
    /// vouches for nothing, so catch-up scans every frame once and the next commit records it.
    var coverageRecorded: Bool
    /// The on-disk database the read-only fan-out connections open; `nil` in memory.
    let databaseURL: URL?
    let searchFanOut: SearchFanOut
    var readerPool: Task<[DatabaseQueue], any Error>?
    var lastSearchPartitionCount = 1
    /// Fan-out reads in flight, and whether a write on the writer connection is running.
    /// Together they keep every partition of one search on the same snapshot.
    var fanOutReadsInFlight = 0
    var writeInProgress = false
    var writeGateWaiters: [CheckedContinuation<Void, Never>] = []
    /// Writers queued at the gate, and fan-out reads held back behind them.
    var writersWaiting = 0
    var fanOutReadersWaiting = 0
    var duringFanOutReadForTesting: (@Sendable () async -> Void)?
    /// Holds on `search` (FTS5SearchEngine+SearchHold.swift): searches wait while any is
    /// held, and a hold waits for the searches already running.
    var searchHolds = 0
    var searchesInFlight = 0
    var searchHoldReleaseWaiters: [CheckedContinuation<Void, Never>] = []
    var searchDrainWaiters: [CheckedContinuation<Void, Never>] = []
    /// Inactive frames whose postings this engine deleted and has not indexed since. Deleted
    /// and superseded frames stay inactive, so `removeInactiveFrames` skips them.
    private var removedInactiveFrameIds: Set<Int64> = []
    /// Inactive frames `removeInactiveFrames` has deleted postings for.
    private(set) var inactiveFrameRemovalsForTesting = 0
    private var lastStagedImageWasBorrowed: Bool?

    private init(
        dbQueue: DatabaseQueue,
        io: BlockingIOExecutor,
        backingStoreDirectory: URL?,
        docCount: UInt64,
        dirty: Bool,
        coveredBelowFrameId: UInt64? = nil,
        databaseURL: URL? = nil,
        searchFanOut: SearchFanOut = .disabled
    ) {
        self.dbQueue = dbQueue
        self.io = io
        self.backingStoreDirectory = backingStoreDirectory
        self.databaseURL = databaseURL
        self.searchFanOut = searchFanOut
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
        // Reopened from its own image, the database lives in one SQLite-owned buffer, which
        // `stageForCommit` hands to the store without copying it.
        try queue.writeWithoutTransaction { db in
            let connection = try Self.requireConnection(db)
            try FTS5Serializer.deserialize(try FTS5Serializer.serialize(connection: connection), into: connection)
            db.clearSchemaCache()
        }
        return FTS5SearchEngine(dbQueue: queue, io: io, backingStoreDirectory: nil, docCount: 0, dirty: false)
    }

    package static func deserialize(
        from data: Data,
        searchFanOut: SearchFanOut = .default
    ) throws -> FTS5SearchEngine {
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
        let (count, coveredBelowFrameId) = try queue.read { db in
            let count = try Int64.fetchOne(db, sql: "SELECT COUNT(*) FROM frame_mapping") ?? 0
            return (count, try FTS5Coverage.coveredBelowFrameId(in: db))
        }
        let docCount = UInt64(max(0, count))
        return FTS5SearchEngine(
            dbQueue: queue,
            io: io,
            backingStoreDirectory: storeDirectory,
            docCount: docCount,
            dirty: false,
            coveredBelowFrameId: coveredBelowFrameId,
            databaseURL: dbURL,
            searchFanOut: searchFanOut
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
            let frameId = try Self.toInt64(meta.id)
            return removedInactiveFrameIds.contains(frameId) ? nil : frameId
        }
        guard !inactiveFrameIds.isEmpty else { return }

        try await flushPendingOpsIfNeeded()
        await beginWrite()
        defer { endWrite() }
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
        // Ops queued while the delete ran are indexed by a later flush, which forgets them here.
        for frameId in inactiveFrameIds where pendingOps[frameId] == nil {
            removedInactiveFrameIds.insert(frameId)
        }
        inactiveFrameRemovalsForTesting += inactiveFrameIds.count

        if removedCount > 0 {
            let removedU = UInt64(removedCount)
            docCount = docCount > removedU ? (docCount &- removedU) : 0
            dirty = true
        }
    }

    package func search(matchQuery: String, topK: Int) async throws -> [TextSearchResult] {
        await beginSearch()
        defer { endSearch() }
        try await flushPendingOpsIfNeeded()
        let trimmed = matchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return [] }
        let limit = try Self.validatedTopK(topK)
        let partitions = databaseURL == nil ? 1 : searchFanOut.partitionCount(docCount: docCount)
        lastSearchPartitionCount = partitions
        let rows: [MatchRow]
        if partitions > 1 {
            rows = try await fanOutMatchRows(matchQuery: trimmed, limit: limit, partitions: partitions)
        } else {
            let dbQueue = self.dbQueue
            rows = try await io.run {
                try dbQueue.read { db in
                    try Self.matchRows(db, matchQuery: trimmed, limit: limit, rowidRange: nil)
                }
            }
        }
        // Rows are ordered best-first, so the first row is this query's best
        // match whatever the limit is.
        let topRank = rows.first?.rank ?? 0
        return rows.compactMap { row in
            guard let frameId = row.frameId, frameId >= 0 else { return nil }
            return TextSearchResult(
                frameId: UInt64(frameId),
                score: Self.score(bm25Rank: row.rank, topBM25Rank: topRank),
                snippet: row.snippet
            )
        }
    }

    /// Partitions the most recent `search(matchQuery:topK:)` ran on.
    package func lastSearchPartitionCountForTesting() -> Int {
        lastSearchPartitionCount
    }

    /// Runs after a flush's database write returns and before the flush settles its ops,
    /// which is where other calls can queue ops while the write is in flight.
    /// Runs inside every fan-out read, after it passes the write gate.
    package func setDuringFanOutReadForTesting(_ hook: (@Sendable () async -> Void)?) {
        duringFanOutReadForTesting = hook
    }

    package func writersWaitingForTesting() -> Int { writersWaiting }
    package func fanOutReadersWaitingForTesting() -> Int { fanOutReadersWaiting }
    package func fanOutReadsInFlightForTesting() -> Int { fanOutReadsInFlight }

    package func setAfterFlushWriteForTesting(_ hook: (@Sendable () async throws -> Void)?) {
        afterFlushWriteForTesting = hook
    }

    package func serialize(compact: Bool = false) async throws -> Data {
        try await flushPendingOpsIfNeeded()
        // VACUUM rewrites the file the fan-out readers have open.
        await beginWrite()
        defer { endWrite() }
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.writeWithoutTransaction { db in
                if compact {
                    try Self.vacuumIfFragmented(db)
                }
                let connection = try Self.requireConnection(db)
                return try FTS5Serializer.serialize(connection: connection)
            }
        }
    }

    package func stageForCommit(into wax: Wax, compact: Bool = false) async throws {
        // Both steps below read only inactive frames and frames at or above the watermark,
        // which only `recordCoverage` moves, and only up.
        let metas = await wax.frameMetasForTextStaging(atOrAbove: coveredBelowFrameId)
        try await removeInactiveFrames(metas)
        try await flushPendingOpsIfNeeded()
        if !dirty, !compact { return }
        try await recordCoverage(of: metas)
        try await flushPendingOpsIfNeeded()
        // Ops queued while the flushes above awaited, or from here on, are not in the image
        // staged below; they keep the engine dirty so the next stage writes them.
        dirty = !pendingOps.isEmpty || !pendingStructuredOps.isEmpty
        do {
            try await stageImage(into: wax, compact: compact)
        } catch {
            dirty = true
            throw error
        }
    }

    /// Hands the store the database image, which it compares page by page with the committed
    /// one to keep only the changed pages. A borrowed image is SQLite's own buffer, so writes
    /// wait until the store has read it. When a commit holds the store, the image is copied
    /// instead, so writes do not wait out the commit's fsyncs.
    private func stageImage(into wax: Wax, compact: Bool) async throws {
        await beginWrite()
        var holdsWriteGate = true
        defer { if holdsWriteGate { endWrite() } }
        let dbQueue = self.dbQueue
        let image = try await io.run { () throws -> (bytes: Data, borrowed: Bool) in
            try dbQueue.writeWithoutTransaction { db in
                if compact {
                    try Self.vacuumIfFragmented(db)
                }
                return try FTS5Serializer.image(connection: try Self.requireConnection(db))
            }
        }
        // Flushes change the count only under the write gate, so it matches the image.
        let imageDocCount = docCount
        var bytes = image.bytes
        if image.borrowed {
            if try await wax.stageLexIndexForNextCommitIfUncontended(bytes: bytes, docCount: imageDocCount) {
                lastStagedImageWasBorrowed = true
                return
            }
            bytes = image.bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> Data in Data(raw) }
        }
        holdsWriteGate = false
        endWrite()
        try await wax.stageLexIndexForNextCommit(bytes: bytes, docCount: imageDocCount)
        lastStagedImageWasBorrowed = false
    }

    /// Whether the last `stageForCommit` handed the store SQLite's buffer instead of a copy.
    package func lastStagedImageWasBorrowedForTesting() -> Bool? {
        lastStagedImageWasBorrowed
    }

    private enum PendingOp: Sendable, Equatable {
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

    /// Queues an upsert unless the frame already has a queued op. Returns whether it queued one.
    func enqueueCatchUpUpsert(frameIdValue: Int64, text: String) -> Bool {
        guard pendingOps[frameIdValue] == nil else { return false }
        enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(text))
        return true
    }

    private func enqueuePendingOp(frameIdValue: Int64, op: PendingOp) {
        removedInactiveFrameIds.remove(frameIdValue)
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

    func flushPendingOpsIfNeeded() async throws {
        guard !pendingOps.isEmpty else {
            if !pendingStructuredOps.isEmpty {
                try await flushPendingStructuredOpsIfNeeded()
            }
            return
        }
        try await flushPendingFrameOps()
        if !pendingStructuredOps.isEmpty {
            try await flushPendingStructuredOpsIfNeeded()
        }
    }

    private func flushPendingFrameOps() async throws {
        await beginWrite()
        defer { endWrite() }
        // Another flush may have written these ops while this one waited for the gate.
        guard !pendingOps.isEmpty else { return }

        let ops = pendingOps
        let keys = pendingKeys
        let dbQueue = self.dbQueue

        let (addedCount, removedCount) = try await io.run { () throws -> (added: Int, removed: Int) in
            var added = 0
            var removed = 0

            try dbQueue.write { db in
                let mappedRowStmt = try db.makeStatement(sql: """
                    SELECT rowid_ref FROM frame_mapping WHERE frame_id = ?
                    """)
                // Deletes one row by rowid only once the mapping names it. A multi-row DELETE
                // on frames_fts opens a statement savepoint, and FTS5 writes out its pending
                // terms at every savepoint, so running one per new frame turned each insert
                // into a segment flush plus merge work.
                let deleteFrameStmt = try db.makeStatement(sql: """
                    DELETE FROM frames_fts WHERE rowid = ?
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

                /// Removes the frame's row and mapping; returns whether it was indexed.
                func removeIndexedFrame(_ frameId: Int64) throws -> Bool {
                    guard let rowid = try Int64.fetchOne(mappedRowStmt, arguments: [frameId]) else {
                        return false
                    }
                    try deleteFrameStmt.execute(arguments: [rowid])
                    try deleteMappingStmt.execute(arguments: [frameId])
                    return true
                }

                for frameIdValue in keys {
                    guard let op = ops[frameIdValue] else { continue }

                    switch op {
                    case .upsert(let text):
                        if try !removeIndexedFrame(frameIdValue) { added += 1 }

                        try insertFrameStmt.execute(arguments: [text])
                        let rowid = db.lastInsertedRowID
                        try insertMappingStmt.execute(arguments: [frameIdValue, rowid])

                    case .delete:
                        if try removeIndexedFrame(frameIdValue) { removed += 1 }
                    }
                }
            }

            return (added, removed)
        }
        if let afterFlushWriteForTesting {
            try await afterFlushWriteForTesting()
        }

        if addedCount > 0 {
            docCount &+= UInt64(addedCount)
        }
        if removedCount > 0 {
            let removedU = UInt64(removedCount)
            docCount = docCount > removedU ? (docCount &- removedU) : 0
        }

        // Other calls can queue ops while the write is awaited. Settle only the ops this
        // flush wrote; a newer op for the same frame stays queued for the next flush.
        for key in keys where pendingOps[key] == ops[key] {
            pendingOps[key] = nil
        }
        pendingKeys.removeAll { pendingOps[$0] == nil }
    }

    private static func makeConfiguration() -> Configuration {
        var config = Configuration()
        // Fan-out readers hold shared locks while they scan; a commit waits for them.
        config.busyMode = .timeout(busyTimeoutSeconds)
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

    private static func vacuumIfFragmented(_ db: Database) throws {
        let freelistCount = try Int.fetchOne(db, sql: "PRAGMA freelist_count") ?? 0
        if freelistCount > 0 {
            try db.execute(sql: "VACUUM")
        }
    }

    private static func requireConnection(_ db: Database) throws -> OpaquePointer {
        guard let connection = db.sqliteConnection else {
            throw WaxError.io("sqlite connection unavailable")
        }
        return connection
    }

    /// Above this BM25 relevance, a match has at least one query term with real IDF.
    ///
    /// FTS5 clamps the IDF of a term found in half the rows or more to 1e-6, so such a
    /// term adds at most 1e-6 × (k1 + 1) = 2.2e-6. Even 20 clamped MATCH clauses (16
    /// tokens and 4 phrases, the planner's caps) stay under 5e-5.
    static let clampedIDFRelevanceCeiling = 0.000_1

    /// Published score for one row of a query whose best row has rank `topRank`.
    ///
    /// When the best match has real IDF, the score is the best match's confidence
    /// times this row's share of its BM25 relevance. The saturation curve alone maps
    /// every ordinary BM25 value (about 1 to 40) to within 1e-7 of 1, the same
    /// `Float`, so rerankers that add small signals to the score saw a tie and
    /// reordered by those signals alone. The ratio keeps BM25's order and spacing.
    ///
    /// When every term's IDF is clamped (tiny or uniform corpora), BM25 only
    /// measures term frequency and length, so the per-row curve is kept and its
    /// near-ties stay for rerank signals to break.
    static func score(bm25Rank rank: Double, topBM25Rank topRank: Double) -> Double {
        let topRelevance = topRank.isFinite ? max(0, -topRank) : 0
        guard topRelevance > clampedIDFRelevanceCeiling else { return scoreFromBM25Rank(rank) }
        let relevance = rank.isFinite ? max(0, -rank) : 0
        return scoreFromBM25Rank(topRank) * min(1, relevance / topRelevance)
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
