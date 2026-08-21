import Foundation
import WaxCore

package actor AgentBrokerService {
    typealias SessionState = VirtualSessionStore.SessionState

    let longTermMemory: MemoryOrchestrator
    let longTermStoreURL: URL
    let sessionRootURL: URL
    let corpusStoreURL: URL
    let noEmbedder: Bool
    let requireVector: Bool
    let embedderChoice: String
    let embedderTuning: CommandLineEmbedderRuntimeTuning
    let enableAccessStatsScoring: Bool
    let scopeContext: MemoryScopeContext
    let promotionSettings: BrokerPromotionSettings
    let embeddingRequest: EmbeddingOpenRequest
    let readiness: EmbeddingReadiness
    let factoryOverride: (@Sendable () async throws -> any EmbeddingProvider)?
    let brokerInstanceID = UUID().uuidString
    let virtualSessions: VirtualSessionStore
    var activeSessions: [UUID: SessionState] {
        virtualSessions.live
    }

    package init(
        storePath: String,
        sessionRootPath: String,
        noEmbedder: Bool,
        embedderChoice: String,
        requireVector: Bool,
        enableAccessStatsScoring: Bool = false,
        embedderTuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment(),
        embedderOverride: (any EmbeddingProvider)? = nil,
        readiness: EmbeddingReadiness = .shared,
        factoryOverride: (@Sendable () async throws -> any EmbeddingProvider)? = nil,
        orchestratorConfig: OrchestratorConfig? = nil
    ) async throws {
        self.longTermStoreURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(storePath)).standardizedFileURL
        self.sessionRootURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(sessionRootPath)).standardizedFileURL
        self.noEmbedder = noEmbedder
        self.requireVector = requireVector
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

        if requireVector, noEmbedder {
            throw BrokerStartupError("Vector search required but --no-embedder was set.")
        }
        let request: EmbeddingOpenRequest
        if let embedderOverride {
            request = .custom(embedderOverride)
        } else {
            do {
                request = try HostEmbeddingReadiness.request(
                    noEmbedder: noEmbedder,
                    requireVector: requireVector,
                    embedderChoice: embedderChoice,
                    options: BuiltInEmbeddingProviderOptions(tuning: embedderTuning)
                )
            } catch {
                if EmbeddingReadinessBinding.isTypedOpenFailure(error) {
                    throw error
                }
                throw BrokerStartupError(error.localizedDescription)
            }
        }
        self.embeddingRequest = request
        self.readiness = readiness
        self.factoryOverride = factoryOverride
        let capturedAccessStats = enableAccessStatsScoring
        let capturedScope = scopeContext
        let capturedRequest = request
        let capturedReadiness = readiness
        let capturedFactory = factoryOverride
        self.virtualSessions = VirtualSessionStore(
            sessionRootURL: sessionRootURL,
            brokerInstanceID: brokerInstanceID,
            openExisting: { url in
                var sessionConfig = OrchestratorConfig.default
                sessionConfig.enableStructuredMemory = false
                sessionConfig.enableAccessStatsScoring = capturedAccessStats
                sessionConfig.defaultScopeContext = capturedScope
                return try await EmbeddingReadinessBinding.openOrchestrator(
                    at: url,
                    config: sessionConfig,
                    request: capturedRequest,
                    waxOptions: CommandLineEmbedderFactory.waxOptions(),
                    readiness: capturedReadiness,
                    factoryOverride: capturedFactory
                )
            }
        )
        var config = orchestratorConfig ?? .default
        config.enableStructuredMemory = true
        config.enableAccessStatsScoring = enableAccessStatsScoring
        config.defaultScopeContext = scopeContext
        do {
            self.longTermMemory = try await EmbeddingReadinessBinding.openOrchestrator(
                at: longTermStoreURL,
                config: config,
                request: request,
                waxOptions: CommandLineEmbedderFactory.waxOptions(),
                readiness: readiness,
                factoryOverride: factoryOverride
            )
        } catch {
            if requireVector {
                if EmbeddingReadinessBinding.isTypedOpenFailure(error) {
                    throw error
                }
                throw BrokerStartupError("Vector search required but the embedding provider is unavailable.")
            }
            throw error
        }
    }

    package func close() async throws {
        await virtualSessions.closeAll()
        try await longTermMemory.flush()
        try await longTermMemory.close()
    }

    package func handle(_ request: AgentBrokerRequest) async -> AgentBrokerResponse {
        do {
            let decoded = try BrokerCommand.decode(
                command: request.command,
                arguments: request.arguments
            )
            let payload: AgentBrokerValue
            let shouldExit: Bool

            switch decoded {
            case .remember(let command):
                payload = try await remember(command)
                shouldExit = false
            case .memoryAppend(let command):
                payload = try await remember(command)
                shouldExit = false
            case .recall(let command):
                payload = try await recall(command)
                shouldExit = false
            case .search(let command):
                payload = try await search(command)
                shouldExit = false
            case .memorySearch(let command):
                payload = try await memorySearch(command)
                shouldExit = false
            case .sessionStart(let command):
                payload = try await sessionStart(command)
                shouldExit = false
            case .sessionResume(let command):
                payload = try await sessionResume(command)
                shouldExit = false
            case .sessionEnd(let command):
                payload = try await sessionEnd(command)
                shouldExit = false
            case .handoff(let command):
                payload = try await handoff(command)
                shouldExit = false
            case .handoffLatest(let command):
                payload = try await handoffLatest(command)
                shouldExit = false
            case .memoryGet(let command):
                payload = try await memoryGet(command)
                shouldExit = false
            case .memoryHealth:
                payload = try await memoryHealth()
                shouldExit = false
            case .stats(let command):
                payload = try await stats(command)
                shouldExit = false
            case .flush:
                payload = try await flush()
                shouldExit = false
            case .markdownSync(let command):
                payload = try await markdownSync(command)
                shouldExit = false
            case .entityUpsert(let command):
                payload = try await entityUpsert(command)
                shouldExit = false
            case .entityResolve(let command):
                payload = try await entityResolve(command)
                shouldExit = false
            case .factRetract(let command):
                payload = try await factRetract(command)
                shouldExit = false
            case .shutdown:
                payload = .object(["status": .string("ok")])
                shouldExit = true
            case .sessionSynthesize(let command):
                payload = try await sessionSynthesize(command)
                shouldExit = false
            case .knowledgeCapture(let command):
                payload = try await knowledgeCapture(command)
                shouldExit = false
            case .sessionClose(let command):
                payload = try await sessionClose(command)
                shouldExit = false
            case .sessionOpen(let command):
                payload = try await sessionOpen(command)
                shouldExit = false
            case .compactContext(let command):
                payload = try await compactContext(command)
                shouldExit = false
            case .markdownExport(let command):
                payload = try await markdownExport(command)
                shouldExit = false
            case .factsQuery(let command):
                payload = try await factsQuery(command)
                shouldExit = false
            case .passthrough(let command, let arguments):
                (payload, shouldExit) = try await handlePassthrough(
                    command: command,
                    arguments: arguments
                )
            }

            return AgentBrokerResponse(
                id: request.id,
                ok: true,
                payload: payload,
                error: nil,
                shouldExit: shouldExit
            )
        } catch let error as BrokerSessionInactiveError {
            return AgentBrokerResponse(
                id: request.id,
                ok: false,
                payload: error.brokerPayload(),
                error: error.localizedDescription,
                shouldExit: false
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
    /// Forwarded from ``BrokerLimits`` for MCP/CLI callers that already import the service.
    package static let maxContentBytes = BrokerLimits.maxContentBytes
    package static let maxTopK = BrokerLimits.maxTopK
    package static let maxRecallLimit = BrokerLimits.maxRecallLimit
    static let maxGraphLimit = BrokerLimits.maxGraphLimit
    static let maxGraphIdentifierBytes = BrokerLimits.maxGraphIdentifierBytes
    static let maxGraphKindBytes = BrokerLimits.maxGraphKindBytes
    static let maxPromotionCandidates = BrokerPromotionSettings.maxCandidateLimit
    static let maxCompactContextTokenBudget = BrokerLimits.maxCompactContextTokenBudget

    typealias MemoryHorizon = LayeredRecall.Horizon
    typealias LayeredMemoryHit = LayeredRecall.Hit
    typealias MemoryReference = LayeredRecall.MemoryReference

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

    func handlePassthrough(
        command: String,
        arguments: [String: AgentBrokerValue]
    ) async throws -> (AgentBrokerValue, Bool) {
        switch command {
        case "memory_promote":
            return (try await memoryPromote(arguments: arguments), false)
        case "promote":
            return (try await promote(arguments: arguments), false)
        case "fact_assert":
            return (try await factAssert(arguments: arguments), false)
        case "corpus_search":
            return (try await corpusSearch(arguments: arguments), false)
        default:
            throw BrokerValidationError.invalid("Unknown broker command '\(command)'.")
        }
    }

    func remember(_ command: BrokerCommand.Remember) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        // Rebind before writeScope so session manifest project/repo stamp correctly after a broker hop.
        if let sessionID {
            _ = try await memory(for: sessionID)
        }
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: command.metadata,
            semantics: command.writeSemantics,
            sessionID: sessionID,
            inferredScope: writeScope(for: sessionID, clientCWD: command.cwd)
        )
        try validateDurableWriteContent(content: command.content, metadata: metadata)
        let memory = try await memory(for: sessionID)
        if let sessionID {
            try await refreshSessionManifest(sessionID)
        }

        let before = await memory.runtimeStats()
        if !noEmbedder, before.vectorSearchEnabled, await memory.shouldDeferRememberUntilEmbedderReady() {
            do {
                try await Self.awaitRememberReady(memory: memory, timeout: .seconds(30))
            } catch {
                throw BrokerValidationError.invalid(
                    "Remember failed: embedding provider not ready (\(error.localizedDescription))"
                )
            }
        }

        return try await completeRemember(
            memory: memory,
            content: command.content,
            metadata: metadata,
            sessionID: sessionID,
            before: before
        )
    }

    /// Suspends until `memory` can accept remember writes, or fails after `timeout`.
    private static func awaitRememberReady(
        memory: MemoryOrchestrator,
        timeout: Duration
    ) async throws {
        try await withThrowingTaskGroup(of: Void.self) { group in
            group.addTask {
                try await memory.waitUntilReadyForRemember()
            }
            group.addTask {
                try await Task.sleep(for: timeout)
                throw BrokerValidationError.invalid(
                    "embedding provider did not become ready within \(timeout.components.seconds)s"
                )
            }
            defer { group.cancelAll() }
            guard try await group.next() != nil else {
                throw BrokerValidationError.invalid("embedding provider readiness wait produced no result")
            }
        }
    }

    func completeRemember(
        memory: MemoryOrchestrator,
        content: String,
        metadata: [String: String],
        sessionID: UUID?,
        before: MemoryOrchestrator.RuntimeStats? = nil
    ) async throws -> AgentBrokerValue {
        let beforeStats: MemoryOrchestrator.RuntimeStats
        if let before {
            beforeStats = before
        } else {
            beforeStats = await memory.runtimeStats()
        }
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
        let totalBefore = beforeStats.frameCount + beforeStats.pendingFrames
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

    func recall(_ command: BrokerCommand.Recall) async throws -> AgentBrokerValue {
        let query = command.query
        let limit = command.limit
        let recallScope = command.scope
        let explicitProject = command.explicitProject
        let explicitRepo = command.explicitRepo
        let clientCWD = command.clientCWD
        let parsedFilters = command.filters
        let mode = command.mode
        let effectiveTopK = command.searchTopK

        // Rebind session lane before resolving project from session manifest (C4).
        if let sessionID = parsedFilters.sessionId {
            _ = try await memory(for: sessionID)
        }

        let request = LayeredRecall.RecallRequest(
            query: query,
            scope: recallScope,
            limit: limit,
            searchTopK: effectiveTopK,
            mode: mode,
            sessionID: parsedFilters.sessionId,
            explicitProject: explicitProject,
            explicitRepo: explicitRepo,
            clientCWD: clientCWD,
            frameFilter: parsedFilters.frameFilter,
            timeRange: parsedFilters.timeRange
        )
        let result = try await LayeredRecall.recall(request: request, stores: layeredRecallStores())

        var lines: [String] = []
        if let scopeMissMessage = result.scopeMissMessage {
            lines.append(scopeMissMessage)
        }
        lines.append(contentsOf: [
            "Query: \(query)",
            "Total tokens: \(result.hits.reduce(0) { $0 + max(1, $1.text.split(whereSeparator: \.isWhitespace).count) })",
            "Results: \(result.hits.count) of \(limit) requested (orchestrator returned \(result.hits.count))",
            "Search controls: requested_mode=\(result.requestedModeSummary) effective_mode=\(result.effectiveModeSummary) query_embedding_state=\(result.queryEmbeddingState) search_top_k=\(effectiveTopK) limit=\(limit) scope=\(result.scope.rawValue)",
        ])
        if let project = result.identity.project {
            lines.append("Resolved project: \(project)")
        }
        if let repo = result.identity.repo {
            lines.append("Resolved repo: \(repo)")
        }
        lines.append("Applied filters: \(parsedFilters.summary.debugJSONString)")
        for (index, hit) in result.hits.enumerated() {
            let kind = hit.kind ?? "snippet"
            lines.append("\(index + 1). [\(kind)] frame=\(hit.frameID) score=\(String(format: "%.4f", hit.score)) \(hit.text)")
        }

        let results: [AgentBrokerValue] = result.hits.enumerated().map { index, hit in
            .object([
                "rank": .from(index + 1),
                "kind": .string(hit.kind ?? "snippet"),
                "frameId": .from(hit.frameID),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map(AgentBrokerValue.string)),
                "text": .string(hit.text),
                "metadata": .object(hit.metadata.mapValues(AgentBrokerValue.string)),
                "explanations": .array(hit.explanations.map(AgentBrokerValue.string)),
            ])
        }
        if let sessionID = parsedFilters.sessionId {
            let sessionMemory = try await memory(for: sessionID)
            try await refreshSessionManifest(sessionID)
            try await recordRetrievalHits(
                sessionID: sessionID,
                query: query,
                hits: result.hits.compactMap { hit in
                    guard hit.explanations.contains("current session") else { return nil }
                    return (hit.frameID, hit.score)
                },
                memory: sessionMemory
            )
        }

        var payload: [String: AgentBrokerValue] = [
            "query": .string(query),
            "total_tokens": .from(result.hits.reduce(0) { $0 + max(1, $1.text.split(whereSeparator: \.isWhitespace).count) }),
            "result_count": .from(result.hits.count),
            "limit": .from(limit),
            "search_top_k": .from(effectiveTopK),
            "requested_mode": .string(result.requestedModeSummary),
            "effective_mode": .string(result.effectiveModeSummary),
            "query_embedding_state": .string(result.queryEmbeddingState),
            "scope": .string(result.scope.rawValue),
            "project": .from(result.identity.project),
            "repo": .from(result.identity.repo),
            "project_miss": .bool(result.projectMiss),
            "applied_filters": parsedFilters.summary,
            "results": .array(results),
            "display_text": .string(lines.joined(separator: "\n")),
        ]
        if let scopeMissMessage = result.scopeMissMessage {
            payload["scope_miss_message"] = .string(scopeMissMessage)
        }
        return .object(payload)
    }

    private func parseRecallScope(_ args: BrokerArguments) throws -> LayeredRecall.Scope {
        try BrokerCommand.parseRecallScope(args)
    }

    private func normalizedOrNil(_ value: String?) -> String? {
        BrokerCommand.normalizedOrNil(value)
    }

    package static func filterRecallItemsByProject(
        _ items: [RAGContext.Item],
        project: String?,
        repo: String?
    ) -> [RAGContext.Item] {
        LayeredRecall.filterRecallItemsByProject(items, project: project, repo: repo)
    }

    /// Returns items whose `wax.project` or `wax.repo` metadata matches the given identity.
    package static func recallItems(
        _ items: [RAGContext.Item],
        matchingProject project: String?,
        repo: String?
    ) -> [RAGContext.Item] {
        filterRecallItemsByProject(items, project: project, repo: repo)
    }

    /// Merges project/repo hard-filter into an existing frame filter so unified search
    /// over-fetches and excludes foreign frames before top-K is finalized.
    package static func frameFilterByAddingProjectScope(
        _ base: FrameFilter?,
        project: String?,
        repo: String?
    ) -> FrameFilter? {
        LayeredRecall.frameFilterForScopedRetrieval(
            base: base,
            scope: .project,
            identity: LayeredRecall.Identity(project: project, repo: repo)
        )
    }

    package static func mergeRecallItems(
        sessionItems: [RAGContext.Item],
        durableItems: [RAGContext.Item],
        limit: Int
    ) -> [RAGContext.Item] {
        LayeredRecall.mergeRecallItems(
            sessionItems: sessionItems,
            durableItems: durableItems,
            limit: limit
        )
    }

    func search(_ command: BrokerCommand.Search) async throws -> AgentBrokerValue {
        let query = command.query
        let mode = command.mode
        let topK = command.topK
        let parsedFilters = command.filters
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
                "preview": .string(agentFacingPreview(hit.previewText)),
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
            "requested_mode": .string(execution.requestedMode.diagnosticsSummary),
            "effective_mode": .string(execution.effectiveMode.diagnosticsSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "applied_filters": parsedFilters.summary,
            "time_range_requested": .from(parsedFilters.timeRange != nil),
            "time_range_applied": .from(parsedFilters.timeRange != nil),
            "results": .array(rows),
            "display_text": .string(text),
        ])
    }

    func memorySearch(_ command: BrokerCommand.MemorySearch) async throws -> AgentBrokerValue {
        let query = command.query
        let topK = command.topK
        let mode = command.mode
        let requestedWorking = command.includeWorking
        let requestedEpisodic = command.includeEpisodic
        let requestedDurable = command.includeDurable
        let policy: SessionResolutionPolicy
        if requestedWorking || requestedEpisodic {
            policy = requestedDurable ? .durableOnlyWhenAmbiguous : .requireUnambiguousWorking
        } else {
            policy = .unscoped
        }
        let scope = try resolveSessionScope(command.sessionID, policy: policy)
        let sessionID: UUID?
        let includeWorking: Bool
        let includeEpisodic: Bool
        let includeDurable: Bool
        switch scope {
        case .session(let resolved):
            sessionID = resolved
            includeWorking = requestedWorking
            includeEpisodic = requestedEpisodic
            includeDurable = requestedDurable
        case .durableOnly:
            sessionID = nil
            includeWorking = false
            includeEpisodic = false
            includeDurable = true
        case .none:
            sessionID = nil
            includeWorking = false
            includeEpisodic = requestedEpisodic
            includeDurable = requestedDurable
        }
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
                hits: hits.compactMap { hit in
                    guard hit.horizon == .working else { return nil }
                    return (hit.frameID, hit.score)
                },
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

    func memoryGet(_ command: BrokerCommand.MemoryGet) async throws -> AgentBrokerValue {
        let reference = try parseMemoryReference(command.memoryID)
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

    func sessionSynthesize(_ command: BrokerCommand.SessionSynthesize) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        guard let resolvedSessionID = try resolveSessionID(sessionID) else {
            if activeSessions.count > 1 {
                throw BrokerValidationError.invalid("session_id is required when more than one session is active")
            }
            throw BrokerValidationError.invalid("session_id is required when no active session is available")
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

    func memoryPromote(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let sessionID = try parseOptionalSessionID(args)
        try await validateActiveSession(sessionID)
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
            inferredScope: writeScope(for: resolvedPromotionSessionID, clientCWD: try args.optionalString("cwd"))
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

    func knowledgeCapture(_ command: BrokerCommand.KnowledgeCapture) async throws -> AgentBrokerValue {
        let metadata = MemorySemantics.normalizeWriteMetadata(
            metadata: command.metadata,
            semantics: command.writeSemantics,
            sessionID: nil,
            inferredScope: writeScope(for: nil, clientCWD: command.cwd)
        )
        try validateDurableWriteContent(content: command.content, metadata: metadata)

        let subject = command.subject
        let predicate = command.predicate
        let kind = command.kind
        let aliases = command.aliases
        let parsedObject = try command.object.map { try parseFactValue($0) }

        try await longTermMemory.remember(command.content, metadata: metadata)

        var entityID: Int64?
        if let subject {
            let requestedKind = kind?.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedKind: String
            if let requestedKind, !requestedKind.isEmpty {
                resolvedKind = requestedKind
            } else if let existing = try await longTermMemory.entity(forKey: EntityKey(subject)),
                      !existing.kind.isEmpty {
                resolvedKind = existing.kind
            } else {
                resolvedKind = "concept"
            }
            entityID = try await longTermMemory.upsertEntity(
                key: EntityKey(subject),
                kind: resolvedKind,
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
            "display_text": .string(MemorySemantics.summarizeCandidate(command.content)),
        ])
    }

    func stats(_ command: BrokerCommand.Stats = .init(sessionID: nil)) async throws -> AgentBrokerValue {
        let requestedSessionID = command.sessionID
        let stats = await longTermMemory.runtimeStats()
        let activeSessionIDs = activeSessions.keys.sorted { $0.uuidString < $1.uuidString }
        let diskBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: stats.storeURL.path),
                  let size = attrs[.size] as? NSNumber
            else { return 0 }
            return size.uint64Value
        }()
        let sessionStats: MemoryOrchestrator.SessionRuntimeStats
        if let requestedSessionID {
            if let session = activeSessions[requestedSessionID] {
                sessionStats = try await session.memory.sessionRuntimeStats(sessionId: requestedSessionID)
            } else {
                sessionStats = .init(
                    active: false,
                    sessionId: requestedSessionID,
                    sessionFrameCount: 0,
                    sessionTokenEstimate: 0,
                    pendingFramesStoreWide: stats.pendingFrames,
                    countsIncludePending: false
                )
            }
        } else {
            sessionStats = .init(
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
            "embeddingStatus": .string(stats.embeddingStatus.wireName),
            "embeddingStatusReason": .from(stats.embeddingStatus.wireReason),
            "queryEmbeddingAvailable": .from(
                stats.vectorSearchEnabled && stats.queryEmbedderReady && !stats.queryEmbeddingCircuitOpen
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

    package func prewarmEmbedder() async {
        guard !noEmbedder else { return }
        _ = try? await longTermMemory.searchExecution(
            query: "wax",
            mode: .hybrid(alpha: 0.5),
            topK: 1,
            frameFilter: nil,
            timeRange: nil
        )
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

    func sessionStart(_ command: BrokerCommand.SessionStart) async throws -> AgentBrokerValue {
        let explicitSessionID = command.sessionID
        let requestedAgentID = command.agentID
        let requestedRunID = command.runID
        let requestedCWD = command.cwd
        let explicitProject = command.project
        let explicitRepo = command.repo
        var inferredScope = requestedCWD.map {
            MemorySemantics.inferScopeContext(currentDirectoryPath: $0)
        } ?? scopeContext
        if explicitProject != nil || explicitRepo != nil {
            inferredScope = MemoryScopeContext(
                cwdPath: inferredScope.cwdPath,
                repoRootPath: inferredScope.repoRootPath,
                repoName: explicitRepo ?? inferredScope.repoName,
                projectName: explicitProject ?? inferredScope.projectName
            )
        }

        let result = try await virtualSessions.start(
            explicitSessionID: explicitSessionID,
            agentID: requestedAgentID,
            runID: requestedRunID,
            inferredScope: inferredScope
        )
        return renderSessionLifecycleResult(result)
    }

    func sessionResume(_ command: BrokerCommand.SessionResume) async throws -> AgentBrokerValue {
        let result = try await virtualSessions.resume(
            explicitSessionID: command.sessionID,
            agentID: command.agentID,
            runID: command.runID
        )
        return renderSessionLifecycleResult(result)
    }

    func sessionEnd(_ command: BrokerCommand.SessionEnd) async throws -> AgentBrokerValue {
        let requested = command.sessionID
        // Explicit session_id must rebind an active-on-disk manifest after a broker hop (C4),
        // matching remember/recall/handoff/session_close. Omitted id stays live-map only.
        if let requested {
            _ = try await virtualSessions.ensureLive(requested)
        }
        guard let target = try virtualSessions.peekEndTarget(sessionID: requested) else {
            return sessionEndPayload(.idle)
        }
        let result = try await virtualSessions.end(sessionID: target)
        return sessionEndPayload(result)
    }

    /// Atomic handoff then end for one `session_id` (C6). Idempotent when already ended.
    func sessionClose(_ command: BrokerCommand.SessionClose) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        let content = command.content
        let project = command.project
        let pendingTasks = command.pendingTasks

        if activeSessions[sessionID] == nil {
            if let status = try virtualSessions.persistedStatus(for: sessionID) {
                if status == .ended {
                    return sessionClosePayload(
                        sessionID: sessionID,
                        ended: true,
                        alreadyEnded: true,
                        handoffFrameID: nil,
                        remainingActive: activeSessions.count
                    )
                }
            } else {
                throw BrokerSessionInactiveError.unknown(sessionID: sessionID)
            }
            // Active on disk but not live — rebind then close.
            _ = try await memory(for: sessionID)
        }

        try await validateActiveSession(sessionID)
        let frameId = try await longTermMemory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID,
            commit: false
        )
        try await recordHandoff(sessionID: sessionID, content: content)
        try await longTermMemory.flush()
        let result = try await virtualSessions.end(sessionID: sessionID)
        return sessionClosePayload(
            sessionID: sessionID,
            ended: result.ended,
            alreadyEnded: false,
            handoffFrameID: frameId,
            remainingActive: result.activeCount
        )
    }

    private func sessionClosePayload(
        sessionID: UUID,
        ended: Bool,
        alreadyEnded: Bool,
        handoffFrameID: UInt64?,
        remainingActive: Int
    ) -> AgentBrokerValue {
        let display =
            "Session \(sessionID.uuidString) \(alreadyEnded ? "already ended" : "closed"). This session active=false. Other live sessions remaining_active=\(remainingActive > 0) count=\(remainingActive)."
        var payload: [String: AgentBrokerValue] = [
            "status": .string("ok"),
            "session_id": .string(sessionID.uuidString),
            "ended": .bool(ended),
            "active": .bool(false),
            "already_ended": .bool(alreadyEnded),
            "remaining_active": .from(remainingActive > 0),
            "active_session_count": .from(remainingActive),
            "display_text": .string(display),
        ]
        if let handoffFrameID {
            payload["frame_id"] = .from(handoffFrameID)
            payload["committed"] = .bool(true)
        }
        return .object(payload)
    }

    /// `handoff_latest` + `session_start` + optional `recall` in one round-trip (Phase 2).
    func sessionOpen(_ command: BrokerCommand.SessionOpen) async throws -> AgentBrokerValue {
        let project = command.project
        let repo = command.repo
        let agentID = command.agentID
        let runID = command.runID
        let recallQuery = command.recallQuery
        let cwd = command.cwd

        let handoffPayload = try await handoffLatest(.init(project: project))
        let startPayload = try await sessionStart(
            .init(
                sessionID: nil,
                agentID: agentID,
                runID: runID,
                cwd: cwd,
                project: project,
                repo: repo
            )
        )
        let startObject = startPayload.objectValue
        let sessionID = startObject?["session_id"]?.stringValue

        // Explicit project must win over cwd inference for both project and repo.
        // Leaving a cwd-inferred repo would advertise a split identity and stamp
        // foreign wax.repo on later remembers.
        if let project,
           let sessionID,
           let uuid = UUID(uuidString: sessionID)
        {
            let trimmedProject = project.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedRepo = repo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if !trimmedProject.isEmpty {
                try virtualSessions.updateLive(uuid) { state in
                    state.manifest.project = trimmedProject
                    state.manifest.repo = trimmedRepo.isEmpty ? trimmedProject : trimmedRepo
                }
            }
        }

        let inferred = cwd.map { MemorySemantics.inferScopeContext(currentDirectoryPath: $0) } ?? scopeContext
        let resolvedProject: String?
        let resolvedRepo: String?
        if let sessionID, let uuid = UUID(uuidString: sessionID), let live = activeSessions[uuid] {
            resolvedProject = live.manifest.project ?? normalizedOrNil(project) ?? inferred.projectName
            resolvedRepo = live.manifest.repo ?? normalizedOrNil(repo) ?? inferred.repoName
        } else {
            resolvedProject = normalizedOrNil(project) ?? inferred.projectName
            resolvedRepo = normalizedOrNil(repo) ?? inferred.repoName
        }

        var recallPayload: AgentBrokerValue?
        if let recallQuery, !recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            var recallArgs: [String: AgentBrokerValue] = [
                "query": .string(recallQuery),
                "scope": .string("project"),
            ]
            if let resolvedProject { recallArgs["project"] = .string(resolvedProject) }
            if let resolvedRepo { recallArgs["repo"] = .string(resolvedRepo) }
            if let sessionID { recallArgs["session_id"] = .string(sessionID) }
            if let cwd { recallArgs["cwd"] = .string(cwd) }
            recallPayload = try await recall(try BrokerCommand.Recall.decode(BrokerArguments(recallArgs)))
        }

        var payload: [String: AgentBrokerValue] = [
            "status": .string("ok"),
            "session_id": .from(sessionID),
            "handoff": handoffPayload,
            "project": .from(resolvedProject),
            "repo": .from(resolvedRepo),
            "display_text": .string(
                "Session open. session_id=\(sessionID ?? "nil") project=\(resolvedProject ?? "nil")."
            ),
        ]
        if let startObject {
            if let resumed = startObject["resumed"] {
                payload["resumed"] = resumed
            }
            if let recovered = startObject["recovered_lease"] {
                payload["recovered_lease"] = recovered
            }
        }
        if let recallPayload {
            payload["recall"] = recallPayload
        }
        return .object(payload)
    }

    private func sessionEndPayload(_ result: VirtualSessionStore.EndResult) -> AgentBrokerValue {
        let remaining = result.activeCount
        let display: String
        switch result {
        case .idle:
            display = "No live session to end. This session active=false. Other live sessions remaining_active=false count=0."
        case .ended(let sessionID, _):
            display = "Session \(sessionID.uuidString) ended. This session active=false. Other live sessions remaining_active=\(remaining > 0) count=\(remaining)."
        }
        return .object([
            "status": .string("ok"),
            "session_id": result.sessionID.map { .string($0.uuidString) } ?? .null,
            "ended": .bool(result.ended),
            "active": .bool(false),
            "remaining_active": .from(result.remainingActive),
            "active_session_count": .from(result.activeCount),
            "display_text": .string(display),
        ])
    }

    func handoff(_ command: BrokerCommand.Handoff) async throws -> AgentBrokerValue {
        let content = command.content
        let project = command.project
        let pendingTasks = command.pendingTasks
        let sessionID = command.sessionID
        try await validateActiveSession(sessionID)
        let frameId = try await longTermMemory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID,
            commit: false
        )
        if let sessionID {
            try await recordHandoff(sessionID: sessionID, content: content)
        }
        try await longTermMemory.flush()
        return .object([
            "status": .string("ok"),
            "frame_id": .from(frameId),
            "committed": .bool(true),
            "display_text": .string("Handoff stored (frame \(frameId))."),
        ])
    }

    func handoffLatest(_ command: BrokerCommand.HandoffLatest) async throws -> AgentBrokerValue {
        let project = command.project
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

    func compactContext(_ command: BrokerCommand.CompactContext) async throws -> AgentBrokerValue {
        let query = command.query
        let tokenBudget = command.tokenBudget
        let maxItems = command.maxItems
        let mode = command.mode
        let sessionID: UUID?
        switch try resolveSessionScope(command.sessionID, policy: .requireUnambiguousWorking) {
        case .session(let resolved):
            sessionID = resolved
        case .none, .durableOnly:
            sessionID = nil
        }
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

    func markdownExport(_ command: BrokerCommand.MarkdownExport) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        let allProjects = command.allProjects
        let explicitProject = command.project
        let clientCWD = command.cwd
        try validateMarkdownExportSession(sessionID)
        let exportURL = URL(
            fileURLWithPath: AgentBrokerPathing.expandPath(command.outputDir),
            isDirectory: true
        ).standardizedFileURL
        let inferredProject: String?
        if allProjects {
            inferredProject = nil
        } else if let explicitProject {
            inferredProject = explicitProject
        } else if let sessionID, let session = activeSessions[sessionID] {
            inferredProject = session.manifest.project
        } else {
            inferredProject = writeScope(for: nil, clientCWD: clientCWD).projectName
        }
        let report = try await exportMarkdownProjection(
            outputURL: exportURL,
            sessionID: sessionID,
            project: inferredProject
        )
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

    func markdownSync(_ command: BrokerCommand.MarkdownSync) async throws -> AgentBrokerValue {
        let dryRun = command.dryRun
        let rootURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(command.rootDir), isDirectory: true).standardizedFileURL
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

    func entityUpsert(_ command: BrokerCommand.EntityUpsert) async throws -> AgentBrokerValue {
        let entityID = try await longTermMemory.upsertEntity(
            key: EntityKey(command.key),
            kind: command.kind,
            aliases: command.aliases,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "entity_id": .from(entityID.rawValue),
            "key": .string(command.key),
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

    func factRetract(_ command: BrokerCommand.FactRetract) async throws -> AgentBrokerValue {
        try await longTermMemory.retractFact(
            factId: FactRowID(rawValue: command.factID),
            atMs: command.atMs,
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "fact_id": .from(command.factID),
            "at_ms": .from(command.atMs),
            "committed": .bool(true),
        ])
    }

    func factsQuery(_ command: BrokerCommand.FactsQuery) async throws -> AgentBrokerValue {
        let limit = command.limit
        let subject = command.subject.map { EntityKey($0) }
        let predicate = command.predicate.map { PredicateKey($0) }
        let asOfMs = command.asOfMs
        let systemAsOfMs = command.systemAsOfMs
        let validAsOfMs = command.validAsOfMs
        let result = try await longTermMemory.facts(
            about: subject,
            predicate: predicate,
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

    func corpusSearch(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let query = try requireNonEmptyQuery(args)
        let recursive = try args.optionalBool("recursive") ?? true
        let rebuild = try args.optionalBool("rebuild") ?? AgentBrokerCommandSurface.corpusSearchDefaultRebuild
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let topK = try args.optionalInt("topK") ?? 10
        guard (1...Self.maxTopK).contains(topK) else {
            throw BrokerValidationError.invalid("topK must be between 1 and \(Self.maxTopK)")
        }
        let corpusNoEmbedder: Bool = switch mode {
        case .textOnly: true
        case .vectorOnly: false
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

        // Disk rebuild skips stores held under exclusive flock. Active sessions in this
        // broker process are still part of "broker-managed session history" and must be
        // searchable via the live MemoryOrchestrator already open for each session.
        let corpusHits: [BrokerCorpusMergeHit] = execution.hits.map { hit in
            let preview = agentFacingPreview(hit.previewText)
            let sourcePath = hit.metadata[BrokerCorpusMetadataKeys.sourceStorePath] ?? ""
            return BrokerCorpusMergeHit(
                frameId: hit.frameId,
                score: hit.score,
                sources: hit.sources.map(\.rawValue),
                preview: preview,
                metadata: hit.metadata,
                dedupeKey: BrokerCorpusMergeHit.makeDedupeKey(
                    sourcePath: sourcePath,
                    frameId: hit.frameId,
                    preview: preview
                )
            )
        }

        let orderedActiveSessions = activeSessions.values.sorted {
            $0.id.uuidString < $1.id.uuidString
        }
        var activeSessionHitGroups: [[BrokerCorpusMergeHit]] = []
        let longTermExecution = try await longTermMemory.searchExecution(
            query: query,
            mode: mode,
            topK: topK,
            frameFilter: nil,
            timeRange: nil
        )
        let longTermHits: [BrokerCorpusMergeHit] = longTermExecution.hits.map { hit in
            let preview = agentFacingPreview(hit.previewText)
            let storePath = longTermStoreURL.path
            var metadata = hit.metadata
            metadata[BrokerCorpusMetadataKeys.origin] = "long_term"
            metadata[BrokerCorpusMetadataKeys.sourceStorePath] = storePath
            metadata[BrokerCorpusMetadataKeys.sourceStoreName] = longTermStoreURL.lastPathComponent
            metadata[BrokerCorpusMetadataKeys.sourceFrameID] = String(hit.frameId)
            return BrokerCorpusMergeHit(
                frameId: hit.frameId,
                score: hit.score,
                sources: hit.sources.map(\.rawValue),
                preview: preview,
                metadata: metadata,
                dedupeKey: BrokerCorpusMergeHit.makeDedupeKey(
                    sourcePath: storePath,
                    frameId: hit.frameId,
                    preview: preview
                )
            )
        }
        if !longTermHits.isEmpty {
            activeSessionHitGroups.append(longTermHits)
        }
        activeSessionHitGroups.reserveCapacity(orderedActiveSessions.count + 1)
        for state in orderedActiveSessions {
            let sessionExecution = try await state.memory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: nil,
                timeRange: nil
            )
            let group: [BrokerCorpusMergeHit] = sessionExecution.hits.map { hit in
                let preview = agentFacingPreview(hit.previewText)
                let storePath = state.storeURL.path
                let metadata = BrokerCorpusHitMerge.annotateActiveSessionMetadata(
                    base: hit.metadata,
                    storePath: storePath,
                    storeName: state.storeURL.lastPathComponent,
                    frameId: hit.frameId,
                    sessionID: state.id.uuidString
                )
                return BrokerCorpusMergeHit(
                    frameId: hit.frameId,
                    score: hit.score,
                    sources: hit.sources.map(\.rawValue),
                    preview: preview,
                    metadata: metadata,
                    dedupeKey: BrokerCorpusMergeHit.makeDedupeKey(
                        sourcePath: storePath,
                        frameId: hit.frameId,
                        preview: preview
                    )
                )
            }
            activeSessionHitGroups.append(group)
        }

        let merged = BrokerCorpusHitMerge.merge(
            corpusHits: corpusHits,
            activeSessionHitGroups: activeSessionHitGroups,
            topK: topK
        )
        let activeSessionsSearched = orderedActiveSessions.count

        let results: [AgentBrokerValue] = merged.enumerated().map { index, hit in
            .object([
                "rank": .from(index + 1),
                "frameId": .from(hit.frameId),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0) }),
                "preview": .string(hit.preview),
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
                "active_sessions_searched": .from(activeSessionsSearched),
            ])
        } else {
            .object([
                "performed": .bool(false),
                "corpus_store_path": .string(corpusStoreURL.path),
                "active_sessions_searched": .from(activeSessionsSearched),
            ])
        }
        let text = results.isEmpty ? "No results." : results.map(\.debugJSONString).joined(separator: "\n")
        return .object([
            "query": .string(query),
            "topK": .from(topK),
            "requested_mode": .string(execution.requestedMode.diagnosticsSummary),
            "effective_mode": .string(execution.effectiveMode.diagnosticsSummary),
            "query_embedding_state": .string(execution.queryEmbeddingState.rawValue),
            "recursive": .from(recursive),
            "rebuild_requested": .from(rebuild),
            "build": buildValue,
            "results": .array(results),
            "display_text": .string(text),
        ])
    }

    private func renderSessionLifecycleResult(
        _ result: VirtualSessionStore.LifecycleResult
    ) -> AgentBrokerValue {
        let state = result.state
        return .object([
            "status": .string("ok"),
            "session_id": .string(state.id.uuidString),
            "agent_id": .string(state.manifest.agentID),
            "run_id": .string(state.manifest.runID),
            "project": .from(state.manifest.project),
            "repo": .from(state.manifest.repo),
            "resumed": .bool(result.resumed),
            "recovered_lease": .bool(result.recoveredLease),
            "store_path": .string(state.storeURL.path),
            "event_log_path": .string(state.eventLogURL.path),
        ])
    }

    func refreshSessionManifest(_ sessionID: UUID) async throws {
        try virtualSessions.refreshManifest(sessionID)
    }

    func appendSessionEvent(
        sessionID: UUID,
        kind: BrokerSessionEvent.Kind,
        payload: [String: String] = [:]
    ) async throws {
        try virtualSessions.appendEvent(sessionID: sessionID, kind: kind, payload: payload)
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
        let summary = MemorySemantics.summarizeCandidate(content, maxLength: 220)
        try await appendSessionEvent(
            sessionID: sessionID,
            kind: .handoff,
            payload: [
                "summary": summary,
            ]
        )
        try virtualSessions.updateLive(sessionID) { state in
            let nowMs = Self.nowMs()
            state.manifest.lastHandoffAtMs = nowMs
            state.manifest.latestHandoff = summary
            state.manifest.updatedAtMs = nowMs
        }
    }

    func recordCheckpoint(sessionID: UUID, summary: String, compactedText: String) async throws {
        try virtualSessions.updateLive(sessionID) { state in
            let nowMs = Self.nowMs()
            state.manifest.lastCheckpointAtMs = nowMs
            state.manifest.lastCompactionAtMs = nowMs
            state.manifest.checkpointCount += 1
            state.manifest.latestSummary = summary
            state.manifest.updatedAtMs = nowMs
        }
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
        mode: Memory.RetrievalMode,
        topK: Int,
        sessionID: UUID?,
        includeWorking: Bool,
        includeEpisodic: Bool,
        includeDurable: Bool
    ) async throws -> [LayeredMemoryHit] {
        try await LayeredRecall.search(
            request: LayeredRecall.SearchRequest(
                query: query,
                mode: mode,
                topK: topK,
                sessionID: sessionID,
                includeWorking: includeWorking,
                includeEpisodic: includeEpisodic,
                includeDurable: includeDurable
            ),
            stores: layeredRecallStores()
        )
    }

    func layeredRecallStores() -> LayeredRecall.Stores {
        let sessionsSnapshot = activeSessions
        let defaultScope = scopeContext
        let noEmbedderFlag = noEmbedder
        let sessionRoot = sessionRootURL

        return LayeredRecall.Stores(
            longTermMemory: longTermMemory,
            workingLane: { sessionID in
                guard let state = sessionsSnapshot[sessionID] else { return nil }
                return LayeredRecall.WorkingLane(
                    sessionID: sessionID,
                    agentID: state.manifest.agentID,
                    runID: state.manifest.runID,
                    updatedAtMs: state.manifest.updatedAtMs,
                    project: state.manifest.project,
                    repo: state.manifest.repo,
                    memory: state.memory
                )
            },
            inferWriteScope: { sessionID, clientCWD in
                if let sessionID, let state = sessionsSnapshot[sessionID] {
                    return LayeredRecall.Identity(
                        project: state.manifest.project ?? defaultScope.projectName,
                        repo: state.manifest.repo ?? defaultScope.repoName
                    )
                }
                if let clientCWD {
                    let inferred = MemorySemantics.inferScopeContext(currentDirectoryPath: clientCWD)
                    return LayeredRecall.Identity(
                        project: inferred.projectName,
                        repo: inferred.repoName
                    )
                }
                return LayeredRecall.Identity(
                    project: defaultScope.projectName,
                    repo: defaultScope.repoName
                )
            },
            preview: { text in
                Wax.dehighlightedPreviewText(text ?? "")
            },
            canonicalFrameID: { frameID, memory in
                await self.bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory)
            },
            endedManifests: {
                try BrokerSessionPersistence.listManifests(rootURL: sessionRoot)
            },
            searchEndedSession: { manifest, query, mode, topK in
                let sessionURL = URL(fileURLWithPath: manifest.storePath)
                let eventLogURL = URL(fileURLWithPath: manifest.eventLogPath)
                let execution = try await self.openAdhocMemory(
                    at: sessionURL,
                    structuredMemoryEnabled: false,
                    noEmbedder: noEmbedderFlag
                ) { memory in
                    try await memory.searchExecution(
                        query: query,
                        mode: mode,
                        topK: topK,
                        frameFilter: nil,
                        timeRange: nil
                    )
                }
                let signals = BrokerSessionPersistence.recallSignals(
                    from: try BrokerSessionPersistence.loadEvents(from: eventLogURL)
                )
                var laneHits: [LayeredRecall.EpisodicLaneHit] = []
                for hit in execution.hits {
                    let canonicalFrameID = try await self.openAdhocMemory(
                        at: sessionURL,
                        structuredMemoryEnabled: false,
                        noEmbedder: noEmbedderFlag,
                        body: { memory in
                            await self.bestEffortCanonicalDocumentFrameID(for: hit.frameId, memory: memory)
                        }
                    )
                    let signal = canonicalFrameID.flatMap { signals[$0] } ?? signals[hit.frameId]
                    laneHits.append(
                        LayeredRecall.EpisodicLaneHit(
                            frameID: hit.frameId,
                            score: hit.score,
                            previewText: hit.previewText,
                            metadata: hit.metadata,
                            explanations: hit.explanations,
                            canonicalFrameID: canonicalFrameID,
                            recallCount: signal.map(\.recallCount),
                            uniqueQueryCount: signal.map(\.uniqueQueryCount)
                        )
                    )
                }
                return laneHits
            },
            nowMs: { Self.nowMs() }
        )
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
        mode: Memory.RetrievalMode,
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
                mode: mode,
                frameFilter: nil,
                timeRange: nil,
                topK: min(4, maxItems)
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
            if short.isEmpty {
                let documents = try await state.memory.corpusSourceDocuments()
                    .sorted { lhs, rhs in
                        if lhs.timestampMs != rhs.timestampMs { return lhs.timestampMs > rhs.timestampMs }
                        return lhs.frameId > rhs.frameId
                    }
                for document in documents.prefix(min(4, maxItems)) {
                    short.append(LayeredMemoryHit(
                        reference: Self.makeMemoryReference(.working, sessionID: sessionID, frameID: document.frameId),
                        horizon: .working,
                        sessionID: sessionID,
                        agentID: state.manifest.agentID,
                        runID: state.manifest.runID,
                        frameID: document.frameId,
                        score: 0.2,
                        text: document.text,
                        preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                        metadata: document.metadata,
                        explanations: ["current session", "recent session note"],
                        timestampMs: document.timestampMs
                    ))
                }
            }
        }

        let longExecution = try await longTermMemory.recallExecution(
            query: query,
            mode: mode,
            frameFilter: nil,
            timeRange: nil,
            topK: min(4, maxItems)
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
                    mode: mode,
                    frameFilter: nil,
                    timeRange: nil,
                    topK: 2
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

    func exportMarkdownProjection(
        outputURL: URL,
        sessionID: UUID?,
        project: String? = nil
    ) async throws -> MarkdownProjectionReport {
        try FileManager.default.createDirectory(at: outputURL, withIntermediateDirectories: true)
        let memoryDir = outputURL.appendingPathComponent("memory", isDirectory: true)
        try FileManager.default.createDirectory(at: memoryDir, withIntermediateDirectories: true)
        try await longTermMemory.flush()

        let durableDocuments = try await longTermMemory.corpusSourceDocuments()
            .filter { document in
                matchesExportProject(document.metadata[MemoryMetadataKeys.project], project: project)
            }
            .sorted { lhs, rhs in
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
            .filter { matchesExportProject($0.project, project: project) }
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

        let dreamsLines = try await dreamProjectionLines(sessionID: sessionID, project: project)
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
        switch try await virtualSessions.ensureLive(sessionID) {
        case .none:
            return longTermMemory
        case .live(let memory):
            return memory
        }
    }

    func validateActiveSession(_ sessionID: UUID?) async throws {
        try await virtualSessions.validateActiveOrRebind(sessionID)
    }

    func openSessionMemory(at url: URL) async throws -> MemoryOrchestrator {
        try await virtualSessions.openExistingSessionMemory(at: url)
    }

    func openAdhocMemory<T: Sendable>(
        at url: URL,
        structuredMemoryEnabled: Bool,
        noEmbedder: Bool,
        body: (MemoryOrchestrator) async throws -> T
    ) async throws -> T {
        var config = OrchestratorConfig.default
        config.enableStructuredMemory = structuredMemoryEnabled
        config.enableAccessStatsScoring = enableAccessStatsScoring
        config.defaultScopeContext = scopeContext
        let request = try HostEmbeddingReadiness.request(
            noEmbedder: noEmbedder,
            requireVector: false,
            embedderChoice: embedderChoice,
            options: BuiltInEmbeddingProviderOptions(tuning: embedderTuning)
        )
        let memory = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: request,
            waxOptions: CommandLineEmbedderFactory.waxOptions(),
            readiness: readiness,
            factoryOverride: noEmbedder ? nil : factoryOverride
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
        try BrokerCommand.parseOptionalSessionID(args)
    }

    func writeScope(for sessionID: UUID?, clientCWD: String? = nil) -> MemoryScopeContext {
        if let sessionID, let session = activeSessions[sessionID] {
            return MemoryScopeContext(
                cwdPath: clientCWD ?? scopeContext.cwdPath,
                repoRootPath: scopeContext.repoRootPath,
                repoName: session.manifest.repo ?? scopeContext.repoName,
                projectName: session.manifest.project ?? scopeContext.projectName
            )
        }
        if let clientCWD {
            return MemorySemantics.inferScopeContext(currentDirectoryPath: clientCWD)
        }
        return scopeContext
    }

    func agentFacingPreview(_ text: String?) -> String {
        Wax.dehighlightedPreviewText(text ?? "")
    }

    func matchesExportProject(_ value: String?, project: String?) -> Bool {
        guard let project else { return true }
        if let value, !value.isEmpty, value != project {
            return false
        }
        return true
    }

    func resolveSessionID(_ explicit: UUID?) throws -> UUID? {
        if let explicit { return explicit }
        if activeSessions.count == 1 {
            return activeSessions.keys.first
        }
        return nil
    }

    enum SessionResolutionPolicy: Sendable, Equatable {
        /// Do not infer a working session from live sessions.
        case unscoped
        /// Infer the sole live session; throw if more than one is live.
        case requireUnambiguousWorking
        /// Infer the sole live session; if more than one is live, search durable only.
        case durableOnlyWhenAmbiguous
    }

    enum ResolvedSessionScope: Sendable, Equatable {
        case session(UUID)
        case durableOnly
        case none
    }

    func resolveSessionScope(
        _ explicit: UUID?,
        policy: SessionResolutionPolicy
    ) throws -> ResolvedSessionScope {
        if let explicit { return .session(explicit) }
        switch policy {
        case .unscoped:
            return .none
        case .requireUnambiguousWorking:
            switch activeSessions.count {
            case 0:
                return .none
            case 1:
                return .session(activeSessions.keys.first!)
            default:
                throw BrokerValidationError.invalid("session_id is required when more than one session is active")
            }
        case .durableOnlyWhenAmbiguous:
            switch activeSessions.count {
            case 0:
                return .none
            case 1:
                return .session(activeSessions.keys.first!)
            default:
                return .durableOnly
            }
        }
    }

    func requireNonEmptyQuery(_ args: BrokerArguments) throws -> String {
        try BrokerCommand.requireNonEmptyQuery(args)
    }

    typealias ParsedSearchFilters = BrokerCommand.ParsedSearchFilters

    func parseSearchFilters(_ args: BrokerArguments) throws -> ParsedSearchFilters {
        try BrokerCommand.parseSearchFilters(args)
    }

    func parseRecallMode(_ args: BrokerArguments) throws -> Memory.RetrievalMode? {
        try BrokerCommand.parseRecallMode(args)
    }

    func parseSearchMode(
        modeRaw: String?,
        alpha: Double?
    ) throws -> Memory.RetrievalMode {
        try BrokerCommand.parseSearchMode(modeRaw: modeRaw, alpha: alpha)
    }

    func validatedHybridAlpha(_ alpha: Double) throws -> Float {
        try BrokerCommand.validatedHybridAlpha(alpha)
    }

    func coerceMetadata(_ object: [String: AgentBrokerValue]?) throws -> [String: String] {
        try BrokerCommand.coerceMetadata(object)
    }

    func parseWriteSemantics(_ args: BrokerArguments) throws -> MemoryWriteSemantics {
        try BrokerCommand.parseWriteSemantics(args)
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

    func promotionSettingsMerging(_ command: BrokerCommand.SessionSynthesize) -> BrokerPromotionSettings {
        BrokerPromotionSettings(
            minimumConfidence: command.minimumConfidence ?? promotionSettings.minimumConfidence,
            minimumRecallCount: command.minimumRecallCount ?? promotionSettings.minimumRecallCount,
            maxCandidates: command.maxCandidates ?? promotionSettings.maxCandidates
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
        LayeredRecall.makeMemoryReference(horizon, sessionID: sessionID, frameID: frameID)
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

/// A structured inactive-session failure for broker hops.
///
/// Codes are stable wire values (`session_ended`, `session_unknown`, `session_unreadable`,
/// `session_not_live`). Construct only via the typed factories — never invent a new code
/// at a call site. UUID rebind never steals a different session via `agent_id`+`run_id`.
package struct BrokerSessionInactiveError: LocalizedError, Sendable, Equatable {
    /// Stable machine-readable failure code for MCP/broker payloads.
    package let code: String
    /// Whether the agent may recover by retrying the same `session_id` (always `false` today).
    package let resumable: Bool
    /// Human-readable explanation suitable for tool error text.
    package let reason: String

    package var errorDescription: String? {
        "\(reason) (code=\(code), resumable=\(resumable))"
    }

    /// Returns the structured broker/MCP error object for this failure.
    package func brokerPayload() -> AgentBrokerValue {
        .object([
            "code": .string(code),
            "resumable": .bool(resumable),
            "reason": .string(reason),
        ])
    }

    /// Creates an error for a session whose manifest is already `.ended`.
    package static func ended(sessionID: UUID) -> BrokerSessionInactiveError {
        BrokerSessionInactiveError(
            code: "session_ended",
            resumable: false,
            reason: "session_id \(sessionID.uuidString) has ended and cannot be rebound; start a new session"
        )
    }

    /// Creates an error when no manifest exists for `sessionID`.
    package static func unknown(sessionID: UUID) -> BrokerSessionInactiveError {
        BrokerSessionInactiveError(
            code: "session_unknown",
            resumable: false,
            reason: "session_id \(sessionID.uuidString) is unknown in this broker; call session_start"
        )
    }

    /// Creates an error when the session manifest cannot be read.
    package static func unreadable(sessionID: UUID, detail: String) -> BrokerSessionInactiveError {
        BrokerSessionInactiveError(
            code: "session_unreadable",
            resumable: false,
            reason: "session_id \(sessionID.uuidString) manifest unreadable: \(detail)"
        )
    }

    /// Creates an error when `sessionID` is absent from this process's live map and the
    /// caller intentionally did not rebind (``VirtualSessionStore/lookup(_:)`` paths).
    package static func notLive(sessionID: UUID) -> BrokerSessionInactiveError {
        BrokerSessionInactiveError(
            code: "session_not_live",
            resumable: false,
            reason: "session_id \(sessionID.uuidString) is not active in this broker process; call session_start or session_resume"
        )
    }

    private init(code: String, resumable: Bool, reason: String) {
        self.code = code
        self.resumable = resumable
        self.reason = reason
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
