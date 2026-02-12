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
    private static let structuredFlushThreshold = 512
    private let dbQueue: DatabaseQueue
    private let io: BlockingIOExecutor
    private let backingStoreDirectory: URL?
    private var docCount: UInt64
    private var dirty: Bool
    private var pendingOps: [Int64: PendingOp] = [:]
    private var pendingKeys: [Int64] = []
    private var pendingStructuredOps: [StructuredOp] = []

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

    public static func inMemory() throws -> FTS5SearchEngine {
        let io = BlockingIOExecutor(label: "com.wax.fts", qos: .userInitiated)
        let config = makeConfiguration()
        let queue = try DatabaseQueue(configuration: config)
        try queue.write { db in
            try FTS5Schema.create(in: db)
        }
        return FTS5SearchEngine(dbQueue: queue, io: io, backingStoreDirectory: nil, docCount: 0, dirty: false)
    }

    public static func deserialize(from data: Data) throws -> FTS5SearchEngine {
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
            let frameIdValue = try Self.toInt64(frameId)
            if trimmed.isEmpty {
                enqueuePendingOp(frameIdValue: frameIdValue, op: .delete)
            } else {
                enqueuePendingOp(frameIdValue: frameIdValue, op: .upsert(trimmed))
            }
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

    // MARK: - Structured Memory

    public func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String],
        nowMs: Int64
    ) async throws -> EntityRowID {
        enqueueStructuredOp(.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs))
        try await flushPendingStructuredOpsIfThresholdExceeded()
        try await flushPendingStructuredOpsIfNeeded()
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = "SELECT entity_id FROM sm_entity WHERE key = ?"
                guard let entityId: Int64 = try Int64.fetchOne(db, sql: sql, arguments: [key.rawValue]) else {
                    throw WaxError.io("entity_id lookup failed after upsert")
                }
                return EntityRowID(rawValue: entityId)
            }
        }
    }

    public func resolveEntities(matchingAlias alias: String, limit: Int) async throws -> [StructuredEntityMatch] {
        try await flushPendingOpsIfNeeded()
        let normalized = StructuredMemoryCanonicalizer.normalizedAlias(alias)
        guard !normalized.isEmpty else { return [] }
        let capped = max(0, min(limit, 10_000))

        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = """
                    SELECT e.entity_id AS entity_id,
                           e.key AS entity_key,
                           e.kind AS entity_kind
                    FROM sm_entity_alias a
                    JOIN sm_entity e ON e.entity_id = a.entity_id
                    WHERE a.alias_norm = ?
                    ORDER BY e.key ASC
                    LIMIT ?
                    """
                let rows = try Row.fetchAll(db, sql: sql, arguments: [normalized, capped])
                return rows.compactMap { row in
                    guard let id: Int64 = row["entity_id"] else { return nil }
                    let key: String = row["entity_key"] ?? ""
                    let kind: String = row["entity_kind"] ?? ""
                    return StructuredEntityMatch(id: id, key: EntityKey(key), kind: kind)
                }
            }
        }
    }

    public func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        valid: StructuredTimeRange,
        system: StructuredTimeRange,
        evidence: [StructuredEvidence]
    ) async throws -> FactRowID {
        guard valid.toMs == nil || valid.toMs! > valid.fromMs else {
            throw WaxError.encodingError(reason: "valid_to_ms must be greater than valid_from_ms")
        }
        guard system.toMs == nil || system.toMs! > system.fromMs else {
            throw WaxError.encodingError(reason: "system_to_ms must be greater than system_from_ms")
        }

        let factHash = try StructuredMemoryHasher.hashFact(
            subject: subject,
            predicate: predicate,
            object: object,
            qualifiersHash: nil
        )

        enqueueStructuredOp(
            .assertFact(
                subject: subject,
                predicate: predicate,
                object: object,
                valid: valid,
                system: system,
                evidence: evidence,
                factHash: factHash
            )
        )
        try await flushPendingStructuredOpsIfThresholdExceeded()
        try await flushPendingStructuredOpsIfNeeded()

        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = "SELECT fact_id FROM sm_fact WHERE fact_hash = ?"
                guard let factId: Int64 = try Int64.fetchOne(db, sql: sql, arguments: [factHash]) else {
                    throw WaxError.io("fact_id lookup failed after assertion")
                }
                return FactRowID(rawValue: factId)
            }
        }
    }

    public func retractFact(factId: FactRowID, atMs: Int64) async throws {
        enqueueStructuredOp(.retractFact(factId: factId, atMs: atMs))
        try await flushPendingStructuredOpsIfThresholdExceeded()
        try await flushPendingStructuredOpsIfNeeded()
    }

    public func facts(
        about subject: EntityKey?,
        predicate: PredicateKey?,
        asOf: StructuredMemoryAsOf,
        limit: Int
    ) async throws -> StructuredFactsResult {
        try await flushPendingOpsIfNeeded()
        let capped = max(0, min(limit, Self.maxResults))
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                var whereClauses: [String] = []
                var args: [any DatabaseValueConvertible] = []

                whereClauses.append("s.system_from_ms <= ?")
                args.append(asOf.systemTimeMs)
                whereClauses.append("(s.system_to_ms IS NULL OR s.system_to_ms > ?)")
                args.append(asOf.systemTimeMs)
                whereClauses.append("s.valid_from_ms <= ?")
                args.append(asOf.validTimeMs)
                whereClauses.append("(s.valid_to_ms IS NULL OR s.valid_to_ms > ?)")
                args.append(asOf.validTimeMs)

                if let subject {
                    whereClauses.append("subj.key = ?")
                    args.append(subject.rawValue)
                }
                if let predicate {
                    whereClauses.append("pred.key = ?")
                    args.append(predicate.rawValue)
                }

                let whereSQL = whereClauses.isEmpty ? "1 = 1" : whereClauses.joined(separator: " AND ")

                let sql = """
                    SELECT f.fact_id AS fact_id,
                           subj.key AS subject_key,
                           pred.key AS predicate_key,
                           f.object_kind AS object_kind,
                           f.object_text AS object_text,
                           f.object_int AS object_int,
                           f.object_real AS object_real,
                           f.object_bool AS object_bool,
                           f.object_blob AS object_blob,
                           f.object_time_ms AS object_time_ms,
                           obj.key AS object_entity_key,
                           s.valid_from_ms AS valid_from_ms,
                           s.valid_to_ms AS valid_to_ms,
                           s.system_to_ms AS system_to_ms
                    FROM sm_fact_span s
                    JOIN sm_fact f ON f.fact_id = s.fact_id
                    JOIN sm_entity subj ON subj.entity_id = f.subject_entity_id
                    JOIN sm_predicate pred ON pred.predicate_id = f.predicate_id
                    LEFT JOIN sm_entity obj ON obj.entity_id = f.object_entity_id
                    WHERE \(whereSQL)
                    ORDER BY pred.key ASC,
                             f.object_kind ASC,
                             COALESCE(
                               f.object_text,
                               CAST(f.object_int AS TEXT),
                               CAST(f.object_real AS TEXT),
                               CAST(f.object_bool AS TEXT),
                               HEX(f.object_blob),
                               CAST(f.object_time_ms AS TEXT),
                               obj.key
                             ) ASC,
                             s.valid_from_ms DESC,
                             f.fact_id ASC
                    LIMIT ?
                    """

                args.append(capped)
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))

                let hits: [StructuredFactHit] = rows.compactMap { row in
                    guard let factId: Int64 = row["fact_id"] else { return nil }
                    let subjectKey: String = row["subject_key"] ?? ""
                    let predicateKey: String = row["predicate_key"] ?? ""
                    let objectKind: Int = row["object_kind"] ?? 0

                    let object: FactValue
                    switch objectKind {
                    case 1:
                        let text: String = row["object_text"] ?? ""
                        object = .string(text)
                    case 2:
                        let intValue: Int64 = row["object_int"] ?? 0
                        object = .int(intValue)
                    case 3:
                        let realValue: Double = row["object_real"] ?? 0
                        object = .double(realValue)
                    case 4:
                        let boolValue: Int64 = row["object_bool"] ?? 0
                        object = .bool(boolValue != 0)
                    case 5:
                        let blobValue: Data = row["object_blob"] ?? Data()
                        object = .data(blobValue)
                    case 6:
                        let timeValue: Int64 = row["object_time_ms"] ?? 0
                        object = .timeMs(timeValue)
                    case 7:
                        let entityKey: String = row["object_entity_key"] ?? ""
                        object = .entity(EntityKey(entityKey))
                    default:
                        return nil
                    }

                    let validTo: Int64? = row["valid_to_ms"]
                    let systemTo: Int64? = row["system_to_ms"]
                    let isOpenEnded = validTo == nil && systemTo == nil

                    return StructuredFactHit(
                        factId: FactRowID(rawValue: factId),
                        fact: StructuredFact(
                            subject: EntityKey(subjectKey),
                            predicate: PredicateKey(predicateKey),
                            object: object
                        ),
                        evidence: [],
                        isOpenEnded: isOpenEnded
                    )
                }

                let truncated = capped > 0 && hits.count >= capped
                return StructuredFactsResult(hits: hits, wasTruncated: truncated)
            }
        }
    }

    public func evidenceFrameIds(
        subjectKeys: [EntityKey],
        asOf: StructuredMemoryAsOf,
        maxFacts: Int,
        maxFrames: Int,
        requireEvidenceSpan: Bool
    ) async throws -> [UInt64] {
        try await flushPendingOpsIfNeeded()
        let factLimit = max(0, min(maxFacts, Self.maxResults))
        let frameLimit = max(0, min(maxFrames, Self.maxResults))
        var subjectValues: [String] = []
        subjectValues.reserveCapacity(subjectKeys.count)
        var seenSubjects: Set<String> = []
        for value in subjectKeys.map(\.rawValue) {
            if seenSubjects.insert(value).inserted {
                subjectValues.append(value)
            }
        }
        let subjectValuesLocal = subjectValues
        guard !subjectValuesLocal.isEmpty, factLimit > 0, frameLimit > 0 else { return [] }

        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let subjectPlaceholders = Array(repeating: "?", count: subjectValuesLocal.count).joined(separator: ",")
                var factArgs: [any DatabaseValueConvertible] = subjectValuesLocal
                factArgs.append(asOf.systemTimeMs)
                factArgs.append(asOf.systemTimeMs)
                factArgs.append(asOf.validTimeMs)
                factArgs.append(asOf.validTimeMs)
                factArgs.append(factLimit)

                let factSql = """
                    SELECT DISTINCT f.fact_id AS fact_id
                    FROM sm_fact_span s
                    JOIN sm_fact f ON f.fact_id = s.fact_id
                    JOIN sm_entity subj ON subj.entity_id = f.subject_entity_id
                    WHERE subj.key IN (\(subjectPlaceholders))
                      AND s.system_from_ms <= ?
                      AND (s.system_to_ms IS NULL OR s.system_to_ms > ?)
                      AND s.valid_from_ms <= ?
                      AND (s.valid_to_ms IS NULL OR s.valid_to_ms > ?)
                    ORDER BY f.fact_id ASC
                    LIMIT ?
                    """

                let factRows = try Row.fetchAll(db, sql: factSql, arguments: StatementArguments(factArgs))
                let factIds: [Int64] = factRows.compactMap { $0["fact_id"] }
                guard !factIds.isEmpty else { return [] }

                let factPlaceholders = Array(repeating: "?", count: factIds.count).joined(separator: ",")
                var evidenceArgs: [any DatabaseValueConvertible] = factIds
                evidenceArgs.append(asOf.systemTimeMs)
                evidenceArgs.append(asOf.systemTimeMs)
                evidenceArgs.append(asOf.validTimeMs)
                evidenceArgs.append(asOf.validTimeMs)
                evidenceArgs.append(frameLimit)

                let spanFilter = "(s.span_id IS NULL OR (s.system_from_ms <= ? AND (s.system_to_ms IS NULL OR s.system_to_ms > ?) AND s.valid_from_ms <= ? AND (s.valid_to_ms IS NULL OR s.valid_to_ms > ?)))"
                let requireSpanFilter = requireEvidenceSpan ? "AND e.span_start_utf8 IS NOT NULL AND e.span_end_utf8 IS NOT NULL" : ""

                let evidenceSql = """
                    SELECT e.source_frame_id AS source_frame_id,
                           MAX(COALESCE(e.confidence, -1.0)) AS max_confidence,
                           MAX(e.asserted_at_ms) AS max_asserted,
                           COUNT(DISTINCT COALESCE(e.fact_id, s.fact_id)) AS fact_count
                    FROM sm_evidence e
                    LEFT JOIN sm_fact_span s ON s.span_id = e.span_id
                    WHERE COALESCE(e.fact_id, s.fact_id) IN (\(factPlaceholders))
                      AND \(spanFilter)
                      \(requireSpanFilter)
                    GROUP BY e.source_frame_id
                    ORDER BY max_confidence DESC,
                             max_asserted DESC,
                             fact_count DESC,
                             e.source_frame_id ASC
                    LIMIT ?
                    """

                let rows = try Row.fetchAll(db, sql: evidenceSql, arguments: StatementArguments(evidenceArgs))
                return rows.compactMap { row in
                    guard let frameIdValue: Int64 = row["source_frame_id"], frameIdValue >= 0 else { return nil }
                    return UInt64(frameIdValue)
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

    private enum StructuredOp: Sendable, Equatable {
        case upsertEntity(key: EntityKey, kind: String, aliases: [String], nowMs: Int64)
        case assertFact(
            subject: EntityKey,
            predicate: PredicateKey,
            object: FactValue,
            valid: StructuredTimeRange,
            system: StructuredTimeRange,
            evidence: [StructuredEvidence],
            factHash: Data
        )
        case retractFact(factId: FactRowID, atMs: Int64)
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
        guard !pendingOps.isEmpty else {
            if !pendingStructuredOps.isEmpty {
                try await flushPendingStructuredOpsIfNeeded()
            }
            return
        }

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

        if !pendingStructuredOps.isEmpty {
            try await flushPendingStructuredOpsIfNeeded()
        }
    }

    private func enqueueStructuredOp(_ op: StructuredOp) {
        pendingStructuredOps.append(op)
        dirty = true
    }

    private func flushPendingStructuredOpsIfThresholdExceeded() async throws {
        guard pendingStructuredOps.count >= Self.structuredFlushThreshold else { return }
        try await flushPendingStructuredOpsIfNeeded()
    }

    private func flushPendingStructuredOpsIfNeeded() async throws {
        guard !pendingStructuredOps.isEmpty else { return }

        let ops = pendingStructuredOps
        let dbQueue = self.dbQueue

        try await io.run {
            try dbQueue.write { db in
                let selectEntityStmt = try db.makeStatement(sql: """
                    SELECT entity_id, kind FROM sm_entity WHERE key = ?
                    """)
                let insertEntityStmt = try db.makeStatement(sql: """
                    INSERT INTO sm_entity(key, kind, created_at_ms) VALUES (?, ?, ?)
                    """)
                let updateEntityKindStmt = try db.makeStatement(sql: """
                    UPDATE sm_entity SET kind = ? WHERE entity_id = ?
                    """)
                let insertAliasStmt = try db.makeStatement(sql: """
                    INSERT OR IGNORE INTO sm_entity_alias(entity_id, alias, alias_norm, created_at_ms)
                    VALUES (?, ?, ?, ?)
                    """)
                let selectPredicateStmt = try db.makeStatement(sql: """
                    SELECT predicate_id FROM sm_predicate WHERE key = ?
                    """)
                let insertPredicateStmt = try db.makeStatement(sql: """
                    INSERT INTO sm_predicate(key, created_at_ms) VALUES (?, ?)
                    """)
                let insertFactStmt = try db.makeStatement(sql: """
                    INSERT OR IGNORE INTO sm_fact(
                        subject_entity_id,
                        predicate_id,
                        object_kind,
                        object_text,
                        object_int,
                        object_real,
                        object_bool,
                        object_blob,
                        object_time_ms,
                        object_entity_id,
                        qualifiers_hash,
                        fact_hash,
                        created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                let selectFactIdStmt = try db.makeStatement(sql: """
                    SELECT fact_id FROM sm_fact WHERE fact_hash = ?
                    """)
                let insertSpanStmt = try db.makeStatement(sql: """
                    INSERT OR IGNORE INTO sm_fact_span(
                        fact_id,
                        valid_from_ms,
                        valid_to_ms,
                        system_from_ms,
                        system_to_ms,
                        span_key_hash,
                        created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?)
                    """)
                let selectSpanIdStmt = try db.makeStatement(sql: """
                    SELECT span_id FROM sm_fact_span WHERE span_key_hash = ?
                    """)
                let insertEvidenceStmt = try db.makeStatement(sql: """
                    INSERT INTO sm_evidence(
                        span_id,
                        fact_id,
                        source_frame_id,
                        chunk_index,
                        span_start_utf8,
                        span_end_utf8,
                        extractor_id,
                        extractor_version,
                        confidence,
                        asserted_at_ms,
                        created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                let selectOpenSpanStmt = try db.makeStatement(sql: """
                    SELECT span_id, system_from_ms FROM sm_fact_span
                    WHERE fact_id = ? AND system_to_ms IS NULL
                    """)
                let retractSpanStmt = try db.makeStatement(sql: """
                    UPDATE sm_fact_span SET system_to_ms = ?
                    WHERE fact_id = ? AND system_to_ms IS NULL
                    """)

                func ensureEntityId(key: EntityKey, kind: String, nowMs: Int64) throws -> Int64 {
                    if let row = try Row.fetchOne(selectEntityStmt, arguments: [key.rawValue]) {
                        let id: Int64 = row["entity_id"] ?? 0
                        let existingKind: String = row["kind"] ?? ""
                        if existingKind.isEmpty, !kind.isEmpty {
                            try updateEntityKindStmt.execute(arguments: [kind, id])
                        }
                        return id
                    }
                    try insertEntityStmt.execute(arguments: [key.rawValue, kind, nowMs])
                    return db.lastInsertedRowID
                }

                func ensurePredicateId(key: PredicateKey, nowMs: Int64) throws -> Int64 {
                    if let row = try Row.fetchOne(selectPredicateStmt, arguments: [key.rawValue]) {
                        let id: Int64 = row["predicate_id"] ?? 0
                        return id
                    }
                    try insertPredicateStmt.execute(arguments: [key.rawValue, nowMs])
                    return db.lastInsertedRowID
                }

                for op in ops {
                    switch op {
                    case .upsertEntity(let key, let kind, let aliases, let nowMs):
                        let entityId = try ensureEntityId(key: key, kind: kind, nowMs: nowMs)
                        for alias in aliases {
                            let trimmed = alias.trimmingCharacters(in: .whitespacesAndNewlines)
                            let normalized = StructuredMemoryCanonicalizer.normalizedAlias(trimmed)
                            guard !normalized.isEmpty else { continue }
                            try insertAliasStmt.execute(arguments: [entityId, trimmed, normalized, nowMs])
                        }

                    case .assertFact(
                        let subject,
                        let predicate,
                        let object,
                        let valid,
                        let system,
                        let evidence,
                        let factHash
                    ):
                        let subjectId = try ensureEntityId(key: subject, kind: "", nowMs: system.fromMs)
                        let predicateId = try ensurePredicateId(key: predicate, nowMs: system.fromMs)

                        let objectColumns = try FactObjectColumns.from(
                            object: object,
                            ensureEntityId: { key in
                                try ensureEntityId(key: key, kind: "", nowMs: system.fromMs)
                            }
                        )

                        try insertFactStmt.execute(arguments: [
                            subjectId,
                            predicateId,
                            objectColumns.kind,
                            objectColumns.text,
                            objectColumns.intValue,
                            objectColumns.realValue,
                            objectColumns.boolValue,
                            objectColumns.blobValue,
                            objectColumns.timeValue,
                            objectColumns.entityId,
                            nil,
                            factHash,
                            system.fromMs,
                        ])

                        guard let factRow = try Row.fetchOne(selectFactIdStmt, arguments: [factHash]),
                              let factId: Int64 = factRow["fact_id"] else {
                            throw WaxError.io("missing fact_id after insert")
                        }

                        let spanHash = StructuredMemoryHasher.hashSpanKey(
                            factId: FactRowID(rawValue: factId),
                            valid: valid,
                            systemFromMs: system.fromMs
                        )

                        try insertSpanStmt.execute(arguments: [
                            factId,
                            valid.fromMs,
                            valid.toMs,
                            system.fromMs,
                            system.toMs,
                            spanHash,
                            system.fromMs,
                        ])

                        guard let spanRow = try Row.fetchOne(selectSpanIdStmt, arguments: [spanHash]),
                              let spanId: Int64 = spanRow["span_id"] else {
                            throw WaxError.io("missing span_id after insert")
                        }

                        for item in evidence {
                            let frameIdValue = try Self.toInt64(item.sourceFrameId)
                            let spanStart: Int64? = item.spanUTF8.map { Int64($0.lowerBound) }
                            let spanEnd: Int64? = item.spanUTF8.map { Int64($0.upperBound) }
                            let chunkIndex = item.chunkIndex.map { Int64($0) }
                            try insertEvidenceStmt.execute(arguments: [
                                spanId,
                                nil,
                                frameIdValue,
                                chunkIndex,
                                spanStart,
                                spanEnd,
                                item.extractorId,
                                item.extractorVersion,
                                item.confidence,
                                item.assertedAtMs,
                                item.assertedAtMs,
                            ])
                        }

                    case .retractFact(let factId, let atMs):
                        let spans = try Row.fetchAll(selectOpenSpanStmt, arguments: [factId.rawValue])
                        guard !spans.isEmpty else { break }

                        for row in spans {
                            let systemFrom: Int64 = row["system_from_ms"] ?? 0
                            if atMs <= systemFrom {
                                throw WaxError.encodingError(reason: "retraction time must be after system_from_ms")
                            }
                        }

                        try retractSpanStmt.execute(arguments: [atMs, factId.rawValue])
                    }
                }
            }
        }

        pendingStructuredOps.removeAll(keepingCapacity: true)
    }

    private struct FactObjectColumns {
        let kind: Int
        let text: String?
        let intValue: Int64?
        let realValue: Double?
        let boolValue: Int?
        let blobValue: Data?
        let timeValue: Int64?
        let entityId: Int64?

        static func from(
            object: FactValue,
            ensureEntityId: (EntityKey) throws -> Int64
        ) throws -> FactObjectColumns {
            switch object {
            case .string(let text):
                return FactObjectColumns(
                    kind: 1,
                    text: text,
                    intValue: nil,
                    realValue: nil,
                    boolValue: nil,
                    blobValue: nil,
                    timeValue: nil,
                    entityId: nil
                )
            case .int(let value):
                return FactObjectColumns(
                    kind: 2,
                    text: nil,
                    intValue: value,
                    realValue: nil,
                    boolValue: nil,
                    blobValue: nil,
                    timeValue: nil,
                    entityId: nil
                )
            case .double(let value):
                guard value.isFinite else {
                    throw WaxError.encodingError(reason: "non-finite Double is not allowed")
                }
                return FactObjectColumns(
                    kind: 3,
                    text: nil,
                    intValue: nil,
                    realValue: value == 0 ? 0.0 : value,
                    boolValue: nil,
                    blobValue: nil,
                    timeValue: nil,
                    entityId: nil
                )
            case .bool(let value):
                return FactObjectColumns(
                    kind: 4,
                    text: nil,
                    intValue: nil,
                    realValue: nil,
                    boolValue: value ? 1 : 0,
                    blobValue: nil,
                    timeValue: nil,
                    entityId: nil
                )
            case .data(let value):
                return FactObjectColumns(
                    kind: 5,
                    text: nil,
                    intValue: nil,
                    realValue: nil,
                    boolValue: nil,
                    blobValue: value,
                    timeValue: nil,
                    entityId: nil
                )
            case .timeMs(let value):
                return FactObjectColumns(
                    kind: 6,
                    text: nil,
                    intValue: nil,
                    realValue: nil,
                    boolValue: nil,
                    blobValue: nil,
                    timeValue: value,
                    entityId: nil
                )
            case .entity(let key):
                let entityId = try ensureEntityId(key)
                return FactObjectColumns(
                    kind: 7,
                    text: nil,
                    intValue: nil,
                    realValue: nil,
                    boolValue: nil,
                    blobValue: nil,
                    timeValue: nil,
                    entityId: entityId
                )
            }
        }
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
