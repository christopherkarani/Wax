import Foundation
import WaxCore
import WaxVectorSearch

/// High-level orchestrator for text memory RAG, managing ingest, recall, and lifecycle on a Wax store.
package actor MemoryOrchestrator {
    /// Total lifecycle of the embedding provider. Replaces the former
    /// `(embedder?, embeddingStatus, text-only-write flag)` triple so illegal
    /// combinations are unrepresentable.
    /// Internal only because of the file split.
    enum EmbedderLifecycle: Sendable {
        case disabled
        /// Provider still compiling. `wroteTextOnly` records that saves persisted
        /// without vectors while waiting, forcing the first attach to report degraded.
        case loading(wroteTextOnly: Bool)
        case ready(
            attached: any EmbeddingProvider,
            degradedReason: String?
        )
        case unavailable(reason: String)
    }

    /// Internal only because of the file split.
    struct SessionRuntimeStatsCacheEntry: Sendable, Equatable {
        var generation: UInt64
        var frameIds: [UInt64]
        var tokenEstimate: Int
    }

    /// Internal only because of the file split.
    static let accessStatsFrameKind = "wax.internal.access_stats"
    /// Internal only because of the file split.
    static let accessStatsLabel = "wax.internal"
    /// Internal only because of the file split.
    static let accessStatsMarkerKey = "wax.internal.kind"
    /// Internal only because of the file split.
    static let accessStatsMarkerValue = "access_stats"
    /// System frame recording how far a superseded-model re-embed got. Its metadata is
    /// committed together with the re-embedded vectors, so a restart resumes after it.
    private static let reembedProgressFrameKind = "wax.internal.reembed_progress"
    private static let reembedTargetModelKey = "wax.reembed.target_model"
    private static let reembedNextFrameIdKey = "wax.reembed.next_frame_id"
    /// Internal only because of the file split.
    static let contentHashMetadataKey = "wax.content.hash"

    let wax: Wax
    let config: OrchestratorConfig
    /// Internal only because of the file split; immutable after init.
    let ragBuilder: FastRAGContextBuilder
    private let handoffWriteMutex = AsyncMutex()
    private let flushMutex = AsyncMutex()
    private let embeddingBackfillMutex = AsyncMutex()
    private let embeddingBackfillStoreMutex = AsyncMutex()

    let session: WaxSession
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var embedderLifecycle: EmbedderLifecycle
    /// Bumped by `transitionEmbedderLifecycle(to:)`.
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var embedderLifecycleGeneration: UInt64 = 0
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var embeddingCache: EmbeddingMemoizer?
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var committedVectorCoverage: CommittedVectorCoverage?
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var isClosed = false
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var readinessFollowTask: Task<Void, Never>?
    private var automaticEmbeddingBackfillEnabled = false
    private var automaticEmbeddingBackfillTask: Task<Void, Never>?
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var readinessWaiters: [UUID: CheckedContinuation<Void, any Error>] = [:]
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var readinessFollowInFlight = false
    package var searchSnapshotHoldForTesting: Duration? = nil

    package func setSearchSnapshotHoldForTesting(_ duration: Duration?) {
        searchSnapshotHoldForTesting = duration
    }
    package var accessStatsPersistenceHoldForTesting: Duration? = nil
    /// Test seam: awaited by `attachEmbedder` after its coverage scan so a test
    /// can interleave another actor call (e.g. a text-only remember) there.
    /// Internal only because of the file split; set it through `setCoverageScanHookForTesting(_:)`.
    var coverageScanHookForTesting: (@Sendable () async -> Void)? = nil

    package func setCoverageScanHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        coverageScanHookForTesting = hook
    }

    /// Test seam: makes every vector-coverage read throw this error.
    /// Internal only because of the file split; set it through `setCoverageReadFailureForTesting(_:)`.
    var coverageReadFailureForTesting: (any Error)? = nil

    package func setCoverageReadFailureForTesting(_ error: (any Error)?) {
        coverageReadFailureForTesting = error
    }

    /// Test seam: called before each index removal and each soft-delete in
    /// ``delete(frameIds:)``; throwing there simulates that step failing.
    /// Internal only because of the file split; set it through `setDeleteStepHookForTesting(_:)`.
    var deleteStepHookForTesting: (@Sendable (DeleteStep, UInt64) throws -> Void)? = nil

    package func setDeleteStepHookForTesting(_ hook: (@Sendable (DeleteStep, UInt64) throws -> Void)?) {
        deleteStepHookForTesting = hook
    }

    package func setAccessStatsPersistenceHoldForTesting(_ duration: Duration?) {
        accessStatsPersistenceHoldForTesting = duration
    }
    /// Internal only because of the file split; immutable after init.
    let enrichmentPipeline: EnrichmentPipeline?
    /// Internal only because of the file split; immutable after init.
    let accessStatsManager = AccessStatsManager()
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var accessStatsFrameId: UInt64?
    private var hasEnsuredMemoryBinding = false
    /// Set while the store's vectors come from a superseded revision of the attached model
    /// (``MemoryBindingCompatibility/Verdict/needsReembed(reason:)``). The vector lane is
    /// excluded from search, and the next backfill re-embeds every live frame before the
    /// binding is replaced, so an interrupted re-embed restarts on the next open.
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var supersededVectorsReason: String?
    /// Fraction (0...1) of the frame-id range already re-embedded while superseded.
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var supersededReembedProgress: Double = 0
    /// Injectable wall-clock source (ms since epoch). Defaults to real time at this
    /// shell boundary so recall decisions remain pure functions of `(store, query, nowMs)`.
    /// Internal only because of the file split; immutable after init.
    let nowProvider: @Sendable () -> Int64
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var queryEmbeddingCircuitOpenedAtMs: Int64?

    /// Externally visible status, derived from ``embedderLifecycle`` so wire
    /// values stay identical to the pre-lifecycle behavior.
    /// Internal only because of the file split.
    var embeddingStatus: EmbeddingStatus {
        switch embedderLifecycle {
        case .disabled:
            .disabled
        case .loading:
            .loading
        case .ready(let attached, let degradedReason):
            if let degradedReason {
                .degraded(attached.identity, reason: degradedReason)
            } else {
                .active(attached.identity)
            }
        case .unavailable(let reason):
            .unavailable(reason: reason)
        }
    }

    /// Atomic snapshot of the ready provider so a concurrent attach cannot
    /// pair one generation's provider with another's.
    /// Ingest uses ``EmbeddingProvider/embed(batch:)``; query uses
    /// ``EmbeddingProvider/embedQuery`` so Arctic prefixes survive erasure.
    /// Internal only because of the file split.
    var readyEmbedderSnapshot: (any EmbeddingProvider)? {
        if case .ready(let attached, _) = embedderLifecycle {
            return attached
        }
        return nil
    }

    /// Stays open for `config.queryEmbeddingCircuitCooldown` after a query-embedding
    /// timeout, then allows one half-open probe; probe success closes the circuit,
    /// another timeout re-opens it for a fresh cooldown window.
    /// Internal only because of the file split.
    var queryEmbeddingCircuitOpen: Bool {
        guard let openedAtMs = queryEmbeddingCircuitOpenedAtMs else { return false }
        return max(0, nowProvider() - openedAtMs) < Self.circuitCooldownMs(config.queryEmbeddingCircuitCooldown)
    }

    /// Circuit uses wall-clock epoch ms with the same open/half-open thresholds;
    /// sub-ms `Duration` components truncate. A backward system-clock step can
    /// extend an open window until wall time catches up (self-heals on next probe).
    private static func circuitCooldownMs(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000
    }

    /// Internal only because of the file split.
    var requiresEmbedderForSave: Bool {
        switch embeddingStatus {
        case .active, .degraded, .unavailable:
            true
        case .disabled, .loading:
            false
        }
    }
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var sessionRuntimeStatsCache: [UUID: SessionRuntimeStatsCacheEntry] = [:]
    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
    var lastStructuredSystemMs: Int64?

    /// Internal only because of the file split; use only from MemoryOrchestrator's own extensions.
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
        try await self.init(
            at: url,
            config: config,
            embedder: nil,
            waxOptions: waxOptions
        )
    }

    package init(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil,
        waxOptions: WaxOptions = .init(),
        initialEmbeddingStatus: EmbeddingStatus? = nil,
        nowMsProvider: @escaping @Sendable () -> Int64 = { Int64(Date().timeIntervalSince1970 * 1000) }
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
            self.wax = try await Wax.create(
                at: url,
                walSize: Constants.defaultWalSize,
                options: waxOptions
            )
        }

        // Auto-disable vector search when no embedder is provided and no pre-existing
        // vector index exists. This lets the simple `MemoryOrchestrator(at:)` initializer
        // work out-of-the-box with text-only search instead of throwing an error.
        // Callers that pass `initialEmbeddingStatus` own the missing-provider rule
        // (index remains + unavailable / loading + live attach).
        var resolvedConfig = config
        let existingMemoryBinding = await wax.memoryBinding()
        var lifecycle: EmbedderLifecycle
        if let initialEmbeddingStatus {
            lifecycle = Self.lifecycle(from: initialEmbeddingStatus, provider: embedder)
            if case .disabled = initialEmbeddingStatus {
                resolvedConfig.enableVectorSearch = false
            }
        } else if resolvedConfig.enableVectorSearch, embedder == nil, await wax.committedVecIndexManifest() == nil {
            resolvedConfig.enableVectorSearch = false
            lifecycle = .disabled
            WaxDiagnostics.logSwallowed(
                WaxError.io("vector search requested but no EmbeddingProvider configured"),
                context: "MemoryOrchestrator init",
                fallback: "text-only search; Memory(at:) auto-wires the built-in MiniLM embedder on iOS 18/macOS 15+"
            )
        } else if let embedder {
            lifecycle = .ready(
                attached: embedder,
                degradedReason: nil
            )
        } else if resolvedConfig.enableVectorSearch {
            lifecycle = .unavailable(reason: "no embedding provider")
        } else {
            lifecycle = .disabled
        }
        if embedder != nil,
           let degradedReason = await Self.vectorCoverageDegradedReason(in: wax) {
            switch lifecycle {
            case .ready(let attached, _):
                lifecycle = .ready(attached: attached, degradedReason: degradedReason)
            case .disabled, .loading, .unavailable:
                break
            }
        }
        var supersededReason: String?
        if let embedder {
            if let binding = existingMemoryBinding, !binding.isEmpty, embedder.identity == nil {
                try? await wax.close()
                throw WaxError.io(
                    "memory binding requires an identifiable embedder provider"
                )
            }
            if let identity = embedder.identity {
                switch await Self.bindingVerdict(existingMemoryBinding, identity: identity, wax: wax) {
                case .compatible:
                    break
                case .needsReembed(let reason):
                    supersededReason = reason
                    if case .ready(let attached, _) = lifecycle {
                        lifecycle = .ready(attached: attached, degradedReason: reason)
                    }
                case .incompatible(let mismatch):
                    try? await wax.close()
                    throw WaxError.io("memory binding mismatch with embedder identity (\(mismatch))")
                }
            }
        }

        self.config = resolvedConfig
        self.ragBuilder = FastRAGContextBuilder()
        self.embedderLifecycle = lifecycle
        self.nowProvider = nowMsProvider
        self.embeddingCache = EmbeddingMemoizer.fromConfig(
            capacity: resolvedConfig.embeddingCacheCapacity,
            enabled: embedder != nil
        )
        self.enrichmentPipeline = resolvedConfig.enableAsyncEnrichment ? EnrichmentPipeline() : nil
        self.hasEnsuredMemoryBinding = existingMemoryBinding != nil
        self.supersededVectorsReason = supersededReason

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
        if supersededReason != nil {
            // Apps that only ever call remember must still finish the re-embed.
            await loadSupersededReembedProgress(targetModel: embedder?.identity?.model)
            scheduleAutomaticEmbeddingBackfillIfReady()
        }
    }

    /// Maps a caller-declared status onto the lifecycle. Readiness producers always
    /// pair `active`/`degraded` with a provider; if one ever arrives without, the
    /// store falls back to the unavailable state used for vector-enabled stores
    /// that have no provider.
    private static func lifecycle(
        from status: EmbeddingStatus,
        provider: (any EmbeddingProvider)?
    ) -> EmbedderLifecycle {
        switch status {
        case .disabled:
            .disabled
        case .loading:
            .loading(wroteTextOnly: false)
        case .active:
            readyLifecycle(provider: provider, degradedReason: nil)
        case .degraded(_, let reason):
            readyLifecycle(provider: provider, degradedReason: reason)
        case .unavailable(let reason):
            .unavailable(reason: reason)
        }
    }

    private static func readyLifecycle(
        provider: (any EmbeddingProvider)?,
        degradedReason: String?
    ) -> EmbedderLifecycle {
        guard let provider else { return .unavailable(reason: "no embedding provider") }
        return .ready(attached: provider, degradedReason: degradedReason)
    }

    /// Internal only because of the file split.
    func ensureMemoryBindingIfNeeded(_ binding: MemoryBinding?) async throws {
        guard let binding, !binding.isEmpty, !hasEnsuredMemoryBinding else { return }
        // The binding is replaced only after every live frame is re-embedded.
        guard supersededVectorsReason == nil else { return }
        hasEnsuredMemoryBinding = true
#if DEBUG
        Self._recordMemoryBindingEnsureCallForTests()
#endif
        do {
            try await wax.setMemoryBindingIfMissing(binding)
        } catch {
            hasEnsuredMemoryBinding = false
            throw error
        }
    }

    /// Embed live searchable frames that have no vectors using the attached provider.
    ///
    /// Returns the number of frames newly embedded. Already-vectorized frames are
    /// skipped. Throws ``WaxError/missingEmbedder`` when no provider is attached.
    @discardableResult
    package func backfillUnembedded() async throws -> UInt64 {
        try await embeddingBackfillMutex.withLock { [self] in
            try await backfillUnembeddedSerialized()
        }
    }

    private func backfillUnembeddedSerialized() async throws -> UInt64 {
        try Task.checkCancellation()
        guard !isClosed else { throw CancellationError() }
        guard config.enableVectorSearch, let attached = readyEmbedderSnapshot else {
            throw WaxError.missingEmbedder
        }
        var embedded: UInt64 = 0
        if supersededVectorsReason != nil, let identity = attached.identity {
            embedded += try await reembedSupersededVectors(attached: attached, identity: identity)
        }
        return embedded + (try await embedMissingVectors(attached: attached))
    }

    private func embedMissingVectors(attached: any EmbeddingProvider) async throws -> UInt64 {
        let embedder = attached
        let missing = try await embeddingBackfillStoreMutex.withLock { [self] in
            try Task.checkCancellation()
            guard !(await isClosed) else { throw CancellationError() }
            let missing = try await unembeddedLiveSources()
            if missing.isEmpty {
                await refreshEmbeddingCoverage()
            } else {
                try await session.ensureVectorEngine(dimensions: embedder.dimensions)
            }
            return missing
        }
        guard !missing.isEmpty else { return 0 }

        let batchSize = max(1, config.ingestBatchSize)
        var embedded: UInt64 = 0
        var index = 0
        while index < missing.count {
            try Task.checkCancellation()
            let end = min(index + batchSize, missing.count)
            let batch = Array(missing[index..<end])
            let vectors = try await Self.prepareEmbeddingsBatchOptimized(
                chunks: batch.map(\.searchText),
                attached: attached,
                cache: embeddingCache,
                timeout: config.ingestEmbeddingTimeout
            )
            try await embeddingBackfillStoreMutex.withLock { [self] in
                try Task.checkCancellation()
                guard !(await isClosed) else { throw CancellationError() }
                try await wax.putEmbeddingBatch(frameIds: batch.map(\.id), vectors: vectors)
                if let identity = embedder.identity {
                    try await ensureMemoryBindingIfNeeded(
                        MemoryBindingCompatibility.binding(from: identity)
                    )
                }
            }
            embedded += UInt64(batch.count)
            index = end
        }

        try await embeddingBackfillStoreMutex.withLock { [self] in
            try Task.checkCancellation()
            guard !(await isClosed) else { throw CancellationError() }
            await refreshEmbeddingCoverage()
        }
        return embedded
    }

    /// Rewrites every vector written by a superseded model revision, in ascending frame-id
    /// order and bounded batches. Progress is committed as a system marker frame together
    /// with the vectors, so an interrupted run resumes after the last checkpoint. The binding
    /// is swapped (and the marker deleted) in the commit that writes the final vectors.
    private func reembedSupersededVectors(
        attached: any EmbeddingProvider,
        identity: EmbeddingIdentity
    ) async throws -> UInt64 {
        let targetModel = identity.model ?? ""
        let plan = try await embeddingBackfillStoreMutex.withLock { [self] in
            try Task.checkCancellation()
            guard !(await isClosed) else { throw CancellationError() }
            try await session.ensureVectorEngine(dimensions: attached.dimensions)
            let marker = await reembedProgressMarker(targetModel: targetModel)
            return SupersededReembedPlan(
                nextFrameId: marker?.nextFrameId ?? 0,
                endFrameId: await wax.stats().frameCount,
                markerFrameId: marker?.frameId,
                embeddedFrameIds: try await embeddedFrameIds()
            )
        }

        let batchSize = UInt64(max(1, config.ingestBatchSize))
        let span = plan.endFrameId - min(plan.nextFrameId, plan.endFrameId)
        let checkpointEvery = UInt64(
            max(1, config.supersededReembedCheckpointFrames ?? max(512, Int(span / 16)))
        )
        var cursor = plan.nextFrameId
        var markerFrameId = plan.markerFrameId
        var sinceCheckpoint: UInt64 = 0
        var reembedded: UInt64 = 0
        while cursor < plan.endFrameId {
            try Task.checkCancellation()
            let windowEnd = min(cursor + batchSize, plan.endFrameId)
            let batch = await wax.reembedSources(
                frameIds: cursor..<windowEnd,
                embeddedFrameIds: plan.embeddedFrameIds
            )
            if !batch.isEmpty {
                let vectors = try await Self.prepareEmbeddingsBatchOptimized(
                    chunks: batch.map(\.searchText),
                    attached: attached,
                    cache: embeddingCache,
                    timeout: config.ingestEmbeddingTimeout
                )
                try await embeddingBackfillStoreMutex.withLock { [self] in
                    try Task.checkCancellation()
                    guard !(await isClosed) else { throw CancellationError() }
                    try await wax.putEmbeddingBatch(frameIds: batch.map(\.id), vectors: vectors)
                }
                reembedded += UInt64(batch.count)
                sinceCheckpoint += UInt64(batch.count)
            }
            cursor = windowEnd
            supersededReembedProgress = plan.endFrameId == 0 ? 1 : Double(cursor) / Double(plan.endFrameId)
            if sinceCheckpoint >= checkpointEvery, cursor < plan.endFrameId {
                markerFrameId = try await checkpointSupersededReembed(
                    nextFrameId: cursor,
                    targetModel: targetModel,
                    previousMarkerFrameId: markerFrameId
                )
                sinceCheckpoint = 0
            }
        }

        try await completeSupersededReembed(identity: identity, markerFrameId: markerFrameId)
        return reembedded
    }

    private struct SupersededReembedPlan: Sendable {
        var nextFrameId: UInt64
        var endFrameId: UInt64
        var markerFrameId: UInt64?
        var embeddedFrameIds: Set<UInt64>
    }

    private func reembedProgressMarker(targetModel: String) async -> (frameId: UInt64, nextFrameId: UInt64)? {
        guard let marker = await wax.latestCommittedActiveSystemFrameMeta(
            kind: Self.reembedProgressFrameKind,
            fallbackMetadataKey: Self.reembedTargetModelKey,
            fallbackMetadataValue: targetModel
        ) else {
            return nil
        }
        let entries = marker.metadata?.entries ?? [:]
        // A marker left by a re-embed toward another model says nothing about this one.
        guard entries[Self.reembedTargetModelKey] == targetModel,
              let raw = entries[Self.reembedNextFrameIdKey],
              let nextFrameId = UInt64(raw) else {
            return (marker.id, 0)
        }
        return (marker.id, nextFrameId)
    }

    /// Internal only because of the file split.
    func loadSupersededReembedProgress(targetModel: String?) async {
        guard let targetModel,
              let marker = await reembedProgressMarker(targetModel: targetModel) else {
            return
        }
        let frameCount = await wax.stats().frameCount
        supersededReembedProgress = frameCount == 0 ? 0 : min(1, Double(marker.nextFrameId) / Double(frameCount))
    }

    /// Writes the new marker and commits it with every vector re-embedded so far.
    private func checkpointSupersededReembed(
        nextFrameId: UInt64,
        targetModel: String,
        previousMarkerFrameId: UInt64?
    ) async throws -> UInt64 {
        try await embeddingBackfillStoreMutex.withLock { [self] in
            try Task.checkCancellation()
            guard !(await isClosed) else { throw CancellationError() }
            var metadata = Metadata()
            metadata.entries[Self.reembedTargetModelKey] = targetModel
            metadata.entries[Self.reembedNextFrameIdKey] = String(nextFrameId)
            let markerFrameId = try await session.put(
                Data(),
                options: FrameMetaSubset(
                    kind: Self.reembedProgressFrameKind,
                    labels: [Self.accessStatsLabel],
                    role: .system,
                    metadata: metadata
                )
            )
            if let previousMarkerFrameId {
                try await wax.delete(frameId: previousMarkerFrameId)
            }
            try await flush()
            return markerFrameId
        }
    }

    /// Swaps the binding to `identity` and drops the progress marker in the same commit as
    /// the last re-embedded vectors. A crash before that commit keeps the old binding and
    /// the last committed marker, so the next open resumes instead of starting over.
    private func completeSupersededReembed(identity: EmbeddingIdentity, markerFrameId: UInt64?) async throws {
        try await embeddingBackfillStoreMutex.withLock { [self] in
            try Task.checkCancellation()
            guard !(await isClosed) else { throw CancellationError() }
            try await wax.replaceMemoryBinding(MemoryBindingCompatibility.binding(from: identity))
            if let markerFrameId {
                try await wax.delete(frameId: markerFrameId)
            }
            try await flush()
            await markSupersededVectorsReplaced()
        }
    }

    private func markSupersededVectorsReplaced() {
        supersededVectorsReason = nil
        supersededReembedProgress = 1
        hasEnsuredMemoryBinding = true
    }

    /// Broker stores repair historical text-only writes when their provider attaches.
    /// Loading never blocks the caller; repair survives a timed-out readiness waiter.
    package func enableAutomaticEmbeddingBackfill() {
        automaticEmbeddingBackfillEnabled = true
        scheduleAutomaticEmbeddingBackfillIfReady()
    }

    /// Internal only because of the file split; takes `embeddingBackfillStoreMutex` itself.
    func scheduleAutomaticEmbeddingBackfillIfReady() {
        guard automaticEmbeddingBackfillEnabled
                || (supersededVectorsReason != nil && config.automaticallyReembedSupersededVectors),
              config.enableVectorSearch,
              readyEmbedderSnapshot != nil,
              !isClosed,
              automaticEmbeddingBackfillTask == nil else { return }
        automaticEmbeddingBackfillTask = Task(priority: .utility) { [self] in
            defer { automaticEmbeddingBackfillTask = nil }
            do {
                let repaired = try await backfillUnembedded()
                try Task.checkCancellation()
                if repaired > 0 {
                    try await embeddingBackfillStoreMutex.withLock { [self] in
                        try Task.checkCancellation()
                        guard !(await isClosed) else { throw CancellationError() }
                        try await flush()
                    }
                }
            } catch is CancellationError {
                // Closing the store cancels repair before the final flush and close.
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "automatic embedding backfill",
                    fallback: "unembedded or superseded frames remain searchable by text; retry on next open"
                )
            }
        }
    }

    package func rememberHandoff(
        content: String,
        project: String? = nil,
        pendingTasks: [String] = [],
        sessionId: UUID? = nil,
        commit: Bool = true
    ) async throws -> UInt64 {
        try await handoffWriteMutex.withLock { [self] in
            try await rememberHandoffSerialized(
                content: content,
                project: project,
                pendingTasks: pendingTasks,
                sessionId: sessionId,
                commit: commit
            )
        }
    }

    // MARK: - Persistence lifecycle

    package func flush() async throws {
        try await flushMutex.withLock { [self] in
            try await flushSerialized()
        }
    }

    private func flushSerialized() async throws {
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
        isClosed = true
        for waiter in readinessWaiters.values { waiter.resume(throwing: CancellationError()) }
        readinessWaiters.removeAll()
        readinessFollowInFlight = false
        readinessFollowTask?.cancel()
        readinessFollowTask = nil
        automaticEmbeddingBackfillTask?.cancel()
        // Inference may ignore cancellation. Drain only store work; any late
        // inference result checks cancellation/isClosed before entering this lock.
        await embeddingBackfillStoreMutex.withLock {}
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
}
