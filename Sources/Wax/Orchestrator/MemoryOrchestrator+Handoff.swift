import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// Internal only because of the file split; call only while holding `handoffWriteMutex` (see `rememberHandoff`).
    func rememberHandoffSerialized(
        content: String,
        project: String?,
        pendingTasks: [String],
        sessionId: UUID?,
        commit: Bool
    ) async throws -> UInt64 {
        let pending = pendingTasks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let normalizedProject = project?.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveSessionId = sessionId ?? currentSessionId
        let previous: FrameMeta? = if let normalizedProject,
                                      !normalizedProject.isEmpty,
                                      let effectiveSessionId {
            await wax.latestActiveHandoffMeta(
                project: normalizedProject,
                matchingSessionId: effectiveSessionId.uuidString
            )
        } else {
            nil
        }
        let searchText = ([content] + pending).joined(separator: "\n")

        var metadata = Metadata()
        metadata.entries["kind"] = "handoff"
        metadata.entries[MemoryMetadataKeys.type] = MemoryType.handoff.rawValue
        metadata.entries[MemoryMetadataKeys.durability] = MemoryDurability.ephemeral.rawValue
        metadata.entries[MemoryMetadataKeys.createdAtMs] = String(nowProvider())
        if let normalizedProject, !normalizedProject.isEmpty {
            metadata.entries["project"] = normalizedProject
            metadata.entries[MemoryMetadataKeys.project] = normalizedProject
        }
        if !pending.isEmpty {
            metadata.entries["pending_tasks"] = pending.joined(separator: "\n")
        }
        if let effectiveSessionId {
            metadata.entries["session_id"] = effectiveSessionId.uuidString
        }

        let frameId = try await session.put(
            Data(content.utf8),
            options: FrameMetaSubset(
                kind: FrameKind.handoff.storageValue,
                labels: ["handoff"],
                role: .document,
                searchText: searchText,
                metadata: metadata
            )
        )
        if config.enableTextSearch {
            try await session.indexText(frameId: frameId, text: searchText)
        }
        if let previous, previous.id != frameId {
            try await wax.supersede(supersededId: previous.id, supersedingId: frameId)
        }
        // Ensure latestHandoff() can observe this frame immediately when commit=true.
        if commit {
            try await session.commit()
        }
        return frameId
    }

    package func latestHandoff(project: String? = nil) async throws -> HandoffRecord? {
        guard let latest = await wax.latestCommittedActiveHandoffMeta(project: project) else {
            return nil
        }

        let payload = try await wax.frameContent(frameId: latest.id)
        guard let content = String(data: payload, encoding: .utf8) else {
            throw WaxError.decodingError(reason: "handoff payload is not UTF-8")
        }
        let metadata = latest.metadata?.entries ?? [:]
        let pendingTasks = metadata["pending_tasks"]?
            .split(separator: "\n")
            .map { String($0) } ?? []

        return HandoffRecord(
            frameId: latest.id,
            timestampMs: latest.timestamp,
            content: content,
            project: metadata["project"],
            pendingTasks: pendingTasks
        )
    }

    package func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String] = [],
        commit: Bool = true
    ) async throws -> EntityRowID {
        try ensureStructuredMemoryEnabled()
        let nowMs = nowProvider()
        let entityID = try await session.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs)
        if commit {
            try await session.commit()
        }
        return entityID
    }

    package func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        relation: VersionRelation = .sets,
        validFromMs: Int64? = nil,
        validToMs: Int64? = nil,
        evidence: [StructuredEvidence] = [],
        commit: Bool = true
    ) async throws -> FactRowID {
        try ensureStructuredMemoryEnabled()
        let nowMs = try nextStructuredSystemMs()
        let valid = StructuredTimeRange(fromMs: validFromMs ?? nowMs, toMs: validToMs)
        let system = StructuredTimeRange(fromMs: nowMs, toMs: nil)
        let factID = try await session.assertFact(
            subject: subject,
            predicate: predicate,
            object: object,
            relation: relation,
            valid: valid,
            system: system,
            evidence: evidence
        )
        if commit {
            try await session.commit()
        }
        return factID
    }

    package func retractFact(factId: FactRowID, atMs: Int64? = nil, commit: Bool = true) async throws {
        try ensureStructuredMemoryEnabled()
        let timestamp = try atMs ?? nextStructuredSystemMs()
        try await session.retractFact(factId: factId, atMs: timestamp)
        if commit {
            try await session.commit()
        }
    }

    private func nextStructuredSystemMs() throws -> Int64 {
        let wallNow = nowProvider()
        guard wallNow < Int64.max else {
            throw WaxError.encodingError(reason: "structured system timestamp must be less than Int64.max")
        }
        guard let last = lastStructuredSystemMs, wallNow <= last else {
            lastStructuredSystemMs = wallNow
            return wallNow
        }

        let next = last.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue < Int64.max else {
            throw WaxError.encodingError(reason: "structured system timestamp overflow")
        }
        lastStructuredSystemMs = next.partialValue
        return next.partialValue
    }

    package func facts(
        about subject: EntityKey? = nil,
        predicate: PredicateKey? = nil,
        asOfMs: Int64 = Int64.max,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> StructuredFactsResult {
        try ensureStructuredMemoryEnabled()
        return try await session.facts(
            about: subject,
            predicate: predicate,
            asOf: StructuredMemoryAsOf(
                systemTimeMs: systemAsOfMs ?? asOfMs,
                validTimeMs: validAsOfMs ?? asOfMs
            ),
            limit: limit
        )
    }

    package func edges(
        for entity: EntityKey,
        direction: StructuredEdgeDirection,
        predicate: PredicateKey? = nil,
        asOfMs: Int64 = Int64.max,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> StructuredEdgesResult {
        try ensureStructuredMemoryEnabled()
        return try await session.edges(
            for: entity,
            direction: direction,
            predicate: predicate,
            asOf: StructuredMemoryAsOf(
                systemTimeMs: systemAsOfMs ?? asOfMs,
                validTimeMs: validAsOfMs ?? asOfMs
            ),
            limit: limit
        )
    }

    package func resolveEntities(matchingAlias alias: String, limit: Int = 10) async throws -> [StructuredEntityMatch] {
        try ensureStructuredMemoryEnabled()
        return try await session.resolveEntities(matchingAlias: alias, limit: limit)
    }

    package func entity(forKey key: EntityKey) async throws -> StructuredEntityMatch? {
        try ensureStructuredMemoryEnabled()
        return try await session.entity(forKey: key)
    }

    private func ensureStructuredMemoryEnabled() throws {
        guard config.enableStructuredMemory else {
            throw WaxError.featureDisabled(feature: "structured memory")
        }
    }
}
