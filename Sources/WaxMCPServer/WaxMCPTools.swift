#if MCPServer
import Foundation
import MCP
import Wax

enum WaxMCPTools {
    private static let maxContentBytes = 128 * 1024
    private static let maxTopK = 200
    private static let maxRecallLimit = 100
    private static let maxGraphLimit = 500
    private static let maxGraphIdentifierBytes = 256
    private static let maxGraphKindBytes = 64
    private static let graphIdentifierAllowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._:-")
    private static let graphKindAllowedScalars = CharacterSet(charactersIn: "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789._-")
    private static let sessionRegistries = SessionRegistryPool()

    static func register(
        on server: Server,
        memory: MemoryOrchestrator,
        structuredMemoryEnabled: Bool,
        noEmbedder: Bool,
        embedderChoice: String
    ) async {
        _ = await sessionRegistries.registry(for: memory)
        _ = await server.withMethodHandler(ListTools.self) { _ in
            ListTools.Result(
                tools: ToolSchemas.tools(structuredMemoryEnabled: structuredMemoryEnabled),
                nextCursor: nil
            )
        }

        _ = await server.withMethodHandler(CallTool.self) { params in
            await handleCall(
                params: params,
                memory: memory,
                structuredMemoryEnabled: structuredMemoryEnabled,
                noEmbedder: noEmbedder,
                embedderChoice: embedderChoice
            )
        }
    }

