import Foundation
import WaxCore

extension AgentBrokerService {
    func knowledgeCapture(_ command: BrokerCommand.KnowledgeCapture) async throws -> AgentBrokerValue {
        if let sessionID = command.sessionID {
            _ = try await memory(for: sessionID)
        }
        let metadata = try MemorySemantics.validatedWriteMetadata(
            metadata: command.metadata,
            destination: command.destination,
            activeSession: command.sessionID != nil,
            inferredScope: writeScope(for: command.sessionID, clientCWD: command.cwd),
            nowMs: BrokerClock.nowMs()
        )
        try validateDurableWriteContent(content: command.content, metadata: metadata)

        let isSessionTaskState =
            metadata[MemoryMetadataKeys.type] == MemoryType.taskState.rawValue
            && command.sessionID != nil
        if isSessionTaskState, let sessionID = command.sessionID {
            let sessionMemory = try await memory(for: sessionID)
            try await sessionMemory.remember(command.content, metadata: metadata)
            try await sessionMemory.flush()
        } else {
            try await longTermMemory.remember(command.content, metadata: metadata)
        }

        var entityID: Int64?
        var factID: Int64?
        switch command.graphWrite {
        case .none:
            break
        case .entity(let key, let kind, let aliases):
            let resolvedKind = try await resolvedKnowledgeCaptureKind(key: key, decodedKind: kind)
            entityID = try await longTermMemory.upsertEntity(
                key: key,
                kind: resolvedKind,
                aliases: aliases,
                commit: false
            ).rawValue
        case .fact(let subject, let predicate, let object, let kind, let aliases):
            let resolvedKind = try await resolvedKnowledgeCaptureKind(key: subject, decodedKind: kind)
            entityID = try await longTermMemory.upsertEntity(
                key: subject,
                kind: resolvedKind,
                aliases: aliases,
                commit: false
            ).rawValue
            factID = try await longTermMemory.assertFact(
                subject: subject,
                predicate: predicate,
                object: object,
                relation: .sets,
                validFromMs: nil,
                validToMs: nil,
                commit: false
            ).rawValue
        }

        try await longTermMemory.flush()

        if let sessionID = command.sessionID {
            try await refreshSessionManifest(sessionID)
            try await appendSessionEvent(
                sessionID: sessionID,
                kind: .remembered,
                payload: [
                    "content_hash": Self.stableHash(command.content),
                    "memory_type": metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue,
                    "durability": metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue,
                ]
            )
        }

        return .object([
            "status": .string("ok"),
            "entity_id": .from(entityID),
            "fact_id": .from(factID),
            "memory_type": .string(metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue),
            "durability": .string(metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue),
            "display_text": .string(MemorySemantics.summarizeCandidate(command.content)),
        ])
    }

    /// Omitted kind decodes as `"concept"`. Keep an existing non-empty kind so
    /// a subject-only capture does not rewrite it.
    private func resolvedKnowledgeCaptureKind(
        key: EntityKey,
        decodedKind: String
    ) async throws -> String {
        if decodedKind != "concept" {
            return decodedKind
        }
        if let existing = try await longTermMemory.entity(forKey: key), !existing.kind.isEmpty {
            return existing.kind
        }
        return "concept"
    }

