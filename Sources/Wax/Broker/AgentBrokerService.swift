import Foundation
import WaxCore

package actor AgentBrokerService {
    typealias SessionState = VirtualSessionStore.SessionState

    let longTermMemory: MemoryOrchestrator
    package let longTermStoreURL: URL
    package let sessionRootURL: URL
    let corpusStoreURL: URL
    let noEmbedder: Bool
    let requireVector: Bool
    let embedderChoice: String
    let embedderTuning: CommandLineEmbedderRuntimeTuning
    let enableAccessStatsScoring: Bool
    let scopeContext: MemoryScopeContext
    let promotionSettings: BrokerPromotionSettings
    /// Loaded once at init (`WAX_WORKING_QUARANTINE_SECS` and friends) and used
    /// by maintain, health, and session sweeps so the knobs actually apply.
    let retentionSettings: MemoryRetentionSettings
    let embeddingRequest: EmbeddingOpenRequest
    let readiness: EmbeddingReadiness
    let factoryOverride: (@Sendable () async throws -> any EmbeddingProvider)?
    let brokerInstanceID = UUID().uuidString
    let virtualSessions: VirtualSessionStore
    let endedSessions: DiskEndedSessionStore
    private let commandMutex = AsyncMutex()
    // A remember may wait for deferred embedding readiness. Keep that wait
    // from blocking unrelated reads while still serializing concurrent writes.
    let rememberMutex = AsyncMutex()
    var cachedSessionDisk: (atMs: Int64, stats: SessionDiskStats)?
    static let sessionDiskCacheTTLMs: Int64 = 15_000
    /// Test seam: awaited between a persisted-session harvest and its manifest write.
    var persistedHarvestHookForTesting: (@Sendable (UUID) async -> Void)?
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
        orchestratorConfig: OrchestratorConfig? = nil,
        automaticEmbeddingBackfill: Bool = true,
        retentionSettings: MemoryRetentionSettings = .fromEnvironment()
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
        self.retentionSettings = retentionSettings

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
        let capturedBackfill = automaticEmbeddingBackfill
        self.virtualSessions = VirtualSessionStore(
            sessionRootURL: sessionRootURL,
            brokerInstanceID: brokerInstanceID,
            openExisting: { url in
                var sessionConfig = OrchestratorConfig.default
                sessionConfig.enableStructuredMemory = false
                sessionConfig.enableAccessStatsScoring = capturedAccessStats
                sessionConfig.defaultScopeContext = capturedScope
                let memory = try await EmbeddingReadinessBinding.openOrchestrator(
                    at: url,
                    config: sessionConfig,
                    request: capturedRequest,
                    waxOptions: CommandLineEmbedderFactory.waxOptions(),
                    readiness: capturedReadiness,
                    factoryOverride: capturedFactory
                )
                if capturedBackfill {
                    await memory.enableAutomaticEmbeddingBackfill()
                }
                return memory
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
        if automaticEmbeddingBackfill {
            await longTermMemory.enableAutomaticEmbeddingBackfill()
        }
        // An expired broker lease does not end the agent's session. Idle daemon
        // restarts must leave active manifests available for the next request to rebind.
        do {
            _ = try await memoryMaintain(
                BrokerCommand.MemoryMaintain(apply: true, forceReclaim: false),
                endExpiredSessions: false
            )
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "broker startup memory_maintain",
                fallback: "broker started without startup maintenance"
            )
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
        let command: BrokerCommand
        do {
            command = try BrokerCommand.decode(
                command: request.command,
                arguments: request.arguments
            )
        } catch {
            let message = error.localizedDescription
            let payload = (error as? BrokerValidationError)?.brokerPayload
            return await commandMutex.withLock {
                AgentBrokerResponse.failure(id: request.id, payload: payload, message: message)
            }
        }

        switch BrokerAdmission.admission(for: command) {
        case .rememberDrain:
            // Migration snapshots and mutates a copy of the long-term store. It
            // must hold both locks: remember intentionally uses its own mutex so
            // deferred embedding waits do not block reads, but a migration must
            // not race that writer while hashing or copying the source. Session
            // teardown needs the same boundary: once end/close returns, every
            // remember admitted before teardown must be flushed and no longer
            // capable of appending to an ended session.
            return await commandMutex.withLock { [self] in
                await rememberMutex.withLock { [self] in
                    await dispatch(command, request: request)
                }
            }
        case .embedderThenCommand:
            // Wait for MiniLM outside commandMutex so a cold first recall does not
            // stall unrelated commands the way remember already uses rememberMutex.
            // Do not wait again inside recall/search — a timeout here must not
            // become a second 30s hold on the serialized path.
            await awaitQueryEmbedderIfNeeded(memory: longTermMemory)
            return await commandMutex.withLock { [self] in
                await dispatch(command, request: request)
            }
        case .remember:
            return await rememberMutex.withLock { [self] in
                await dispatch(command, request: request)
            }
        case .command:
            return await commandMutex.withLock { [self] in
                await dispatch(command, request: request)
            }
        }
    }

    /// New `BrokerCommand` cases must pick true (teardown) or false.
    package static func requiresRememberDrain(_ command: BrokerCommand) -> Bool {
        switch command {
        // memory_maintain stays on commandMutex: its harvests can be slow, and
        // remember must not queue behind them. It takes rememberMutex only for
        // the liveness re-check + mark-ended step (see harvestPersistedSession).
        case .taskStateMigrate, .sessionEnd, .sessionClose:
            return true
        case .remember, .recall, .search, .memorySearch, .sessionStart, .sessionResume,
             .handoff, .handoffLatest, .memoryGet, .memoryHealth, .stats, .flush,
             .markdownSync, .entityUpsert, .entityResolve, .factRetract, .shutdown,
             .sessionSynthesize, .knowledgeCapture, .sessionOpen, .compactContext,
             .markdownExport, .factsQuery, .memoryPromote, .promote, .factAssert,
             .corpusSearch, .memoryMaintain:
            return false
        }
    }

    private func dispatch(
        _ command: BrokerCommand,
        request: AgentBrokerRequest
    ) async -> AgentBrokerResponse {
        do {
            let payload: AgentBrokerValue
            let shouldExit: Bool

            switch command {
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
        } catch let error as BrokerValidationError {
            return AgentBrokerResponse.failure(
                id: request.id,
                payload: error.brokerPayload,
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

package extension AgentBrokerValue {
    package var debugJSONString: String {
        guard let data = try? JSONEncoder().encode(self),
              let string = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return string
    }
}