    static func handleCall(
        params: CallTool.Parameters,
        memory: MemoryOrchestrator,
        structuredMemoryEnabled: Bool = true,
        noEmbedder: Bool = false,
        embedderChoice: String = "minilm"
    ) async -> CallTool.Result {
        let sessionRegistry = await sessionRegistries.registry(for: memory)
        do {
            try validateArgumentSurface(name: params.name, arguments: params.arguments)
            switch params.name {
            case "wax_remember":
                return try await remember(arguments: params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "wax_recall":
                return try await recall(arguments: params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "wax_search":
                return try await search(arguments: params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "wax_corpus_search":
                return try await corpusSearch(
                    arguments: params.arguments,
                    memory: memory,
                    noEmbedder: noEmbedder,
                    embedderChoice: embedderChoice
                )
            case "wax_flush":
                return try await flush(memory: memory)
            case "wax_stats":
                return try await stats(memory: memory, sessionRegistry: sessionRegistry)
            case "wax_session_start":
                return await sessionStart(sessionRegistry: sessionRegistry)
            case "wax_session_end":
                return try await sessionEnd(arguments: params.arguments, sessionRegistry: sessionRegistry)
            case "wax_handoff":
                return try await handoff(arguments: params.arguments, memory: memory, sessionRegistry: sessionRegistry)
            case "wax_handoff_latest":
                return try await handoffLatest(arguments: params.arguments, memory: memory)
            case "wax_entity_upsert" where structuredMemoryEnabled:
                return try await entityUpsert(arguments: params.arguments, memory: memory)
            case "wax_fact_assert" where structuredMemoryEnabled:
                return try await factAssert(arguments: params.arguments, memory: memory)
            case "wax_fact_retract" where structuredMemoryEnabled:
                return try await factRetract(arguments: params.arguments, memory: memory)
            case "wax_facts_query" where structuredMemoryEnabled:
                return try await factsQuery(arguments: params.arguments, memory: memory)
            case "wax_entity_resolve" where structuredMemoryEnabled:
                return try await entityResolve(arguments: params.arguments, memory: memory)
            case "wax_entity_upsert",
                 "wax_fact_assert",
                 "wax_fact_retract",
                 "wax_facts_query",
                 "wax_entity_resolve":
                return errorResult(
                    message: "tool '\(params.name)' requires structured memory to be enabled",
                    code: "feature_disabled"
                )
            default:
                return errorResult(
                    message: "Unknown tool '\(params.name)'.",
                    code: "unknown_tool"
                )
            }
        } catch let error as ToolValidationError {
            return errorResult(message: error.localizedDescription, code: "invalid_arguments")
        } catch {
            return errorResult(message: error.localizedDescription, code: "execution_failed")
        }
    }

    private static func remember(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator,
        sessionRegistry: SessionRegistry
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let content = try args.requiredString("content", maxBytes: maxContentBytes)
        let sessionID = try parseOptionalSessionID(args)
        try await validateActiveSession(sessionID, in: sessionRegistry)
        let commit = try args.optionalBool("commit") ?? true
        var metadata = try coerceMetadata(try args.optionalObject("metadata"))
        if metadata["session_id"] != nil {
            throw ToolValidationError.invalid("metadata.session_id is reserved; use top-level session_id")
        }
        if let sessionID {
            metadata["session_id"] = sessionID.uuidString
        }

        let before = await memory.runtimeStats()
        try await memory.remember(content, metadata: metadata)
        if commit {
            try await memory.flush()
        }
        let after = await memory.runtimeStats()

        let totalBefore = before.frameCount + before.pendingFrames
        let totalAfter = after.frameCount + after.pendingFrames
        let added = totalAfter >= totalBefore ? (totalAfter - totalBefore) : 0

        return jsonResult([
            "status": "ok",
            "framesAdded": value(from: added),
            "frameCount": value(from: after.frameCount),
            "pendingFrames": value(from: after.pendingFrames),
            "committed": value(from: commit),
            "commit": [
                "requested": value(from: commit),
                "performed": value(from: commit),
            ],
        ])
    }

    private static func recall(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator,
        sessionRegistry: SessionRegistry
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let query = try args.requiredString("query", maxBytes: maxContentBytes)
        let limit = try args.optionalInt("limit") ?? 5
        guard limit > 0, limit <= maxRecallLimit else {
            throw ToolValidationError.invalid("limit must be between 1 and \(maxRecallLimit)")
        }
        let parsedFilters = try parseSearchFilters(args)
        try await validateActiveSession(parsedFilters.sessionId, in: sessionRegistry)
        let mode = try parseRecallMode(args)
        let requestedTopK = try args.optionalInt("search_top_k") ?? (try args.optionalInt("topK"))
        if let requestedTopK, !(1...maxTopK).contains(requestedTopK) {
            throw ToolValidationError.invalid("search_top_k must be between 1 and \(maxTopK)")
        }
        let effectiveTopK = requestedTopK ?? limit
        let embeddingPolicy: MemoryOrchestrator.QueryEmbeddingPolicy = if case .text? = mode {
            .never
        } else {
            .ifAvailable
        }
        try await ensureNoPendingWritesForRead(memory: memory, toolName: "wax_recall")

        let execution = try await memory.recallExecution(
            query: query,
            embeddingPolicy: embeddingPolicy,
            frameFilter: parsedFilters.frameFilter,
            timeRange: parsedFilters.timeRange,
            topK: effectiveTopK,
            mode: mode
        )
        let context = execution.context
        let selected = context.items.prefix(limit)
        var lines: [String] = []
        lines.reserveCapacity(selected.count + 5)
        lines.append("Query: \(context.query)")
        lines.append("Total tokens: \(context.totalTokens)")
        lines.append("Results: \(selected.count) of \(limit) requested (orchestrator returned \(context.items.count))")
        lines.append(
            "Search controls: requested_mode=\(execution.requestedModeSummary) effective_mode=\(execution.effectiveModeSummary) " +
                "query_embedding_state=\(execution.queryEmbeddingState.rawValue) search_top_k=\(effectiveTopK) limit=\(limit)"
        )
        lines.append("Applied filters: \(encodeJSON(parsedFilters.summary) ?? "{}")")

        for (index, item) in selected.enumerated() {
            lines.append(
                "\(index + 1). [\(item.kind)] frame=\(item.frameId) score=\(String(format: "%.4f", item.score)) \(item.text)"
            )
        }

        return textWithJSONResourceResult(
            text: lines.joined(separator: "\n"),
            payload: [
                "query": value(from: context.query),
                "total_tokens": value(from: context.totalTokens),
                "result_count": value(from: selected.count),
                "limit": value(from: limit),
                "search_top_k": value(from: effectiveTopK),
                "requested_mode": value(from: execution.requestedModeSummary),
                "effective_mode": value(from: execution.effectiveModeSummary),
                "query_embedding_state": value(from: execution.queryEmbeddingState.rawValue),
                "applied_filters": parsedFilters.summary,
            ],
            uri: "wax://tool/recall-summary"
        )
    }

    private static func search(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator,
        sessionRegistry: SessionRegistry
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let query = try args.requiredString("query", maxBytes: maxContentBytes)
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let topK = try args.optionalInt("topK") ?? 10
        guard topK > 0, topK <= maxTopK else {
            throw ToolValidationError.invalid("topK must be between 1 and \(maxTopK)")
        }
        let parsedFilters = try parseSearchFilters(args)
        try await validateActiveSession(parsedFilters.sessionId, in: sessionRegistry)
        try await ensureNoPendingWritesForRead(memory: memory, toolName: "wax_search")

        let execution = try await memory.searchExecution(
            query: query,
            mode: mode,
            topK: topK,
            frameFilter: parsedFilters.frameFilter,
            timeRange: parsedFilters.timeRange
        )
        let hits = execution.hits
        let lines = hits.enumerated().map { index, hit in
            let row: Value = [
                "rank": value(from: index + 1),
                "frameId": value(from: hit.frameId),
                "score": value(from: Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": value(from: hit.previewText ?? ""),
            ]
            return encodeJSON(row) ?? "{}"
        }
        return textWithJSONResourceResult(
            text: lines.joined(separator: "\n"),
            payload: [
                "query": value(from: query),
                "topK": value(from: topK),
                "requested_mode": value(from: execution.requestedModeSummary),
                "effective_mode": value(from: execution.effectiveModeSummary),
                "query_embedding_state": value(from: execution.queryEmbeddingState.rawValue),
                "applied_filters": parsedFilters.summary,
                "time_range_requested": value(from: parsedFilters.timeRange != nil),
                "time_range_applied": value(from: parsedFilters.timeRange != nil),
            ],
            uri: "wax://tool/search-summary"
        )
    }

    private static func flush(memory: MemoryOrchestrator) async throws -> CallTool.Result {
        try await memory.flush()
        let stats = await memory.runtimeStats()
        return textResult("Flushed. \(stats.frameCount) frames now searchable.")
    }

    private static func corpusSearch(
        arguments: [String: Value]?,
        memory _: MemoryOrchestrator,
        noEmbedder: Bool,
        embedderChoice: String
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let query = try args.requiredString("query", maxBytes: maxContentBytes)
        let sessionsDirRaw = try args.optionalString("sessions_dir") ?? "~/.wax/sessions"
        let corpusStoreRaw = try args.optionalString("corpus_store_path") ?? "~/.wax/corpus.wax"
        let rebuild = try args.optionalBool("rebuild") ?? true
        let recursive = try args.optionalBool("recursive") ?? true
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let mode = try parseSearchMode(modeRaw: modeRaw, alpha: try args.optionalDouble("alpha"))
        let topK = try args.optionalInt("topK") ?? 10
        guard topK > 0, topK <= maxTopK else {
            throw ToolValidationError.invalid("topK must be between 1 and \(maxTopK)")
        }
        let corpusNoEmbedder: Bool
        switch mode {
        case .text:
            corpusNoEmbedder = true
        case .hybrid:
            corpusNoEmbedder = noEmbedder
        }

        let sessionsDirectoryURL = try MCPPathing.resolveDirectoryURL(sessionsDirRaw)
        let corpusStoreURL = try MCPPathing.resolveStoreURL(corpusStoreRaw)

        let buildSummary: CorpusBuildSummary?
        if rebuild || !FileManager.default.fileExists(atPath: corpusStoreURL.path) {
            buildSummary = try await CorpusStoreBuilder.build(
                sessionsDirectory: sessionsDirectoryURL,
                targetStoreURL: corpusStoreURL,
                noEmbedder: corpusNoEmbedder,
                embedderChoice: embedderChoice,
                recursive: recursive
            )
        } else {
            buildSummary = nil
        }

        let execution = try await MCPMemoryFactory.withOpenMemory(
            at: corpusStoreURL,
            noEmbedder: corpusNoEmbedder,
            embedderChoice: embedderChoice,
            structuredMemoryEnabled: false
        ) { corpusMemory in
            try await corpusMemory.searchExecution(
                query: query,
                mode: mode,
                topK: topK,
                frameFilter: nil,
                timeRange: nil
            )
        }

        let resultRows = execution.hits.enumerated().map { index, hit -> Value in
            [
                "rank": value(from: index + 1),
                "frameId": value(from: hit.frameId),
                "score": value(from: Double(hit.score)),
                "sources": .array(hit.sources.map { .string($0.rawValue) }),
                "preview": value(from: hit.previewText ?? ""),
                "metadata": .object(hit.metadata.mapValues(value(from:))),
            ]
        }
        let text = if resultRows.isEmpty {
            "No results."
        } else {
            resultRows.map { encodeJSON($0) ?? "{}" }.joined(separator: "\n")
        }

        let summaryValue: Value = if let buildSummary {
            [
                "performed": value(from: true),
                "stores_discovered": value(from: buildSummary.storesDiscovered),
                "stores_indexed": value(from: buildSummary.storesIndexed),
                "documents_indexed": value(from: buildSummary.documentsIndexed),
                "documents_skipped": value(from: buildSummary.documentsSkipped),
                "corpus_store_path": value(from: buildSummary.targetStorePath),
            ]
        } else {
            [
                "performed": value(from: false),
                "corpus_store_path": value(from: corpusStoreURL.path),
            ]
        }

        return textWithJSONResourceResult(
            text: text,
            payload: [
                "query": value(from: query),
                "topK": value(from: topK),
                "requested_mode": value(from: execution.requestedModeSummary),
                "effective_mode": value(from: execution.effectiveModeSummary),
                "query_embedding_state": value(from: execution.queryEmbeddingState.rawValue),
                "sessions_dir": value(from: sessionsDirectoryURL.path),
                "recursive": value(from: recursive),
                "rebuild_requested": value(from: rebuild),
                "build": summaryValue,
                "results": .array(resultRows),
            ],
            uri: "wax://tool/corpus-search-summary"
        )
    }

    private static func stats(
        memory: MemoryOrchestrator,
        sessionRegistry: SessionRegistry
    ) async throws -> CallTool.Result {
        let stats = await memory.runtimeStats()
        let activeSessions = await sessionRegistry.activeSessionIDs().sorted { $0.uuidString < $1.uuidString }
        let pendingFramesStoreWide = stats.pendingFrames
        let sessionStats: MemoryOrchestrator.SessionRuntimeStats = if activeSessions.count == 1 {
            try await memory.sessionRuntimeStats(sessionId: activeSessions[0])
        } else {
            .init(
                active: !activeSessions.isEmpty,
                sessionId: nil,
                sessionFrameCount: 0,
                sessionTokenEstimate: 0,
                pendingFramesStoreWide: pendingFramesStoreWide,
                countsIncludePending: false
            )
        }

        let diskBytes: UInt64 = {
            guard let attrs = try? FileManager.default.attributesOfItem(atPath: stats.storeURL.path),
                  let size = attrs[.size] as? NSNumber
            else {
                return 0
            }
            return size.uint64Value
        }()

        let embedder: Value = {
            guard let identity = stats.embedderIdentity else { return .null }
            return [
                "provider": value(from: identity.provider ?? ""),
                "model": value(from: identity.model ?? ""),
                "dimensions": value(from: identity.dimensions ?? 0),
                "normalized": value(from: identity.normalized ?? false),
            ]
        }()

        return jsonResult([
            "frameCount": value(from: stats.frameCount),
            "pendingFrames": value(from: stats.pendingFrames),
            "generation": value(from: stats.generation),
            "diskBytes": value(from: diskBytes),
            "storePath": value(from: stats.storeURL.path),
            "vectorSearchEnabled": value(from: stats.vectorSearchEnabled),
            "queryEmbeddingAvailable": value(
                from: stats.vectorSearchEnabled &&
                    stats.queryEmbedderConfigured &&
                    !stats.queryEmbeddingCircuitOpen
            ),
            "queryEmbeddingCircuitOpen": value(from: stats.queryEmbeddingCircuitOpen),
            "features": [
                "structuredMemoryEnabled": value(from: stats.structuredMemoryEnabled),
                "accessStatsScoringEnabled": value(from: stats.accessStatsScoringEnabled),
            ],
            "embedder": embedder,
            "wal": [
                "walSize": value(from: stats.wal.walSize),
                "writePos": value(from: stats.wal.writePos),
                "checkpointPos": value(from: stats.wal.checkpointPos),
                "pendingBytes": value(from: stats.wal.pendingBytes),
                "committedSeq": value(from: stats.wal.committedSeq),
                "lastSeq": value(from: stats.wal.lastSeq),
                "wrapCount": value(from: stats.wal.wrapCount),
                "checkpointCount": value(from: stats.wal.checkpointCount),
            ],
            "session": [
                "active": value(from: sessionStats.active),
                "session_id": sessionStats.sessionId.map { value(from: $0.uuidString) } ?? .null,
                "activeSessionCount": value(from: activeSessions.count),
                "activeSessionIds": .array(activeSessions.map { value(from: $0.uuidString) }),
                "sessionFrameCount": value(from: sessionStats.sessionFrameCount),
                "sessionTokenEstimate": value(from: sessionStats.sessionTokenEstimate),
                "pendingFramesStoreWide": value(from: sessionStats.pendingFramesStoreWide),
                "countsIncludePending": value(from: sessionStats.countsIncludePending),
            ],
        ])
    }

    private static func sessionStart(sessionRegistry: SessionRegistry) async -> CallTool.Result {
        let sessionID = await sessionRegistry.start()
        return jsonResult([
            "status": "ok",
            "session_id": value(from: sessionID.uuidString),
        ])
    }

    private static func sessionEnd(
        arguments: [String: Value]?,
        sessionRegistry: SessionRegistry
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let sessionID = try parseOptionalSessionID(args)
        let endResult = try await sessionRegistry.end(sessionID: sessionID)
        return jsonResult([
            "status": "ok",
            "session_id": endResult.endedSessionID.map { value(from: $0.uuidString) } ?? .null,
            "active": value(from: endResult.hasActiveSessions),
        ])
    }

    private static func handoff(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator,
        sessionRegistry: SessionRegistry
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let content = try args.requiredString("content", maxBytes: maxContentBytes)
        let sessionID = try parseOptionalSessionID(args)
        try await validateActiveSession(sessionID, in: sessionRegistry)
        let project = try args.optionalString("project")
        let pendingTasks = try args.optionalStringArray("pending_tasks") ?? []
        let commit = try args.optionalBool("commit") ?? true

        let frameId = try await memory.rememberHandoff(
            content: content,
            project: project,
            pendingTasks: pendingTasks,
            sessionId: sessionID,
            commit: commit
        )

        return jsonResult([
            "status": "ok",
            "frame_id": value(from: frameId),
            "committed": value(from: commit),
            "commit": [
                "requested": value(from: commit),
                "performed": value(from: commit),
            ],
        ])
    }

    private static func handoffLatest(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let project = try args.optionalString("project")
        guard let latest = try await memory.latestHandoff(project: project) else {
            return jsonResult([
                "found": value(from: false),
            ])
        }

        return jsonResult([
            "found": value(from: true),
            "frame_id": value(from: latest.frameId),
            "timestamp_ms": value(from: latest.timestampMs),
            "project": latest.project.map(value(from:)) ?? .null,
            "pending_tasks": .array(latest.pendingTasks.map(value(from:))),
            "content": value(from: latest.content),
        ])
    }

    private static func entityUpsert(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let key = try args.requiredString("key", maxBytes: maxGraphIdentifierBytes)
        let kind = try args.requiredString("kind", maxBytes: maxGraphKindBytes)
        let aliases = try args.optionalStringArray("aliases") ?? []
        let commit = try args.optionalBool("commit") ?? true

        try validateEntityKey(key, field: "key")
        try validateGraphKind(kind, field: "kind")

        let entityID = try await memory.upsertEntity(
            key: EntityKey(key),
            kind: kind,
            aliases: aliases,
            commit: commit
        )

        return jsonResult([
            "status": "ok",
            "entity_id": value(from: entityID.rawValue),
            "key": value(from: key),
            "committed": value(from: commit),
        ])
    }

    private static func factAssert(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let subject = try args.requiredString("subject", maxBytes: maxGraphIdentifierBytes)
        let predicate = try args.requiredString("predicate", maxBytes: maxGraphIdentifierBytes)
        let objectValue = try args.requiredValue("object")
        let validFrom = try args.optionalInt64("valid_from")
        let validTo = try args.optionalInt64("valid_to")
        let commit = try args.optionalBool("commit") ?? true

        try validateEntityKey(subject, field: "subject")
        try validatePredicateKey(predicate, field: "predicate")
        let object = try parseFactValue(objectValue)

        let factID = try await memory.assertFact(
            subject: EntityKey(subject),
            predicate: PredicateKey(predicate),
            object: object,
            validFromMs: validFrom,
            validToMs: validTo,
            commit: commit
        )
        return jsonResult([
            "status": "ok",
            "fact_id": value(from: factID.rawValue),
            "committed": value(from: commit),
        ])
    }

    private static func factRetract(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let factIDRaw = try args.requiredInt64("fact_id")
        let atMs = try args.optionalInt64("at_ms")
        let commit = try args.optionalBool("commit") ?? true
        try await memory.retractFact(
            factId: FactRowID(rawValue: factIDRaw),
            atMs: atMs,
            commit: commit
        )
        return jsonResult([
            "status": "ok",
            "fact_id": value(from: factIDRaw),
            "committed": value(from: commit),
        ])
    }

    private static func factsQuery(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let subjectRaw = try args.optionalString("subject")
        if let subjectRaw {
            try validateEntityKey(subjectRaw, field: "subject")
        }
        let predicateRaw = try args.optionalString("predicate")
        if let predicateRaw {
            try validatePredicateKey(predicateRaw, field: "predicate")
        }
        let subject = subjectRaw.map { EntityKey($0) }
        let predicate = predicateRaw.map { PredicateKey($0) }
        let asOf = try args.optionalInt64("as_of") ?? Int64.max
        let limit = try args.optionalInt("limit") ?? 20
        guard limit > 0, limit <= maxGraphLimit else {
            throw ToolValidationError.invalid("limit must be between 1 and \(maxGraphLimit)")
        }

        let result = try await memory.facts(
            about: subject,
            predicate: predicate,
            asOfMs: asOf,
            limit: limit
        )

        let hits = result.hits.map { hit -> Value in
            [
                "fact_id": value(from: hit.factId.rawValue),
                "subject": value(from: hit.fact.subject.rawValue),
                "predicate": value(from: hit.fact.predicate.rawValue),
                "object": valueFromFactValue(hit.fact.object),
                "is_open_ended": value(from: hit.isOpenEnded),
                "evidence_count": value(from: hit.evidence.count),
            ]
        }

        return jsonResult([
            "count": value(from: result.hits.count),
            "truncated": value(from: result.wasTruncated),
            "hits": .array(hits),
        ])
    }

    private static func entityResolve(
        arguments: [String: Value]?,
        memory: MemoryOrchestrator
    ) async throws -> CallTool.Result {
        let args = ToolArguments(arguments)
        let alias = try args.requiredString("alias", maxBytes: maxContentBytes)
        let limit = try args.optionalInt("limit") ?? 10
        guard limit > 0, limit <= 100 else {
            throw ToolValidationError.invalid("limit must be between 1 and 100")
        }
        let matches = try await memory.resolveEntities(matchingAlias: alias, limit: limit)
        let payload = matches.map { match -> Value in
            [
                "id": value(from: match.id),
                "key": value(from: match.key.rawValue),
                "kind": value(from: match.kind),
            ]
        }
        return jsonResult([
            "count": value(from: matches.count),
            "entities": .array(payload),
        ])
    }

    private struct ParsedSearchFilters {
        let sessionId: UUID?
        let frameFilter: FrameFilter?
        let timeRange: SearchTimeRange?
        let summary: Value
    }

    private static func parseSearchFilters(_ args: ToolArguments) throws -> ParsedSearchFilters {
        let sessionID = try parseOptionalSessionID(args)
        let filters = try args.optionalObject("filters")

        var metadataEntries: [String: String] = [:]
        var labels: [String] = []
        var includeSurrogates = false
        var timeAfterMs: Int64?
        var timeBeforeMs: Int64?

        if let filters {
            let allowedKeys: Set<String> = [
                "metadata",
                "labels",
                "time_after_ms",
                "time_before_ms",
                "include_surrogates",
            ]
            let unknownKeys = Set(filters.keys).subtracting(allowedKeys)
            if let unknown = unknownKeys.sorted().first {
                throw ToolValidationError.invalid("filters.\(unknown) is not supported")
            }

            if let metadataRaw = filters["metadata"] {
                guard let metadataObject = metadataRaw.objectValue else {
                    throw ToolValidationError.invalid("filters.metadata must be an object")
                }
                if let exact = metadataObject["exact"] {
                    guard metadataObject.count == 1 else {
                        throw ToolValidationError.invalid(
                            "filters.metadata may be either a flat object or {\"exact\": {...}}"
                        )
                    }
                    guard let exactObject = exact.objectValue else {
                        throw ToolValidationError.invalid("filters.metadata.exact must be an object")
                    }
                    metadataEntries = try coerceMetadata(exactObject)
                } else {
                    metadataEntries = try coerceMetadata(metadataObject)
                }
            }

            if let labelsRaw = filters["labels"] {
                guard case .array(let rawLabels) = labelsRaw else {
                    throw ToolValidationError.invalid("filters.labels must be an array of strings")
                }
                labels = try rawLabels.map { element in
                    guard case .string(let raw) = element else {
                        throw ToolValidationError.invalid("filters.labels must contain only strings")
                    }
                    let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !trimmed.isEmpty else {
                        throw ToolValidationError.invalid("filters.labels must not contain empty values")
                    }
                    return trimmed
                }
            }

            if let includeSurrogatesRaw = filters["include_surrogates"] {
                guard let parsed = try valueAsBool(includeSurrogatesRaw, field: "filters.include_surrogates") else {
                    throw ToolValidationError.invalid("filters.include_surrogates must be a boolean")
                }
                includeSurrogates = parsed
            }

            if let timeAfterRaw = filters["time_after_ms"] {
                guard let parsed = try valueAsInt64(timeAfterRaw, field: "filters.time_after_ms") else {
                    throw ToolValidationError.invalid("filters.time_after_ms must be an integer")
                }
                timeAfterMs = parsed
            }

            if let timeBeforeRaw = filters["time_before_ms"] {
                guard let parsed = try valueAsInt64(timeBeforeRaw, field: "filters.time_before_ms") else {
                    throw ToolValidationError.invalid("filters.time_before_ms must be an integer")
                }
                timeBeforeMs = parsed
            }
        }

        if let sessionID {
            if let existing = metadataEntries["session_id"], existing != sessionID.uuidString {
                throw ToolValidationError.invalid("filters.metadata.session_id conflicts with session_id")
            }
            metadataEntries["session_id"] = sessionID.uuidString
        }

        if let timeAfterMs, let timeBeforeMs, timeAfterMs >= timeBeforeMs {
            throw ToolValidationError.invalid("filters.time_after_ms must be less than filters.time_before_ms")
        }

        let metadataFilter: MetadataFilter? =
            (!metadataEntries.isEmpty || !labels.isEmpty)
            ? MetadataFilter(requiredEntries: metadataEntries, requiredLabels: labels)
            : nil

        let frameFilter: FrameFilter? =
            (metadataFilter != nil || includeSurrogates)
            ? FrameFilter(includeSurrogates: includeSurrogates, metadataFilter: metadataFilter)
            : nil

        let timeRange: SearchTimeRange? =
            (timeAfterMs != nil || timeBeforeMs != nil)
            ? SearchTimeRange(after: timeAfterMs, before: timeBeforeMs)
            : nil

        let metadataSummary = Value.object(metadataEntries.reduce(into: [String: Value]()) { partial, entry in
            partial[entry.key] = value(from: entry.value)
        })
        let summary: Value = [
            "session_id": sessionID.map { value(from: $0.uuidString) } ?? .null,
            "metadata": metadataSummary,
            "labels": .array(labels.map(value(from:))),
            "time_after_ms": timeAfterMs.map(value(from:)) ?? .null,
            "time_before_ms": timeBeforeMs.map(value(from:)) ?? .null,
            "include_surrogates": value(from: includeSurrogates),
            "has_frame_filter": value(from: frameFilter != nil),
            "has_time_range": value(from: timeRange != nil),
        ]

        return ParsedSearchFilters(
            sessionId: sessionID,
            frameFilter: frameFilter,
            timeRange: timeRange,
            summary: summary
        )
    }

    private static func parseRecallMode(_ args: ToolArguments) throws -> MemoryOrchestrator.DirectSearchMode? {
        let modeRaw = try args.optionalString("mode")?.lowercased()
        let alpha = try args.optionalDouble("alpha")

        guard let modeRaw else {
            if alpha != nil {
                return .hybrid(alpha: try validatedHybridAlpha(alpha))
            }
            return nil
        }

        switch modeRaw {
        case "text":
            if alpha != nil {
                throw ToolValidationError.invalid("alpha is only valid when mode=hybrid")
            }
            return .text
        case "hybrid":
            return .hybrid(alpha: try validatedHybridAlpha(alpha))
        default:
            throw ToolValidationError.invalid("mode must be one of: text, hybrid")
        }
    }

    private static func parseSearchMode(
        modeRaw: String?,
        alpha: Double?
    ) throws -> MemoryOrchestrator.DirectSearchMode {
        let resolvedMode = modeRaw ?? "hybrid"
        switch resolvedMode {
        case "text":
            if alpha != nil {
                throw ToolValidationError.invalid("alpha is only valid when mode=hybrid")
            }
            return .text
        case "hybrid":
            return .hybrid(alpha: try validatedHybridAlpha(alpha))
        default:
            throw ToolValidationError.invalid("mode must be one of: text, hybrid")
        }
    }

    private static func validatedHybridAlpha(_ alpha: Double?) throws -> Float {
        let resolved = alpha ?? 0.5
        guard resolved.isFinite else {
            throw ToolValidationError.invalid("alpha must be a finite number in [0,1]")
        }
        guard (0...1).contains(resolved) else {
            throw ToolValidationError.invalid("alpha must be between 0 and 1")
        }
        return Float(resolved)
    }

    private static func parseOptionalSessionID(_ args: ToolArguments) throws -> UUID? {
        guard let sessionID = try args.optionalString("session_id") else { return nil }
        guard let parsed = UUID(uuidString: sessionID) else {
            throw ToolValidationError.invalid("session_id must be a valid UUID")
        }
        return parsed
    }

    private static func validateArgumentSurface(name: String, arguments: [String: Value]?) throws {
        let args = ToolArguments(arguments)
        switch name {
        case "wax_remember":
            try args.rejectUnknownKeys(["content", "session_id", "metadata", "commit"])
        case "wax_recall":
            try args.rejectUnknownKeys(["query", "limit", "session_id", "mode", "alpha", "search_top_k", "topK", "filters"])
        case "wax_search":
            try args.rejectUnknownKeys(["query", "mode", "topK", "session_id", "alpha", "filters"])
        case "wax_corpus_search":
            try args.rejectUnknownKeys(["query", "sessions_dir", "corpus_store_path", "rebuild", "recursive", "mode", "alpha", "topK"])
        case "wax_flush", "wax_stats", "wax_session_start":
            try args.rejectUnknownKeys([])
        case "wax_session_end":
            try args.rejectUnknownKeys(["session_id"])
        case "wax_handoff":
            try args.rejectUnknownKeys(["content", "session_id", "project", "pending_tasks", "commit"])
        case "wax_handoff_latest":
            try args.rejectUnknownKeys(["project"])
        case "wax_entity_upsert":
            try args.rejectUnknownKeys(["key", "kind", "aliases", "commit"])
        case "wax_fact_assert":
            try args.rejectUnknownKeys(["subject", "predicate", "object", "valid_from", "valid_to", "commit"])
        case "wax_fact_retract":
            try args.rejectUnknownKeys(["fact_id", "at_ms", "commit"])
        case "wax_facts_query":
            try args.rejectUnknownKeys(["subject", "predicate", "as_of", "limit"])
        case "wax_entity_resolve":
            try args.rejectUnknownKeys(["alias", "limit"])
        default:
            break
        }
    }

    private static func validateActiveSession(
        _ sessionID: UUID?,
        in sessionRegistry: SessionRegistry
    ) async throws {
        guard let sessionID else { return }
        guard await sessionRegistry.isActive(sessionID) else {
            throw ToolValidationError.invalid("session_id is not active in this server process; call wax_session_start again")
        }
    }

    private static func ensureNoPendingWritesForRead(
        memory: MemoryOrchestrator,
        toolName: String
    ) async throws {
        let stats = await memory.runtimeStats()
        guard stats.pendingFrames == 0 else {
            throw ToolValidationError.invalid(
                "\(toolName) requires wax_flush before reads when pending writes exist"
            )
        }
    }

    private static func parseFactValue(_ value: Value) throws -> FactValue {
        switch value {
        case .string(let string):
            return .string(string)
        case .int(let int):
            return .int(Int64(int))
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("object must be finite")
            }
            return .double(double)
        case .bool(let bool):
            return .bool(bool)
        case .object(let object):
            return try parseTypedFactObject(object)
        default:
            throw ToolValidationError.invalid(
                "object must be a primitive or typed object ({entity}, {time_ms}, {data_base64}, or {type,value})"
            )
        }
    }

    private static func parseTypedFactObject(_ object: [String: Value]) throws -> FactValue {
        let keys = Set(object.keys)

        if keys.contains("type") {
            guard keys == ["type", "value"] else {
                throw ToolValidationError.invalid(
                    "typed object with object.type must contain exactly {type, value}"
                )
            }
            guard let type = valueAsString(object["type"]) else {
                throw ToolValidationError.invalid("object.type must be a string")
            }
            guard let wrapped = object["value"] else {
                throw ToolValidationError.invalid("object.value is required when object.type is provided")
            }
            return try parseTypedFactEnvelope(type: type, value: wrapped)
        }

        if keys == ["entity"] {
            guard let entity = valueAsString(object["entity"]) else {
                throw ToolValidationError.invalid("object.entity must be a string")
            }
            try validateEntityKey(entity, field: "object.entity")
            return .entity(EntityKey(entity))
        }

        if keys == ["time_ms"] {
            guard let timeMs = try valueAsInt64(object["time_ms"], field: "object.time_ms") else {
                throw ToolValidationError.invalid("object.time_ms must be an integer")
            }
            return .timeMs(timeMs)
        }

        if keys == ["data_base64"] {
            guard let base64 = valueAsString(object["data_base64"]) else {
                throw ToolValidationError.invalid("object.data_base64 must be a string")
            }
            guard let decoded = Data(base64Encoded: base64) else {
                throw ToolValidationError.invalid("object.data_base64 must be valid base64")
            }
            return .data(decoded)
        }

        throw ToolValidationError.invalid(
            "typed object must be one of: {entity}, {time_ms}, {data_base64}, or {type,value}"
        )
    }

    private static func parseTypedFactEnvelope(type: String, value: Value) throws -> FactValue {
        switch type.lowercased() {
        case "entity":
            guard case .string(let raw) = value else {
                throw ToolValidationError.invalid("object.value must be a string when object.type=entity")
            }
            try validateEntityKey(raw, field: "object.value")
            return .entity(EntityKey(raw))
        case "time_ms":
            let timestamp = try valueAsInt64(value, field: "object.value")
            guard let timestamp else {
                throw ToolValidationError.invalid("object.value must be an integer when object.type=time_ms")
            }
            return .timeMs(timestamp)
        case "data_base64":
            guard case .string(let base64) = value else {
                throw ToolValidationError.invalid("object.value must be a string when object.type=data_base64")
            }
            guard let decoded = Data(base64Encoded: base64) else {
                throw ToolValidationError.invalid("object.value must be valid base64 when object.type=data_base64")
            }
            return .data(decoded)
        case "string":
            guard case .string(let raw) = value else {
                throw ToolValidationError.invalid("object.value must be a string when object.type=string")
            }
            return .string(raw)
        case "int", "integer":
            let intValue = try valueAsInt64(value, field: "object.value")
            guard let intValue else {
                throw ToolValidationError.invalid("object.value must be an integer when object.type=int")
            }
            return .int(intValue)
        case "double", "number":
            guard let double = valueAsDouble(value), double.isFinite else {
                throw ToolValidationError.invalid("object.value must be a finite number when object.type=double")
            }
            return .double(double)
        case "bool", "boolean":
            guard case .bool(let bool) = value else {
                throw ToolValidationError.invalid("object.value must be a boolean when object.type=bool")
            }
            return .bool(bool)
        default:
            throw ToolValidationError.invalid(
                "object.type must be one of: entity, time_ms, data_base64, string, int, double, bool"
            )
        }
    }

    private static func valueFromFactValue(_ factValue: FactValue) -> Value {
        switch factValue {
        case .string(let string):
            return .string(string)
        case .int(let int):
            return value(from: int)
        case .double(let double):
            return value(from: double)
        case .bool(let bool):
            return value(from: bool)
        case .data(let data):
            return .object([
                "data_base64": .string(data.base64EncodedString()),
            ])
        case .timeMs(let timestamp):
            return .object([
                "time_ms": value(from: timestamp),
            ])
        case .entity(let key):
            return .object([
                "entity": .string(key.rawValue),
            ])
        }
    }

    private static func validateEntityKey(_ value: String, field: String) throws {
        try validateGraphIdentifier(value, field: field, requireNamespace: true)
    }

    private static func validatePredicateKey(_ value: String, field: String) throws {
        try validateGraphIdentifier(value, field: field, requireNamespace: false)
    }

    private static func validateGraphIdentifier(
        _ value: String,
        field: String,
        requireNamespace: Bool
    ) throws {
        guard !value.isEmpty else {
            throw ToolValidationError.invalid("\(field) must not be empty")
        }
        guard value.utf8.count <= maxGraphIdentifierBytes else {
            throw ToolValidationError.invalid("\(field) exceeds max size (\(maxGraphIdentifierBytes) bytes)")
        }
        guard value.unicodeScalars.allSatisfy({ graphIdentifierAllowedScalars.contains($0) }) else {
            throw ToolValidationError.invalid(
                "\(field) contains invalid characters; allowed: letters, digits, ., _, :, -"
            )
        }
        if requireNamespace {
            let parts = value.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false)
            guard parts.count == 2, !parts[0].isEmpty, !parts[1].isEmpty else {
                throw ToolValidationError.invalid("\(field) must be namespaced as '<namespace>:<id>'")
            }
        }
    }

    private static func validateGraphKind(_ value: String, field: String) throws {
        guard !value.isEmpty else {
            throw ToolValidationError.invalid("\(field) must not be empty")
        }
        guard value.utf8.count <= maxGraphKindBytes else {
            throw ToolValidationError.invalid("\(field) exceeds max size (\(maxGraphKindBytes) bytes)")
        }
        guard value.unicodeScalars.allSatisfy({ graphKindAllowedScalars.contains($0) }) else {
            throw ToolValidationError.invalid(
                "\(field) contains invalid characters; allowed: letters, digits, ., _, -"
            )
        }
    }

    private static func valueAsString(_ value: Value?) -> String? {
        guard let value else { return nil }
        guard case .string(let string) = value else { return nil }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    private static func valueAsInt64(_ value: Value?, field: String) throws -> Int64? {
        guard let value else { return nil }
        switch value {
        case .int(let int):
            return Int64(int)
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("\(field) must be an integer")
            }
            let truncated = double.rounded(.towardZero)
            guard truncated == double else {
                throw ToolValidationError.invalid("\(field) must be an integer")
            }
            guard truncated >= Double(Int64.min), truncated <= Double(Int64.max) else {
                throw ToolValidationError.invalid("\(field) is out of range")
            }
            return Int64(truncated)
        case .string(let string):
            guard let parsed = Int64(string) else {
                throw ToolValidationError.invalid("\(field) must be an integer, got '\(string)'")
            }
            return parsed
        default:
            return nil
        }
    }

    private static func coerceMetadata(_ metadata: [String: Value]?) throws -> [String: String] {
        guard let metadata else { return [:] }
        var output: [String: String] = [:]
        output.reserveCapacity(metadata.count)

        for (key, value) in metadata {
            switch value {
            case .null:
                continue
            case .string(let string):
                output[key] = string
            case .int(let int):
                output[key] = String(int)
            case .double(let double):
                output[key] = String(double)
            case .bool(let bool):
                output[key] = bool ? "true" : "false"
            case .data(_, _), .array(_), .object(_):
                throw ToolValidationError.invalid("metadata.\(key) must be a scalar")
            }
        }
        return output
    }

    private static func textResult(_ text: String) -> CallTool.Result {
        CallTool.Result(content: [.text(text)], isError: false)
    }

    private static func textWithJSONResourceResult(
        text: String,
        payload: Value,
        uri: String = "wax://tool/result"
    ) -> CallTool.Result {
        let json = encodeJSON(payload) ?? "{}"
        return CallTool.Result(
            content: [
                .text(text),
                .resource(
                    resource: .text(json, uri: uri, mimeType: "application/json")
                ),
            ],
            isError: false
        )
    }

    private static func jsonResult(_ value: Value) -> CallTool.Result {
        let json = encodeJSON(value) ?? "{}"
        return CallTool.Result(
            content: [
                .text(json),
                .resource(
                    resource: .text(json, uri: "wax://tool/result", mimeType: "application/json")
                ),
            ],
            isError: false
        )
    }

    private static func errorResult(message: String, code: String) -> CallTool.Result {
        let payload: Value = [
            "code": value(from: code),
            "message": value(from: message),
        ]
        let json = encodeJSON(payload) ?? "{\"code\":\(escapeJSONString(code)),\"message\":\(escapeJSONString(message))}"
        return CallTool.Result(
            content: [
                .text(message),
                .resource(
                    resource: .text(json, uri: "wax://errors/\(code)", mimeType: "application/json")
                ),
            ],
            isError: true
        )
    }

    private static func encodeJSON(_ value: Value) -> String? {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]
        guard let data = try? encoder.encode(value) else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// Wraps a string in double-quotes with proper JSON escaping.
    /// Used as a fallback when `encodeJSON` fails.
    private static func escapeJSONString(_ value: String) -> String {
        var result = "\""
        for char in value {
            switch char {
            case "\"": result += "\\\""
            case "\\": result += "\\\\"
            case "\n": result += "\\n"
            case "\r": result += "\\r"
            case "\t": result += "\\t"
            default:
                let scalar = char.unicodeScalars.first!
                if scalar.value < 0x20 {
                    result += String(format: "\\u%04x", scalar.value)
                } else {
                    result.append(char)
                }
            }
        }
        result += "\""
        return result
    }

    private static func value(from value: UInt64) -> Value {
        if value <= UInt64(Int.max) {
            return .int(Int(value))
        }
        return .string(String(value))
    }

    private static func value(from value: Int) -> Value {
        .int(value)
    }

    private static func value(from value: Int64) -> Value {
        if value >= Int64(Int.min), value <= Int64(Int.max) {
            return .int(Int(value))
        }
        return .string(String(value))
    }

    private static func value(from value: Double) -> Value {
        if value.isFinite {
            return .double(value)
        }
        // JSON has no representation for NaN/Infinity; return a descriptive
        // string so consumers can see the original value instead of a silent null.
        return .string(String(value))
    }

    private static func value(from value: String) -> Value {
        .string(value)
    }

    private static func value(from value: Bool) -> Value {
        .bool(value)
    }

    private static func valueAsDouble(_ value: Value?) -> Double? {
        guard let value else { return nil }
        switch value {
        case .double(let double):
            return double
        case .int(let int):
            return Double(int)
        case .string(let string):
            return Double(string)
        default:
            return nil
        }
    }

    private static func valueAsBool(_ value: Value, field: String) throws -> Bool? {
        switch value {
        case .bool(let bool):
            return bool
        case .string(let raw):
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                throw ToolValidationError.invalid("\(field) must be a boolean")
            }
        default:
            return nil
        }
    }

}

private struct ToolArguments {
    let values: [String: Value]

