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
    let endedSessions: DiskEndedSessionStore
    private let commandMutex = AsyncMutex()
    // A remember may wait for deferred embedding readiness. Keep that wait
    // from blocking unrelated reads while still serializing concurrent writes.
    private let rememberMutex = AsyncMutex()
    var activeSessions: [UUID: SessionState] {
        virtualSessions.live
    }

    package init(
        storePath: String,
        sessionRootPath: String,
        noEmbedder: Bool,
        embedderChoice: String,
        requireVector: Bool,
        enableAccessStatsScoring: Bool = true,
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
        self.endedSessions = DiskEndedSessionStore(
            sessionRootURL: sessionRootURL,
            noEmbedder: noEmbedder,
            embedderChoice: embedderChoice,
            enableAccessStatsScoring: enableAccessStatsScoring,
            scopeContext: scopeContext,
            embedderTuning: embedderTuning,
            readiness: readiness,
            factoryOverride: factoryOverride
        )
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
        try await commandMutex.withLock { [self] in
            try await rememberMutex.withLock { [self] in
                await virtualSessions.closeAll()
                try await longTermMemory.flush()
                try await longTermMemory.close()
            }
        }
    }

    package func handle(_ request: AgentBrokerRequest) async -> AgentBrokerResponse {
        if Self.isTaskStateMigrationRequest(request) {
            // Migration snapshots and mutates a copy of the long-term store. It
            // must hold both locks: remember intentionally uses its own mutex so
            // deferred embedding waits do not block reads, but a migration must
            // not race that writer while hashing or copying the source.
            return await commandMutex.withLock { [self] in
                await rememberMutex.withLock { [self] in
                    await handleSerialized(request)
                }
            }
        }
        // Wait for MiniLM outside commandMutex so a cold first recall does not
        // stall unrelated commands the way remember already uses rememberMutex.
        // Do not wait again inside recall/search — a timeout here must not
        // become a second 30s hold on the serialized path.
        if Self.isQueryEmbedderWaitRequest(request) {
            await awaitQueryEmbedderIfNeeded(memory: longTermMemory)
        }
        let mutex = Self.isRememberRequest(request) ? rememberMutex : commandMutex
        return await mutex.withLock { [self] in
            await handleSerialized(request)
        }
    }

    private static func isQueryEmbedderWaitRequest(_ request: AgentBrokerRequest) -> Bool {
        guard let command = try? BrokerCommand.decode(
            command: request.command,
            arguments: request.arguments
        ) else {
            return false
        }
        switch command {
        case .recall, .search:
            return true
        case .sessionOpen(let open):
            let query = open.recallQuery?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !query.isEmpty
        default:
            return false
        }
    }

    private static func isRememberRequest(_ request: AgentBrokerRequest) -> Bool {
        guard let command = try? BrokerCommand.decode(
            command: request.command,
            arguments: request.arguments
        ) else {
            return false
        }
        if case .remember = command {
            return true
        }
        return false
    }

    private static func isTaskStateMigrationRequest(_ request: AgentBrokerRequest) -> Bool {
        guard let command = try? BrokerCommand.decode(
            command: request.command,
            arguments: request.arguments
        ) else {
            return false
        }
        if case .taskStateMigrate = command {
            return true
        }
        return false
    }

    private func handleSerialized(_ request: AgentBrokerRequest) async -> AgentBrokerResponse {
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
            case .taskStateMigrate(let command):
                payload = try await taskStateMigrate(command)
                shouldExit = false
            case .factsQuery(let command):
                payload = try await factsQuery(command)
                shouldExit = false
            case .memoryPromote(let command), .promote(let command):
                payload = try await memoryPromote(command)
                shouldExit = false
            case .factAssert(let command):
                payload = try await factAssert(command)
                shouldExit = false
            case .corpusSearch(let command):
                payload = try await corpusSearch(command)
                shouldExit = false
            case .memoryMaintain(let command):
                payload = try await memoryMaintain(command)
                shouldExit = false
            }

            return AgentBrokerResponse.success(
                id: request.id,
                payload: payload,
                shouldExit: shouldExit
            )
        } catch let error as BrokerSessionInactiveError {
            return AgentBrokerResponse.failure(
                id: request.id,
                payload: error.brokerPayload(),
                message: error.localizedDescription
            )
        } catch {
            return AgentBrokerResponse.failure(
                id: request.id,
                message: error.localizedDescription
            )
        }
    }
}

extension AgentBrokerService {
    /// Forwarded from ``BrokerLimits`` for MCP/CLI callers that already import the service.
    package static let maxContentBytes = BrokerLimits.maxContentBytes
    static let maxGraphLimit = BrokerLimits.maxGraphLimit

    typealias MemoryHorizon = LayeredRecall.Horizon
    typealias LayeredMemoryHit = LayeredRecall.Hit
    typealias MemoryReference = MemoryID

