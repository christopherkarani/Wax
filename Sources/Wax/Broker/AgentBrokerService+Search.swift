import Foundation
import WaxCore

extension AgentBrokerService {
    func remember(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let content = try args.requiredStringPreservingWhitespace("content", maxBytes: Self.maxContentBytes)
        let sessionID = try parseOptionalSessionID(args)
        let rawMetadata = try coerceMetadata(try args.optionalObject("metadata"))
        if rawMetadata["session_id"] != nil {
            throw BrokerValidationError.invalid("metadata.session_id is reserved; use top-level session_id")
        }
        let writeSemantics = try parseWriteSemantics(args)
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: rawMetadata,
            semantics: writeSemantics,
            sessionID: sessionID,
            inferredScope: scopeContext
        )
        try validateDurableWriteContent(content: content, metadata: metadata)
        let memory = try await memory(for: sessionID)

        let before = await memory.runtimeStats()
        try await memory.remember(content, metadata: metadata)
        if let sessionID {
            try await refreshSessionManifest(sessionID)
            try await appendSessionEvent(
                sessionID: sessionID,
                kind: .remembered,
                payload: [
                    "content_hash": Self.stableHash(content),
                    "memory_type": metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue,
                    "durability": metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue,
                ]
            )
        }
        try await memory.flush()
        let after = await memory.runtimeStats()
        let totalBefore = before.frameCount + before.pendingFrames
        let totalAfter = after.frameCount + after.pendingFrames
        let added = totalAfter >= totalBefore ? (totalAfter - totalBefore) : 0

