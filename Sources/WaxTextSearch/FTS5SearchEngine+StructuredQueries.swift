import Foundation
@preconcurrency import GRDB
import WaxCore

extension FTS5SearchEngine {
    package func facts(
        about subject: EntityKey?,
        predicate: PredicateKey?,
        asOf: StructuredMemoryAsOf,
        limit: Int
    ) async throws -> StructuredFactsResult {
        if let subject {
            try StructuredMemoryValidation.validateEntityKey(subject, field: "facts subject")
        }
        if let predicate {
            try StructuredMemoryValidation.validatePredicateKey(predicate, field: "facts predicate")
        }
        try await flushPendingOpsIfNeeded()
        let capped = max(0, min(limit, Self.maxResults))
        let fetchLimit = capped > 0 ? capped + 1 : 0
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
                           s.span_id AS span_id,
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
                           s.version_relation AS version_relation,
                           s.valid_from_ms AS valid_from_ms,
                           s.valid_to_ms AS valid_to_ms,
                           s.system_from_ms AS system_from_ms,
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

                args.append(fetchLimit)
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                let visibleRows = rows.prefix(capped)
                let spanIds: [Int64] = visibleRows.compactMap { $0["span_id"] }
                var evidenceBySpanId: [Int64: [StructuredEvidence]] = [:]
                if !spanIds.isEmpty {
                    let placeholders = Array(repeating: "?", count: spanIds.count).joined(separator: ",")
                    let evidenceSql = """
                        SELECT span_id,
                               source_frame_id,
                               chunk_index,
                               span_start_utf8,
                               span_end_utf8,
                               extractor_id,
                               extractor_version,
                               confidence,
                               asserted_at_ms
                        FROM sm_evidence
                        WHERE span_id IN (\(placeholders))
                        ORDER BY evidence_id ASC
                        """
                    let evidenceRows = try Row.fetchAll(db, sql: evidenceSql, arguments: StatementArguments(spanIds))
                    for row in evidenceRows {
                        guard let spanId: Int64 = row["span_id"],
                              let evidence = Self.structuredEvidence(from: row) else {
                            continue
                        }
                        evidenceBySpanId[spanId, default: []].append(evidence)
                    }
                }

                let hits: [StructuredFactHit] = visibleRows.compactMap { row in
                    guard let factId: Int64 = row["fact_id"],
                          let spanId: Int64 = row["span_id"] else { return nil }
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

                    let validFrom: Int64 = row["valid_from_ms"] ?? 0
                    let validTo: Int64? = row["valid_to_ms"]
                    let systemFrom: Int64 = row["system_from_ms"] ?? 0
                    let systemTo: Int64? = row["system_to_ms"]
                    let isOpenEnded = validTo == nil && systemTo == nil
                    let relationRaw: Int = row["version_relation"] ?? 0
                    guard let relation = VersionRelation(rawValue: UInt8(relationRaw)) else {
                        return nil
                    }

                    return StructuredFactHit(
                        factId: FactRowID(rawValue: factId),
                        spanId: spanId,
                        fact: StructuredFact(
                            subject: EntityKey(subjectKey),
                            predicate: PredicateKey(predicateKey),
                            object: object
                        ),
                        relation: relation,
                        valid: StructuredTimeRange(fromMs: validFrom, toMs: validTo),
                        system: StructuredTimeRange(fromMs: systemFrom, toMs: systemTo),
                        evidence: evidenceBySpanId[spanId] ?? [],
                        isOpenEnded: isOpenEnded
                    )
                }

                let truncated = capped > 0 && rows.count > capped
                return StructuredFactsResult(hits: hits, wasTruncated: truncated)
            }
        }
    }

    package func edges(
        for entity: EntityKey,
        direction: StructuredEdgeDirection,
        predicate: PredicateKey?,
        asOf: StructuredMemoryAsOf,
        limit: Int
    ) async throws -> StructuredEdgesResult {
        try StructuredMemoryValidation.validateEntityKey(entity, field: "edges entity")
        if let predicate {
            try StructuredMemoryValidation.validatePredicateKey(predicate, field: "edges predicate")
        }
        try await flushPendingOpsIfNeeded()
        let capped = max(0, min(limit, Self.maxResults))
        let fetchLimit = capped > 0 ? capped + 1 : 0
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                var whereClauses = [
                    "f.object_kind = 7",
                    "focus.key = ?",
                    "s.system_from_ms <= ?",
                    "(s.system_to_ms IS NULL OR s.system_to_ms > ?)",
                    "s.valid_from_ms <= ?",
                    "(s.valid_to_ms IS NULL OR s.valid_to_ms > ?)",
                ]
                var args: [any DatabaseValueConvertible] = [
                    entity.rawValue,
                    asOf.systemTimeMs,
                    asOf.systemTimeMs,
                    asOf.validTimeMs,
                    asOf.validTimeMs,
                ]
                if let predicate {
                    whereClauses.append("p.key = ?")
                    args.append(predicate.rawValue)
                }
                let whereSQL = whereClauses.joined(separator: " AND ")
                let directionSQL: String
                let directionValue: Int
                switch direction {
                case .outbound:
                    directionSQL = """
                    JOIN sm_entity focus ON focus.entity_id = f.subject_entity_id
                    JOIN sm_entity neighbor ON neighbor.entity_id = f.object_entity_id
                    """
                    directionValue = 0
                case .inbound:
                    directionSQL = """
                    JOIN sm_entity focus ON focus.entity_id = f.object_entity_id
                    JOIN sm_entity neighbor ON neighbor.entity_id = f.subject_entity_id
                    """
                    directionValue = 1
                }
                let sql = """
                    SELECT f.fact_id AS fact_id,
                           p.key AS predicate_key,
                           neighbor.key AS neighbor_key
                    FROM sm_fact_span s
                    JOIN sm_fact f ON f.fact_id = s.fact_id
                    JOIN sm_predicate p ON p.predicate_id = f.predicate_id
                    \(directionSQL)
                    WHERE \(whereSQL)
                    ORDER BY p.key ASC,
                             neighbor.key ASC,
                             s.valid_from_ms DESC,
                             f.fact_id ASC
                    LIMIT ?
                    """
                args.append(fetchLimit)
                let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
                let hits = rows.prefix(capped).compactMap { row -> EdgeHit? in
                    guard let factId: Int64 = row["fact_id"] else { return nil }
                    let predicateKey: String = row["predicate_key"] ?? ""
                    let neighborKey: String = row["neighbor_key"] ?? ""
                    return EdgeHit(
                        factId: FactRowID(rawValue: factId),
                        predicate: PredicateKey(predicateKey),
                        direction: directionValue == 0 ? .outbound : .inbound,
                        neighbor: EntityKey(neighborKey)
                    )
                }
                return StructuredEdgesResult(hits: hits, wasTruncated: capped > 0 && rows.count > capped)
            }
        }
    }

    package func evidenceFrameIds(
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
                    WITH candidate_entities AS (
                        SELECT entity_id FROM sm_entity WHERE key IN (\(subjectPlaceholders))
                    ),
                    candidate_facts AS (
                        SELECT f.fact_id AS fact_id
                        FROM sm_fact f
                        JOIN candidate_entities c ON c.entity_id = f.subject_entity_id
                        UNION
                        SELECT f.fact_id AS fact_id
                        FROM sm_fact f
                        JOIN candidate_entities c ON c.entity_id = f.object_entity_id
                        WHERE f.object_kind = 7
                    )
                    SELECT DISTINCT cf.fact_id AS fact_id
                    FROM candidate_facts cf
                    JOIN sm_fact_span s ON s.fact_id = cf.fact_id
                    WHERE s.system_from_ms <= ?
                      AND (s.system_to_ms IS NULL OR s.system_to_ms > ?)
                      AND s.valid_from_ms <= ?
                      AND (s.valid_to_ms IS NULL OR s.valid_to_ms > ?)
                    ORDER BY cf.fact_id ASC
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

    private static func structuredEvidence(from row: Row) -> StructuredEvidence? {
        guard let frameIdValue: Int64 = row["source_frame_id"], frameIdValue >= 0 else {
            return nil
        }
        let chunkIndex: UInt32? = {
            guard let value: Int64 = row["chunk_index"],
                  value >= 0,
                  value <= Int64(UInt32.max) else {
                return nil
            }
            return UInt32(value)
        }()
        let spanUTF8: Range<Int>? = {
            guard let start: Int64 = row["span_start_utf8"],
                  let end: Int64 = row["span_end_utf8"],
                  start >= 0,
                  end > start,
                  start <= Int64(Int.max),
                  end <= Int64(Int.max) else {
                return nil
            }
            return Int(start)..<Int(end)
        }()
        let extractorId: String = row["extractor_id"] ?? ""
        let extractorVersion: String = row["extractor_version"] ?? ""
        let confidence: Double? = row["confidence"]
        let assertedAtMs: Int64 = row["asserted_at_ms"] ?? 0
        return StructuredEvidence(
            sourceFrameId: UInt64(frameIdValue),
            chunkIndex: chunkIndex,
            spanUTF8: spanUTF8,
            extractorId: extractorId,
            extractorVersion: extractorVersion,
            confidence: confidence,
            assertedAtMs: assertedAtMs
        )
    }
}