    struct MarkdownProjectionReport {
        var memoryMarkdownPath: String
        var dailyNotePaths: [String]
        var dreamsPath: String?
        var handoffSummaryPath: String?
    }

    func remember(_ command: BrokerCommand.Remember) async throws -> AgentBrokerValue {
        let sessionID = command.sessionID
        // Rebind before writeScope so session manifest project/repo stamp correctly after a broker hop.
        if let sessionID {
            _ = try await memory(for: sessionID)
        }
        let metadata = try MemorySemantics.validatedWriteMetadata(
            metadata: command.metadata,
            destination: command.destination,
            activeSession: sessionID != nil,
            inferredScope: writeScope(for: sessionID, clientCWD: command.cwd),
            nowMs: Self.nowMs()
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
            sessionID: sessionID
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
        sessionID: UUID?
    ) async throws -> AgentBrokerValue {
        let rememberResult = try await memory.remember(content, metadata: metadata)
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

        let scope = sessionID == nil ? "durable" : "session"
        let memoryID = sessionID.map {
            "working:\($0.uuidString):\(rememberResult.frameId)"
        } ?? "durable:\(rememberResult.frameId)"
        return .object([
            "status": .string("ok"),
            "frame_id": .from(rememberResult.frameId),
            "memory_id": .string(memoryID),
            "framesAdded": .from(rememberResult.framesAdded),
            "frameCount": .from(after.frameCount),
            "pendingFrames": .from(after.pendingFrames),
            "scope": .string(scope),
            "session_id": .from(sessionID?.uuidString),
            "memory_type": .string(metadata[MemoryMetadataKeys.type] ?? MemoryType.note.rawValue),
            "durability": .string(metadata[MemoryMetadataKeys.durability] ?? MemoryDurability.working.rawValue),
            "deduplicated": .bool(rememberResult.deduplicated),
            "searchable": .bool(rememberResult.searchable),
            "display_text": .string("Remembered. \(rememberResult.framesAdded) frame(s) added (\(after.frameCount) total, \(after.pendingFrames) pending)."),
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
        // Session stores attach on their own follow task. After MiniLM is ready,
        // wait for that attach here so a session-scoped first recall is hybrid.
        // Skip when long-term is still loading so a timeout does not become a
        // second 30s hold on commandMutex.
        if let sessionID = parsedFilters.sessionId,
           await longTermMemory.isQueryEmbedderReady() {
            await awaitQueryEmbedderIfNeeded(memory: try await memory(for: sessionID))
        }
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
            let kind = Self.itemKindLabel(hit.kind)
            lines.append("\(index + 1). [\(kind)] frame=\(hit.frameID) score=\(String(format: "%.4f", hit.score)) \(hit.text)")
        }

        let results: [AgentBrokerValue] = result.hits.enumerated().map { index, hit in
            .object([
                "rank": .from(index + 1),
                "kind": .string(Self.itemKindLabel(hit.kind)),
                "frameId": .from(hit.frameID),
                "score": .double(Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
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
            await sessionMemory.recordImpressions(
                frameIds: result.hits.filter { $0.horizon == .working }.map(\.frameID)
            )
        }
        await longTermMemory.recordImpressions(
            frameIds: result.hits.filter { $0.horizon == .durable }.map(\.frameID)
        )

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
        if let warning = Self.retrievalDowngradeWarning(
            requestedMode: result.requestedModeSummary,
            effectiveMode: result.effectiveModeSummary,
            queryEmbeddingState: result.queryEmbeddingState
        ) {
            payload["warning"] = .string(warning)
        }
        if let scopeMissMessage = result.scopeMissMessage {
            payload["scope_miss_message"] = .string(scopeMissMessage)
        }
        return .object(payload)
    }

    func search(_ command: BrokerCommand.Search) async throws -> AgentBrokerValue {
        let query = command.query
        let mode = command.mode
        let topK = command.topK
        let parsedFilters = command.filters
        let memory = try await memory(for: parsedFilters.sessionId)
        if parsedFilters.sessionId != nil, await longTermMemory.isQueryEmbedderReady() {
            await awaitQueryEmbedderIfNeeded(memory: memory)
        }
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
        var payload: [String: AgentBrokerValue] = [
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
        ]
        if let warning = Self.retrievalDowngradeWarning(
            requestedMode: execution.requestedMode.diagnosticsSummary,
            effectiveMode: execution.effectiveMode.diagnosticsSummary,
            queryEmbeddingState: execution.queryEmbeddingState.rawValue
        ) {
            payload["warning"] = .string(warning)
        }
        return .object(payload)
    }

    func memorySearch(_ command: BrokerCommand.MemorySearch) async throws -> AgentBrokerValue {
        let query = command.query
        let topK = command.topK
        let mode = command.mode
        let requested = command.horizons
        let sessionLanes = requested.intersection([.working, .episodic])
        let policy: SessionResolutionPolicy
        if sessionLanes.isEmpty {
            policy = .unscoped
        } else {
            policy = requested.contains(.durable) ? .durableOnlyWhenAmbiguous : .requireUnambiguousWorking
        }
        let scope = try resolveSessionScope(command.sessionID, policy: policy)
        let sessionID: UUID?
        if case .session(let resolved) = scope {
            sessionID = resolved
        } else {
            sessionID = nil
        }
        let horizons = Self.scopedHorizons(scope: scope, requested: requested)
        let hits = try await layeredMemorySearch(
            query: query,
            mode: mode,
            topK: topK,
            sessionID: sessionID,
            horizons: horizons
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
            nowMs: Self.nowMs()
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
                nowMs: Self.nowMs()
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

    func memoryHealth() async throws -> AgentBrokerValue {
        let documents = try await longTermMemory.corpusSourceDocuments()
        let accessStats = await longTermMemory.accessStatsSnapshot()
        let facts = try? await longTermMemory.facts(limit: Self.maxGraphLimit)
        let report = BrokerMemoryInsights.healthReport(
            documents: documents,
            accessStats: accessStats,
            facts: facts
        )
        let sessionDisk = SessionReclaim.diskStats(
            rootURL: sessionRootURL,
            manifests: (try? BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)) ?? [],
            liveIDs: Set(activeSessions.keys),
            nowMs: Self.nowMs()
        )
        return .object([
            "total_documents": .from(report.totalDocuments),
            "typed_counts": .object(report.typedCounts.mapValues { .from($0) }),
            "expired_frame_ids": .array(report.expiredFrameIds.map(AgentBrokerValue.from)),
            "stale_frame_ids": .array(report.staleFrameIds.map(AgentBrokerValue.from)),
            "low_hit_frame_ids": .array(report.lowHitFrameIds.map(AgentBrokerValue.from)),
            "quarantine_candidate_ids": .array(report.quarantineCandidateIds.map(AgentBrokerValue.from)),
            "reclaimable_session_ids": .array(sessionDisk.reclaimableSessionIDs.map { .string($0.uuidString) }),
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
        if let sessionID = command.sessionID {
            _ = try await memory(for: sessionID)
        }
        let metadata = try MemorySemantics.validatedWriteMetadata(
            metadata: command.metadata,
            destination: command.destination,
            activeSession: command.sessionID != nil,
            inferredScope: writeScope(for: command.sessionID, clientCWD: command.cwd),
            nowMs: Self.nowMs()
        )
        try validateDurableWriteContent(content: command.content, metadata: metadata)

        let subject = command.subject
        let predicate = command.predicate
        let kind = command.kind
        let aliases = command.aliases
        let parsedObject = try command.object.map { try parseFactValue($0) }

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
        let sessionDisk = SessionReclaim.diskStats(
            rootURL: sessionRootURL,
            manifests: (try? BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)) ?? [],
            liveIDs: Set(activeSessions.keys),
            nowMs: Self.nowMs()
        )

        return .object([
            "frameCount": .from(stats.frameCount),
            "pendingFrames": .from(stats.pendingFrames),
            "framesWithoutVectors": .from(stats.framesWithoutVectors),
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
            "sessions": sessionDisk.asBrokerValue(),
        ])
    }

    package func prewarmEmbedder() async {
        guard !noEmbedder else { return }
        await awaitQueryEmbedderIfNeeded(memory: longTermMemory)
        _ = try? await longTermMemory.searchExecution(
            query: "wax",
            mode: .hybrid(alpha: 0.5),
            topK: 1,
            frameFilter: nil,
            timeRange: nil
        )
        guard await longTermMemory.isQueryEmbedderReady() else { return }
        _ = try? await longTermMemory.backfillUnembedded()
    }

    /// Suspends while MiniLM (or the configured provider) is `.loading`, matching remember.
    /// Missing providers and wait timeouts do not throw — callers degrade to text + warning.
    func awaitQueryEmbedderIfNeeded(memory: MemoryOrchestrator) async {
        guard !noEmbedder else { return }
        let stats = await memory.runtimeStats()
        guard stats.vectorSearchEnabled, await memory.shouldDeferRememberUntilEmbedderReady() else {
            return
        }
        try? await Self.awaitRememberReady(memory: memory, timeout: .seconds(30))
    }

    /// Compact JSON warning when hybrid was requested but the query ran as text.
    package static func retrievalDowngradeWarning(
        requestedMode: String,
        effectiveMode: String,
        queryEmbeddingState: String
    ) -> String? {
        let requestedHybrid = requestedMode.hasPrefix("hybrid")
        let usedText = effectiveMode == "text" || effectiveMode.hasPrefix("text")
        guard requestedHybrid, usedText else { return nil }
        let reason: String
        switch RAGContext.QueryEmbeddingState(rawValue: queryEmbeddingState) {
        case .timeout:
            reason = "embedder timeout"
        case .circuitOpen:
            reason = "embedder circuit open"
        case .failed:
            reason = "embedder failed"
        case .vectorDisabled:
            reason = "vector search disabled"
        case .noEmbedder, .notRequested, .available, .none:
            reason = "embedder missing"
        }
        return "WARNING: hybrid requested, \(reason), used text"
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
        } ?? MemoryScopeContext()
        if explicitProject != nil || explicitRepo != nil {
            inferredScope = MemoryScopeContext(
                cwdPath: inferredScope.cwdPath,
                repoRootPath: inferredScope.repoRootPath,
                repoName: explicitRepo ?? explicitProject ?? inferredScope.repoName,
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
        let result = try await virtualSessions.end(sessionID: target, afterFlush: makeHarvestCallback())
        return sessionEndPayload(result, sessionID: target)
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
                    let harvest = await harvestPersistedSession(sessionID: sessionID)
                    return sessionClosePayload(
                        sessionID: sessionID,
                        ended: true,
                        alreadyEnded: true,
                        handoffFrameID: nil,
                        remainingActive: activeSessions.count,
                        harvest: harvest
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
        let result = try await virtualSessions.end(sessionID: sessionID, afterFlush: makeHarvestCallback())
        return sessionClosePayload(
            sessionID: sessionID,
            ended: result.ended,
            alreadyEnded: false,
            handoffFrameID: frameId,
            remainingActive: result.activeCount,
            harvest: loadHarvestReport(sessionID: sessionID)
        )
    }

    private func sessionClosePayload(
        sessionID: UUID,
        ended: Bool,
        alreadyEnded: Bool,
        handoffFrameID: UInt64?,
        remainingActive: Int,
        harvest: SessionHarvest.Report = .skipped,
        reclaimed: Bool = false
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
            "harvested": .bool(harvest.harvested),
            "promoted_count": .from(harvest.promotedCount),
            "reclaim_after_ms": .from(harvest.reclaimAfterMs),
            "reclaimed": .bool(reclaimed),
            "display_text": .string(display),
        ]
        if let handoffFrameID {
            payload["frame_id"] = .from(handoffFrameID)
            payload["committed"] = .bool(true)
        }
        payload.merge(harvestErrorPayload(harvest)) { _, new in new }
        return .object(payload)
    }

    /// `handoff_latest` + `session_start` + optional `recall` in one round-trip (Phase 2).
    ///
    /// The handoff is intentionally projected to a bounded bootstrap shape.
    /// Callers that need frame metadata or the complete pending-task list can
    /// use `handoff_latest` explicitly.
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

        let inferred = cwd.map { MemorySemantics.inferScopeContext(currentDirectoryPath: $0) } ?? MemoryScopeContext()
        let resolvedProject: String?
        let resolvedRepo: String?
        if let sessionID, let uuid = UUID(uuidString: sessionID), let live = activeSessions[uuid] {
            resolvedProject = live.manifest.project ?? BrokerCommand.normalizedOrNil(project) ?? inferred.projectName
            resolvedRepo = live.manifest.repo ?? BrokerCommand.normalizedOrNil(repo) ?? inferred.repoName
        } else {
            resolvedProject = BrokerCommand.normalizedOrNil(project) ?? inferred.projectName
            resolvedRepo = BrokerCommand.normalizedOrNil(repo) ?? inferred.repoName
        }

        var recallPayload: AgentBrokerValue?
        if let recallQuery, !recallQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            if let sessionID,
               let uuid = UUID(uuidString: sessionID),
               await longTermMemory.isQueryEmbedderReady() {
                await awaitQueryEmbedderIfNeeded(memory: try await memory(for: uuid))
            }
            var recallArgs: [String: AgentBrokerValue] = [
                "query": .string(recallQuery),
                "scope": .string("project"),
                "limit": .from(5),
            ]
            if let resolvedProject { recallArgs["project"] = .string(resolvedProject) }
            if let resolvedRepo { recallArgs["repo"] = .string(resolvedRepo) }
            if let sessionID { recallArgs["session_id"] = .string(sessionID) }
            if let cwd { recallArgs["cwd"] = .string(cwd) }
            recallPayload = try await recall(try BrokerCommand.Recall.decode(BrokerArguments(recallArgs)))
        }

        // Keep the bootstrap wire shape deliberately small.  Callers that
        // need project/repo, lease state, or the full handoff can issue the
        // corresponding explicit read after they have the session UUID.
        var payload: [String: AgentBrokerValue] = [
            "session_id": .from(sessionID),
            "handoff": try await Self.compactSessionOpenHandoff(handoffPayload),
        ]
        if let recallPayload {
            payload["recall"] = recallPayload
            if let warning = recallPayload.objectValue?["warning"] {
                payload["warning"] = warning
            }
        }
        return .object(payload)
    }

    private static func compactSessionOpenHandoff(_ value: AgentBrokerValue) async throws -> AgentBrokerValue {
        guard let handoff = value.objectValue,
              handoff["found"]?.boolValue == true
        else {
            return value
        }

        let originalContent = handoff["content"]?.stringValue ?? ""
        let byteLimitedContent = utf8Prefix(
            originalContent,
            maxBytes: BrokerLimits.maxSessionOpenHandoffContentBytes
        )
        let tokenCounter = try await TokenCounter.shared()
        let compactContent = await Self.tokenLimitedPrefix(
            byteLimitedContent,
            counter: tokenCounter,
            maxTokens: BrokerLimits.maxSessionOpenHandoffContentTokens
        )
        let contentTruncated = compactContent != originalContent

        let originalTasks = handoff["pending_tasks"]?.arrayValue?.compactMap(\.stringValue) ?? []
        let boundedTasks = originalTasks
            .prefix(BrokerLimits.maxSessionOpenPendingTasks)
            .map { task in
                utf8Prefix(task, maxBytes: BrokerLimits.maxSessionOpenPendingTaskBytes)
            }
        let pendingTaskTruncations = zip(
            originalTasks.prefix(BrokerLimits.maxSessionOpenPendingTasks),
            boundedTasks
        ).reduce(into: 0) { count, task in
            if task.0 != task.1 { count += 1 }
        }
        let omittedTaskCount = max(0, originalTasks.count - boundedTasks.count)
        let anyTruncated = contentTruncated || pendingTaskTruncations > 0 || omittedTaskCount > 0

        return .object([
            "found": .bool(true),
            "content": .string(compactContent),
            "pending_tasks": .array(boundedTasks.map { .string($0) }),
            "truncated": .bool(anyTruncated),
            "content_truncated": .bool(contentTruncated),
            "pending_tasks_truncated": .from(pendingTaskTruncations),
            "pending_tasks_omitted": .from(omittedTaskCount),
            "content_bytes": .from(compactContent.utf8.count),
            "content_tokens": .from(await tokenCounter.count(compactContent)),
        ])
    }

    /// Return a prefix without splitting a user-visible Unicode grapheme.
    private static func utf8Prefix(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        var bytes = 0
        var result = String()
        result.reserveCapacity(min(text.utf8.count, maxBytes))
        for character in text {
            let characterBytes = String(character).utf8.count
            guard bytes + characterBytes <= maxBytes else { break }
            result.append(character)
            bytes += characterBytes
        }
        return result
    }

    /// Bound `text` to `maxTokens` while remaining a grapheme prefix of `text`.
    ///
    /// Encode the full string once, then take a proportional character prefix
    /// and shrink by graphemes if that prefix is still over budget. This avoids
    /// re-tokenizing every binary-search midpoint on `TokenCounter.shared()`,
    /// which serializes orchestrator chunking and MCP remember/recall.
    private static func tokenLimitedPrefix(
        _ text: String,
        counter: TokenCounter,
        maxTokens: Int
    ) async -> String {
        guard maxTokens > 0, !text.isEmpty else { return "" }
        let fullCount = await counter.count(text)
        if fullCount <= maxTokens { return text }

        let characters = Array(text)
        var high = max(1, min(characters.count, (maxTokens * characters.count) / fullCount))
        var candidate = String(characters.prefix(high))
        var candidateCount = await counter.count(candidate)
        while candidateCount > maxTokens && high > 1 {
            high = max(1, (high * 3) / 4)
            candidate = String(characters.prefix(high))
            candidateCount = await counter.count(candidate)
        }
        return candidateCount <= maxTokens ? candidate : ""
    }

    private func sessionEndPayload(
        _ result: VirtualSessionStore.EndResult,
        sessionID: UUID? = nil,
        reclaimed: Bool = false
    ) -> AgentBrokerValue {
        let remaining = result.activeCount
        let harvest = sessionID.map { loadHarvestReport(sessionID: $0) } ?? .skipped
        let display: String
        switch result {
        case .idle:
            display = "No live session to end. This session active=false. Other live sessions remaining_active=false count=0."
        case .ended(let endedID, _):
            display = "Session \(endedID.uuidString) ended. This session active=false. Other live sessions remaining_active=\(remaining > 0) count=\(remaining)."
        }
        return .object([
            "status": .string("ok"),
            "session_id": result.sessionID.map { .string($0.uuidString) } ?? .null,
            "ended": .bool(result.ended),
            "active": .bool(false),
            "remaining_active": .from(result.remainingActive),
            "active_session_count": .from(result.activeCount),
            "harvested": .bool(harvest.harvested),
            "promoted_count": .from(harvest.promotedCount),
            "reclaim_after_ms": .from(harvest.reclaimAfterMs),
            "reclaimed": .bool(reclaimed),
            "display_text": .string(display),
        ].merging(harvestErrorPayload(harvest)) { _, new in new })
    }

    private func harvestErrorPayload(_ harvest: SessionHarvest.Report) -> [String: AgentBrokerValue] {
        guard let error = harvest.error, !error.isEmpty else { return [:] }
        return ["harvest_error": .string(error)]
    }

    private func makeHarvestCallback() -> @Sendable (VirtualSessionStore.SessionState) async -> SessionHarvest.Report {
        let longTerm = longTermMemory
        let settings = promotionSettings
        let scope = scopeContext
        return { state in
            let events = (try? BrokerSessionPersistence.loadEvents(from: state.eventLogURL)) ?? []
            return await SessionHarvest.run(
                sessionMemory: state.memory,
                longTermMemory: longTerm,
                sessionID: state.id,
                manifest: state.manifest,
                events: events,
                scope: scope,
                settings: settings,
                nowMs: AgentBrokerService.nowMs()
            )
        }
    }

    private func loadHarvestReport(sessionID: UUID) -> SessionHarvest.Report {
        guard let manifest = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ) else {
            return .skipped
        }
        let immediate = manifest.reclaimAfterMs == manifest.harvestedAtMs
        return SessionHarvest.Report(
            harvested: manifest.harvestedAtMs != nil,
            promotedCount: manifest.promotedCount,
            leftoverDocumentCount: immediate ? 0 : 1,
            leftoverLockedCount: 0,
            reclaimAfterMs: manifest.reclaimAfterMs,
            error: manifest.harvestError,
            alreadyHarvested: manifest.harvestedAtMs != nil
        )
    }

    private func harvestPersistedSession(sessionID: UUID) async -> SessionHarvest.Report {
        guard let manifest = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ) else {
            return .skipped
        }
        if manifest.harvestedAtMs != nil, manifest.harvestError == nil {
            return loadHarvestReport(sessionID: sessionID)
        }
        let events = (try? BrokerSessionPersistence.loadEvents(
            from: URL(fileURLWithPath: manifest.eventLogPath)
        )) ?? []
        let storeURL = URL(fileURLWithPath: manifest.storePath)
        let report: SessionHarvest.Report
        if FileManager.default.fileExists(atPath: storeURL.path) {
            do {
                let longTerm = longTermMemory
                let scope = scopeContext
                let settings = promotionSettings
                let now = Self.nowMs()
                report = try await endedSessions.withMemory(at: storeURL) { memory in
                    await SessionHarvest.run(
                        sessionMemory: memory,
                        longTermMemory: longTerm,
                        sessionID: sessionID,
                        manifest: manifest,
                        events: events,
                        scope: scope,
                        settings: settings,
                        nowMs: now
                    )
                }
            } catch {
                report = SessionHarvest.Report(
                    harvested: false,
                    promotedCount: 0,
                    leftoverDocumentCount: 0,
                    leftoverLockedCount: 0,
                    reclaimAfterMs: nil,
                    error: error.localizedDescription,
                    alreadyHarvested: false
                )
            }
        } else {
            report = SessionHarvest.Report(
                harvested: true,
                promotedCount: 0,
                leftoverDocumentCount: 0,
                leftoverLockedCount: 0,
                reclaimAfterMs: Self.nowMs(),
                error: nil,
                alreadyHarvested: false
            )
        }
        _ = try? virtualSessions.persistHarvestToDisk(
            sessionID: sessionID,
            report: report,
            markEnded: true
        )
        return report
    }

    @discardableResult
    private func reclaimSessionIfDue(sessionID: UUID, force: Bool = false) async -> Bool {
        guard let manifest = try? BrokerSessionPersistence.loadManifest(
            rootURL: sessionRootURL,
            sessionID: sessionID
        ) else {
            return false
        }
        let now = Self.nowMs()
        guard SessionReclaim.isReclaimable(manifest: manifest, nowMs: now, force: force) else {
            return false
        }
        do {
            _ = try SessionReclaim.unlink(
                manifest: manifest,
                sessionRootURL: sessionRootURL,
                nowMs: now
            )
            return true
        } catch {
            return false
        }
    }

    func memoryMaintain(_ command: BrokerCommand.MemoryMaintain) async throws -> AgentBrokerValue {
        let apply = command.apply
        let force = command.forceReclaim
        let now = Self.nowMs()
        let manifests = (try? BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)) ?? []
        let liveIDs = Set(activeSessions.keys)
        var zombiesToEnd = 0
        var harvests = 0
        var unlinks = 0
        var quarantineSoftDeletes = 0

        var zombieIDs = Set<UUID>()
        for manifest in manifests where SessionReclaim.isZombie(manifest: manifest, liveIDs: liveIDs, nowMs: now) {
            zombiesToEnd += 1
            zombieIDs.insert(manifest.sessionID)
            harvests += 1
            if apply {
                _ = await harvestPersistedSession(sessionID: manifest.sessionID)
            }
        }

        let afterZombies = (try? BrokerSessionPersistence.listManifests(rootURL: sessionRootURL)) ?? []
        for manifest in afterZombies {
            if !zombieIDs.contains(manifest.sessionID),
               manifest.status == .ended,
               manifest.harvestedAtMs == nil || manifest.harvestError != nil {
                harvests += 1
                if apply {
                    _ = await harvestPersistedSession(sessionID: manifest.sessionID)
                }
            }
            let current = (try? BrokerSessionPersistence.loadManifest(
                rootURL: sessionRootURL,
                sessionID: manifest.sessionID
            )) ?? manifest
            if SessionReclaim.isReclaimable(manifest: current, nowMs: now, force: force) {
                unlinks += 1
                if apply {
                    if await reclaimSessionIfDue(sessionID: current.sessionID, force: force) {
                        // counted
                    }
                }
            }
        }

        let documents = try await longTermMemory.corpusSourceDocuments()
        let accessStats = await longTermMemory.accessStatsSnapshot()
        let quarantineIDs = documents.compactMap { document -> UInt64? in
            MemoryRetention.isQuarantineCandidate(
                metadata: document.metadata,
                stats: accessStats[document.frameId],
                nowMs: now
            ) ? document.frameId : nil
        }
        quarantineSoftDeletes = quarantineIDs.count
        if apply {
            for frameId in quarantineIDs {
                try await longTermMemory.delete(frameId: frameId)
            }
            if !quarantineIDs.isEmpty {
                try await longTermMemory.flush()
            }
        }

        let display = apply
            ? "Maintain apply: zombies=\(zombiesToEnd) harvests=\(harvests) unlinks=\(unlinks) quarantine=\(quarantineSoftDeletes)"
            : "Maintain dry-run: zombies=\(zombiesToEnd) harvests=\(harvests) unlinks=\(unlinks) quarantine=\(quarantineSoftDeletes)"
        return .object([
            "status": .string("ok"),
            "dry_run": .bool(!apply),
            "zombies_to_end": .from(zombiesToEnd),
            "harvests": .from(harvests),
            "unlinks": .from(unlinks),
            "quarantine_soft_deletes": .from(quarantineSoftDeletes),
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
        let counter = try await TokenCounter.shared()
        let tokenizer = CompactAssembly.Tokenizer(
            count: { text in await counter.count(text) },
            truncate: { text, maxTokens in await counter.truncate(text, maxTokens: maxTokens) }
        )
        let assembled = try await CompactAssembly.assemble(
            request: CompactAssembly.Request(
                query: query,
                sessionID: sessionID,
                mode: mode,
                tokenBudget: tokenBudget,
                maxItems: maxItems
            ),
            stores: layeredRecallStores(),
            tokenizer: tokenizer
        )
        if let sessionID {
            try await recordCheckpoint(
                sessionID: sessionID,
                summary: assembled.summary,
                compactedText: assembled.compactedText
            )
        }
        for hit in assembled.short + assembled.medium + assembled.long {
            if hit.horizon == .durable {
                await longTermMemory.recordAccess(frameId: hit.frameID)
            } else if let sessionID = hit.sessionID, let session = activeSessions[sessionID] {
                await session.memory.recordAccess(frameId: hit.frameID)
            }
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

    func factAssert(_ command: BrokerCommand.FactAssert) async throws -> AgentBrokerValue {
        let evidence = try parseStructuredEvidence(command.evidence)
        let factID = try await longTermMemory.assertFact(
            subject: EntityKey(command.subject),
            predicate: PredicateKey(command.predicate),
            object: try parseFactValue(command.object),
            relation: try parseVersionRelation(command.relation),
            validFromMs: command.validFromMs,
            validToMs: command.validToMs,
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

    func corpusSearch(_ command: BrokerCommand.CorpusSearch) async throws -> AgentBrokerValue {
        let query = command.query
        let recursive = command.recursive
        let rebuild = command.rebuild
        let mode = command.mode
        let topK = command.topK
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
        let execution = try await endedSessions.withMemory(
            at: corpusStoreURL,
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
        horizons: HorizonSet
    ) async throws -> [LayeredMemoryHit] {
        try await LayeredRecall.search(
            request: LayeredRecall.SearchRequest(
                query: query,
                mode: mode,
                topK: topK,
                sessionID: sessionID,
                horizons: horizons
            ),
            stores: layeredRecallStores()
        )
    }

    func layeredRecallStores() -> LayeredRecall.Stores {
        let sessionsSnapshot = activeSessions

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
                        project: state.manifest.project,
                        repo: state.manifest.repo
                    )
                }
                if let clientCWD {
                    let inferred = MemorySemantics.inferScopeContext(currentDirectoryPath: clientCWD)
                    return LayeredRecall.Identity(
                        project: inferred.projectName,
                        repo: inferred.repoName
                    )
                }
                return LayeredRecall.Identity(project: nil, repo: nil)
            },
            preview: { text in
                Wax.dehighlightedPreviewText(text ?? "")
            },
            canonicalFrameID: { frameID, memory in
                await self.bestEffortCanonicalDocumentFrameID(for: frameID, memory: memory)
            },
            endedSessions: endedSessions,
            nowMs: { Self.nowMs() }
        )
    }

    func layeredMemoryGet(reference: MemoryReference) async throws -> LayeredMemoryHit {
        switch reference {
        case .durable(let frameID):
            let document = try await requireDocument(frameID: frameID, memory: longTermMemory)
            await longTermMemory.recordAccess(frameId: document.frameId)
            return LayeredMemoryHit(
                id: .durable(frameID: frameID),
                score: 0,
                text: document.text,
                preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                metadata: document.metadata,
                explanations: ["durable memory"],
                timestampMs: document.timestampMs
            )
        case .working(let sessionID, let frameID), .episodic(let sessionID, let frameID):
            if let state = activeSessions[sessionID] {
                let document = try await requireDocument(frameID: frameID, memory: state.memory)
                await state.memory.recordAccess(frameId: document.frameId)
                return LayeredMemoryHit(
                    id: MemoryID.make(horizon: reference.horizon, sessionID: sessionID, frameID: frameID),
                    agentID: state.manifest.agentID,
                    runID: state.manifest.runID,
                    score: 0,
                    text: document.text,
                    preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                    metadata: document.metadata,
                    explanations: [reference.horizon == .working ? "current session" : "recent session episode"],
                    timestampMs: document.timestampMs
                )
            }
            let document = try await endedSessions.document(
                EndedSessionDocumentQuery(sessionID: sessionID, frameID: frameID)
            )
            return LayeredMemoryHit(
                id: MemoryID.make(horizon: reference.horizon, sessionID: sessionID, frameID: frameID),
                agentID: document.agentID,
                runID: document.runID,
                score: 0,
                text: document.text,
                preview: MemorySemantics.summarizeCandidate(document.text, maxLength: 180),
                metadata: document.metadata,
                explanations: [reference.horizon == .working ? "current session" : "recent session episode"],
                timestampMs: document.timestampMs
            )
        }
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

    func writeScope(for sessionID: UUID?, clientCWD: String? = nil) -> MemoryScopeContext {
        if let sessionID, let session = activeSessions[sessionID] {
            return MemoryScopeContext(
                cwdPath: clientCWD,
                repoRootPath: nil,
                repoName: session.manifest.repo,
                projectName: session.manifest.project
            )
        }
        if let clientCWD {
            return MemorySemantics.inferScopeContext(currentDirectoryPath: clientCWD)
        }
        return MemoryScopeContext()
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

    /// Lane visibility after session-scope resolution: a resolved session keeps
    /// the request, an unscoped search drops working, ambiguity keeps durable only.
    static func scopedHorizons(scope: ResolvedSessionScope, requested: HorizonSet) -> HorizonSet {
        switch scope {
        case .session:
            return requested
        case .durableOnly:
            return .durable
        case .none:
            return requested.subtracting(.working)
        }
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

    func promotionSettingsMerging(_ command: BrokerCommand.SessionSynthesize) -> BrokerPromotionSettings {
        BrokerPromotionSettings(
            minimumConfidence: command.minimumConfidence ?? promotionSettings.minimumConfidence,
            minimumRecallCount: command.minimumRecallCount ?? promotionSettings.minimumRecallCount,
            maxCandidates: command.maxCandidates ?? promotionSettings.maxCandidates
        )
    }

    func validateDurableWriteContent(content: String, metadata: [String: String]) throws {
        let semantics = MemorySemantics.parse(metadata: metadata, nowMs: Self.nowMs())
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
        try MemoryID.parse(raw)
    }

    static func itemKindLabel(_ kind: RAGContext.ItemKind) -> String {
        switch kind {
        case .expanded:
            return "expanded"
        case .surrogate:
            return "surrogate"
        case .snippet:
            return "snippet"
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


    func renderMemoryMarkdown(documents: [MemoryOrchestrator.CorpusSourceDocument]) -> String {
        var sections: [MemoryType: [String]] = [:]
        for document in documents {
            let info = MemorySemantics.parse(metadata: document.metadata, nowMs: Self.nowMs())
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

    static func makeMemoryReference(frameID: UInt64) -> String {
        LayeredRecall.makeMemoryReference(frameID: frameID)
    }

    static func makeMemoryReference(_ horizon: MemoryHorizon, sessionID: UUID, frameID: UInt64) -> String {
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
