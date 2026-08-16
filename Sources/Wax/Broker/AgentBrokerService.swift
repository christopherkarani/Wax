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

    func resolveSessionID(
        _ explicit: UUID?,
        requiringUnambiguousWorkingMemory includeWorking: Bool
    ) throws -> UUID? {
        if let explicit { return explicit }
        guard includeWorking else { return nil }
        switch activeSessions.count {
        case 0:
            return nil
        case 1:
            return activeSessions.keys.first
        default:
            throw BrokerValidationError.invalid("session_id is required when more than one session is active")
        }
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
        // CLI/MCP often send explicit JSON null for omitted optional filters.
        if value == .null { return nil }
        guard let stringValue = value.stringValue else {
            throw BrokerValidationError.invalid("\(key) must be a string")
        }
        return stringValue
    }

    func optionalStringArray(_ key: String) throws -> [String]? {
        guard let value = values[key] else { return nil }
        if value == .null { return nil }
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
        if value == .null { return nil }
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
        switch value {
        case .int(let intValue):
            return intValue
        case .double(let double):
            guard double.isFinite else {
                throw BrokerValidationError.invalid("\(key) is out of range")
            }
            guard double.rounded() == double else {
                throw BrokerValidationError.invalid("\(key) must be an integer")
            }
            guard let intValue = Int64(exactly: double) else {
                throw BrokerValidationError.invalid("\(key) is out of range")
            }
            return intValue
        default:
            throw BrokerValidationError.invalid("\(key) must be an integer")
        }
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
