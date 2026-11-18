import Foundation
import WaxCore

extension AgentBrokerService {
    func sessionSynthesize(_ command: BrokerCommand.SessionSynthesize) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        guard let resolvedSessionID = try resolveSessionID(sessionID) else {
            if activeSessions.count > 1 {
                throw BrokerValidationError.invalid("session_id is required when more than one session is active")
            }
            throw BrokerValidationError.invalid("session_id is required when no active session is available; call session_open with conversation_id")
        }
        _ = try await memory(for: resolvedSessionID)
        guard let session = activeSessions[resolvedSessionID] else {
            throw BrokerSessionInactiveError.unknown(sessionID: resolvedSessionID)
        }
        let sessionDocuments = try await session.memory.corpusSourceDocuments()
        let longTermDocuments = try await longTermMemory.corpusSourceDocuments()
        let recallSignals = try await sessionSignals(for: resolvedSessionID)
        let settings = promotionSettingsMerging(command)
        let synthesis = BrokerMemoryInsights.synthesizeSession(
            documents: sessionDocuments,
            scope: scopeContext,
            longTermDocuments: longTermDocuments,
            recallSignalsByFrameID: recallSignals,
            settings: settings
        )
        return .object([
            "session_id": .string(resolvedSessionID.uuidString),
            "summary": .string(synthesis.summary),
            "handoff": .string(synthesis.handoff),
            "lessons": .array(synthesis.lessons.map(AgentBrokerValue.string)),
            "decisions": .array(synthesis.decisions.map(AgentBrokerValue.string)),
            "preferences": .array(synthesis.preferences.map(AgentBrokerValue.string)),
            "constraints": .array(synthesis.constraints.map(AgentBrokerValue.string)),
            "durable_candidates": .array(synthesis.durableCandidates.map(renderPromotionProposal)),
            "display_text": .string(synthesis.summary),
        ])
    }

    func memoryPromote(_ command: BrokerCommand.MemoryPromote) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        try await validateActiveSession(sessionID)
        let approve = command.approve
        let requestedSourceFrameId = command.frameID
        let explicitContent = command.content
        let writeSemantics = command.writeSemantics
        let longTermDocuments = try await longTermMemory.corpusSourceDocuments()
        let settings = BrokerPromotionSettings(
            minimumConfidence: command.minimumConfidence ?? promotionSettings.minimumConfidence,
            minimumRecallCount: command.minimumRecallCount ?? promotionSettings.minimumRecallCount,
            maxCandidates: command.maxCandidates ?? promotionSettings.maxCandidates
        )

        let content: String
        var sourceMetadata: [String: String] = [:]
        var sourceFrameId = requestedSourceFrameId
        var resolvedPromotionSessionID = sessionID

        if let explicitContent, !explicitContent.isEmpty {
            content = explicitContent
        } else {
            guard let resolvedSessionID = try resolveSessionID(sessionID),
                  let session = activeSessions[resolvedSessionID] else {
                throw BrokerValidationError.invalid("Provide content or an active session_id for promotion")
            }
            resolvedPromotionSessionID = resolvedSessionID
            let documents = try await session.memory.corpusSourceDocuments()
            let sourceDocument: MemoryOrchestrator.CorpusSourceDocument?
            if let requestedSourceFrameId {
                sourceDocument = documents.first { $0.frameId == requestedSourceFrameId }
            } else {
                sourceDocument = documents.sorted { $0.timestampMs > $1.timestampMs }.first
            }
            guard let sourceDocument else {
                throw BrokerValidationError.invalid("No promotable session memory was found")
            }
            content = sourceDocument.text
            sourceMetadata = sourceDocument.metadata
            sourceFrameId = sourceDocument.frameId
            await session.memory.recordAccess(frameId: sourceDocument.frameId)
        }

        let baseMetadata = command.metadata.merging(sourceMetadata) { current, _ in current }
        var normalizedMetadata = MemorySemantics.normalizeWriteMetadata(
            metadata: baseMetadata,
            semantics: writeSemantics,
            sessionID: nil,
            inferredScope: writeScope(for: resolvedPromotionSessionID, clientCWD: command.cwd),
            nowMs: BrokerClock.nowMs()
        )
        if let resolvedPromotionSessionID {
            normalizedMetadata[MemoryMetadataKeys.promotedFromSession] = resolvedPromotionSessionID.uuidString
            normalizedMetadata.removeValue(forKey: "session_id")
        }
        if let sourceFrameId {
            normalizedMetadata[MemoryMetadataKeys.promotedFromFrame] = String(sourceFrameId)
        }
        let recallSignal: BrokerSessionRecallSignals?
        if let resolvedPromotionSessionID, let sourceFrameId {
            recallSignal = try await sessionSignals(for: resolvedPromotionSessionID)[sourceFrameId]
        } else {
            recallSignal = nil
        }
        let proposal = BrokerMemoryInsights.proposePromotion(
            content: content,
            metadata: normalizedMetadata,
            sessionID: resolvedPromotionSessionID,
            sourceFrameID: sourceFrameId,
            scope: scopeContext,
            longTermDocuments: longTermDocuments,
            recallSignals: recallSignal,
            settings: settings
        )

        if approve, proposal.shouldWrite {
            normalizedMetadata = MemorySemantics.approvedPromotionMetadata(
                metadata: normalizedMetadata,
                semantics: writeSemantics,
                suggestedType: proposal.suggestedType,
                suggestedDurability: proposal.suggestedDurability,
                suggestedConfidence: proposal.confidence
            )
            let destination = try RememberDestination.decode(
                sessionID: nil,
                writeScope: .durable,
                semantics: writeSemantics,
                metadata: normalizedMetadata
            )
            normalizedMetadata = try MemorySemantics.validatedWriteMetadata(
                metadata: normalizedMetadata,
                destination: destination,
                activeSession: false,
                inferredScope: writeScope(for: resolvedPromotionSessionID, clientCWD: command.cwd),
                nowMs: BrokerClock.nowMs()
            )
            try validateDurableWriteContent(content: content, metadata: normalizedMetadata)
            try await longTermMemory.remember(content, metadata: normalizedMetadata)
            try await longTermMemory.flush()
        }
        if let resolvedPromotionSessionID {
            try await refreshSessionManifest(resolvedPromotionSessionID)
            try await appendSessionEvent(
                sessionID: resolvedPromotionSessionID,
                kind: approve && proposal.shouldWrite ? .promotionWritten : .promotionReviewed,
                payload: [
                    "frame_id": sourceFrameId.map(String.init) ?? "",
                    "memory_type": proposal.suggestedType.rawValue,
                    "confidence": String(proposal.confidence),
                    "approved": approve ? "true" : "false",
                    "written": (approve && proposal.shouldWrite) ? "true" : "false",
                ]
            )
        }

        return .object([
            "approved": .bool(approve),
            "written": .bool(approve && proposal.shouldWrite),
            "proposal": renderPromotionProposal(proposal),
            "metadata": .object(normalizedMetadata.mapValues(AgentBrokerValue.string)),
            "display_text": .string(proposal.summary),
        ])
    }

    func renderPromotionProposal(_ proposal: BrokerPromotionProposal) -> AgentBrokerValue {
        .object([
            "content": .string(proposal.content),
            "summary": .string(proposal.summary),
            "suggested_type": .string(proposal.suggestedType.rawValue),
            "suggested_durability": .string(proposal.suggestedDurability.rawValue),
            "confidence": .double(Double(proposal.confidence)),
            "recall_count": .from(proposal.recallCount),
            "unique_query_count": .from(proposal.uniqueQueryCount),
            "last_retrieved_at_ms": .from(proposal.lastRetrievedAtMs),
            "average_relevance_score": .double(Double(proposal.averageRelevanceScore)),
            "should_write": .bool(proposal.shouldWrite),
            "reasons": .array(proposal.reasons.map(AgentBrokerValue.string)),
            "duplicate_matches": .array(proposal.duplicateMatches.map { duplicate in
                .object([
                    "frame_id": .from(duplicate.frameId),
                    "similarity": .double(Double(duplicate.similarity)),
                    "summary": .string(duplicate.summary),
                    "memory_type": .string(duplicate.memoryType.rawValue),
                ])
            }),
        ])
    }
}
