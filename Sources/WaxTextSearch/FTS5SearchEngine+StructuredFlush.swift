import Foundation
@preconcurrency import GRDB
import WaxCore

extension FTS5SearchEngine {
    func enqueueStructuredOp(_ op: StructuredOp) {
        pendingStructuredOps.append(op)
        dirty = true
    }

    func flushPendingStructuredOpsIfThresholdExceeded() async throws {
        guard pendingStructuredOps.count >= Self.structuredFlushThreshold else { return }
        try await flushPendingStructuredOpsIfNeeded()
    }

    func flushPendingStructuredOpsIfNeeded() async throws {
        guard !pendingStructuredOps.isEmpty else { return }
        await beginWrite()
        defer { endWrite() }
        // Another flush may have written these ops while this one waited for the gate.
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
                        version_relation,
                        qualifiers_hash,
                        fact_hash,
                        created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)
                    """)
                let selectFactIdStmt = try db.makeStatement(sql: """
                    SELECT fact_id FROM sm_fact WHERE fact_hash = ?
                    """)
                let insertSpanStmt = try db.makeStatement(sql: """
                    INSERT OR IGNORE INTO sm_fact_span(
                        fact_id,
                        valid_from_ms,
                        valid_to_ms,
                        version_relation,
                        system_from_ms,
                        system_to_ms,
                        span_key_hash,
                        created_at_ms
                    ) VALUES (?, ?, ?, ?, ?, ?, ?, ?)
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
                    SELECT span_id,
                           fact_id,
                           valid_from_ms,
                           valid_to_ms,
                           version_relation,
                           system_from_ms
                    FROM sm_fact_span
                    WHERE fact_id = ? AND system_to_ms IS NULL
                    """)
                let selectOpenSpanForFactStmt = try db.makeStatement(sql: """
                    SELECT s.span_id AS span_id,
                           s.fact_id AS fact_id,
                           s.valid_from_ms AS valid_from_ms,
                           s.valid_to_ms AS valid_to_ms,
                           s.version_relation AS version_relation,
                           s.system_from_ms AS system_from_ms
                    FROM sm_fact_span s
                    WHERE s.fact_id = ?
                      AND s.system_to_ms IS NULL
                      AND s.valid_from_ms < ?
                      AND (s.valid_to_ms IS NULL OR s.valid_to_ms > ?)
                    """)
                let closeSpanByIDStmt = try db.makeStatement(sql: """
                    UPDATE sm_fact_span SET system_to_ms = ?, span_key_hash = ?
                    WHERE span_id = ? AND system_to_ms IS NULL
                    """)

                func ensureEntityId(key: EntityKey, kind: String, nowMs: Int64) throws -> Int64 {
                    if let row = try Row.fetchOne(selectEntityStmt, arguments: [key.rawValue]) {
                        let id: Int64 = row["entity_id"] ?? 0
                        let existingKind: String = row["kind"] ?? ""
                        if !kind.isEmpty, existingKind != kind {
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

                func closeSpan(_ row: Row, at closeAt: Int64) throws {
                    let spanId: Int64 = row["span_id"] ?? 0
                    let factId: Int64 = row["fact_id"] ?? 0
                    let validFrom: Int64 = row["valid_from_ms"] ?? 0
                    let validTo: Int64? = row["valid_to_ms"]
                    let relationRaw: Int = row["version_relation"] ?? 0
                    let systemFrom: Int64 = row["system_from_ms"] ?? 0
                    guard let spanRelation = VersionRelation(rawValue: UInt8(relationRaw)) else {
                        throw WaxError.io("unsupported structured fact version_relation \(relationRaw) while closing span")
                    }
                    let closedHash = StructuredMemoryHasher.hashSpanKey(
                        factId: FactRowID(rawValue: factId),
                        valid: StructuredTimeRange(fromMs: validFrom, toMs: validTo),
                        relation: spanRelation,
                        system: StructuredTimeRange(fromMs: systemFrom, toMs: closeAt)
                    )
                    try closeSpanByIDStmt.execute(arguments: [closeAt, closedHash, spanId])
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
                        let relation,
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
                            Int(relation.rawValue),
                            nil,
                            factHash,
                            system.fromMs,
                        ])

                        guard let factRow = try Row.fetchOne(selectFactIdStmt, arguments: [factHash]),
                              let factId: Int64 = factRow["fact_id"] else {
                            throw WaxError.io("missing fact_id after insert")
                        }

                        var effectiveSystemFromMs = system.fromMs
                        if relation.supersedes {
                            let openSpans = try Row.fetchAll(
                                selectOpenSpanForFactStmt,
                                arguments: [factId, valid.toMs ?? Int64.max, valid.fromMs]
                            )
                            for row in openSpans {
                                let systemFrom: Int64 = row["system_from_ms"] ?? 0
                                guard system.fromMs >= systemFrom else {
                                    throw WaxError.encodingError(
                                        reason: "superseding fact system_from_ms must be greater than or equal to open span system_from_ms"
                                    )
                                }
                                let closeAt: Int64
                                if system.fromMs > systemFrom {
                                    closeAt = system.fromMs
                                } else {
                                    let next = systemFrom.addingReportingOverflow(1)
                                    guard !next.overflow, next.partialValue < Int64.max else {
                                        throw WaxError.encodingError(
                                            reason: "superseding fact system_from_ms overflows monotonic close timestamp"
                                        )
                                    }
                                    closeAt = next.partialValue
                                }
                                effectiveSystemFromMs = max(effectiveSystemFromMs, closeAt)
                                try closeSpan(row, at: closeAt)
                            }
                        }
                        if let systemToMs = system.toMs, systemToMs <= effectiveSystemFromMs {
                            throw WaxError.encodingError(
                                reason: "superseding fact system range must end after its monotonic system_from_ms"
                            )
                        }
                        if relation == .retracts {
                            continue
                        }

                        let spanHash = StructuredMemoryHasher.hashSpanKey(
                            factId: FactRowID(rawValue: factId),
                            valid: valid,
                            relation: relation,
                            system: StructuredTimeRange(fromMs: effectiveSystemFromMs, toMs: system.toMs)
                        )

                        try insertSpanStmt.execute(arguments: [
                            factId,
                            valid.fromMs,
                            valid.toMs,
                            Int(relation.rawValue),
                            effectiveSystemFromMs,
                            system.toMs,
                            spanHash,
                            effectiveSystemFromMs,
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
                            if atMs < systemFrom {
                                throw WaxError.encodingError(reason: "retraction time must be greater than or equal to system_from_ms")
                            }
                        }

                        for row in spans {
                            let systemFrom: Int64 = row["system_from_ms"] ?? 0
                            let closeAt: Int64
                            if atMs > systemFrom {
                                closeAt = atMs
                            } else {
                                let next = systemFrom.addingReportingOverflow(1)
                                guard !next.overflow else {
                                    throw WaxError.encodingError(
                                        reason: "retraction time overflows monotonic close timestamp"
                                    )
                                }
                                closeAt = next.partialValue
                            }
                            try closeSpan(row, at: closeAt)
                        }
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
}
