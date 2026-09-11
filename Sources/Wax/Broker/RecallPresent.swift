import Foundation

/// Pure hit → `AgentBrokerValue` wire rendering for recall / memory_search / compact.
/// Layered recall I/O and packing stay elsewhere; this only owns presentation keys.
package enum RecallPresent {
    package static func itemKindLabel(_ kind: RAGContext.ItemKind) -> String {
        switch kind {
        case .expanded:
            return "expanded"
        case .surrogate:
            return "surrogate"
        case .snippet:
            return "snippet"
        }
    }

    package static func ageDays(createdAtMs: Int64, nowMs: Int64) -> Int64 {
        guard createdAtMs > 0 else { return 0 }
        return max(0, (nowMs - createdAtMs) / (1000 * 60 * 60 * 24))
    }

    package static func compactHitObject(
        id: String,
        text: String,
        preview: String?,
        metadata: [String: String],
        score: Float,
        createdAtMs: Int64,
        nowMs: Int64
    ) -> [String: AgentBrokerValue] {
        var object: [String: AgentBrokerValue] = [
            "id": .string(id),
            "text": .string(text),
            "score": .double(Double(score)),
        ]
        if createdAtMs > 0 {
            object["created_at_ms"] = .int(createdAtMs)
            object["age_days"] = .int(ageDays(createdAtMs: createdAtMs, nowMs: nowMs))
        }
        if let preview {
            object["preview"] = .string(preview)
        }
        if let project = metadata[MemoryMetadataKeys.project], !project.isEmpty {
            object["project"] = .string(project)
        }
        if let repo = metadata[MemoryMetadataKeys.repo], !repo.isEmpty {
            object["repo"] = .string(repo)
        }
        if let memoryType = metadata[MemoryMetadataKeys.type], !memoryType.isEmpty {
            object["memory_type"] = .string(memoryType)
        }
        if let durability = metadata[MemoryMetadataKeys.durability], !durability.isEmpty {
            object["durability"] = .string(durability)
        }
        if let reviewed = metadata[MemoryMetadataKeys.reviewed] {
            object["reviewed"] = .bool(reviewed.lowercased() == "true")
        }
        if let confidence = metadata[MemoryMetadataKeys.confidence].flatMap(Double.init) {
            object["confidence"] = .double(confidence)
        }
        return object
    }

    package static func renderRecallHit(
        _ hit: LayeredRecall.Hit,
        rank: Int,
        verbose: Bool,
        nowMs: Int64
    ) -> AgentBrokerValue {
        var object = compactHitObject(
            id: hit.reference,
            text: hit.text,
            preview: nil,
            metadata: hit.metadata,
            score: hit.score,
            createdAtMs: hit.timestampMs,
            nowMs: nowMs
        )
        if verbose {
            object["rank"] = .from(rank)
            object["kind"] = .string(itemKindLabel(hit.kind))
            object["frameId"] = .from(hit.frameID)
            object["sources"] = .array(hit.sources.map { .string($0.rawValue) })
            object["metadata"] = .object(hit.metadata.mapValues(AgentBrokerValue.string))
            object["explanations"] = .array(hit.explanations.map(AgentBrokerValue.string))
        }
        return .object(object)
    }

    package static let compactRecallEnvelopeKeysToDrop: Set<String> = [
        "query_embedding_state", "applied_filters", "retrieval_top_k", "search_top_k",
        "total_tokens", "display_text",
    ]

    package static func slimCompactRecallEnvelope(
        _ payload: [String: AgentBrokerValue]
    ) -> [String: AgentBrokerValue] {
        var object = payload
        for key in compactRecallEnvelopeKeysToDrop {
            object.removeValue(forKey: key)
        }
        return object
    }

    package static func renderLayeredMemoryHit(
        _ hit: LayeredRecall.Hit,
        nowMs: Int64
    ) -> AgentBrokerValue {
        var object = compactHitObject(
            id: hit.reference,
            text: hit.text,
            preview: hit.preview,
            metadata: hit.metadata,
            score: hit.score,
            createdAtMs: hit.timestampMs,
            nowMs: nowMs
        )
        object["memory_id"] = .string(hit.reference)
        object["horizon"] = .string(hit.horizon.rawValue)
        object["session_id"] = .from(hit.sessionID?.uuidString)
        object["agent_id"] = .from(hit.agentID)
        object["run_id"] = .from(hit.runID)
        object["frame_id"] = .from(hit.frameID)
        object["explanations"] = .array(hit.explanations.map(AgentBrokerValue.string))
        object["metadata"] = .object(hit.metadata.mapValues(AgentBrokerValue.string))
        return .object(object)
    }

    package static func renderCompactLayeredMemoryHit(
        _ hit: LayeredRecall.Hit,
        nowMs: Int64
    ) -> AgentBrokerValue {
        var object = compactHitObject(
            id: hit.reference,
            text: hit.text,
            preview: hit.preview,
            metadata: hit.metadata,
            score: hit.score,
            createdAtMs: hit.timestampMs,
            nowMs: nowMs
        )
        object["memory_id"] = .string(hit.reference)
        object["frame_id"] = .from(hit.frameID)
        return .object(object)
    }
}
