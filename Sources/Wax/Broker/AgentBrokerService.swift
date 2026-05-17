import Foundation
import WaxCore

package actor AgentBrokerService {
    struct SessionState: Sendable {
        let id: UUID
        var manifest: BrokerSessionManifest
        let manifestURL: URL
        let eventLogURL: URL
        let storeURL: URL
        let memory: MemoryOrchestrator
    }

    let longTermMemory: MemoryOrchestrator
    let longTermStoreURL: URL
    let sessionRootURL: URL
    let corpusStoreURL: URL
    let noEmbedder: Bool
    let embedderChoice: String
    let embedderTuning: CommandLineEmbedderRuntimeTuning
    let enableAccessStatsScoring: Bool
    let scopeContext: MemoryScopeContext
    let promotionSettings: BrokerPromotionSettings
    let brokerInstanceID = UUID().uuidString
    var activeSessions: [UUID: SessionState] = [:]

    package init(
        storePath: String,
        sessionRootPath: String,
        noEmbedder: Bool,
        embedderChoice: String,
        requireVector: Bool,
        enableAccessStatsScoring: Bool = false,
        embedderTuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws {
        self.longTermStoreURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(storePath)).standardizedFileURL
        self.sessionRootURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(sessionRootPath)).standardizedFileURL
        self.noEmbedder = noEmbedder
        self.embedderChoice = embedderChoice
        self.embedderTuning = embedderTuning
        self.enableAccessStatsScoring = enableAccessStatsScoring
        self.scopeContext = MemorySemantics.inferScopeContext()
        self.promotionSettings = BrokerPromotionSettings.fromEnvironment()

        try FileManager.default.createDirectory(
            at: longTermStoreURL.deletingLastPathComponent(),
            withIntermediateDirectories: true
        )
        try FileManager.default.createDirectory(at: sessionRootURL, withIntermediateDirectories: true)

        let corpusFileName = ".corpus-\(Self.stableHash(longTermStoreURL.path)).wax"
        self.corpusStoreURL = sessionRootURL.deletingLastPathComponent().appendingPathComponent(corpusFileName)

        let embedder = try await CommandLineEmbedderFactory.buildEmbedder(
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            tuning: embedderTuning
        )
        if requireVector {
            if noEmbedder {
                throw BrokerStartupError("Vector search required but --no-embedder was set.")
            }
            if embedder == nil {
                throw BrokerStartupError("Vector search required but the embedding provider is unavailable.")
            }
        }
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = true
        config.enableAccessStatsScoring = enableAccessStatsScoring
        config.defaultScopeContext = scopeContext
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        self.longTermMemory = try await MemoryOrchestrator(
            at: longTermStoreURL,
            config: config,
            embedder: embedder,
            waxOptions: CommandLineEmbedderFactory.waxOptions()
        )
    }

    package func close() async throws {
        for session in activeSessions.values {
            try? await session.memory.flush()
            try? await session.memory.close()
        }
        activeSessions.removeAll()
        try await longTermMemory.flush()
        try await longTermMemory.close()
    }

    package func handle(_ request: AgentBrokerRequest) async -> AgentBrokerResponse {
        do {
            let command = request.command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            try AgentBrokerCommandSurface.validateArgumentSurface(
                command: command,
                providedKeys: Set(request.arguments.keys)
            )
            let payload: AgentBrokerValue
            let shouldExit: Bool

            switch command {
            case "memory_append":
                payload = try await memoryAppend(arguments: request.arguments)
                shouldExit = false
            case "memory_search":
                payload = try await memorySearch(arguments: request.arguments)
                shouldExit = false
            case "memory_get":
                payload = try await memoryGet(arguments: request.arguments)
                shouldExit = false
            case "remember":
                payload = try await remember(arguments: request.arguments)
                shouldExit = false
            case "recall":
                payload = try await recall(arguments: request.arguments)
                shouldExit = false
            case "search":
                payload = try await search(arguments: request.arguments)
                shouldExit = false
            case "session_synthesize":
                payload = try await sessionSynthesize(arguments: request.arguments)
                shouldExit = false
            case "memory_promote":
                payload = try await memoryPromote(arguments: request.arguments)
                shouldExit = false
            case "promote":
                payload = try await promote(arguments: request.arguments)
                shouldExit = false
            case "memory_health":
                payload = try await memoryHealth()
                shouldExit = false
            case "knowledge_capture":
                payload = try await knowledgeCapture(arguments: request.arguments)
                shouldExit = false
            case "stats":
                payload = try await stats()
                shouldExit = false
            case "flush":
                payload = try await flush()
                shouldExit = false
            case "session_start":
                payload = try await sessionStart(arguments: request.arguments)
                shouldExit = false
            case "session_resume":
                payload = try await sessionResume(arguments: request.arguments)
                shouldExit = false
            case "session_end":
                payload = try await sessionEnd(arguments: request.arguments)
                shouldExit = false
            case "handoff":
                payload = try await handoff(arguments: request.arguments)
                shouldExit = false
            case "handoff_latest":
                payload = try await handoffLatest(arguments: request.arguments)
                shouldExit = false
            case "compact_context":
                payload = try await compactContext(arguments: request.arguments)
                shouldExit = false
            case "markdown_export":
                payload = try await markdownExport(arguments: request.arguments)
                shouldExit = false
            case "markdown_sync":
                payload = try await markdownSync(arguments: request.arguments)
                shouldExit = false
            case "entity_upsert":
                payload = try await entityUpsert(arguments: request.arguments)
                shouldExit = false
            case "fact_assert":
                payload = try await factAssert(arguments: request.arguments)
                shouldExit = false
            case "fact_retract":
                payload = try await factRetract(arguments: request.arguments)
                shouldExit = false
            case "facts_query":
                payload = try await factsQuery(arguments: request.arguments)
                shouldExit = false
            case "entity_resolve":
                payload = try await entityResolve(arguments: request.arguments)
                shouldExit = false
            case "corpus_search":
                payload = try await corpusSearch(arguments: request.arguments)
                shouldExit = false
            case "shutdown", "exit", "quit":
                payload = .object(["status": .string("ok")])
                shouldExit = true
            default:
                throw BrokerValidationError.invalid("Unknown broker command '\(request.command)'.")
            }

            return AgentBrokerResponse(
                id: request.id,
                ok: true,
                payload: payload,
                error: nil,
                shouldExit: shouldExit
            )
        } catch {
            return AgentBrokerResponse(
                id: request.id,
                ok: false,
                payload: nil,
                error: error.localizedDescription,
                shouldExit: false
            )
        }
    }
}

extension AgentBrokerService {
    static let maxContentBytes = 128 * 1024
    static let maxTopK = 200
    static let maxRecallLimit = 100
    static let maxGraphLimit = 500
    static let maxGraphIdentifierBytes = 256
    static let maxGraphKindBytes = 64
    static let maxPromotionCandidates = BrokerPromotionSettings.maxCandidateLimit
    static let defaultSessionLeaseSeconds = 300
    static let maxCompactContextTokenBudget = 32_000

    enum MemoryHorizon: String {
        case working
        case episodic
        case durable
    }

    struct LayeredMemoryHit {
        var reference: String
        var horizon: MemoryHorizon
        var sessionID: UUID?
        var agentID: String?
        var runID: String?
        var frameID: UInt64
        var score: Float
        var text: String
        var preview: String
        var metadata: [String: String]
        var explanations: [String]
        var timestampMs: Int64
    }

    struct MemoryReference {
        var horizon: MemoryHorizon
        var sessionID: UUID?
        var frameID: UInt64
    }

    struct CompactContextAssembly {
        var short: [LayeredMemoryHit]
        var medium: [LayeredMemoryHit]
        var long: [LayeredMemoryHit]
        var compactedText: String
        var summary: String
        var usedTokens: Int
    }

    struct MarkdownProjectionReport {
        var memoryMarkdownPath: String
        var dailyNotePaths: [String]
        var dreamsPath: String?
        var handoffSummaryPath: String?
    }

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
        try await memory.flush()
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
        let sessionID = try resolveSessionID(try parseOptionalSessionID(args))
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

