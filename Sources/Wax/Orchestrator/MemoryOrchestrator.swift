import Foundation
import WaxCore
import WaxVectorSearch

/// High-level orchestrator for text memory RAG, managing ingest, recall, and lifecycle on a Wax store.
package actor MemoryOrchestrator {
    /// Policy controlling when to compute query embeddings for vector search.
    package enum QueryEmbeddingPolicy: Sendable, Equatable {
        case never
        case ifAvailable
        case always
    }

    /// Direct search mode for raw candidate retrieval.
    package enum DirectSearchMode: Sendable, Equatable {
        case text
        case vector
        case hybrid(alpha: Float)

        package static let `default`: DirectSearchMode = .hybrid(alpha: 0.5)
    }

    package enum QueryEmbeddingState: String, Sendable, Equatable {
        case notRequested = "not_requested"
        case available = "available"
        case timeout = "timeout"
        case circuitOpen = "circuit_open"
        case noEmbedder = "no_embedder"
        case vectorDisabled = "vector_disabled"
        case failed = "failed"
    }

    /// Stable search hit DTO for MCP and other raw-search callers.
    package struct MemorySearchHit: Sendable, Equatable {
        package var frameId: UInt64
        package var score: Float
        package var previewText: String?
        package var sources: [SearchResponse.Source]
        package var metadata: [String: String]
        package var explanations: [String]

        package init(
            frameId: UInt64,
            score: Float,
            previewText: String?,
            sources: [SearchResponse.Source],
            metadata: [String: String] = [:],
            explanations: [String] = []
        ) {
            self.frameId = frameId
            self.score = score
            self.previewText = previewText
            self.sources = sources
            self.metadata = metadata
            self.explanations = explanations
        }
    }

    package struct SearchExecution: Sendable, Equatable {
        package var hits: [MemorySearchHit]
        package var requestedModeSummary: String
        package var effectiveModeSummary: String
        package var queryEmbeddingState: QueryEmbeddingState

        package init(
            hits: [MemorySearchHit],
            requestedModeSummary: String,
            effectiveModeSummary: String,
            queryEmbeddingState: QueryEmbeddingState
        ) {
            self.hits = hits
            self.requestedModeSummary = requestedModeSummary
            self.effectiveModeSummary = effectiveModeSummary
            self.queryEmbeddingState = queryEmbeddingState
        }
    }

    package struct RecallExecution: Sendable, Equatable {
        package var context: RAGContext
        package var requestedModeSummary: String
        package var effectiveModeSummary: String
        package var queryEmbeddingState: QueryEmbeddingState

        package init(
            context: RAGContext,
            requestedModeSummary: String,
            effectiveModeSummary: String,
            queryEmbeddingState: QueryEmbeddingState
        ) {
            self.context = context
            self.requestedModeSummary = requestedModeSummary
            self.effectiveModeSummary = effectiveModeSummary
            self.queryEmbeddingState = queryEmbeddingState
        }
    }

    /// Runtime stats DTO exposed to external callers.
    package struct RuntimeStats: Sendable, Equatable {
        package var frameCount: UInt64
        package var pendingFrames: UInt64
        package var generation: UInt64
        package var wal: WaxWALStats
        package var storeURL: URL
        package var vectorSearchEnabled: Bool
        package var queryEmbedderConfigured: Bool
        package var queryEmbeddingCircuitOpen: Bool
        package var structuredMemoryEnabled: Bool
        package var accessStatsScoringEnabled: Bool
        package var embedderIdentity: EmbeddingIdentity?

        package init(
            frameCount: UInt64,
            pendingFrames: UInt64,
            generation: UInt64,
            wal: WaxWALStats,
            storeURL: URL,
            vectorSearchEnabled: Bool,
            queryEmbedderConfigured: Bool,
            queryEmbeddingCircuitOpen: Bool,
            structuredMemoryEnabled: Bool,
            accessStatsScoringEnabled: Bool,
            embedderIdentity: EmbeddingIdentity?
        ) {
            self.frameCount = frameCount
            self.pendingFrames = pendingFrames
            self.generation = generation
            self.wal = wal
            self.storeURL = storeURL
            self.vectorSearchEnabled = vectorSearchEnabled
            self.queryEmbedderConfigured = queryEmbedderConfigured
            self.queryEmbeddingCircuitOpen = queryEmbeddingCircuitOpen
            self.structuredMemoryEnabled = structuredMemoryEnabled
            self.accessStatsScoringEnabled = accessStatsScoringEnabled
            self.embedderIdentity = embedderIdentity
        }
    }

    package struct SessionRuntimeStats: Sendable, Equatable {
        package var active: Bool
        package var sessionId: UUID?
        package var sessionFrameCount: Int
        package var sessionTokenEstimate: Int
        package var pendingFramesStoreWide: UInt64
        package var countsIncludePending: Bool

        package init(
            active: Bool,
            sessionId: UUID?,
            sessionFrameCount: Int,
            sessionTokenEstimate: Int,
            pendingFramesStoreWide: UInt64,
            countsIncludePending: Bool
        ) {
            self.active = active
            self.sessionId = sessionId
            self.sessionFrameCount = sessionFrameCount
            self.sessionTokenEstimate = sessionTokenEstimate
            self.pendingFramesStoreWide = pendingFramesStoreWide
            self.countsIncludePending = countsIncludePending
        }
    }

    package struct HandoffRecord: Sendable, Equatable {
        package var frameId: UInt64
        package var timestampMs: Int64
        package var content: String
        package var project: String?
        package var pendingTasks: [String]

        package init(frameId: UInt64, timestampMs: Int64, content: String, project: String?, pendingTasks: [String]) {
            self.frameId = frameId
            self.timestampMs = timestampMs
            self.content = content
            self.project = project
            self.pendingTasks = pendingTasks
        }
    }

    struct SessionRuntimeStatsCacheEntry: Sendable, Equatable {
        var generation: UInt64
        var frameIds: [UInt64]
        var tokenEstimate: Int
    }

    private static let accessStatsFrameKind = "wax.internal.access_stats"
    private static let accessStatsLabel = "wax.internal"
    private static let accessStatsMarkerKey = "wax.internal.kind"
    private static let accessStatsMarkerValue = "access_stats"
    static let contentHashMetadataKey = "wax.content.hash"

    let wax: Wax
    let config: OrchestratorConfig
    let ragBuilder: FastRAGContextBuilder

    let session: WaxSession
    let embedder: (any EmbeddingProvider)?
    let embeddingCache: EmbeddingMemoizer?
    let enrichmentPipeline: EnrichmentPipeline?
    let accessStatsManager = AccessStatsManager()
    private var accessStatsFrameId: UInt64?
    var hasEnsuredMemoryBinding = false
    var queryEmbeddingCircuitOpenedAt: ContinuousClock.Instant?

    /// Stays open for `config.queryEmbeddingCircuitCooldown` after a query-embedding
    /// timeout, then allows one half-open probe; probe success closes the circuit,
    /// another timeout re-opens it for a fresh cooldown window.
    var queryEmbeddingCircuitOpen: Bool {
        guard let openedAt = queryEmbeddingCircuitOpenedAt else { return false }
        return ContinuousClock.now - openedAt < config.queryEmbeddingCircuitCooldown
    }
    var sessionRuntimeStatsCache: [UUID: SessionRuntimeStatsCacheEntry] = [:]
    private var lastStructuredSystemMs: Int64?

    var currentSessionId: UUID?
    var flushCount: UInt64 = 0
    var lastWriteActivityAt: ContinuousClock.Instant = .now
    var lastScheduledLiveSetMaintenanceReport: ScheduledLiveSetMaintenanceReport?
    var scheduledLiveSetMaintenanceTask: Task<Void, Never>?
    var scheduledLiveSetMaintenanceQueued = false
    var scheduledLiveSetMaintenanceLastCompletedAt: ContinuousClock.Instant?

    package init(
        at url: URL,
        config: OrchestratorConfig = .default,
        waxOptions: WaxOptions = .init()
    ) async throws {
        try await self.init(at: url, config: config, embedder: nil, waxOptions: waxOptions)
    }

    package init(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil,
        waxOptions: WaxOptions = .init()
    ) async throws {
        // Prewarm tokenizer in parallel with Wax file operations
        // This overlaps BPE loading (~9-13ms) with I/O-bound file operations
        async let tokenizerPrewarm: Bool = { 
            do {
                _ = try await TokenCounter.preload()
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "tokenizer prewarm",
                    fallback: "cold start on first use"
                )
            }
            return true
        }()

        if config.requireOnDeviceProviders, let localEmbedder = embedder {
            try ProviderValidation.validateOnDevice(
                [.init(name: "embedding provider", executionMode: localEmbedder.executionMode)],
                orchestratorName: "MemoryOrchestrator"
            )
        }
        
        if FileManager.default.fileExists(atPath: url.path) {
            self.wax = try await Wax.open(at: url, options: waxOptions)
        } else {
            self.wax = try await Wax.create(at: url, options: waxOptions)
        }

        // Auto-disable vector search when no embedder is provided and no pre-existing
        // vector index exists. This lets the simple `MemoryOrchestrator(at:)` initializer
        // work out-of-the-box with text-only search instead of throwing an error.
        var resolvedConfig = config
        let existingMemoryBinding = await wax.memoryBinding()
        if resolvedConfig.enableVectorSearch, embedder == nil, await wax.committedVecIndexManifest() == nil {
            resolvedConfig.enableVectorSearch = false
            WaxDiagnostics.logSwallowed(
                WaxError.io("vector search requested but no EmbeddingProvider configured"),
                context: "MemoryOrchestrator init",
                fallback: "text-only search; Memory(at:) auto-wires the built-in MiniLM embedder on iOS 18/macOS 15+"
            )
        }
        if let identity = embedder?.identity,
           let binding = existingMemoryBinding,
           !MemoryBindingCompatibility.isCompatible(binding, with: identity) {
            let mismatch = MemoryBindingCompatibility.mismatchReason(binding, with: identity) ?? "unknown mismatch"
            try? await wax.close()
            throw WaxError.io("memory binding mismatch with embedder identity (\(mismatch))")
        }

        self.config = resolvedConfig
        self.ragBuilder = FastRAGContextBuilder()
        self.embedder = embedder
        self.embeddingCache = EmbeddingMemoizer.fromConfig(
            capacity: resolvedConfig.embeddingCacheCapacity,
            enabled: embedder != nil
        )
        self.enrichmentPipeline = resolvedConfig.enableAsyncEnrichment ? EnrichmentPipeline() : nil
        self.hasEnsuredMemoryBinding = existingMemoryBinding != nil

        let preference = resolvedConfig.vectorEnginePreference
        let sessionConfig = WaxSession.Config(
            enableTextSearch: resolvedConfig.enableTextSearch,
            enableVectorSearch: resolvedConfig.enableVectorSearch,
            enableStructuredMemory: resolvedConfig.enableStructuredMemory,
            vectorEnginePreference: preference,
            vectorMetric: .cosine,
            vectorDimensions: embedder?.dimensions
        )
        self.session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        // Wait for tokenizer prewarm to complete (should already be done by now)
        _ = await tokenizerPrewarm
        if let enrichmentPipeline {
            let session = self.session
            await enrichmentPipeline.start { task in
                EnrichmentResult(
                    frameId: task.frameId,
                    keywords: KeywordExtractor.extract(from: task.text),
                    entities: EntityExtractor.extract(from: task.text)
                )
            } resultHandler: { result in
                try await Self.persistEnrichmentResult(result, in: session)
            }
        }
        if resolvedConfig.enableAccessStatsScoring {
            try await loadPersistedAccessStatsIfNeeded()
        }
    }


    // MARK: - Session tagging (v1)

    package func startSession() -> UUID {
        let id = UUID()
        currentSessionId = id
        return id
    }

    package func endSession() {
        currentSessionId = nil
    }

    package func activeSessionId() -> UUID? {
        currentSessionId
    }


    package func rememberHandoff(
        content: String,
        project: String? = nil,
        pendingTasks: [String] = [],
        sessionId: UUID? = nil,
        commit: Bool = true
    ) async throws -> UInt64 {
        let pending = pendingTasks
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }

        let text: String
        if pending.isEmpty {
            text = content
        } else {
            let items = pending.map { "- \($0)" }.joined(separator: "\n")
            text = """
            \(content)

            Pending tasks:
            \(items)
            """
        }

        var metadata = Metadata()
        metadata.entries["kind"] = "handoff"
        metadata.entries[MemoryMetadataKeys.type] = MemoryType.handoff.rawValue
        metadata.entries[MemoryMetadataKeys.durability] = MemoryDurability.ephemeral.rawValue
        metadata.entries[MemoryMetadataKeys.createdAtMs] = String(Int64(Date().timeIntervalSince1970 * 1000))
        if let project, !project.isEmpty {
            metadata.entries["project"] = project
            metadata.entries[MemoryMetadataKeys.project] = project
        }
        if !pending.isEmpty {
            metadata.entries["pending_tasks"] = pending.joined(separator: "\n")
        }
        if let effectiveSessionId = sessionId ?? currentSessionId {
            metadata.entries["session_id"] = effectiveSessionId.uuidString
        }

        let frameId = try await session.put(
            Data(text.utf8),
            options: FrameMetaSubset(
                kind: "handoff",
                labels: ["handoff"],
                role: .document,
                searchText: text,
                metadata: metadata
            )
        )
        if config.enableTextSearch {
            try await session.indexText(frameId: frameId, text: text)
        }
        // Ensure latestHandoff() can observe this frame immediately when commit=true.
        if commit {
            try await session.commit()
        }
        return frameId
    }

    package func latestHandoff(project: String? = nil) async throws -> HandoffRecord? {
        guard let latest = await wax.latestCommittedActiveHandoffMeta(project: project) else {
            return nil
        }

        let payload = try await wax.frameContent(frameId: latest.id)
        guard let content = String(data: payload, encoding: .utf8) else {
            throw WaxError.decodingError(reason: "handoff payload is not UTF-8")
        }
        let metadata = latest.metadata?.entries ?? [:]
        let pendingTasks = metadata["pending_tasks"]?
            .split(separator: "\n")
            .map { String($0) } ?? []

        return HandoffRecord(
            frameId: latest.id,
            timestampMs: latest.timestamp,
            content: content,
            project: metadata["project"],
            pendingTasks: pendingTasks
        )
    }

    package func upsertEntity(
        key: EntityKey,
        kind: String,
        aliases: [String] = [],
        commit: Bool = true
    ) async throws -> EntityRowID {
        try ensureStructuredMemoryEnabled()
        let nowMs = Int64(Date().timeIntervalSince1970 * 1000)
        let entityID = try await session.upsertEntity(key: key, kind: kind, aliases: aliases, nowMs: nowMs)
        if commit {
            try await session.commit()
        }
        return entityID
    }

    package func assertFact(
        subject: EntityKey,
        predicate: PredicateKey,
        object: FactValue,
        relation: VersionRelation = .sets,
        validFromMs: Int64? = nil,
        validToMs: Int64? = nil,
        evidence: [StructuredEvidence] = [],
        commit: Bool = true
    ) async throws -> FactRowID {
        try ensureStructuredMemoryEnabled()
        let nowMs = try nextStructuredSystemMs()
        let valid = StructuredTimeRange(fromMs: validFromMs ?? nowMs, toMs: validToMs)
        let system = StructuredTimeRange(fromMs: nowMs, toMs: nil)
        let factID = try await session.assertFact(
            subject: subject,
            predicate: predicate,
            object: object,
            relation: relation,
            valid: valid,
            system: system,
            evidence: evidence
        )
        if commit {
            try await session.commit()
        }
        return factID
    }

    package func retractFact(factId: FactRowID, atMs: Int64? = nil, commit: Bool = true) async throws {
        try ensureStructuredMemoryEnabled()
        let timestamp = try atMs ?? nextStructuredSystemMs()
        try await session.retractFact(factId: factId, atMs: timestamp)
        if commit {
            try await session.commit()
        }
    }

    private func nextStructuredSystemMs() throws -> Int64 {
        let wallNow = Int64(Date().timeIntervalSince1970 * 1000)
        guard wallNow < Int64.max else {
            throw WaxError.encodingError(reason: "structured system timestamp must be less than Int64.max")
        }
        guard let last = lastStructuredSystemMs, wallNow <= last else {
            lastStructuredSystemMs = wallNow
            return wallNow
        }

        let next = last.addingReportingOverflow(1)
        guard !next.overflow, next.partialValue < Int64.max else {
            throw WaxError.encodingError(reason: "structured system timestamp overflow")
        }
        lastStructuredSystemMs = next.partialValue
        return next.partialValue
    }


    package func facts(
        about subject: EntityKey? = nil,
        predicate: PredicateKey? = nil,
        asOfMs: Int64 = Int64.max,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> StructuredFactsResult {
        try ensureStructuredMemoryEnabled()
        return try await session.facts(
            about: subject,
            predicate: predicate,
            asOf: StructuredMemoryAsOf(
                systemTimeMs: systemAsOfMs ?? asOfMs,
                validTimeMs: validAsOfMs ?? asOfMs
            ),
            limit: limit
        )
    }

    package func edges(
        for entity: EntityKey,
        direction: StructuredEdgeDirection,
        predicate: PredicateKey? = nil,
        asOfMs: Int64 = Int64.max,
        systemAsOfMs: Int64? = nil,
        validAsOfMs: Int64? = nil,
        limit: Int = 50
    ) async throws -> StructuredEdgesResult {
        try ensureStructuredMemoryEnabled()
        return try await session.edges(
            for: entity,
            direction: direction,
            predicate: predicate,
            asOf: StructuredMemoryAsOf(
                systemTimeMs: systemAsOfMs ?? asOfMs,
                validTimeMs: validAsOfMs ?? asOfMs
            ),
            limit: limit
        )
    }

    package func resolveEntities(matchingAlias alias: String, limit: Int = 10) async throws -> [StructuredEntityMatch] {
        try ensureStructuredMemoryEnabled()
        return try await session.resolveEntities(matchingAlias: alias, limit: limit)
    }

    // MARK: - Delete

    /// Soft-deletes a frame and removes it from text/vector indexes when those features are enabled.
    ///
    /// Matches ``FrameStore/delete(frameID:)`` durability (delete + commit) while also cleaning
    /// search indexes so forgotten content is not returned by subsequent recalls.
    ///
    /// Soft-delete is pending until a single commit after index removes, so the committed vector
    /// (and text) indexes exclude the deleted frame without a second commit or close-time flush.
    /// If index remove throws, the soft-delete is not committed in this call.
    package func delete(frameId: UInt64) async throws {
        lastWriteActivityAt = .now

        try await wax.delete(frameId: frameId)

        if config.enableTextSearch {
            try await session.removeText(frameId: frameId)
        }
        if config.enableVectorSearch {
            try await session.removeVector(frameId: frameId)
        }
        try await session.commit()
    }

    // MARK: - Persistence lifecycle

    package func flush() async throws {
        if let enrichmentPipeline {
            let drained = try await enrichmentPipeline.waitUntilIdle(
                bestEffortTimeout: config.enrichmentFlushDrainTimeout
            )
            if !drained {
                WaxDiagnostics.logSwallowed(
                    WaxError.io("enrichment drain timed out before flush"),
                    context: "enrichment flush drain timeout",
                    fallback: "continuing flush with pending enrichment work"
                )
            }
        }
        if config.enableAccessStatsScoring {
            try await persistAccessStatsIfNeeded()
        }
        try await session.commit()
        flushCount &+= 1
        enqueueScheduledLiveSetMaintenance()
    }

    package func close() async throws {
        try await flush()
        if let enrichmentPipeline {
            do {
                try await enrichmentPipeline.stop(timeout: config.enrichmentStopTimeout)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "enrichment stop during close",
                    fallback: "continuing close after cancelling enrichment worker"
                )
            }
        }
        let sourceURL = await wax.fileURL()
        let maintenanceReport = await closeTimeLiveSetMaintenanceReport()
        await session.close()
        try await wax.close()
        if let maintenanceReport {
            do {
                try Self.promoteValidatedLiveSetCandidateIfNeeded(
                    maintenanceReport,
                    sourceURL: sourceURL
                )
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "close-time live-set candidate promotion",
                    fallback: "source store left unchanged; validated candidate retained"
                )
            }
        }
    }

    func enrichmentStatsForTesting() async -> EnrichmentPipeline.Stats? {
        guard let enrichmentPipeline else { return nil }
        return await enrichmentPipeline.stats
    }

    package func scheduledLiveSetMaintenanceReport() -> ScheduledLiveSetMaintenanceReport? {
        lastScheduledLiveSetMaintenanceReport
    }

    private func enqueueScheduledLiveSetMaintenance() {
        guard config.liveSetRewriteSchedule.enabled else { return }
        scheduledLiveSetMaintenanceQueued = true
        guard scheduledLiveSetMaintenanceTask == nil else { return }

        scheduledLiveSetMaintenanceTask = Task(priority: .utility) { [self] in
            await drainScheduledLiveSetMaintenanceQueue()
        }
    }

    private func drainScheduledLiveSetMaintenanceQueue() async {
        while scheduledLiveSetMaintenanceQueued {
            scheduledLiveSetMaintenanceQueued = false
            let triggerFlushCount = flushCount
            do {
                if let report = try await runScheduledLiveSetMaintenanceIfNeeded(
                    flushCount: triggerFlushCount,
                    force: false,
                    triggeredByFlush: true
                ) {
                    lastScheduledLiveSetMaintenanceReport = report
                }
            } catch {
                lastScheduledLiveSetMaintenanceReport = ScheduledLiveSetMaintenanceReport(
                    outcome: .rewriteFailed,
                    triggeredByFlush: true,
                    flushCount: triggerFlushCount,
                    deadPayloadBytes: 0,
                    totalPayloadBytes: 0,
                    deadPayloadFraction: 0,
                    candidateURL: nil,
                    rewriteReport: nil,
                    rollbackPerformed: false,
                    notes: ["scheduled maintenance task failed: \(error)"]
                )
            }
        }

        scheduledLiveSetMaintenanceTask = nil
        if scheduledLiveSetMaintenanceQueued {
            enqueueScheduledLiveSetMaintenance()
        }
    }

    private func closeTimeLiveSetMaintenanceReport() async -> ScheduledLiveSetMaintenanceReport? {
        let schedule = config.liveSetRewriteSchedule
        guard schedule.enabled else {
            if let task = scheduledLiveSetMaintenanceTask {
                await task.value
            }
            return lastScheduledLiveSetMaintenanceReport
        }

        if schedule.promoteValidatedCandidateOnClose {
            do {
                let report = try await runScheduledLiveSetMaintenanceNow()
                lastScheduledLiveSetMaintenanceReport = report
                return report
            } catch {
                let report = ScheduledLiveSetMaintenanceReport(
                    outcome: .rewriteFailed,
                    triggeredByFlush: false,
                    flushCount: flushCount,
                    deadPayloadBytes: 0,
                    totalPayloadBytes: 0,
                    deadPayloadFraction: 0,
                    candidateURL: nil,
                    rewriteReport: nil,
                    rollbackPerformed: false,
                    notes: ["close-time maintenance failed: \(error)"]
                )
                lastScheduledLiveSetMaintenanceReport = report
                return report
            }
        }

        if let task = scheduledLiveSetMaintenanceTask {
            await task.value
        }
        return lastScheduledLiveSetMaintenanceReport
    }

    // MARK: - Math helpers

    /// L2 normalization using Accelerate framework for optimal SIMD performance.
    @inline(__always)
    static func normalizedL2(_ vector: [Float]) -> [Float] {
        VectorMath.normalizeL2(vector)
    }

    @inline(__always)
    static func clampHybridAlpha(_ alpha: Float) -> Float {
        guard alpha.isFinite else { return 0.5 }
        return min(1, max(0, alpha))
    }

    private static func writeEmbeddings(_ embeddings: [[Float]], to url: URL) throws {
        var data = Data()
        data.reserveCapacity(8 + embeddings.reduce(0) { $0 + ($1.count * 4) })

        var count = UInt32(embeddings.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for vector in embeddings {
            guard vector.count <= Int(UInt32.max) else {
                throw WaxError.encodingError(reason: "embedding dimension exceeds UInt32.max")
            }
            var dimension = UInt32(vector.count).littleEndian
            withUnsafeBytes(of: &dimension) { data.append(contentsOf: $0) }
            for value in vector {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }

        try data.write(to: url, options: .atomic)
    }

    private static func readEmbeddings(from url: URL) throws -> [[Float]] {
        let data = try Data(contentsOf: url)
        var offset = 0

        func readUInt32() throws -> UInt32 {
            guard data.count - offset >= 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var raw: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { destination in
                data.copyBytes(to: destination, from: offset..<(offset + 4))
            }
            let value = UInt32(littleEndian: raw)
            offset += 4
            return value
        }

        let count = try Int(readUInt32())
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(count)

        for _ in 0..<count {
            let dimension = try Int(readUInt32())
            guard dimension >= 0 else {
                throw WaxError.decodingError(reason: "invalid embedding dimension")
            }
            guard data.count - offset >= dimension * 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var vector: [Float] = []
            vector.reserveCapacity(dimension)
            for _ in 0..<dimension {
                var raw: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &raw) { destination in
                    data.copyBytes(to: destination, from: offset..<(offset + 4))
                }
                let bits = UInt32(littleEndian: raw)
                vector.append(Float(bitPattern: bits))
                offset += 4
            }
            embeddings.append(vector)
        }

        guard offset == data.count else {
            throw WaxError.decodingError(reason: "invalid embedding batch payload trailing bytes")
        }

        return embeddings
    }

    #if DEBUG
    final class DebugCounterState: @unchecked Sendable {
        let lock = NSLock()
        var batchPreparationPathCallCounts: [String: Int] = [:]
        var memoryBindingEnsureCallCounts: [String: Int] = [:]
    }

    private static let debugCounterState = DebugCounterState()
    @TaskLocal private static var activeDebugCounterScopeKey: String?

    package static func _recordBatchPreparationPathCallForTests() {
        debugCounterState.lock.lock()
        let key = activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.batchPreparationPathCallCounts[key, default: 0] += 1
        debugCounterState.lock.unlock()
    }

    package static func _withIsolatedDebugCountersForTests<T: Sendable>(
        _ body: @Sendable (String) async throws -> T
    ) async rethrows -> T {
        let key = UUID().uuidString
        return try await $activeDebugCounterScopeKey.withValue(key) {
            try await body(key)
        }
    }

    package static func _resetBatchPreparationPathCallCountForTests(scopeKey: String? = nil) {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.batchPreparationPathCallCounts[key] = 0
        debugCounterState.lock.unlock()
    }

    package static func _batchPreparationPathCallCountForTests(scopeKey: String? = nil) -> Int {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        let count = debugCounterState.batchPreparationPathCallCounts[key, default: 0]
        debugCounterState.lock.unlock()
        return count
    }

    package static func _recordMemoryBindingEnsureCallForTests() {
        debugCounterState.lock.lock()
        let key = activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.memoryBindingEnsureCallCounts[key, default: 0] += 1
        debugCounterState.lock.unlock()
    }

    package static func _resetMemoryBindingEnsureCallCountForTests(scopeKey: String? = nil) {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        debugCounterState.memoryBindingEnsureCallCounts[key] = 0
        debugCounterState.lock.unlock()
    }

    package static func _memoryBindingEnsureCallCountForTests(scopeKey: String? = nil) -> Int {
        debugCounterState.lock.lock()
        let key = scopeKey ?? activeDebugCounterScopeKey ?? "__global__"
        let count = debugCounterState.memoryBindingEnsureCallCounts[key, default: 0]
        debugCounterState.lock.unlock()
        return count
    }

    package static func _writeEmbeddingsForTesting(_ embeddings: [[Float]], to url: URL) throws {
        try writeEmbeddings(embeddings, to: url)
    }

    package static func _readEmbeddingsForTesting(from url: URL) throws -> [[Float]] {
        try readEmbeddings(from: url)
    }
    #endif


    private func ensureStructuredMemoryEnabled() throws {
        guard config.enableStructuredMemory else {
            throw WaxError.featureDisabled(feature: "structured memory")
        }
    }

    func recordAccessesIfEnabled(frameIds: [UInt64]) async {
        guard config.enableAccessStatsScoring, !frameIds.isEmpty else { return }
        await accessStatsManager.recordAccesses(frameIds: frameIds)
    }

    private func loadPersistedAccessStatsIfNeeded() async throws {
        guard let latest = await wax.latestCommittedActiveSystemFrameMeta(
            kind: Self.accessStatsFrameKind,
            fallbackMetadataKey: Self.accessStatsMarkerKey,
            fallbackMetadataValue: Self.accessStatsMarkerValue
        ) else {
            return
        }

        let payload = try await wax.frameContent(frameId: latest.id)
        do {
            let imported = try JSONDecoder().decode([FrameAccessStats].self, from: payload)
            await accessStatsManager.importStats(imported)
            accessStatsFrameId = latest.id
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "access stats import",
                fallback: "starting with empty access stats"
            )
        }
    }

    private func persistAccessStatsIfNeeded() async throws {
        guard let exported = await accessStatsManager.exportStatsIfDirty() else {
            return
        }
        guard !exported.isEmpty else {
            await accessStatsManager.markPersisted()
            return
        }
        let payload = try JSONEncoder().encode(exported)

        var metadata = Metadata()
        metadata.entries[Self.accessStatsMarkerKey] = Self.accessStatsMarkerValue
        let frameId = try await session.put(
            payload,
            options: FrameMetaSubset(
                kind: Self.accessStatsFrameKind,
                labels: [Self.accessStatsLabel],
                role: .system,
                metadata: metadata
            )
        )
        let previousFrameId = accessStatsFrameId
        // Update the tracked frame ID before superseding so that if supersede throws,
        // the next flush will still attempt to supersede this frame rather than
        // the pre-supersede frame, preventing orphaned stats frames from accumulating.
        accessStatsFrameId = frameId
        if let previous = previousFrameId, previous != frameId {
            do {
                try await wax.supersede(supersededId: previous, supersedingId: frameId)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "access stats supersede",
                    fallback: "previous stats frame may remain active until next flush"
                )
            }
        }
        await accessStatsManager.markPersisted()
    }
}
