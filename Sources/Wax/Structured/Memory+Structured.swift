import WaxCore

extension Memory {
    /// Create or update an entity and its aliases. Commits immediately.
    public func upsertEntity(
        key: String,
        kind: String,
        aliases: [String] = []
    ) async throws -> EntityID {
        let rowID = try await orchestrator.upsertEntity(
            key: EntityKey(key),
            kind: kind,
            aliases: aliases
        )
        return EntityID(rowID)
    }

    /// Resolve entities whose aliases match `alias`.
    public func resolveEntities(alias: String, limit: Int = 10) async throws -> [EntityMatch] {
        let matches = try await orchestrator.resolveEntities(matchingAlias: alias, limit: limit)
        return matches.map(EntityMatch.init)
    }

    /// Assert a fact about `subject`. Commits immediately.
    public func assertFact(
        subject: String,
        predicate: String,
        object: FactValue,
        relation: FactRelation = .sets,
        validFromMs: Int64? = nil,
        validToMs: Int64? = nil
    ) async throws -> FactID {
        let rowID = try await orchestrator.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: object.coreValue,
            relation: relation.coreRelation,
            validFromMs: validFromMs,
            validToMs: validToMs
        )
        return FactID(rowID)
    }

    /// Retract a previously asserted fact. Commits immediately.
    public func retractFact(_ id: FactID, atMs: Int64? = nil) async throws {
        try await orchestrator.retractFact(factId: id.coreID, atMs: atMs)
    }

    /// Query facts, optionally filtered by subject, predicate, and millisecond as-of times.
    public func facts(
        subject: String? = nil,
        predicate: String? = nil,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> FactsResult {
        let result = try await orchestrator.facts(
            about: subject.map { EntityKey($0) },
            predicate: predicate.map { PredicateKey($0) },
            systemAsOfMs: systemAsOfMs,
            validAsOfMs: validAsOfMs,
            limit: limit
        )
        return FactsResult(result)
    }

    /// Traverse entity-valued facts as edges.
    public func edges(
        for entity: String,
        direction: EdgeDirection = .outbound,
        predicate: String? = nil,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> EdgesResult {
        let result = try await orchestrator.edges(
            for: EntityKey(entity),
            direction: direction.coreDirection,
            predicate: predicate.map { PredicateKey($0) },
            systemAsOfMs: systemAsOfMs,
            validAsOfMs: validAsOfMs,
            limit: limit
        )
        return EdgesResult(result)
    }
}