    init(_ values: [String: Value]?) {
        self.values = values ?? [:]
    }

    func requiredString(_ key: String, maxBytes: Int? = nil) throws -> String {
        guard let value = values[key] else {
            throw ToolValidationError.missing(key)
        }
        guard case .string(let string) = value else {
            throw ToolValidationError.invalid("\(key) must be a string")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw ToolValidationError.invalid("\(key) must not be empty")
        }
        if let maxBytes, trimmed.utf8.count > maxBytes {
            throw ToolValidationError.invalid("\(key) exceeds max size (\(maxBytes) bytes)")
        }
        return trimmed
    }

    func optionalString(_ key: String) throws -> String? {
        guard let value = values[key] else { return nil }
        guard case .string(let string) = value else {
            throw ToolValidationError.invalid("\(key) must be a string")
        }
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    func optionalInt(_ key: String) throws -> Int? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let int):
            return int
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            let truncated = double.rounded(.towardZero)
            guard truncated == double else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            guard truncated >= Double(Int.min), truncated <= Double(Int.max) else {
                throw ToolValidationError.invalid("\(key) is out of range")
            }
            return Int(truncated)
        case .string(let string):
            guard let parsed = Int(string) else {
                throw ToolValidationError.invalid("\(key) must be an integer, got '\(string)'")
            }
            return parsed
        default:
            throw ToolValidationError.invalid("\(key) must be an integer")
        }
    }

    func optionalDouble(_ key: String) throws -> Double? {
        guard let value = values[key] else { return nil }
        switch value {
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("\(key) must be a finite number")
            }
            return double
        case .int(let int):
            return Double(int)
        case .string(let string):
            guard let parsed = Double(string), parsed.isFinite else {
                throw ToolValidationError.invalid("\(key) must be a finite number, got '\(string)'")
            }
            return parsed
        default:
            throw ToolValidationError.invalid("\(key) must be a number")
        }
    }

    func optionalBool(_ key: String) throws -> Bool? {
        guard let value = values[key] else { return nil }
        switch value {
        case .bool(let bool):
            return bool
        case .string(let raw):
            switch raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
            case "1", "true", "yes", "on":
                return true
            case "0", "false", "no", "off":
                return false
            default:
                throw ToolValidationError.invalid("\(key) must be a boolean")
            }
        default:
            throw ToolValidationError.invalid("\(key) must be a boolean")
        }
    }

    func requiredInt64(_ key: String) throws -> Int64 {
        guard let value = try optionalInt64(key) else {
            throw ToolValidationError.missing(key)
        }
        return value
    }

    func optionalInt64(_ key: String) throws -> Int64? {
        guard let value = values[key] else { return nil }
        switch value {
        case .int(let int):
            return Int64(int)
        case .double(let double):
            guard double.isFinite else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            let truncated = double.rounded(.towardZero)
            guard truncated == double else {
                throw ToolValidationError.invalid("\(key) must be an integer")
            }
            guard truncated >= Double(Int64.min), truncated <= Double(Int64.max) else {
                throw ToolValidationError.invalid("\(key) is out of range")
            }
            return Int64(truncated)
        case .string(let string):
            guard let parsed = Int64(string) else {
                throw ToolValidationError.invalid("\(key) must be an integer, got '\(string)'")
            }
            return parsed
        default:
            throw ToolValidationError.invalid("\(key) must be an integer")
        }
    }

    func requiredValue(_ key: String) throws -> Value {
        guard let value = values[key] else {
            throw ToolValidationError.missing(key)
        }
        return value
    }

    func requiredStringArray(_ key: String) throws -> [String] {
        guard let value = values[key] else {
            throw ToolValidationError.missing(key)
        }
        guard case .array(let array) = value else {
            throw ToolValidationError.invalid("\(key) must be an array of strings")
        }
        let parsed = try array.map { element -> String in
            guard case .string(let string) = element else {
                throw ToolValidationError.invalid("\(key) must contain only strings")
            }
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else {
                throw ToolValidationError.invalid("\(key) must not contain empty values")
            }
            return trimmed
        }
        return parsed
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard values[key] != nil else { return nil }
        return try requiredStringArray(key)
    }

    func optionalObject(_ key: String) throws -> [String: Value]? {
        guard let value = values[key] else { return nil }
        guard let object = value.objectValue else {
            throw ToolValidationError.invalid("\(key) must be an object")
        }
        return object
    }

    func rejectUnknownKeys(_ allowed: [String]) throws {
        let unknown = Set(values.keys).subtracting(Set(allowed))
        guard unknown.isEmpty else {
            let invalid = unknown.sorted().joined(separator: ", ")
            throw ToolValidationError.invalid("unsupported argument(s): \(invalid)")
        }
    }
}

