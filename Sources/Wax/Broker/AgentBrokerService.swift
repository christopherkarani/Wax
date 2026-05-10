import Foundation
import WaxCore

package actor AgentBrokerService {
    private struct SessionState: Sendable {
        let id: UUID
        let storeURL: URL
        let memory: MemoryOrchestrator
    }

    private let longTermMemory: MemoryOrchestrator
    private let longTermStoreURL: URL
    private let sessionRootURL: URL
    private let corpusStoreURL: URL
    private let noEmbedder: Bool
    private let embedderChoice: String
    private let embedderTuning: CommandLineEmbedderRuntimeTuning
    private var activeSessions: [UUID: SessionState] = [:]

    package init(
        storePath: String,
        sessionRootPath: String,
        noEmbedder: Bool,
        embedderChoice: String,
        requireVector: Bool,
        embedderTuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws {
        self.longTermStoreURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(storePath)).standardizedFileURL
        self.sessionRootURL = URL(fileURLWithPath: AgentBrokerPathing.expandPath(sessionRootPath)).standardizedFileURL
        self.noEmbedder = noEmbedder
        self.embedderChoice = embedderChoice
        self.embedderTuning = embedderTuning

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
            let payload: AgentBrokerValue
            let shouldExit: Bool

            switch command {
            case "remember":
                payload = try await remember(arguments: request.arguments)
                shouldExit = false
            case "recall":
                payload = try await recall(arguments: request.arguments)
                shouldExit = false
            case "search":
                payload = try await search(arguments: request.arguments)
                shouldExit = false
            case "stats":
                payload = try await stats()
                shouldExit = false
            case "flush":
                payload = try await flush()
                shouldExit = false
            case "session_start":
                payload = try await sessionStart()
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

private extension AgentBrokerService {
    static let maxContentBytes = 128 * 1024
    static let maxTopK = 200
    static let maxRecallLimit = 100
    static let maxGraphLimit = 500
    static let maxGraphIdentifierBytes = 256
    static let maxGraphKindBytes = 64

    func remember(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let content = try args.requiredString("content", maxBytes: Self.maxContentBytes)
        let sessionID = try parseOptionalSessionID(args)
        let metadata = try coerceMetadata(try args.optionalObject("metadata"))
        if metadata["session_id"] != nil {
            throw BrokerValidationError.invalid("metadata.session_id is reserved; use top-level session_id")
        }
        let memory = try await memory(for: sessionID)

        let before = await memory.runtimeStats()
        try await memory.remember(content, metadata: metadata)
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
            ])
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
            ])
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
            try await activeSessions[session]?.memory.sessionRuntimeStats() ?? .init(
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

    func sessionStart() async throws -> AgentBrokerValue {
        let sessionID = UUID()
        let sessionURL = sessionRootURL.appendingPathComponent("\(sessionID.uuidString).wax")
        let memory = try await openSessionMemory(at: sessionURL)
        activeSessions[sessionID] = SessionState(id: sessionID, storeURL: sessionURL, memory: memory)
        return .object([
            "status": .string("ok"),
            "session_id": .string(sessionID.uuidString),
        ])
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
        let content = try args.requiredString("content", maxBytes: Self.maxContentBytes)
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
        let factID = try await longTermMemory.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: try parseFactValue(objectValue),
            relation: relation,
            validFromMs: try args.optionalInt64("valid_from"),
            validToMs: try args.optionalInt64("valid_to"),
            commit: true
        )
        return .object([
            "status": .string("ok"),
            "fact_id": .from(factID.rawValue),
            "committed": .bool(true),
        ])
    }

    func factRetract(arguments: [String: AgentBrokerValue]) async throws -> AgentBrokerValue {
        let args = BrokerArguments(arguments)
        let factID = try args.requiredInt64("fact_id")
        try await longTermMemory.retractFact(factId: FactRowID(rawValue: factID), atMs: nil, commit: true)
        return .object([
            "status": .string("ok"),
            "fact_id": .from(factID),
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
        let result = try await longTermMemory.facts(
            about: subject,
            predicate: predicate,
            asOfMs: Int64.max,
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
            ])
        }
        return .object([
            "count": .from(result.hits.count),
            "truncated": .from(result.wasTruncated),
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
        var includeSurrogates = false
        var timeAfterMs: Int64?
        var timeBeforeMs: Int64?

        if let filters {
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
            if let includeRaw = filters["include_surrogates"] {
                guard let parsed = includeRaw.boolValue else {
                    throw BrokerValidationError.invalid("filters.include_surrogates must be a boolean")
                }
                includeSurrogates = parsed
            }
            timeAfterMs = filters["time_after_ms"]?.intValue
            timeBeforeMs = filters["time_before_ms"]?.intValue
        }
        let metadataFilter: MetadataFilter? = (!metadataEntries.isEmpty || !labels.isEmpty)
            ? MetadataFilter(requiredEntries: metadataEntries, requiredLabels: labels)
            : nil
        let frameFilter: FrameFilter? = (metadataFilter != nil || includeSurrogates)
            ? FrameFilter(includeSurrogates: includeSurrogates, metadataFilter: metadataFilter)
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
                "include_surrogates": .from(includeSurrogates),
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

private struct BrokerArguments {
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

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard let stringValue = value.stringValue else {
            throw BrokerValidationError.invalid("\(key) must be a string")
        }
        return stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
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

    func requiredValue(_ key: String) throws -> AgentBrokerValue {
        guard let value = values[key] else {
            throw BrokerValidationError.missing(key)
        }
        return value
    }
}

private enum BrokerValidationError: LocalizedError {
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
