import Foundation
import WaxCore
import WaxTextSearch

public actor WaxStructuredMemorySession {
    public let wax: Wax
    public let engine: FTS5SearchEngine

    public init(wax: Wax) async throws {
        self.wax = wax
        self.engine = try await FTS5SearchEngine.load(from: wax)
    }

    public func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String],
        nowMs: Int64
    ) async throws -> EntityRowID {
        try await engine.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs)
    }

    public func resolveEntities(matchingAlias alias: String, limit: Int) async throws -> [StructuredEntityMatch] {
        try await engine.resolveEntities(matchingAlias: alias, limit: limit)
    }

    public func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        valid: StructuredTimeRange,
        system: StructuredTimeRange,
        evidence: [StructuredEvidence]
    ) async throws -> FactRowID {
        try await engine.assertFact(
            subject: subject,
            predicate: predicate,
            object: object,
            valid: valid,
            system: system,
            evidence: evidence
        )
    }

    public func retractFact(factId: FactRowID, atMs: Int64) async throws {
        try await engine.retractFact(factId: factId, atMs: atMs)
    }

    public func facts(
        about subject: EntityKey?,
        predicate: PredicateKey?,
        asOf: StructuredMemoryAsOf,
        limit: Int
    ) async throws -> StructuredFactsResult {
        try await engine.facts(about: subject, predicate: predicate, asOf: asOf, limit: limit)
    }

    public func stageForCommit(compact: Bool = false) async throws {
        try await engine.stageForCommit(into: wax, compact: compact)
    }

    public func commit(compact: Bool = false) async throws {
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

public extension Wax {
    func structuredMemory() async throws -> WaxStructuredMemorySession {
        try await WaxStructuredMemorySession(wax: self)
    }
}
