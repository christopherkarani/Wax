import Foundation
@preconcurrency import GRDB
import WaxCore

extension FTS5SearchEngine {
    // MARK: - Structured Memory

    package func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String],
        nowMs: Int64
    ) async throws -> EntityRowID {
        try StructuredMemoryValidation.validateEntityKey(key)
        try await enqueueAndFlushStructuredOp(.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs))
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

    package func entity(forKey key: EntityKey) async throws -> StructuredEntityMatch? {
        try await flushPendingOpsIfNeeded()
        try await flushPendingStructuredOpsIfNeeded()
        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = "SELECT entity_id, key, kind FROM sm_entity WHERE key = ?"
                guard let row = try Row.fetchOne(db, sql: sql, arguments: [key.rawValue]) else {
                    return nil
                }
                guard let id: Int64 = row["entity_id"] else { return nil }
                let storedKey: String = row["key"] ?? key.rawValue
                let kind: String = row["kind"] ?? ""
                return StructuredEntityMatch(id: id, key: EntityKey(storedKey), kind: kind)
            }
        }
    }

    package func resolveEntities(matchingAlias alias: String, limit: Int) async throws -> [StructuredEntityMatch] {
        try await flushPendingOpsIfNeeded()
        let normalized = StructuredMemoryCanonicalizer.normalizedAlias(alias)
        guard !normalized.isEmpty else { return [] }
        let capped = max(0, min(limit, 10_000))
        let escaped = Self.escapedLikePattern(normalized)
        let prefixPattern = "\(escaped)%"
        let wordPattern = "% \(escaped)%"

        let dbQueue = self.dbQueue
        return try await io.run {
            try dbQueue.read { db in
                let sql = """
                    WITH alias_matches AS (
                      SELECT e.entity_id AS entity_id,
                             e.key AS entity_key,
                             e.kind AS entity_kind,
                             MIN(
                               CASE
                                 WHEN a.alias_norm = ? THEN 0
                                 WHEN a.alias_norm LIKE ? ESCAPE '/' THEN 1
                                 ELSE 2
                               END
                             ) AS match_rank
                      FROM sm_entity_alias a
                      JOIN sm_entity e ON e.entity_id = a.entity_id
                      WHERE a.alias_norm = ?
                         OR a.alias_norm LIKE ? ESCAPE '/'
                         OR a.alias_norm LIKE ? ESCAPE '/'
                      GROUP BY e.entity_id, e.key, e.kind
                    )
                    SELECT e.entity_id AS entity_id,
                           e.entity_key AS entity_key,
                           e.entity_kind AS entity_kind
                    FROM alias_matches e
                    ORDER BY e.match_rank ASC, e.entity_key ASC
                    LIMIT ?
                    """
                let rows = try Row.fetchAll(
                    db,
                    sql: sql,
                    arguments: [
                        normalized,
                        prefixPattern,
                        normalized,
                        prefixPattern,
                        wordPattern,
                        capped,
                    ]
                )
                return rows.compactMap { row in
                    guard let id: Int64 = row["entity_id"] else { return nil }
                    let key: String = row["entity_key"] ?? ""
                    let kind: String = row["entity_kind"] ?? ""
                    return StructuredEntityMatch(id: id, key: EntityKey(key), kind: kind)
                }
            }
        }
    }

    private static func escapedLikePattern(_ value: String) -> String {
        var escaped = ""
        escaped.reserveCapacity(value.count)
        for character in value {
            switch character {
            case "/", "%", "_":
                escaped.append("/")
                escaped.append(character)
            default:
                escaped.append(character)
            }
        }
        return escaped
    }

    package func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        relation: VersionRelation = .sets,
        valid: StructuredTimeRange,
        system: StructuredTimeRange,
        evidence: [StructuredEvidence]
    ) async throws -> FactRowID {
        try StructuredMemoryValidation.validateEntityKey(subject, field: "fact subject")
        try StructuredMemoryValidation.validatePredicateKey(predicate, field: "fact predicate")
        try StructuredMemoryValidation.validateFactValue(object)
        try StructuredMemoryValidation.validateEvidence(evidence)
        guard valid.toMs == nil || valid.toMs! > valid.fromMs else {
            throw WaxError.encodingError(reason: "valid_to_ms must be greater than valid_from_ms")
        }
        guard system.toMs == nil || system.toMs! > system.fromMs else {
            throw WaxError.encodingError(reason: "system_to_ms must be greater than system_from_ms")
        }
        guard system.fromMs < Int64.max else {
            throw WaxError.encodingError(reason: "system_from_ms must be less than Int64.max")
        }
        // Checked here, not when applying, so a bad frame id fails this call instead of the batch.
        for item in evidence {
            _ = try Self.toInt64(item.sourceFrameId)
        }

        let factHash = try StructuredMemoryHasher.hashFact(
            subject: subject,
            predicate: predicate,
            object: object,
            qualifiersHash: nil
        )

        try await enqueueAndFlushStructuredOp(
            .assertFact(
                subject: subject,
                predicate: predicate,
                object: object,
                relation: relation,
                valid: valid,
                system: system,
                evidence: evidence,
                factHash: factHash
            )
        )

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

    package func retractFact(factId: FactRowID, atMs: Int64) async throws {
        let dbQueue = self.dbQueue
        let factExists = try await io.run {
            try dbQueue.read { db in
                try Int64.fetchOne(
                    db,
                    sql: "SELECT fact_id FROM sm_fact WHERE fact_id = ?",
                    arguments: [factId.rawValue]
                ) != nil
            }
        }
        guard factExists else {
            throw WaxError.io("fact_id has no open spans")
        }
        try await enqueueAndFlushStructuredOp(.retractFact(factId: factId, atMs: atMs))
    }
}