        var entityID: Int64?
        if let subject, let kind {
            entityID = try await longTermMemory.upsertEntity(
                key: EntityKey(subject),
                kind: kind,
                aliases: aliases,
                commit: true
            ).rawValue
        }
        var factID: Int64?
        if let subject, let predicate, let objectValue {
            factID = try await longTermMemory.assertFact(
                subject: EntityKey(subject),
                predicate: PredicateKey(predicate),
                object: try parseFactValue(objectValue),
                relation: .sets,
                validFromMs: nil,
                validToMs: nil,
                commit: true
            ).rawValue
        }

        try await longTermMemory.remember(content, metadata: metadata)
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

    func sessionStart(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let explicitSessionID = try parseOptionalSessionID(args)
        let sessionID = explicitSessionID ?? UUID()
        if let active = activeSessions[sessionID] {
            return renderSessionLifecycleResult(state: active, resumed: false, recoveredLease: false)
        }

        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        if FileManager.default.fileExists(atPath: manifestURL.path) {
            throw BrokerValidationError.invalid("session_id already exists; use session_resume to reopen it")
        }

        let sessionURL = sessionRootURL.appendingPathComponent("\(sessionID.uuidString).wax")
        let eventLogURL = BrokerSessionPersistence.eventLogURL(rootURL: sessionRootURL, sessionID: sessionID)
        let memory = try await openSessionMemory(at: sessionURL)

        let nowMs = Self.nowMs()
        let agentID = try args.optionalString("agent_id") ?? scopeContext.repoName ?? "wax-agent"
        let runID = try args.optionalString("run_id") ?? UUID().uuidString
        let manifest = BrokerSessionManifest(
            sessionID: sessionID,
            agentID: agentID,
            runID: runID,
            project: scopeContext.projectName,
            repo: scopeContext.repoName,
            storePath: sessionURL.path,
            eventLogPath: eventLogURL.path,
            status: .active,
            brokerLeaseOwnerID: brokerInstanceID,
            leaseExpiresAtMs: nowMs + Int64(Self.defaultSessionLeaseSeconds * 1000),
            createdAtMs: nowMs,
            updatedAtMs: nowMs
        )
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: sessionID,
                agentID: agentID,
                runID: runID,
                timestampMs: nowMs,
                kind: .started,
                payload: [
                    "project": manifest.project ?? "",
                    "repo": manifest.repo ?? "",
                ]
            ),
            to: eventLogURL
        )
        try BrokerSessionPersistence.saveManifest(manifest, to: manifestURL)
        let state = SessionState(
            id: sessionID,
            manifest: manifest,
            manifestURL: manifestURL,
            eventLogURL: eventLogURL,
            storeURL: sessionURL,
            memory: memory
        )
        activeSessions[sessionID] = state
        return renderSessionLifecycleResult(state: state, resumed: false, recoveredLease: false)
    }

    func sessionResume(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let explicitSessionID = try parseOptionalSessionID(args)
        let requestedAgentID = try args.optionalString("agent_id")
        let requestedRunID = try args.optionalString("run_id")

        let manifest = try resolveSessionManifest(
            explicitSessionID: explicitSessionID,
            agentID: requestedAgentID,
            runID: requestedRunID
        )
        guard manifest.status == .active else {
            throw BrokerValidationError.invalid("session_id has already been ended and cannot be resumed")
        }

        if let existing = activeSessions[manifest.sessionID] {
            return renderSessionLifecycleResult(state: existing, resumed: true, recoveredLease: false)
        }

        let nowMs = Self.nowMs()
        let recoveredLease = manifest.brokerLeaseOwnerID != nil && manifest.brokerLeaseOwnerID != brokerInstanceID
        let memory = try await openSessionMemory(at: URL(fileURLWithPath: manifest.storePath))
        var refreshed = manifest
        refreshed.brokerLeaseOwnerID = brokerInstanceID
        refreshed.leaseExpiresAtMs = nowMs + Int64(Self.defaultSessionLeaseSeconds * 1000)
        refreshed.updatedAtMs = nowMs

        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: manifest.sessionID)
        let eventLogURL = URL(fileURLWithPath: refreshed.eventLogPath)
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: refreshed.sessionID,
                agentID: refreshed.agentID,
                runID: refreshed.runID,
                timestampMs: nowMs,
                kind: .resumed,
                payload: [
                    "recovered_lease": recoveredLease ? "true" : "false",
                ]
            ),
            to: eventLogURL
        )
        try BrokerSessionPersistence.saveManifest(refreshed, to: manifestURL)
        let state = SessionState(
            id: refreshed.sessionID,
            manifest: refreshed,
            manifestURL: manifestURL,
            eventLogURL: eventLogURL,
            storeURL: URL(fileURLWithPath: refreshed.storePath),
            memory: memory
        )
        activeSessions[refreshed.sessionID] = state
        return renderSessionLifecycleResult(state: state, resumed: true, recoveredLease: recoveredLease)
    }

    func sessionEnd(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let sessionID = try parseOptionalSessionID(args)
        let target: UUID
        switch (sessionID, activeSessions.count) {
        case let (.some(explicit), _):
            guard activeSessions[explicit] != nil else {
                throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
            }
            target = explicit
        case (.none, 1):
            target = activeSessions.keys.first!
        case (.none, 0):
            return .object([
                "status": .string("ok"),
                "session_id": .null,
                "active": .bool(false),
            ])
        default:
            throw BrokerValidationError.invalid("session_id is required when more than one session is active")
        }
        if let state = activeSessions.removeValue(forKey: target) {
            var manifest = state.manifest
            manifest.status = .ended
            manifest.updatedAtMs = Self.nowMs()
            manifest.brokerLeaseOwnerID = nil
            manifest.leaseExpiresAtMs = nil
            try BrokerSessionPersistence.saveManifest(manifest, to: state.manifestURL)
            try BrokerSessionPersistence.appendEvent(
                BrokerSessionEvent(
                    sessionID: state.id,
                    agentID: manifest.agentID,
                    runID: manifest.runID,
                    timestampMs: manifest.updatedAtMs,
                    kind: .ended
                ),
                to: state.eventLogURL
            )
            try await state.memory.flush()
            try await state.memory.close()
        }
        return .object([
            "status": .string("ok"),
            "session_id": .string(target.uuidString),
            "active": .from(!activeSessions.isEmpty),
        ])
    }

    func handoff(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let content = try args.requiredStringPreservingWhitespace("content", maxBytes: Self.maxContentBytes)
        let project = try args.optionalString("project")
        let pendingTasks = try args.optionalStringArray("pending_tasks") ?? []
        let sessionID = try parseOptionalSessionID(args)
        try validateActiveSession(sessionID)
        let frameId = try await longTermMemory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID,
            commit: true
        )
        if let sessionID {
            try await recordHandoff(sessionID: sessionID, content: content)
        }
        return .object([
            "status": .string("ok"),
            "frame_id": .from(frameId),
            "committed": .bool(true),
            "display_text": .string("Handoff stored (frame \(frameId))."),
        ])
    }

    func handoffLatest(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let project = try args.optionalString("project")
        guard let latest = try await longTermMemory.latestHandoff(project: project) else {
            return .object(["found": .bool(false)])
        }
        return .object([
            "found": .bool(true),
            "frame_id": .from(latest.frameId),
            "timestamp_ms": .from(latest.timestampMs),
            "project": .from(latest.project),
            "pending_tasks": .array(latest.pendingTasks.map { .string($0) }),
            "content": .string(latest.content),
            "display_text": .string(latest.content),
        ])
    }

    func compactContext(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try args.requiredString("query", maxBytes: Self.maxContentBytes)
        let tokenBudget = try args.optionalInt("token_budget") ?? 1800
        guard (128...Self.maxCompactContextTokenBudget).contains(tokenBudget) else {
            throw BrokerValidationError.invalid("token_budget must be between 128 and \(Self.maxCompactContextTokenBudget)")
        }
        let maxItems = try args.optionalInt("max_items") ?? 12
        guard (1...64).contains(maxItems) else {
            throw BrokerValidationError.invalid("max_items must be between 1 and 64")
        }
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let sessionID = try resolveSessionID(try parseOptionalSessionID(args))
        if let sessionID {
            let sessionMemory = try await memory(for: sessionID)
            try await sessionMemory.flush()
            try await refreshSessionManifest(sessionID)
        }
        try await longTermMemory.flush()
        let assembled = try await assembleCompactContext(
            query: query,
            sessionID: sessionID,
            mode: mode,
            tokenBudget: tokenBudget,
            maxItems: maxItems
        )
        if let sessionID {
            try await recordCheckpoint(
                sessionID: sessionID,
                summary: assembled.summary,
                compactedText: assembled.compactedText
            )
        }
        return .object([
            "query": .string(query),
            "token_budget": .from(tokenBudget),
            "used_tokens": .from(assembled.usedTokens),
            "summary": .string(assembled.summary),
            "short_context": .array(assembled.short.map(renderLayeredMemoryHit)),
            "medium_context": .array(assembled.medium.map(renderLayeredMemoryHit)),
            "long_context": .array(assembled.long.map(renderLayeredMemoryHit)),
            "compacted_text": .string(assembled.compactedText),
            "display_text": .string(assembled.compactedText),
        ])
    }

    func markdownExport(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let outputDir = try args.requiredString("output_dir", maxBytes: 4096)
        let sessionID = try parseOptionalSessionID(args)
        try validateMarkdownExportSession(sessionID)
        let exportURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(outputDir), isDirectory: true).standardizedFileURL
        let report = try await exportMarkdownProjection(outputURL: exportURL, sessionID: sessionID)
        return .object([
            "status": .string("ok"),
            "output_dir": .string(exportURL.path),
            "memory_md_path": .string(report.memoryMarkdownPath),
            "daily_note_paths": .array(report.dailyNotePaths.map(AgentBrokerValue.string)),
            "dreams_path": .from(report.dreamsPath),
            "handoff_summary_path": .from(report.handoffSummaryPath),
            "display_text": .string("Exported Markdown projection to \(exportURL.path)"),
        ])
    }

    private func validateMarkdownExportSession(_ sessionID: UUID?) throws {
        guard let sessionID else { return }
        let manifestURL = BrokerSessionPersistence.manifestURL(rootURL: sessionRootURL, sessionID: sessionID)
        guard FileManager.default.fileExists(atPath: manifestURL.path) else {
            throw BrokerValidationError.invalid("No session manifest found for session_id \(sessionID.uuidString)")
        }
        let manifest = try BrokerSessionPersistence.loadManifest(at: manifestURL)
        if manifest.status == .active && activeSessions[sessionID] == nil {
            throw BrokerValidationError.invalid("session_id is active in another broker process; call session_resume before exporting it")
        }
    }

    func markdownSync(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let rootDir = try args.requiredString("root_dir", maxBytes: 4096)
        let dryRun = try args.optionalBool("dry_run") ?? false
        let rootURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(rootDir), isDirectory: true).standardizedFileURL
        let report = try await syncMarkdownProjection(rootURL: rootURL, dryRun: dryRun)
        return .object([
            "status": .string("ok"),
            "dry_run": .bool(dryRun),
            "root_dir": .string(report.rootDir),
            "memory_md_path": .from(report.memoryPath),
            "daily_note_paths": .array(report.dailyNotePaths.map(AgentBrokerValue.string)),
            "dreams_path": .from(report.dreamsPath),
            "counts": .object([
                "created": .from(report.counts.created),
                "updated": .from(report.counts.updated),
                "deleted": .from(report.counts.deleted),
                "unchanged": .from(report.counts.unchanged),
                "approved_dreams": .from(report.counts.approvedDreams),
                "rejected_dreams": .from(report.counts.rejectedDreams),
            ]),
            "display_text": .string(
                "\(dryRun ? "Dry-run sync for" : "Synced") Markdown projection from \(report.rootDir): " +
                    "\(report.counts.created) created, \(report.counts.updated) updated, " +
                    "\(report.counts.deleted) deleted, \(report.counts.approvedDreams) dreams approved."
            ),
        ])
    }

    func entityUpsert(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let key = try args.requiredString("key", maxBytes: Self.maxGraphIdentifierBytes)
        let kind = try args.requiredString("kind", maxBytes: Self.maxGraphKindBytes)
        let aliases = try args.optionalStringArray("aliases") ?? []
        let entityID = try await longTermMemory.upsertEntity(
            key: EntityKey(key),
            kind: kind,
            aliases: aliases,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "entity_id": .from(entityID.rawValue),
            "key": .string(key),
            "committed": .bool(true),
        ])
    }

    func factAssert(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let subject = try args.requiredString("subject", maxBytes: Self.maxGraphIdentifierBytes)
        let predicate = try args.requiredString("predicate", maxBytes: Self.maxGraphIdentifierBytes)
        let objectValue = try args.requiredValue("object")
        let relation = try parseVersionRelation(try args.optionalString("relation") ?? "sets")
        let evidence = try parseStructuredEvidence(args.optionalValue("evidence"))
        let factID = try await longTermMemory.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: try parseFactValue(objectValue),
            relation: relation,
            validFromMs: try args.optionalInt64("valid_from"),
            validToMs: try args.optionalInt64("valid_to"),
            evidence: evidence,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "fact_id": .from(factID.rawValue),
            "evidence_count": .from(evidence.count),
            "committed": .bool(true),
        ])
    }

    func factRetract(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let factID = try args.requiredInt64("fact_id")
        let atMs = try args.optionalInt64("at_ms")
        try await longTermMemory.retractFact(factId: FactRowID(rawValue: factID), atMs: atMs, commit: true)
        return .object([
            "status": .string("ok"),
            "fact_id": .from(factID),
            "at_ms": .from(atMs),
            "committed": .bool(true),
        ])
    }

    func factsQuery(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let limit = try args.optionalInt("limit") ?? 20
        guard (1...Self.maxGraphLimit).contains(limit) else {
            throw BrokerValidationError.invalid("limit must be between 1 and \(Self.maxGraphLimit)")
        }
        let subject = try args.optionalString("subject").map { EntityKey($0) }
        let predicate = try args.optionalString("predicate").map { PredicateKey($0) }
        let asOfMs = try args.optionalInt64("as_of") ?? Int64.max
        let result = try await longTermMemory.facts(
            about: subject,
            predicate: predicate,
            asOfMs: asOfMs,
            limit: limit
        )
        let hits: [AgentBrokerValue] = result.hits.map { hit in
            AgentBrokerValue.object([
                "fact_id": .from(hit.factId.rawValue),
                "subject": .string(hit.fact.subject.rawValue),
                "predicate": .string(hit.fact.predicate.rawValue),
                "object": factValueAsBrokerValue(hit.fact.object),
                "is_open_ended": .from(hit.isOpenEnded),
                "evidence_count": .from(hit.evidence.count),
                "evidence": .array(hit.evidence.map(renderStructuredEvidence)),
            ])
        }
        return .object([
            "count": .from(result.hits.count),
            "truncated": .from(result.wasTruncated),
            "as_of": .from(asOfMs),
            "hits": .array(hits),
        ])
    }

    func entityResolve(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let alias = try args.requiredString("alias", maxBytes: Self.maxGraphIdentifierBytes)
        let limit = try args.optionalInt("limit") ?? 10
        let matches = try await longTermMemory.resolveEntities(matchingAlias: alias, limit: limit)
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

    func corpusSearch(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try args.requiredString("query", maxBytes: Self.maxContentBytes)
        let recursive = try args.optionalBool("recursive") ?? true
        let rebuild = try args.optionalBool("rebuild") ?? true
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...Self.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(Self.maxTopK)")
        }
        let corpusNoEmbedder: Bool = switch mode {
        case .text: true
        case .vector: false
        case .hybrid: noEmbedder
        }
        let buildSummary: BrokerCorpusBuildSummary?
        if rebuild || !FileManager.default.fileExists(atPath: corpusStoreURL.path) {
            buildSummary = try await BrokerCorpusStoreBuilder.build(
                sessionsDirectory: sessionRootURL,
                targetStoreURL: corpusStoreURL,
                noEmbedder: corpusNoEmbedder,
                embedderChoice: embedderChoice,
                embedderTuning: embedderTuning,
                recursive: recursive
            )
        } else {
            buildSummary = nil
        }
        let execution = try await openAdhocMemory(
            at: corpusStoreURL,
            structuredMemoryEnabled: false,
            noEmbedder: corpusNoEmbedder
        ) { memory in
            try await memory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: nil,
                timeRange: nil
            )
        }
        let results: [AgentBrokerValue] = execution.hits.enumerated().map { index, hit in
            .object([
                "rank": .from(index + 1),
                "frameId": .from(hit.frameId),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": .string(hit.previewText ?? ""),
                "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
            ])
        }
        let buildValue: AgentBrokerValue = if let buildSummary {
            .object([
                "performed": .bool(true),
                "stores_discovered": .from(buildSummary.storesDiscovered),
                "stores_indexed": .from(buildSummary.storesIndexed),
                "stores_skipped": .from(buildSummary.storesSkipped),
                "documents_indexed": .from(buildSummary.documentsIndexed),
                "documents_skipped": .from(buildSummary.documentsSkipped),
                "corpus_store_path": .string(buildSummary.targetStorePath),
            ])
        } else {
            .object([
                "performed": .bool(false),
                "corpus_store_path": .string(corpusStoreURL.path),
            ])
        }
        let text = results.isEmpty ? "No results." : results.map(\.debugJSONString).joined(separator: "\n")
        return .object([
            "query": .string(query),
            "topK": .from(topK),
            "requested_mode": .string(execution.requestedModeSummary),
            "effective_mode": .string(execution.effectiveModeSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "recursive": .from(recursive),
            "rebuild_requested": .from(rebuild),
            "build": buildValue,
            "results": .array(results),
            "display_text": .string(text),
        ])
    }

    func resolveSessionManifest(
        explicitSessionID: UUID?,
        agentID: String?,
        runID: String?
    ) throws -> BrokerSessionManifest {
        if let explicitSessionID {
            return try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: explicitSessionID)
        }

        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
        let filtered = manifests.filter { manifest in
            guard manifest.status == .active else { return false }
            if let agentID, manifest.agentID != agentID { return false }
            if let runID, manifest.runID != runID { return false }
            return true
        }
        guard let match = filtered.first else {
            throw BrokerValidationError.invalid("No resumable session manifest matched the requested selectors")
        }
        return match
    }

    private func renderSessionLifecycleResult(
        state: SessionState,
        resumed: Bool,
        recoveredLease: Bool
    ) -> AgentBrokerValue {
        .object([
            "status": .string("ok"),
            "session_id": .string(state.id.uuidString),
            "agent_id": .string(state.manifest.agentID),
            "run_id": .string(state.manifest.runID),
            "project": .from(state.manifest.project),
            "repo": .from(state.manifest.repo),
            "resumed": .bool(resumed),
            "recovered_lease": .bool(recoveredLease),
            "store_path": .string(state.storeURL.path),
            "event_log_path": .string(state.eventLogURL.path),
        ])
    }

    func refreshSessionManifest(_ sessionID: UUID) async throws {
        guard var state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        state.manifest.updatedAtMs = Self.nowMs()
        state.manifest.brokerLeaseOwnerID = brokerInstanceID
        state.manifest.leaseExpiresAtMs = state.manifest.updatedAtMs + Int64(Self.defaultSessionLeaseSeconds * 1000)
        try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
        activeSessions[sessionID] = state
    }

    func appendSessionEvent(
        sessionID: UUID,
        kind: BrokerSessionEvent.Kind,
        payload: [String: String] = [:]
    ) async throws {
        guard let state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        try BrokerSessionPersistence.appendEvent(
            BrokerSessionEvent(
                sessionID: sessionID,
                agentID: state.manifest.agentID,
                runID: state.manifest.runID,
                timestampMs: Self.nowMs(),
                kind: kind,
                payload: payload
            ),
            to: state.eventLogURL
        )
    }

    func recordRetrievalHits(
        sessionID: UUID,
        query: String,
        hits: [(frameID: UInt64, score: Float)],
        memory: MemoryOrchestrator
    ) async throws {
        guard !hits.isEmpty else { return }
        let queryHash = Self.stableHash(query.lowercased())
        var seenFrameIDs = Set<UInt64>()
        for hit in hits {
            let frameID = hit.frameID
            guard let canonicalFrameID = await bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory) else {
                continue
            }
            guard seenFrameIDs.insert(canonicalFrameID).inserted else { continue }
            try await appendSessionEvent(
                sessionID: sessionID,
                kind: .retrievalHit,
                payload: [
                    "frame_id": String(canonicalFrameID),
                    "score": String(hit.score),
                    "query_hash": queryHash,
                ]
            )
        }
    }

    func recordHandoff(sessionID: UUID, content: String) async throws {
        guard var state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        let nowMs = Self.nowMs()
        state.manifest.lastHandoffAtMs = nowMs
        state.manifest.latestHandoff = MemorySemantics.summarizeCandidate(content, maxLength: 220)
        state.manifest.updatedAtMs = nowMs
        try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
        activeSessions[sessionID] = state
        try await appendSessionEvent(
            sessionID: sessionID,
            kind: .handoff,
            payload: [
                "summary": state.manifest.latestHandoff ?? "",
            ]
        )
    }

    func recordCheckpoint(sessionID: UUID, summary: String, compactedText: String) async throws {
        guard var state = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        let nowMs = Self.nowMs()
        state.manifest.lastCheckpointAtMs = nowMs
        state.manifest.lastCompactionAtMs = nowMs
        state.manifest.checkpointCount += 1
        state.manifest.latestSummary = summary
        state.manifest.updatedAtMs = nowMs
        try BrokerSessionPersistence.saveManifest(state.manifest, to: state.manifestURL)
        activeSessions[sessionID] = state
        try await appendSessionEvent(
            sessionID: sessionID,
            kind: .checkpoint,
            payload: [
                "summary": summary,
                "content_hash": Self.stableHash(compactedText),
            ]
        )
    }

    func sessionSignals(for sessionID: UUID) async throws -> [UInt64: BrokerSessionRecallSignals] {
        if let state = activeSessions[sessionID] {
            return BrokerSessionPersistence.recallSignals(
                from: try BrokerSessionPersistence.loadEvents(from: state.eventLogURL)
            )
        }
        let manifest = try BrokerSessionPersistence.loadManifest(rootURL: sessionRootURL, sessionID: sessionID)
        return BrokerSessionPersistence.recallSignals(
            from: try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
        )
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
            .prefix(4)
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
        medium = Self.deduplicateLayeredHits(medium)
        long = Self.deduplicateLayeredHits(long)

        let ordered = Array((short.prefix(maxItems) + medium.prefix(maxItems) + long.prefix(maxItems)).prefix(maxItems * 3))
        let tokenCounts = await counter.countBatch(ordered.map(\.text))
        var usedTokens = 0
        var selectedShort: [LayeredMemoryHit] = []
        var selectedMedium: [LayeredMemoryHit] = []
        var selectedLong: [LayeredMemoryHit] = []

        for (index, hit) in ordered.enumerated() {
            let tokens = tokenCounts[index]
            if usedTokens + tokens > tokenBudget { continue }
            usedTokens += tokens
            switch hit.horizon {
            case .working:
                selectedShort.append(hit)
            case .episodic:
                selectedMedium.append(hit)
            case .durable:
                selectedLong.append(hit)
            }
        }

        let compactedText = renderCompactedContext(
            query: query,
            short: selectedShort,
            medium: selectedMedium,
            long: selectedLong
        )
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

    func exportMarkdownProjection(outputURL: URL, sessionID: UUID?) async throws -> MarkdownProjectionReport {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let memoryDir = outputURL.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try await longTermMemory.flush()

        let durableDocuments = try await longTermMemory.corpusSourceDocuments().sorted { lhs, rhs in
            if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
            return lhs.frameId > rhs.frameId
        }
        let memoryMarkdown = renderMemoryMarkdown(documents: durableDocuments)
        let memoryMarkdownURL = outputURL.appendingPathComponent("MEMORY.md")
        try memoryMarkdown.write(to: memoryMarkdownURL, atomically: true, encoding: .utf8)

        var dailyNotesByDate: [String: [String]] = [:]
        var handoffLines: [String] = []
        let manifests = try BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)
            .filter { sessionID == nil || $0.sessionID == sessionID }
        for manifest in manifests {
            let events = try BrokerSessionPersistence.loadEvents(from: URL(fileURLWithPath: manifest.eventLogPath))
            for event in events {
                let dateKey = Self.dayString(fromMs: event.timestampMs)
                switch event.kind {
                case .remembered, .checkpoint, .promotionWritten, .promotionReviewed:
                    let summary = if let summary = event.payload["summary"], !summary.isEmpty {
                        summary
                    } else if let contentHash = event.payload["content_hash"] {
                        "session event \(event.kind.rawValue) [\(contentHash)]"
                    } else {
                        ""
                    }
                    if !summary.isEmpty {
                        let marker = MarkdownProjectionMarker(
                            managed: false,
                            sourceKind: "daily_note_event",
                            hash: Self.stableHash(summary),
                            sessionID: manifest.sessionID.uuidString,
                            sourceFrameID: event.payload["frame_id"].flatMap(UInt64.init),
                            memoryType: event.payload["memory_type"],
                            dateKey: dateKey
                        )
                        dailyNotesByDate[dateKey, default: []].append(
                            renderManagedMarkdownLine(text: summary, marker: marker)
                        )
                    }
                case .handoff:
                    let summary = "[\(dateKey)] \(manifest.agentID)/\(manifest.runID): \(event.payload["summary"] ?? "")"
                    let marker = MarkdownProjectionMarker(
                        managed: false,
                        sourceKind: "daily_note_event",
                        hash: Self.stableHash(summary),
                        sessionID: manifest.sessionID.uuidString,
                        dateKey: dateKey
                    )
                    let line = renderManagedMarkdownLine(text: summary, marker: marker)
                    handoffLines.append(line)
                    dailyNotesByDate[dateKey, default: []].append(line)
                default:
                    break
                }
            }
        }

        let managedDailyNotes = durableDocuments
            .filter { $0.metadata[MemoryMetadataKeys.sourceKind] == MarkdownProjectionKind.dailyNote.rawValue }
            .sorted { lhs, rhs in
                if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
                return lhs.frameId > rhs.frameId
        }
        for document in managedDailyNotes {
            let dateKey = Self.safeMarkdownDailyDateKey(
                document.metadata[MemoryMetadataKeys.sourceDate],
                fallbackMs: document.timestampMs
            )
            let marker = marker(for: document, kind: .dailyNote, dateKey: dateKey)
            dailyNotesByDate[dateKey, default: []].append(renderManagedMarkdownLine(text: document.text, marker: marker))
        }

        var dailyNotePaths: [String] = []
        var dailyNoteURLs = Set<URL>()
        for dateKey in dailyNotesByDate.keys.sorted() {
            let noteURL = memoryDir.appendingPathComponent("\(dateKey).md")
            var bodyLines = ["# \(dateKey)", ""]
            bodyLines.append(contentsOf: dailyNotesByDate[dateKey, default: []])
            let body = bodyLines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
            try body.write(to: noteURL, atomically: true, encoding: .utf8)
            dailyNoteURLs.insert(noteURL.standardizedFileURL)
            dailyNotePaths.append(noteURL.path)
        }

        let dreamsLines = try await dreamProjectionLines(sessionID: sessionID)
        let dreamsURL = memoryDir.appendingPathComponent("DREAMS.md")
        var dreamsPath: String?
        if !dreamsLines.isEmpty {
            let body = "# DREAMS\n\n" + dreamsLines.joined(separator: "\n") + "\n"
            try body.write(to: dreamsURL, atomically: true, encoding: .utf8)
            dreamsPath = dreamsURL.path
        } else {
            try removeGeneratedMarkdownFileIfPresent(at: dreamsURL, allowedSourceKinds: [MarkdownProjectionKind.dreams.rawValue])
        }

        var handoffSummaryPath: String?
        if !handoffLines.isEmpty {
            let handoffURL = memoryDir.appendingPathComponent("HANDOFFS.md")
            let body = "# Handoffs\n\n" + handoffLines.joined(separator: "\n") + "\n"
            try body.write(to: handoffURL, atomically: true, encoding: .utf8)
            handoffSummaryPath = handoffURL.path
        } else {
            try removeGeneratedMarkdownFileIfPresent(at: memoryDir.appendingPathComponent("HANDOFFS.md"), allowedSourceKinds: ["daily_note_event"])
        }

        try removeStaleGeneratedDailyNotes(in: memoryDir, keeping: dailyNoteURLs)

        if let sessionID, activeSessions[sessionID] != nil {
            try await appendSessionEvent(
                sessionID: sessionID,
                kind: .markdownExported,
                payload: ["output_dir": outputURL.path]
            )
        }

        return MarkdownProjectionReport(
            memoryMarkdownPath: memoryMarkdownURL.path,
            dailyNotePaths: dailyNotePaths.sorted(),
            dreamsPath: dreamsPath,
            handoffSummaryPath: handoffSummaryPath
        )
    }

    private func removeStaleGeneratedDailyNotes(in memoryDir: URL, keeping currentDailyNoteURLs: Set<URL>) throws {
        guard FileManager.default.fileExists(atPath: memoryDir.path) else { return }
        let urls = try FileManager.default.contentsOfDirectory(
            at: memoryDir,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        for url in urls where url.pathExtension == "md" {
            guard !url.lastPathComponent.hasPrefix("DREAMS"),
                  !url.lastPathComponent.hasPrefix("HANDOFFS"),
                  url.lastPathComponent.range(of: #"^\d{4}-\d{2}-\d{2}\.md$"#, options: .regularExpression) != nil,
                  !currentDailyNoteURLs.contains(url.standardizedFileURL)
            else { continue }
            try removeGeneratedMarkdownFileIfPresent(
                at: url,
                allowedSourceKinds: [MarkdownProjectionKind.dailyNote.rawValue, "daily_note_event"]
            )
        }
    }

    private func removeGeneratedMarkdownFileIfPresent(at url: URL, allowedSourceKinds: Set<String>) throws {
        guard FileManager.default.fileExists(atPath: url.path) else { return }
        let entries = try BrokerMarkdownSync.parseFile(at: url)
        guard !entries.isEmpty else { return }
        var generatedLines = Set<String>()
        let generatedOnly = entries.allSatisfy { entry in
            guard let marker = entry.marker else { return false }
            guard allowedSourceKinds.contains(marker.sourceKind) else { return false }
            guard marker.hash == Self.stableHash(entry.text) else { return false }
            if marker.sourceKind == MarkdownProjectionKind.dreams.rawValue, entry.checked == true {
                return false
            }
            generatedLines.insert(renderManagedMarkdownLine(text: entry.text, marker: marker, checked: entry.checked))
            return true
        }
        guard generatedOnly else { return }
        let raw = try String(contentsOf: url, encoding: .utf8)
        let hasUserContent = raw.components(separatedBy: .newlines).contains { line in
            let trimmed = line.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { return false }
            guard !trimmed.hasPrefix("#") else { return false }
            return !generatedLines.contains(trimmed)
        }
        guard !hasUserContent else { return }
        try FileManager.default.removeItem(at: url)
    }

    func memory(for sessionID: UUID?) async throws -> MemoryOrchestrator {
        guard let sessionID else {
            return longTermMemory
        }
        guard let session = activeSessions[sessionID] else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
        return session.memory
    }

    func validateActiveSession(_ sessionID: UUID?) throws {
        guard let sessionID else { return }
        guard activeSessions[sessionID] != nil else {
            throw BrokerValidationError.invalid("session_id is not active in this broker process; call session_start again")
        }
    }

    func openSessionMemory(at url: URL) async throws -> MemoryOrchestrator {
        let embedder = try await CommandLineEmbedderFactory.buildEmbedder(
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            tuning: embedderTuning
        )
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = false
        config.enableAccessStatsScoring = enableAccessStatsScoring
        config.defaultScopeContext = scopeContext
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        return try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder,
            waxOptions: CommandLineEmbedderFactory.waxOptions()
        )
    }

    func openAdhocMemory<T: Sendable>(
        at url: URL,
        structuredMemoryEnabled: Bool,
        noEmbedder: Bool,
        body: (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        let embedder = try await CommandLineEmbedderFactory.buildEmbedder(
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            tuning: embedderTuning
        )
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = structuredMemoryEnabled
        config.enableAccessStatsScoring = enableAccessStatsScoring
        config.defaultScopeContext = scopeContext
        if embedder == nil {
            config.enableVectorSearch = false
            config.rag.searchMode = .textOnly
        }
        let memory = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: embedder,
            waxOptions: CommandLineEmbedderFactory.waxOptions()
        )
        do {
            let result = try await body(memory)
            try await memory.close()
            return result
        } catch {
            try? await memory.close()
            throw error
        }
    }

    func parseOptionalSessionID(_ args: BrokerArguments) throws -> UUID? {
        guard let raw = try args.optionalString("session_id") else { return nil }
        guard let value = UUID(uuidString: raw) else {
            throw BrokerValidationError.invalid("session_id must be a valid UUID")
        }
        return value
    }

    func resolveSessionID(_ explicit: UUID?) throws -> UUID? {
        if let explicit { return explicit }
        if activeSessions.count == 1 {
            return activeSessions.keys.first
        }
        return nil
    }

    struct ParsedSearchFilters {
        let sessionId: UUID?
        let frameFilter: FrameFilter?
        let timeRange: SearchTimeRange?
        let summary: AgentBrokerValue
    }

    func parseSearchFilters(_ args: BrokerArguments) throws -> ParsedSearchFilters {
        let sessionID = try parseOptionalSessionID(args)
        let filters = try args.optionalObject("filters")

        var metadataEntries: [String: String] = [:]
        var labels: [String] = []
        var includeDeleted = false
        var includeSuperseded = false
        var includeSurrogates = false
        var frameIds: Set<UInt64>?
        var timeAfterMs: Int64?
        var timeBeforeMs: Int64?

        if let filters {
            let allowedFilterKeys: Set<String> = [
                "metadata",
                "labels",
                "include_deleted",
                "include_superseded",
                "include_surrogates",
                "frame_ids",
                "time_after_ms",
                "time_before_ms",
            ]
            let unknownFilterKeys = Set(filters.keys).subtracting(allowedFilterKeys)
            guard unknownFilterKeys.isEmpty else {
                let names = unknownFilterKeys.sorted().map { "filters.\($0)" }.joined(separator: ", ")
                throw BrokerValidationError.invalid("unsupported filter key(s): \(names)")
            }

            if let metadataRaw = filters["metadata"] {
                guard let metadataObject = metadataRaw.objectValue else {
                    throw BrokerValidationError.invalid("filters.metadata must be an object")
                }
                if let exact = metadataObject["exact"] {
                    guard metadataObject.count == 1 else {
                        throw BrokerValidationError.invalid("filters.metadata may be either a flat object or {\"exact\": {...}}")
                    }
                    guard let exactObject = exact.objectValue else {
                        throw BrokerValidationError.invalid("filters.metadata.exact must be an object")
                    }
                    metadataEntries = try coerceMetadata(exactObject)
                } else {
                    metadataEntries = try coerceMetadata(metadataObject)
                }
            }
            if let labelsRaw = filters["labels"]?.arrayValue {
                labels = try labelsRaw.map { value in
                    guard let raw = value.stringValue else {
                        throw BrokerValidationError.invalid("filters.labels must contain only strings")
                    }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw BrokerValidationError.invalid("filters.labels must not contain empty values")
                    }
                    return trimmed
                }
            }
            if let includeRaw = filters["include_deleted"] {
                guard let parsed = includeRaw.boolValue else {
                    throw BrokerValidationError.invalid("filters.include_deleted must be a boolean")
                }
                includeDeleted = parsed
            }
            if let includeRaw = filters["include_superseded"] {
                guard let parsed = includeRaw.boolValue else {
                    throw BrokerValidationError.invalid("filters.include_superseded must be a boolean")
                }
                includeSuperseded = parsed
            }
            if let includeRaw = filters["include_surrogates"] {
                guard let parsed = includeRaw.boolValue else {
                    throw BrokerValidationError.invalid("filters.include_surrogates must be a boolean")
                }
                includeSurrogates = parsed
            }
            if let frameIdsRaw = filters["frame_ids"] {
                guard let rawArray = frameIdsRaw.arrayValue else {
                    throw BrokerValidationError.invalid("filters.frame_ids must be an array of non-negative integers")
                }
                var parsedFrameIds = Set<UInt64>()
                parsedFrameIds.reserveCapacity(rawArray.count)
                for value in rawArray {
                    guard case .int(let raw) = value, raw >= 0 else {
                        throw BrokerValidationError.invalid("filters.frame_ids must contain only non-negative integers")
                    }
                    parsedFrameIds.insert(UInt64(raw))
                }
                frameIds = parsedFrameIds
            }
            timeAfterMs = filters["time_after_ms"]?.intValue
            timeBeforeMs = filters["time_before_ms"]?.intValue
        }
        let metadataFilter: MetadataFilter? = (!metadataEntries.isEmpty || !labels.isEmpty)
            ? MetadataFilter(requiredEntries: metadataEntries, requiredLabels: labels)
            : nil
        let frameFilter: FrameFilter? = (metadataFilter != nil || includeDeleted || includeSuperseded || includeSurrogates || frameIds != nil)
            ? FrameFilter(
                includeDeleted: includeDeleted,
                includeSuperseded: includeSuperseded,
                includeSurrogates: includeSurrogates,
                frameIds: frameIds,
                metadataFilter: metadataFilter
            )
            : nil
        let timeRange: SearchTimeRange? = (timeAfterMs != nil || timeBeforeMs != nil)
            ? SearchTimeRange(after: timeAfterMs, before: timeBeforeMs)
            : nil
        return ParsedSearchFilters(
            sessionId: sessionID,
            frameFilter: frameFilter,
            timeRange: timeRange,
            summary: .object([
                "session_id": .from(sessionID?.uuidString),
                "metadata": .object(metadataEntries.mapValues(AgentBrokerValue.string)),
                "labels": .array(labels.map(AgentBrokerValue.string)),
                "time_after_ms": .from(timeAfterMs),
                "time_before_ms": .from(timeBeforeMs),
                "include_deleted": .from(includeDeleted),
                "include_superseded": .from(includeSuperseded),
                "include_surrogates": .from(includeSurrogates),
                "frame_ids": .array((frameIds ?? []).sorted().map(AgentBrokerValue.from)),
                "has_frame_filter": .from(frameFilter != nil),
                "has_time_range": .from(timeRange != nil),
            ])
        )
    }

    func parseRecallMode(_ args: BrokerArguments) throws -> MemoryOrchestrator.DirectSearchMode? {
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let alpha = try args.optionalDouble("alpha")

        guard let modeRaw else {
            if let alpha {
                return .hybrid(alpha: try validatedHybridAlpha(alpha))
            }
            return nil
        }

        switch modeRaw {
        case "text":
            return .text
        case "vector":
            return .vector
        case "hybrid":
            return .hybrid(alpha: try validatedHybridAlpha(alpha ?? 0.5))
        default:
            throw BrokerValidationError.invalid("mode must be one of: text, vector, hybrid")
        }
    }

    func parseSearchMode(
        modeRaw: String?,
        alpha: Double?
    ) throws -> MemoryOrchestrator.DirectSearchMode {
        let validatedAlpha = try validatedHybridAlpha(alpha ?? 0.5)
        switch modeRaw ?? "text" {
        case "text":
            return .text
        case "vector":
            return .vector
        case "hybrid":
            return .hybrid(alpha: validatedAlpha)
        default:
            throw BrokerValidationError.invalid("mode must be one of: text, vector, hybrid")
        }
    }

    func validatedHybridAlpha(_ alpha: Double) throws -> Float {
        guard (0.0...1.0).contains(alpha) else {
            throw BrokerValidationError.invalid("alpha must be between 0 and 1")
        }
        return Float(alpha)
    }

    func coerceMetadata(_ object: [String: AgentBrokerValue]?) throws -> [String: String] {
        guard let object else { return [:] }
        return try object.reduce(into: [String: String]()) { partial, entry in
            switch entry.value {
            case .string(let value):
                partial[entry.key] = value
            case .bool(let value):
                partial[entry.key] = value ? "true" : "false"
            case .int(let value):
                partial[entry.key] = String(value)
            case .double(let value):
                partial[entry.key] = String(value)
            default:
                throw BrokerValidationError.invalid("metadata.\(entry.key) must be a scalar")
            }
        }
    }

    func parseWriteSemantics(_ args: BrokerArguments) throws -> MemoryWriteSemantics {
        let type = try args.optionalString("memory_type").flatMap(MemoryType.init(rawValue:))
        if try args.optionalString("memory_type") != nil, type == nil {
            throw BrokerValidationError.invalid("memory_type must be one of: \(MemoryType.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        let durability = try args.optionalString("durability").flatMap(MemoryDurability.init(rawValue:))
        if try args.optionalString("durability") != nil, durability == nil {
            throw BrokerValidationError.invalid("durability must be one of: \(MemoryDurability.allCases.map(\.rawValue).joined(separator: ", "))")
        }
        return MemoryWriteSemantics(
            type: type,
            durability: durability,
            project: try args.optionalString("project"),
            repo: try args.optionalString("repo"),
            confidence: try args.optionalFloat("confidence"),
            expiresInDays: try args.optionalInt("expires_in_days"),
            reviewed: try args.optionalBool("reviewed") ?? false,
            lock: try args.optionalBool("locked") ?? false
        )
    }

    func parsePromotionSettings(_ args: BrokerArguments) throws -> BrokerPromotionSettings {
        let minimumConfidence = try args.optionalFloat("minimum_confidence").map { min(max($0, 0), 1) }
            ?? promotionSettings.minimumConfidence
        let minimumRecallCount = try args.optionalInt("minimum_recall_count").map { max(0, $0) }
            ?? promotionSettings.minimumRecallCount
        let maxCandidates = try args.optionalInt("max_candidates").map { min(max(1, $0), Self.maxPromotionCandidates) }
            ?? promotionSettings.maxCandidates
        return BrokerPromotionSettings(
            minimumConfidence: minimumConfidence,
            minimumRecallCount: minimumRecallCount,
            maxCandidates: maxCandidates
        )
    }

    func validateDurableWriteContent(content: String, metadata: [String: String]) throws {
        let semantics = MemorySemantics.parse(metadata: metadata)
        guard semantics.durability == .durable || semantics.durability == .locked else { return }
        if let detected = SecretHeuristics.detectSecretLikeContent(content, metadata: metadata) {
            throw BrokerValidationError.invalid("Refusing to store durable memory containing secret-like content (\(detected))")
        }
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

    func parseFactValue(_ value: AgentBrokerValue) throws -> FactValue {
        switch value {
        case .string(let raw):
            return .string(raw)
        case .bool(let raw):
            return .bool(raw)
        case .int(let raw):
            return .int(raw)
        case .double(let raw):
            return .double(raw)
        case .object(let raw):
            if raw.count == 2,
               let type = raw["type"]?.stringValue,
               let genericValue = raw["value"] {
                switch type {
                case "entity":
                    guard let entity = genericValue.stringValue else {
                        throw BrokerValidationError.invalid("entity typed object value must be a string")
                    }
                    return .entity(EntityKey(entity))
                case "time_ms":
                    guard let time = genericValue.intValue else {
                        throw BrokerValidationError.invalid("time_ms typed object value must be an integer")
                    }
                    return .timeMs(time)
                case "data_base64":
                    guard let data = genericValue.stringValue, let decoded = Data(base64Encoded: data) else {
                        throw BrokerValidationError.invalid("data_base64 typed object value must be a base64 string")
                    }
                    return .data(decoded)
                default:
                    throw BrokerValidationError.invalid("typed object type must be one of: entity, time_ms, data_base64")
                }
            }
            if let entity = raw["entity"]?.stringValue, raw.count == 1 {
                return .entity(EntityKey(entity))
            }
            if let time = raw["time_ms"]?.intValue, raw.count == 1 {
                return .timeMs(time)
            }
            if let data = raw["data_base64"]?.stringValue, raw.count == 1, let decoded = Data(base64Encoded: data) {
                return .data(decoded)
            }
            throw BrokerValidationError.invalid("typed object values must be one of {entity}, {time_ms}, or {data_base64}")
        default:
            throw BrokerValidationError.invalid("object must be a string, number, bool, or typed object")
        }
    }

    func parseVersionRelation(_ raw: String) throws -> VersionRelation {
        switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
        case "sets": return .sets
        case "updates": return .updates
        case "extends": return .extends
        case "retracts": return .retracts
        default:
            throw BrokerValidationError.invalid("relation must be one of: sets, updates, extends, retracts")
        }
    }

    func parseStructuredEvidence(_ value: AgentBrokerValue?) throws -> [StructuredEvidence] {
        guard let value else { return [] }
        guard let array = value.arrayValue else {
            throw BrokerValidationError.invalid("evidence must be an array")
        }
        return try array.map { item in
            guard let object = item.objectValue else {
                throw BrokerValidationError.invalid("evidence must contain only objects")
            }
            let allowedKeys: Set<String> = [
                "source_frame_id",
                "chunk_index",
                "span_start_utf8",
                "span_end_utf8",
                "extractor_id",
                "extractor_version",
                "confidence",
                "asserted_at_ms",
            ]
            let unknownKeys = Set(object.keys).subtracting(allowedKeys)
            guard unknownKeys.isEmpty else {
                throw BrokerValidationError.invalid("unknown evidence fields: \(unknownKeys.sorted().joined(separator: ", "))")
            }
            guard let sourceFrameId = object["source_frame_id"], case .int(let sourceRaw) = sourceFrameId, sourceRaw >= 0 else {
                throw BrokerValidationError.invalid("evidence.source_frame_id must be a non-negative integer")
            }
            let chunkIndex: UInt32? = try {
                guard let value = object["chunk_index"] else { return nil }
                guard case .int(let raw) = value, raw >= 0, raw <= Int64(UInt32.max) else {
                    throw BrokerValidationError.invalid("evidence.chunk_index must be a non-negative integer")
                }
                return UInt32(raw)
            }()
            let span = try parseEvidenceSpan(object)
            let extractorId = try requiredEvidenceString(object, key: "extractor_id")
            let extractorVersion = try requiredEvidenceString(object, key: "extractor_version")
            let confidence = try parseEvidenceConfidence(object["confidence"])
            guard let assertedAtValue = object["asserted_at_ms"], case .int(let assertedAtMs) = assertedAtValue else {
                throw BrokerValidationError.invalid("evidence.asserted_at_ms must be an integer")
            }
            return StructuredEvidence(
                sourceFrameId: UInt64(sourceRaw),
                chunkIndex: chunkIndex,
                spanUTF8: span,
                extractorId: extractorId,
                extractorVersion: extractorVersion,
                confidence: confidence,
                assertedAtMs: assertedAtMs
            )
        }
    }

    func parseEvidenceSpan(_ object: [String: AgentBrokerValue]) throws -> Range<Int>? {
        guard object["span_start_utf8"] != nil || object["span_end_utf8"] != nil else {
            return nil
        }
        guard let startValue = object["span_start_utf8"], case .int(let startRaw) = startValue,
              let endValue = object["span_end_utf8"], case .int(let endRaw) = endValue,
              startRaw >= 0, endRaw > startRaw,
              startRaw <= Int64(Int.max), endRaw <= Int64(Int.max) else {
            throw BrokerValidationError.invalid("evidence span must include non-negative span_start_utf8 and greater span_end_utf8")
        }
        return Int(startRaw)..<Int(endRaw)
    }

    func requiredEvidenceString(_ object: [String: AgentBrokerValue], key: String) throws -> String {
        guard let value = object[key], let raw = value.stringValue else {
            throw BrokerValidationError.invalid("evidence.\(key) must be a string")
        }
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw BrokerValidationError.invalid("evidence.\(key) must not be empty")
        }
        return trimmed
    }

    func parseEvidenceConfidence(_ value: AgentBrokerValue?) throws -> Double? {
        guard let value else { return nil }
        guard let confidence = value.doubleValue, confidence.isFinite, (0...1).contains(confidence) else {
            throw BrokerValidationError.invalid("evidence.confidence must be a finite number between 0 and 1")
        }
        return confidence
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

    func parseMemoryReference(_ raw: String) throws -> MemoryReference {
        let parts = raw.split(separator: ":").map(String.init)
        guard parts.count >= 2 else {
            throw BrokerValidationError.invalid("memory_id must be in the form '<horizon>:<frame>' or '<horizon>:<session_id>:<frame>'")
        }
        guard let horizon = MemoryHorizon(rawValue: parts[0]) else {
            throw BrokerValidationError.invalid("memory_id horizon must be one of: working, episodic, durable")
        }
        switch horizon {
        case .durable:
            guard parts.count == 2, let frameID = UInt64(parts[1]) else {
                throw BrokerValidationError.invalid("durable memory_id must be 'durable:<frame_id>'")
            }
            return MemoryReference(horizon: .durable, sessionID: nil, frameID: frameID)
        case .working, .episodic:
            guard parts.count == 3,
                  let sessionID = UUID(uuidString: parts[1]),
                  let frameID = UInt64(parts[2]) else {
                throw BrokerValidationError.invalid("session memory_id must be '\(horizon.rawValue):<session_id>:<frame_id>'")
            }
            return MemoryReference(horizon: horizon, sessionID: sessionID, frameID: frameID)
        }
    }

    func renderLayeredMemoryHit(_ hit: LayeredMemoryHit) -> AgentBrokerValue {
        .object([
            "memory_id": .string(hit.reference),
            "horizon": .string(hit.horizon.rawValue),
            "session_id": .from(hit.sessionID?.uuidString),
            "agent_id": .from(hit.agentID),
            "run_id": .from(hit.runID),
            "frame_id": .from(hit.frameID),
            "score": .double(Double(hit.score)),
            "preview": .string(hit.preview),
            "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
            "explanations": .array(hit.explanations.map(AgentBrokerValue.string)),
            "timestamp_ms": .from(hit.timestampMs),
        ])
    }

    func requireDocument(
        frameID: UInt64,
        memory: MemoryOrchestrator
    ) async throws -> MemoryOrchestrator.CorpusSourceDocument {
        guard let document = try await memory.corpusSourceDocuments().first(where: { $0.frameId == frameID }) else {
            throw BrokerValidationError.invalid("No memory document found for frame_id \(frameID)")
        }
        return document
    }

    func canonicalDocumentFrameID(
        for frameID: UInt64,
        memory: MemoryOrchestrator
    ) async throws -> UInt64 {
        let meta = try await memory.wax.frameMetaIncludingPending(frameId: frameID)
        if meta.role == .chunk, let parentID = meta.parentId {
            return parentID
        }
        return frameID
    }

    func bestEffortCanonicalDocumentFrameID(
        for frameID: UInt64,
        memory: MemoryOrchestrator
    ) async -> UInt64? {
        do {
            return try await canonicalDocumentFrameID(for: frameID, memory: memory)
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "broker canonical frame lookup",
                fallback: "skip stale search hit"
            )
            return nil
        }
    }

    func renderCompactedContext(
        query: String,
        short: [LayeredMemoryHit],
        medium: [LayeredMemoryHit],
        long: [LayeredMemoryHit]
    ) -> String {
        var lines = ["Query: \(query)"]
        func appendSection(_ title: String, _ hits: [LayeredMemoryHit]) {
            guard !hits.isEmpty else { return }
            lines.append("")
            lines.append(title)
            for hit in hits {
                let reason = hit.explanations.prefix(2).joined(separator: ", ")
                lines.append("- \(hit.preview)")
                if !reason.isEmpty {
                    lines.append("  why: \(reason)")
                }
            }
        }
        appendSection("Short-Term Context", short)
        appendSection("Medium-Term Context", medium)
        appendSection("Long-Term Context", long)
        return lines.joined(separator: "\n")
    }

    func renderMemoryMarkdown(documents: [MemoryOrchestrator.CorpusSourceDocument]) -> String {
        var sections: [MemoryType: [String]] = [:]
        for document in documents {
            let info = MemorySemantics.parse(metadata: document.metadata)
            guard info.durability == .durable || info.durability == .locked else { continue }
            let type = info.type
            let marker = marker(for: document, kind: .memory)
            sections[type, default: []].append(renderManagedMarkdownLine(text: document.text, marker: marker))
        }
        let orderedTypes: [MemoryType] = [.decision, .lesson, .userPreference, .constraint, .fact, .handoff, .note, .taskState]
        var lines = ["# MEMORY", ""]
        for type in orderedTypes {
            guard let entries = sections[type], !entries.isEmpty else { continue }
            lines.append("## \(type.rawValue)")
            lines.append(contentsOf: entries)
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func dayString(fromMs timestampMs: Int64) -> String {
        let formatter = DateFormatter()
        formatter.calendar = Calendar(identifier: .iso8601)
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.timeZone = TimeZone(secondsFromGMT: 0)
        formatter.dateFormat = "yyyy-MM-dd"
        return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestampMs) / 1000))
    }

    static func safeMarkdownDailyDateKey(_ rawValue: String?, fallbackMs: Int64) -> String {
        guard let rawValue else {
            return dayString(fromMs: fallbackMs)
        }
        let trimmed = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.range(of: #"^\d{4}-\d{2}-\d{2}$"#, options: .regularExpression) != nil else {
            return dayString(fromMs: fallbackMs)
        }
        return trimmed
    }

    static func makeMemoryReference(_ horizon: MemoryHorizon, sessionID: UUID?, frameID: UInt64) -> String {
        switch horizon {
        case .durable:
            return "durable:\(frameID)"
        case .working, .episodic:
            return "\(horizon.rawValue):\(sessionID?.uuidString ?? "unknown"):\(frameID)"
        }
    }

    static func nowMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    static func stableHash(_ text: String) -> String {
        var hash: UInt64 = 14695981039346656037
        for byte in text.utf8 {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return String(hash, radix: 16)
    }
}