    func entityUpsert(_ command: BrokerCommand.EntityUpsert) async throws -> AgentBrokerValue {
        let entityID = try await longTermMemory.upsertEntity(
            key: command.key,
            kind: command.kind,
            aliases: command.aliases,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "entity_id": .from(entityID.rawValue),
            "key": .string(command.key.rawValue),
            "committed": .bool(true),
        ])
    }

    func factAssert(_ command: BrokerCommand.FactAssert) async throws -> AgentBrokerValue {
        let factID = try await longTermMemory.assertFact(
            subject: command.subject,
            predicate: command.predicate,
            object: command.object,
            relation: command.relation,
            validFromMs: command.validFromMs,
            validToMs: command.validToMs,
            evidence: command.evidence,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "fact_id": .from(factID.rawValue),
            "evidence_count": .from(command.evidence.count),
            "committed": .bool(true),
        ])
    }

    func factRetract(_ command: BrokerCommand.FactRetract) async throws -> AgentBrokerValue {
        try await longTermMemory.retractFact(
            factId: command.factID,
            atMs: command.atMs,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "fact_id": .from(command.factID.rawValue),
            "at_ms": .from(command.atMs),
            "committed": .bool(true),
        ])
    }

    func factsQuery(_ command: BrokerCommand.FactsQuery) async throws -> AgentBrokerValue {
        let limit = command.limit
        let asOfMs = command.asOfMs
        let systemAsOfMs = command.systemAsOfMs
        let validAsOfMs = command.validAsOfMs
        let result = try await longTermMemory.facts(
            about: command.subject,
            predicate: command.predicate,
            asOfMs: asOfMs ?? Int64.max,
            systemAsOfMs: systemAsOfMs,
            validAsOfMs: validAsOfMs,
            limit: limit
        )
        let effectiveSystemAsOfMs = systemAsOfMs ?? asOfMs
        let effectiveValidAsOfMs = validAsOfMs ?? asOfMs
        let hits: [AgentBrokerValue] = result.hits.map { hit in
            AgentBrokerValue.object([
                "fact_id": .from(hit.factId.rawValue),
                "span_id": .from(hit.spanId),
                "subject": .string(hit.fact.subject.rawValue),
                "predicate": .string(hit.fact.predicate.rawValue),
                "object": factValueAsBrokerValue(hit.fact.object),
                "relation": .string(hit.relation.wireName),
                "valid_from_ms": .from(hit.valid.fromMs),
                "valid_to_ms": hit.valid.toMs.map(AgentBrokerValue.from) ?? .null,
                "system_from_ms": .from(hit.system.fromMs),
                "system_to_ms": hit.system.toMs.map(AgentBrokerValue.from) ?? .null,
                "is_open_ended": .from(hit.isOpenEnded),
                "evidence_count": .from(hit.evidence.count),
                "evidence": .array(hit.evidence.map(renderStructuredEvidence)),
            ])
        }
        return .object([
            "count": .from(result.hits.count),
            "truncated": .from(result.wasTruncated),
            "as_of": asOfMs.map(AgentBrokerValue.from) ?? .null,
            "system_as_of": effectiveSystemAsOfMs.map(AgentBrokerValue.from) ?? .null,
            "valid_as_of": effectiveValidAsOfMs.map(AgentBrokerValue.from) ?? .null,
            "hits": .array(hits),
        ])
    }

    func entityResolve(_ command: BrokerCommand.EntityResolve) async throws -> AgentBrokerValue {
        let matches = try await longTermMemory.resolveEntities(
            matchingAlias: command.alias,
            limit: command.limit
        )
        let entities: [AgentBrokerValue] = matches.map { match in
            .object([
                "id": .from(match.id),
                "key": .string(match.key.rawValue),
                "kind": .string(match.kind),
            ])
        }
        return .object([
            "count": .from(matches.count),
            "entities": .array(entities),
        ])
    }

    func renderStructuredEvidence(_ evidence: StructuredEvidence) -> AgentBrokerValue {
        var object: [String: AgentBrokerValue] = [
            "source_frame_id": .from(evidence.sourceFrameId),
            "extractor_id": .string(evidence.extractorId),
            "extractor_version": .string(evidence.extractorVersion),
            "asserted_at_ms": .from(evidence.assertedAtMs),
        ]
        object["chunk_index"] = evidence.chunkIndex.map { .int(Int64($0)) } ?? .null
        object["span_start_utf8"] = evidence.spanUTF8.map { .from($0.lowerBound) } ?? .null
        object["span_end_utf8"] = evidence.spanUTF8.map { .from($0.upperBound) } ?? .null
        object["confidence"] = evidence.confidence.map { .double($0) } ?? .null
        return .object(object)
    }

    func factValueAsBrokerValue(_ value: FactValue) -> AgentBrokerValue {
        switch value {
        case .string(let s):
            return .string(s)
        case .int(let i):
            return .int(i)
        case .double(let d):
            return .double(d)
        case .bool(let b):
            return .bool(b)
        case .entity(let key):
            return .object(["entity": .string(key.rawValue)])
        case .timeMs(let ms):
            return .object(["time_ms": .int(ms)])
        case .data(let data):
            return .object(["data_base64": .string(data.base64EncodedString())])
        }
    }
}