        return .object([
            "status": .string("ok"),
            "framesAdded": .from(added),
            "frameCount": .from(after.frameCount),
            "pendingFrames": .from(after.pendingFrames),
            "display_text": .string("Remembered. \(added) frame(s) added (\(after.frameCount) total, \(after.pendingFrames) pending)."),
        ])
    }

    func memoryAppend(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        try await remember(arguments: arguments)
    }

    func recall(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try args.requiredString("query", maxBytes: Self.maxContentBytes)
        let limit = try args.optionalInt("limit") ?? 5
        guard (1...Self.maxRecallLimit).contains(limit) else {
            throw BrokerValidationError.invalid("limit must be between 1 and \(Self.maxRecallLimit)")
        }
        let parsedFilters = try parseSearchFilters(args)
        let memory = try await memory(for: parsedFilters.sessionId)

        let mode = try parseRecallMode(args)
        let requestedTopK = try args.optionalInt("search_top_k") ?? (try args.optionalInt("topK"))
        if let requestedTopK, !(1...Self.maxTopK).contains(requestedTopK) {
            throw BrokerValidationError.invalid("search_top_k must be between 1 and \(Self.maxTopK)")
        }
        let effectiveTopK = requestedTopK ?? limit
        let embeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy = switch mode {
        case .text?:
            .never
        case .vector?:
            .always
        case .hybrid?, nil:
            .ifAvailable
        }
        let execution = try await memory.recallExecution(
            query: query,
            embeddingPolicy: embeddingPolicy,
            frameFilter: parsedFilters.frameFilter,
            timeRange: parsedFilters.timeRange,
            topK: effectiveTopK,
            mode: mode
        )
        let context = execution.context
        let selected = Array(context.items.prefix(limit))
        var lines: [String] = [
            "Query: \(context.query)",
            "Total tokens: \(context.totalTokens)",
            "Results: \(selected.count) of \(limit) requested (orchestrator returned \(context.items.count))",
            "Search controls: requested_mode=\(execution.requestedModeSummary) effective_mode=\(execution.effectiveModeSummary) query_embedding_state=\(execution.queryEmbeddingState.rawValue) search_top_k=\(effectiveTopK) limit=\(limit)",
        ]
        lines.append("Applied filters: \(parsedFilters.summary.debugJSONString)")
        for (index, item) in selected.enumerated() {
            lines.append("\(index + 1). [\(item.kind)] frame=\(item.frameId) score=\(String(format: "%.4f", item.score)) \(item.text)")
        }

        let results: [AgentBrokerValue] = selected.enumerated().map { index, item in
            .object([
                "rank": .from(index + 1),
                "kind": .string("\(item.kind)"),
                "frameId": .from(item.frameId),
                "score": .double(Double(item.score)),
                "sources": .array(item.sources.map { .string($0.rawValue) }),
                "text": .string(item.text),
                "metadata": .object(item.metadata.mapValues(AgentBrokerValue.string)),
                "explanations": .array(item.explanations.map(AgentBrokerValue.string)),
            ])
        }
        if let sessionID = parsedFilters.sessionId {
            try await refreshSessionManifest(sessionID)
            try await recordRetrievalHits(
                sessionID: sessionID,
                query: query,
                hits: selected.map { ($0.frameId, $0.score) },
                memory: memory
            )
        }

        return .object([
            "query": .string(context.query),
            "total_tokens": .from(context.totalTokens),
            "result_count": .from(selected.count),
            "limit": .from(limit),
            "search_top_k": .from(effectiveTopK),
            "requested_mode": .string(execution.requestedModeSummary),
            "effective_mode": .string(execution.effectiveModeSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "applied_filters": parsedFilters.summary,
            "results": .array(results),
            "display_text": .string(lines.joined(separator: "\n")),
        ])
    }

    func search(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try args.requiredString("query", maxBytes: Self.maxContentBytes)
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...Self.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(Self.maxTopK)")
        }
        let parsedFilters = try parseSearchFilters(args)
        let memory = try await memory(for: parsedFilters.sessionId)
        let execution = try await memory.searchExecution(
            query: query,
            mode: mode,
            topK: topK,
            frameFilter: parsedFilters.frameFilter,
            timeRange: parsedFilters.timeRange
        )
        let rows: [AgentBrokerValue] = execution.hits.enumerated().map { index, hit in
            .object([
                "rank": .from(index + 1),
                "frameId": .from(hit.frameId),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": .string(hit.previewText ?? ""),
                "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
                "explanations": .array(hit.explanations.map(AgentBrokerValue.string)),
            ])
        }
        if let sessionID = parsedFilters.sessionId {
            try await refreshSessionManifest(sessionID)
            try await recordRetrievalHits(
                sessionID: sessionID,
                query: query,
                hits: execution.hits.map { ($0.frameId, $0.score) },
                memory: memory
            )
        }
        let text = rows.isEmpty ? "No results." : rows.map(\.debugJSONString).joined(separator: "\n")
        return .object([
            "query": .string(query),
            "topK": .from(topK),
            "requested_mode": .string(execution.requestedModeSummary),
            "effective_mode": .string(execution.effectiveModeSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "applied_filters": parsedFilters.summary,
            "time_range_requested": .from(parsedFilters.timeRange != nil),
            "time_range_applied": .from(parsedFilters.timeRange != nil),
            "results": .array(rows),
            "display_text": .string(text),
        ])
    }

    func memorySearch(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try args.requiredString("query", maxBytes: Self.maxContentBytes)
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...Self.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(Self.maxTopK)")
        }
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let includeWorking = try args.optionalBool("include_working") ?? true
        let includeEpisodic = try args.optionalBool("include_episodic") ?? true
        let includeDurable = try args.optionalBool("include_durable") ?? true
        let sessionID = try resolveSessionID(
            try parseOptionalSessionID(args),
            requiringUnambiguousWorkingMemory: includeWorking
        )
        let hits = try await layeredMemorySearch(
            query: query,
            mode: mode,
            topK: topK,
            sessionID: sessionID,
            includeWorking: includeWorking,
            includeEpisodic: includeEpisodic,
            includeDurable: includeDurable
        )

        if let sessionID {
            let sessionMemory = try await memory(for: sessionID)
            try await refreshSessionManifest(sessionID)
            try await recordRetrievalHits(
                sessionID: sessionID,
                query: query,
                hits: hits.map { ($0.frameID, $0.score) },
                memory: sessionMemory
            )
        }

        let rows = hits.map(renderLayeredMemoryHit)
        let text = rows.isEmpty ? "No results." : rows.map(\.debugJSONString).joined(separator: "\n")
        return .object([
            "query": .string(query),
            "topK": .from(topK),
            "results": .array(rows),
            "display_text": .string(text),
        ])
    }

    func memoryGet(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let memoryID = try args.requiredString("memory_id", maxBytes: 512)
        let reference = try parseMemoryReference(memoryID)
        let hit = try await layeredMemoryGet(reference: reference)
        return .object([
            "memory_id": .string(hit.reference),
            "horizon": .string(hit.horizon.rawValue),
            "session_id": .from(hit.sessionID?.uuidString),
            "agent_id": .from(hit.agentID),
            "run_id": .from(hit.runID),
            "frame_id": .from(hit.frameID),
            "timestamp_ms": .from(hit.timestampMs),
            "text": .string(hit.text),
            "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
            "explanations": .array(hit.explanations.map(AgentBrokerValue.string)),
            "display_text": .string(hit.text),
        ])
    }

    func sessionSynthesize(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let sessionID = try parseOptionalSessionID(args)
        guard let resolvedSessionID = try resolveSessionID(sessionID) else {
            throw BrokerValidationError.invalid("session_id is required when no active session is available")
        }
        guard let session = activeSessions[resolvedSessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        let sessionDocuments = try await session.memory.corpusSourceDocuments()
        let longTermDocuments = try await longTermMemory.corpusSourceDocuments()
        let recallSignals = try await sessionSignals(for: resolvedSessionID)
        let settings = try parsePromotionSettings(args)
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

    func memoryPromote(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let sessionID = try parseOptionalSessionID(args)
        try validateActiveSession(sessionID)
        let approve = try args.optionalBool("approve") ?? false
        let requestedSourceFrameId = try args.optionalUInt64("frame_id")
        let explicitContent = try args.optionalStringPreservingWhitespace("content")
        let writeSemantics = try parseWriteSemantics(args)
        let longTermDocuments = try await longTermMemory.corpusSourceDocuments()
        let settings = try parsePromotionSettings(args)

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
        }

        let baseMetadata = try coerceMetadata(try args.optionalObject("metadata")).merging(sourceMetadata) { current, _ in current }
        var normalizedMetadata = MemorySemantics.normalizeWriteMetadata(
            metadata: baseMetadata,
            semantics: writeSemantics,
            sessionID: nil,
            inferredScope: scopeContext
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

    func promote(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        var normalized = arguments
        if normalized["approve"] == nil {
            normalized["approve"] = .bool(true)
        }
        return try await memoryPromote(arguments: normalized)
    }

    func memoryHealth() async throws -> AgentBrokerValue {
        let documents = try await longTermMemory.corpusSourceDocuments()
        let accessStats = await longTermMemory.accessStatsSnapshot()
        let facts = try? await longTermMemory.facts(limit: Self.maxGraphLimit)
        let report = BrokerMemoryInsights.healthReport(
            documents: documents,
            accessStats: accessStats,
            facts: facts
        )
        return .object([
            "total_documents": .from(report.totalDocuments),
            "typed_counts": .object(report.typedCounts.mapValues { .from($0) }),
            "expired_frame_ids": .array(report.expiredFrameIds.map(AgentBrokerValue.from)),
            "stale_frame_ids": .array(report.staleFrameIds.map(AgentBrokerValue.from)),
            "low_hit_frame_ids": .array(report.lowHitFrameIds.map(AgentBrokerValue.from)),
            "duplicate_pairs": .array(report.duplicatePairs.map { pair in
                .object([
                    "left_frame_id": .from(pair.leftFrameId),
                    "right_frame_id": .from(pair.rightFrameId),
                    "similarity": .double(Double(pair.similarity)),
                ])
            }),
            "contradictions": .array(report.contradictionSummaries.map(AgentBrokerValue.string)),
            "display_text": .string("Health: \(report.totalDocuments) docs, \(report.duplicatePairs.count) duplicate pairs, \(report.contradictionSummaries.count) contradiction signals."),
        ])
    }

    func knowledgeCapture(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let content = try args.requiredStringPreservingWhitespace("content", maxBytes: Self.maxContentBytes)
        var writeSemantics = try parseWriteSemantics(args)
        if !writeSemantics.lock, writeSemantics.durability == nil {
            writeSemantics.durability = .durable
        }
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: try coerceMetadata(try args.optionalObject("metadata")),
            semantics: writeSemantics,
            sessionID: nil,
            inferredScope: scopeContext
        )
        try validateDurableWriteContent(content: content, metadata: metadata)

        let subject = try args.optionalString("subject")
        let predicate = try args.optionalString("predicate")
        let objectValue = try args.optionalValue("object")
        let kind = try args.optionalString("kind")
        let aliases = try args.optionalStringArray("aliases") ?? []
        let parsedObject = try objectValue.map { try parseFactValue($0) }

        try await longTermMemory.remember(content, metadata: metadata)

        var entityID: Int64?
        if let subject, let kind {
            entityID = try await longTermMemory.upsertEntity(
                key: EntityKey(subject),
                kind: kind,
                aliases: aliases,
                commit: false
            ).rawValue
        }
        var factID: Int64?
        if let subject, let predicate, let parsedObject {
            factID = try await longTermMemory.assertFact(
                subject: EntityKey(subject),
                predicate: PredicateKey(predicate),
                object: parsedObject,
                relation: .sets,
                validFromMs: nil,
                validToMs: nil,
                commit: false
            ).rawValue
        }

        try await longTermMemory.flush()

        return .object([
            "status": .string("ok"),
            "entity_id": .from(entityID),
            "fact_id": .from(factID),
            "memory_type": .string(metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue),
            "durability": .string(metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue),
            "display_text": .string(MemorySemantics.summarizeCandidate(content)),
        ])
    }

    func stats() async throws -> AgentBrokerValue {
        let stats = await longTermMemory.runtimeStats()
        let activeSessionIDs = activeSessions.keys.sorted { $0.uuidString < $1.uuidString }
        let diskBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: stats.storeURL.path),
                  let size = attrs[.size] as? NSNumber
            else { return 0 }
            return size.uint64Value
        }()
        let sessionStats: MemoryOrchestrator.SessionRuntimeStats = if activeSessionIDs.count == 1,
            let session = activeSessionIDs.first {
            try await activeSessions[session]?.memory.sessionRuntimeStats(sessionId: session) ?? .init(
                active: false,
                sessionId: nil,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: 0,
                countsIncludePending: false
            )
        } else {
            .init(
                active: !activeSessionIDs.isEmpty,
                sessionId: nil,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: stats.pendingFrames,
                countsIncludePending: false
            )
        }

        let embedder: AgentBrokerValue = {
            guard let identity = stats.embedderIdentity else { return .null }
            return .object([
                "provider": .from(identity.provider),
                "model": .from(identity.model),
                "dimensions": .from(identity.dimensions),
                "normalized": .from(identity.normalized),
            ])
        }()

        return .object([
            "frameCount": .from(stats.frameCount),
            "pendingFrames": .from(stats.pendingFrames),
            "generation": .from(stats.generation),
            "diskBytes": .from(diskBytes),
            "storePath": .string(stats.storeURL.path),
            "vectorSearchEnabled": .from(stats.vectorSearchEnabled),
            "queryEmbeddingAvailable": .from(
                stats.vectorSearchEnabled && stats.queryEmbedderConfigured && !stats.queryEmbeddingCircuitOpen
            ),
            "queryEmbeddingCircuitOpen": .from(stats.queryEmbeddingCircuitOpen),
            "features": .object([
                "structuredMemoryEnabled": .from(stats.structuredMemoryEnabled),
                "accessStatsScoringEnabled": .from(stats.accessStatsScoringEnabled),
            ]),
            "embedder": embedder,
            "wal": .object([
                "walSize": .from(stats.wal.walSize),
                "writePos": .from(stats.wal.writePos),
                "checkpointPos": .from(stats.wal.checkpointPos),
                "pendingBytes": .from(stats.wal.pendingBytes),
                "committedSeq": .from(stats.wal.committedSeq),
                "lastSeq": .from(stats.wal.lastSeq),
                "wrapCount": .from(stats.wal.wrapCount),
                "checkpointCount": .from(stats.wal.checkpointCount),
            ]),
            "session": .object([
                "active": .from(sessionStats.active),
                "session_id": .from(sessionStats.sessionId?.uuidString),
                "activeSessionCount": .from(activeSessionIDs.count),
                "activeSessionIds": .array(activeSessionIDs.map { .string($0.uuidString) }),
                "sessionFrameCount": .from(sessionStats.sessionFrameCount),
                "sessionTokenEstimate": .from(sessionStats.sessionTokenEstimate),
                "pendingFramesStoreWide": .from(sessionStats.pendingFramesStoreWide),
                "countsIncludePending": .from(sessionStats.countsIncludePending),
            ]),
        ])
    }

    func flush() async throws -> AgentBrokerValue {
        try await longTermMemory.flush()
        for session in activeSessions.values {
            try await session.memory.flush()
        }
        let stats = await longTermMemory.runtimeStats()
        let message = "Flushed. \(stats.frameCount) frames now searchable."
        return .object([
            "status": .string("ok"),
            "message": .string(message),
            "frameCount": .from(stats.frameCount),
            "pendingFrames": .from(stats.pendingFrames),
            "display_text": .string(message),
        ])
    }

    func layeredMemorySearch(
        query: String,
        mode: MemoryOrchestrator.DirectSearchMode,
        topK: Int,
        sessionID: UUID?,
        includeWorking: Bool,
        includeEpisodic: Bool,
        includeDurable: Bool
    ) async throws -> [LayeredMemoryHit] {
        var hits: [LayeredMemoryHit] = []

        if includeWorking, let sessionID, let state = activeSessions[sessionID] {
            let execution = try await state.memory.searchExecution(
                query: query,
                mode: mode,
                topK: max(1, min(topK, 6)),
                frameFilter: nil,
                timeRange: nil
            )
            for hit in execution.hits {
                guard let canonicalFrameID = await bestEffortCanonicalDocumentFrameID(for: hit.frameId, memory: state.memory) else {
                    continue
                }
                hits.append(LayeredMemoryHit(
                    reference: Self.makeMemoryReference(.working, sessionID: sessionID, frameID: canonicalFrameID),
                    horizon: .working,
                    sessionID: sessionID,
                    agentID: state.manifest.agentID,
                    runID: state.manifest.runID,
                    frameID: canonicalFrameID,
                    score: hit.score + 0.25,
                    text: hit.previewText ?? "",
                    preview: hit.previewText ?? "",
                    metadata: hit.metadata,
                    explanations: ["current session"] + hit.explanations,
                    timestampMs: state.manifest.updatedAtMs
                ))
            }
        }

        if includeDurable {
            let execution = try await longTermMemory.searchExecution(
                query: query,
                mode: mode,
                topK: max(1, min(topK, 8)),
                frameFilter: nil,
                timeRange: nil
            )
            for hit in execution.hits {
                guard let canonicalFrameID = await bestEffortCanonicalDocumentFrameID(for: hit.frameId, memory: longTermMemory) else {
                    continue
                }
                hits.append(LayeredMemoryHit(
                    reference: Self.makeMemoryReference(.durable, sessionID: nil, frameID: canonicalFrameID),
                    horizon: .durable,
                    sessionID: nil,
                    agentID: nil,
                    runID: nil,
                    frameID: canonicalFrameID,
                    score: hit.score + 0.10,
                    text: hit.previewText ?? "",
                    preview: hit.previewText ?? "",
                    metadata: hit.metadata,
                    explanations: ["durable memory"] + hit.explanations,
                    timestampMs: hit.metadata[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init) ?? 0
                ))
            }
        }

        if includeEpisodic {
            let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
            let scopedManifests = manifests
                .filter { manifest in
                    guard manifest.status == .ended else { return false }
                    if let sessionID, manifest.sessionID == sessionID { return false }
                    if let current = sessionID, let active = activeSessions[current]?.manifest {
                        if manifest.agentID != active.agentID { return false }
                    }
                    return true
                }
                .prefix(6)

            for manifest in scopedManifests {
                let sessionURL = URL(fileURLWithPath: manifest.storePath)
                let eventLogURL = URL(fileURLWithPath: manifest.eventLogPath)
                let execution = try await openAdhocMemory(
                    at: sessionURL,
                    structuredMemoryEnabled: false,
                    noEmbedder: noEmbedder
                ) { memory in
                    try await memory.searchExecution(
                        query: query,
                        mode: mode,
                        topK: max(1, min(3, topK)),
                        frameFilter: nil,
                        timeRange: nil
                    )
                }
                let ageMs: Int64 = max(0, Self.nowMs() - manifest.updatedAtMs)
                let recencyBoost: Float = ageMs < Int64(7 * 24 * 60 * 60 * 1000) ? 0.15 : 0.05
                let signals = BrokerSessionPersistence.recallSignals(from: try BrokerSessionPersistence.loadEvents(from: eventLogURL))
                for hit in execution.hits {
                    guard let canonicalFrameID = try await openAdhocMemory(
                        at: sessionURL,
                        structuredMemoryEnabled: false,
                        noEmbedder: noEmbedder,
                        body: { memory in
                            await bestEffortCanonicalDocumentFrameID(for: hit.frameId, memory: memory)
                        }
                    ) else { continue }
                    let signal = signals[canonicalFrameID] ?? signals[hit.frameId]
                    var explanations = ["recent session episode", "agent \(manifest.agentID)"]
                    if let signal {
                        explanations.append("recalled \(signal.recallCount)x across \(signal.uniqueQueryCount) queries")
                    }
                    explanations.append(contentsOf: hit.explanations)
                    hits.append(LayeredMemoryHit(
                        reference: Self.makeMemoryReference(.episodic, sessionID: manifest.sessionID, frameID: canonicalFrameID),
                        horizon: .episodic,
                        sessionID: manifest.sessionID,
                        agentID: manifest.agentID,
                        runID: manifest.runID,
                        frameID: canonicalFrameID,
                        score: hit.score + recencyBoost,
                        text: hit.previewText ?? "",
                        preview: hit.previewText ?? "",
                        metadata: hit.metadata,
                        explanations: explanations,
                        timestampMs: manifest.updatedAtMs
                    ))
                }
            }
        }

        let deduped = Dictionary(hits.map { ($0.reference, $0) }, uniquingKeysWith: { current, candidate in
            candidate.score > current.score ? candidate : current
        }).values

        return deduped.sorted { lhs, rhs in
            if lhs.score != rhs.score { return lhs.score > rhs.score }
            if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
            return lhs.reference < rhs.reference
        }.prefix(topK).map { $0 }
    }

    func layeredMemoryGet(reference: MemoryReference) async throws -> LayeredMemoryHit {
        switch reference.horizon {
        case .durable:
            let document = try await requireDocument(frameID: reference.frameID, memory: longTermMemory)
            return LayeredMemoryHit(
                reference: Self.makeMemoryReference(.durable, sessionID: nil, frameID: reference.frameID),
                horizon: .durable,
                sessionID: nil,
                agentID: nil,
                runID: nil,
                frameID: document.frameId,
                score: 0,
                text: document.text,
                preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                metadata: document.metadata,
                explanations: ["durable memory"],
                timestampMs: document.timestampMs
            )
        case .working, .episodic:
            guard let sessionID = reference.sessionID else {
                throw BrokerValidationError.invalid("session-backed memory references require a session_id")
            }
            let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
            let loader: (MemoryOrchestrator) async throws -> LayeredMemoryHit = { memory in
                let document = try await self.requireDocument(frameID: reference.frameID, memory: memory)
                return LayeredMemoryHit(
                    reference: Self.makeMemoryReference(reference.horizon, sessionID: sessionID, frameID: reference.frameID),
                    horizon: reference.horizon,
                    sessionID: sessionID,
                    agentID: manifest.agentID,
                    runID: manifest.runID,
                    frameID: document.frameId,
                    score: 0,
                    text: document.text,
                    preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                    metadata: document.metadata,
                    explanations: [reference.horizon == .working ? "current session" : "recent session episode"],
                    timestampMs: document.timestampMs
                )
            }
            if let state = activeSessions[sessionID] {
                return try await loader(state.memory)
            }
            return try await openAdhocMemory(
                at: URL(fileURLWithPath: manifest.storePath),
                structuredMemoryEnabled: false,
                noEmbedder: noEmbedder,
                body: loader
            )
        }
    }

    func assembleCompactContext(
        query: String,
        sessionID: UUID?,
        mode: MemoryOrchestrator.DirectSearchMode,
        tokenBudget: Int,
        maxItems: Int
    ) async throws -> CompactContextAssembly {
        let counter = try await TokenCounter.shared()
        var short: [LayeredMemoryHit] = []
        var medium: [LayeredMemoryHit] = []
        var long: [LayeredMemoryHit] = []

        if let sessionID, let state = activeSessions[sessionID] {
            let execution = try await state.memory.recallExecution(
                query: query,
                embeddingPolicy: mode == .text ? .never : .ifAvailable,
                frameFilter: nil,
                timeRange: nil,
                topK: min(4, maxItems),
                mode: mode
            )
            for item in execution.context.items {
                let canonicalFrameID = try await canonicalDocumentFrameID(for: item.frameId, memory: state.memory)
                short.append(LayeredMemoryHit(
                    reference: Self.makeMemoryReference(.working, sessionID: sessionID, frameID: canonicalFrameID),
                    horizon: .working,
                    sessionID: sessionID,
                    agentID: state.manifest.agentID,
                    runID: state.manifest.runID,
                    frameID: canonicalFrameID,
                    score: item.score,
                    text: item.text,
                    preview: MemorySemantics.summarizeCandidate(item.text, maxLength: 180),
                    metadata: item.metadata,
                    explanations: ["current session"] + item.explanations,
                    timestampMs: state.manifest.updatedAtMs
                ))
            }
        }

        let longExecution = try await longTermMemory.recallExecution(
            query: query,
            embeddingPolicy: mode == .text ? .never : .ifAvailable,
            frameFilter: nil,
            timeRange: nil,
            topK: min(4, maxItems),
            mode: mode
        )
        for item in longExecution.context.items {
            let canonicalFrameID = try await canonicalDocumentFrameID(for: item.frameId, memory: longTermMemory)
            long.append(LayeredMemoryHit(
                reference: Self.makeMemoryReference(.durable, sessionID: nil, frameID: canonicalFrameID),
                horizon: .durable,
                sessionID: nil,
                agentID: nil,
                runID: nil,
                frameID: canonicalFrameID,
                score: item.score,
                text: item.text,
                preview: MemorySemantics.summarizeCandidate(item.text, maxLength: 180),
                metadata: item.metadata,
                explanations: ["durable memory"] + item.explanations,
                timestampMs: item.metadata[MemoryMetadataKeys.createdAtMs].flatMap(Int64.init) ?? 0
            ))
        }

        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
        let selectedManifests = manifests
            .filter { manifest in
                if let sessionID, manifest.sessionID == sessionID { return false }
                if let sessionID, let active = activeSessions[sessionID]?.manifest, manifest.agentID != active.agentID {
                    return false
                }
                return manifest.status == .ended
            }
        for manifest in selectedManifests {
            let episodicHits = try await openAdhocMemory(
                at: URL(fileURLWithPath: manifest.storePath),
                structuredMemoryEnabled: false,
                noEmbedder: noEmbedder
            ) { memory in
                let items = try await memory.recallExecution(
                    query: query,
                    embeddingPolicy: mode == .text ? .never : .ifAvailable,
                    frameFilter: nil,
                    timeRange: nil,
                    topK: 2,
                    mode: mode
                ).context.items
                var hits: [LayeredMemoryHit] = []
                hits.reserveCapacity(items.count)
                for item in items {
                    let canonicalFrameID = try await self.canonicalDocumentFrameID(for: item.frameId, memory: memory)
                    hits.append(LayeredMemoryHit(
                        reference: Self.makeMemoryReference(.episodic, sessionID: manifest.sessionID, frameID: canonicalFrameID),
                        horizon: .episodic,
                        sessionID: manifest.sessionID,
                        agentID: manifest.agentID,
                        runID: manifest.runID,
                        frameID: canonicalFrameID,
                        score: item.score,
                        text: item.text,
                        preview: MemorySemantics.summarizeCandidate(item.text, maxLength: 180),
                        metadata: item.metadata,
                        explanations: ["recent session episode"] + item.explanations,
                        timestampMs: manifest.updatedAtMs
                    ))
                }
                return hits
            }
            medium.append(contentsOf: episodicHits)
        }

        short = Self.deduplicateLayeredHits(short)
        medium = Self.deduplicateLayeredHits(medium).sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.timestampMs != $1.timestampMs { return $0.timestampMs > $1.timestampMs }
            return $0.reference < $1.reference
        }
        long = Self.deduplicateLayeredHits(long)

        let ordered = Array((short.prefix(maxItems) + medium.prefix(maxItems) + long.prefix(maxItems)).prefix(maxItems * 3))
        var selectedShort: [LayeredMemoryHit] = []
        var selectedMedium: [LayeredMemoryHit] = []
        var selectedLong: [LayeredMemoryHit] = []
        var usedTokens = await counter.count(renderCompactedContext(
            query: query,
            short: selectedShort,
            medium: selectedMedium,
            long: selectedLong
        ))

        for hit in ordered {
            var candidateShort = selectedShort
            var candidateMedium = selectedMedium
            var candidateLong = selectedLong
            switch hit.horizon {
            case .working:
                candidateShort.append(hit)
            case .episodic:
                candidateMedium.append(hit)
            case .durable:
                candidateLong.append(hit)
            }
            let candidateText = renderCompactedContext(
                query: query,
                short: candidateShort,
                medium: candidateMedium,
                long: candidateLong
            )
            let candidateTokens = await counter.count(candidateText)
            guard candidateTokens <= tokenBudget else { continue }
            selectedShort = candidateShort
            selectedMedium = candidateMedium
            selectedLong = candidateLong
            usedTokens = candidateTokens
        }

        var compactedText = renderCompactedContext(
            query: query,
            short: selectedShort,
            medium: selectedMedium,
            long: selectedLong
        )
        let renderedTokens = await counter.count(compactedText)
        if renderedTokens > tokenBudget {
            compactedText = await counter.truncate(compactedText, maxTokens: tokenBudget)
            usedTokens = await counter.count(compactedText)
        } else {
            usedTokens = renderedTokens
        }
        let summary = [
            selectedShort.first?.preview,
            selectedMedium.first?.preview,
            selectedLong.first?.preview,
        ]
        .compactMap { $0 }
        .prefix(3)
        .joined(separator: " | ")

        return CompactContextAssembly(
            short: selectedShort,
            medium: selectedMedium,
            long: selectedLong,
            compactedText: compactedText,
            summary: summary.isEmpty ? "No compacted context available." : summary,
            usedTokens: usedTokens
        )
    }

    static func deduplicateLayeredHits(_ hits: [LayeredMemoryHit]) -> [LayeredMemoryHit] {
        var seen = Set<String>()
        var deduped: [LayeredMemoryHit] = []
        deduped.reserveCapacity(hits.count)
        for hit in hits where seen.insert(hit.reference).inserted {
            deduped.append(hit)
        }
        return deduped
    }

}