private enum ToolValidationError: LocalizedError {
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

private actor SessionRegistryPool {
    private var registries: [ObjectIdentifier: SessionRegistry] = [:]

    func registry(for memory: MemoryOrchestrator) -> SessionRegistry {
        let key = ObjectIdentifier(memory)
        if let existing = registries[key] {
            return existing
        }

        let created = SessionRegistry()
        registries[key] = created
        return created
    }
}

private actor SessionRegistry {
    struct EndResult {
        let endedSessionID: UUID?
        let hasActiveSessions: Bool
    }

    private var activeSessions: Set<UUID> = []

    func start() -> UUID {
        let sessionID = UUID()
        activeSessions.insert(sessionID)
        return sessionID
    }

    func end(sessionID: UUID?) throws -> EndResult {
        if let sessionID {
            guard activeSessions.remove(sessionID) != nil else {
                throw ToolValidationError.invalid("session_id is not active in this server process; call wax_session_start again")
            }
            return EndResult(endedSessionID: sessionID, hasActiveSessions: !activeSessions.isEmpty)
        }

        switch activeSessions.count {
        case 0:
            return EndResult(endedSessionID: nil, hasActiveSessions: false)
        case 1:
            return EndResult(endedSessionID: activeSessions.removeFirst(), hasActiveSessions: false)
        default:
            throw ToolValidationError.invalid("session_id is required when more than one MCP session is active")
        }
    }

    func isActive(_ sessionID: UUID) -> Bool {
        activeSessions.contains(sessionID)
    }

    func activeSessionIDs() -> [UUID] {
        Array(activeSessions)
    }
}
#endif
