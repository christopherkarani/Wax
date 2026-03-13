import Foundation
import WaxCore
import WaxTextSearch

package actor WaxStructuredMemorySession {
    package let wax: Wax
    package let engine: FTS5SearchEngine

    package init(wax: Wax) async throws {
        self.wax = wax
        self.engine = try await FTS5SearchEngine.load(from: wax)
    }

    package func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String],
        nowMs: Int64
    ) async throws -> EntityRowID {
        try await engine.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs)
    }

    package func resolveEntities(matchingAlias alias: String, limit: Int) async throws -> [StructuredEntityMatch] {
        try await engine.resolveEntities(matchingAlias: alias, limit: limit)
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
        try await engine.assertFact(
            subject: subject,
            predicate: predicate,
            object: object,
            relation: relation,
            valid: valid,
            system: system,
            evidence: evidence
        )
    }

    package func retractFact(factId: FactRowID, atMs: Int64) async throws {
        try await engine.retractFact(factId: factId, atMs: atMs)
    }

    package func facts(
        about subject: EntityKey?,
        predicate: PredicateKey?,
        asOf: StructuredMemoryAsOf,
        limit: Int
    ) async throws -> StructuredFactsResult {
        try await engine.facts(about: subject, predicate: predicate, asOf: asOf, limit: limit)
    }

    package func stageForCommit(compact: Bool = false) async throws {
        try await engine.stageForCommit(into: wax, compact: compact)
    }

    package func commit(compact: Bool = false) async throws {
        try await stageForCommit(compact: compact)
        do {
            try await wax.commit()
        } catch let error as WaxError {
            if case .io(let message) = error,
               message == "vector index must be staged before committing embeddings" {
                return
            }
            throw error
        }
    }
}

package extension Wax {
    @available(*, deprecated, message: "Use Wax.openSession(...)")
    func structuredMemory() async throws -> WaxStructuredMemorySession {
        try await WaxStructuredMemorySession(wax: self)
    }
}