private struct BrokerStartupError: LocalizedError {
    let message: String

    init(_ message: String) {
        self.message = message
    }

    var errorDescription: String? { message }
}

struct BrokerArguments {
    let values: [String: AgentBrokerValue]

    init(_ values: [String: AgentBrokerValue]) {
        self.values = values
    }

    func requiredString(_ key: String, maxBytes: Int) throws -> String {
        guard let raw = try optionalString(key) else {
            throw BrokerValidationError.missing(key)
        }
        guard raw.utf8.count <= maxBytes else {
            throw BrokerValidationError.invalid("\(key) exceeds \(maxBytes) bytes")
        }
        return raw
    }

    func requiredStringPreservingWhitespace(_ key: String, maxBytes: Int) throws -> String {
        guard let raw = try optionalStringPreservingWhitespace(key) else {
            throw BrokerValidationError.missing(key)
        }
        guard raw.utf8.count <= maxBytes else {
            throw BrokerValidationError.invalid("\(key) exceeds \(maxBytes) bytes")
        }
        return raw
    }

    func optionalString(_ key: String) throws -> String? {
        try optionalStringPreservingWhitespace(key)?.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func optionalStringPreservingWhitespace(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let stringValue = value.stringValue else {
            throw BrokerValidationError.invalid("\(key) must be a string")
        }
        return stringValue
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        guard let array = value.arrayValue else {
            throw BrokerValidationError.invalid("\(key) must be an array of strings")
        }
        return try array.map { element in
            guard let stringValue = element.stringValue else {
                throw BrokerValidationError.invalid("\(key) must contain only strings")
            }
            return stringValue
        }
    }

    func optionalObject(_ key: String) throws -> [String: AgentBrokerValue]? {
        guard let value = values[key] else { return nil }
        guard let object = value.objectValue else {
            throw BrokerValidationError.invalid("\(key) must be an object")
        }
        return object
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        guard let boolValue = value.boolValue else {
            throw BrokerValidationError.invalid("\(key) must be a boolean")
        }
        return boolValue
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        guard let intValue = value.intValue else {
            throw BrokerValidationError.invalid("\(key) must be an integer")
        }
        return Int(intValue)
    }

    func optionalUInt64(_ key: String) throws -> UInt64? {
        guard let value = values[key] else { return nil }
        guard let intValue = value.intValue, intValue >= 0 else {
            throw BrokerValidationError.invalid("\(key) must be a non-negative integer")
        }
        return UInt64(intValue)
    }

    func requiredInt64(_ key: String) throws -> Int64 {
        guard let value = values[key], let intValue = value.intValue else {
            throw BrokerValidationError.missing(key)
        }
        return intValue
    }

    func optionalInt64(_ key: String) throws -> Int64? {
        guard let value = values[key] else { return nil }
        guard let intValue = value.intValue else {
            throw BrokerValidationError.invalid("\(key) must be an integer")
        }
        return intValue
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        guard let doubleValue = value.doubleValue else {
            throw BrokerValidationError.invalid("\(key) must be a number")
        }
        return doubleValue
    }

    func optionalFloat(_ key: String) throws -> Float? {
        guard let value = try optionalDouble(key) else { return nil }
        guard value.isFinite else {
            throw BrokerValidationError.invalid("\(key) must be a finite number")
        }
        return Float(value)
    }

    func requiredValue(_ key: String) throws -> AgentBrokerValue {
        guard let value = values[key] else {
            throw BrokerValidationError.missing(key)
        }
        return value
    }

    func optionalValue(_ key: String) throws -> AgentBrokerValue? {
        values[key]
    }
}

enum BrokerValidationError: LocalizedError {
    case missing(String)
    case invalid(String)

    var errorDescription: String? {
        switch self {
        case .missing(let key):
            return "Missing required argument '\(key)'."
        case .invalid(let message):
            return message
        }
    }
}

private extension AgentBrokerValue {
    var debugJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
