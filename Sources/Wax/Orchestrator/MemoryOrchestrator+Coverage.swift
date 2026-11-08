import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// Returns lightweight store/runtime stats useful for operators and MCP tools.
    package func runtimeStats() async -> RuntimeStats {
        let stats = await wax.stats()
        let walStats = await wax.walStats()
        let storeURL = await wax.fileURL()
        // Before reading `embeddingStatus`: an unreadable coverage scan marks it degraded.
        let framesWithoutVectors = await framesWithoutVectorsCount()

        return RuntimeStats(
            frameCount: stats.frameCount,
            pendingFrames: stats.pendingFrames,
            generation: stats.generation,
            wal: walStats,
            storeURL: storeURL,
            vectorSearchEnabled: config.enableVectorSearch,
            queryEmbedderConfigured: embeddingStatus.isQueryEmbedderConfigured,
            queryEmbedderReady: await isQueryEmbedderReady(),
            queryEmbeddingCircuitOpen: queryEmbeddingCircuitOpen,
            structuredMemoryEnabled: config.enableStructuredMemory,
            accessStatsScoringEnabled: config.enableAccessStatsScoring,
            embedderIdentity: embeddingStatus.identity,
            embeddingStatus: embeddingStatus,
            framesWithoutVectors: framesWithoutVectors,
            vectorsNeedReembed: supersededVectorsReason != nil
        )
    }

    /// Select a real live searchable frame for operator health canaries. The
    /// caller can then constrain the vector query to this ID instead of
    /// validating a synthetic temporary store.
    package func healthCanaryFrame() async -> SurrogateSourceFrame? {
        await wax.activeSurrogateSourceFrames().first
    }

    /// Internal only because of the file split.
    static func bindingVerdict(
        _ binding: MemoryBinding?,
        identity: EmbeddingIdentity,
        wax: Wax
    ) async -> MemoryBindingCompatibility.Verdict {
        let unbound = binding?.isEmpty ?? true
        var storeHasVectors = false
        if unbound, MemoryBindingCompatibility.treatsUnboundVectorsAsSuperseded(for: identity) {
            // Presence only: the manifest count avoids decoding the vector index at open.
            let committedVectors = await wax.committedVecIndexManifest()?.vectorCount ?? 0
            let pendingVectors = await wax.pendingEmbeddingMutations()
            storeHasVectors = committedVectors > 0 || !pendingVectors.isEmpty
        }
        return MemoryBindingCompatibility.verdict(
            binding: binding,
            storeHasVectors: storeHasVectors,
            identity: identity
        )
    }

    /// Internal only because of the file split.
    static let missingVectorsReason = "some saved frames have no vectors"

    private static let coverageUnknownReasonPrefix = "vector coverage unknown"

    private static func coverageUnknownReason(_ error: any Error) -> String {
        "\(coverageUnknownReasonPrefix): \(error)"
    }

    /// Frame IDs in the committed vector index, keyed by its manifest so
    /// `stats()` does not decode an unchanged index on every call.
    struct CommittedVectorCoverage: Sendable {
        let manifest: VecIndexManifest
        let frameIds: Set<UInt64>
    }

    /// `nil` when every live source has a vector. A coverage read/decode failure
    /// is reported as degraded, never as "no vectors" or "fully embedded".
    /// Internal only because of the file split.
    func vectorCoverageDegradedReason() async -> String? {
        let reason: String?
        do {
            reason = try await unembeddedLiveSources().isEmpty ? nil : Self.missingVectorsReason
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "vector coverage scan",
                fallback: "report embedding status degraded"
            )
            reason = Self.coverageUnknownReason(error)
        }
        if let hook = coverageScanHookForTesting {
            await hook()
        }
        return reason
    }

    /// Store-open variant (no actor state yet). `loadedFrameIds` are the frame IDs of the
    /// vector engine the session just loaded (committed segment plus pending embeddings,
    /// the set the store holds right after open); `nil` reads them from the store.
    /// Internal only because of the file split.
    static func vectorCoverageDegradedReason(in wax: Wax, loadedFrameIds: Set<UInt64>?) async -> String? {
        if let loadedFrameIds {
            let sources = await wax.activeSurrogateSourceFrames()
            return sources.allSatisfy { loadedFrameIds.contains($0.id) } ? nil : missingVectorsReason
        }
        do {
            return try await unembeddedLiveSources(in: wax, cached: nil).sources.isEmpty
                ? nil
                : missingVectorsReason
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "vector coverage scan at open",
                fallback: "report embedding status degraded"
            )
            return coverageUnknownReason(error)
        }
    }

    /// 0 when coverage cannot be read; the embedder is then reported degraded.
    /// A later successful read replaces a "coverage unknown" reason (and only
    /// that reason) with the coverage it found.
    private func framesWithoutVectorsCount() async -> UInt64 {
        do {
            let count = UInt64(try await unembeddedLiveSources().count)
            if case .ready(let attached, let reason?) = embedderLifecycle,
               reason.hasPrefix(Self.coverageUnknownReasonPrefix) {
                embedderLifecycle = .ready(
                    attached: attached,
                    degradedReason: count == 0 ? nil : Self.missingVectorsReason
                )
            }
            return count
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "vector coverage for stats",
                fallback: "report 0 frames without vectors and embedding status degraded"
            )
            if case .ready(let attached, _) = embedderLifecycle {
                embedderLifecycle = .ready(attached: attached, degradedReason: Self.coverageUnknownReason(error))
            }
            return 0
        }
    }

    /// Throws when a vector index cannot be read or decoded. Callers must not
    /// treat that as "nothing is embedded" (backfill would re-embed the store).
    /// Internal only because of the file split.
    func unembeddedLiveSources() async throws -> [SurrogateSourceFrame] {
        if let error = coverageReadFailureForTesting { throw error }
        let result = try await Self.unembeddedLiveSources(in: wax, cached: committedVectorCoverage)
        if let committed = result.committed { committedVectorCoverage = committed }
        return result.sources
    }

    /// Internal only because of the file split.
    func embeddedFrameIds() async throws -> Set<UInt64> {
        if let error = coverageReadFailureForTesting { throw error }
        let result = try await Self.embeddedFrameIds(in: wax, cached: committedVectorCoverage)
        if let committed = result.committed { committedVectorCoverage = committed }
        return result.ids
    }

    private static func unembeddedLiveSources(
        in wax: Wax,
        cached: CommittedVectorCoverage?
    ) async throws -> (sources: [SurrogateSourceFrame], committed: CommittedVectorCoverage?) {
        let sources = await wax.activeSurrogateSourceFrames()
        let embedded = try await embeddedFrameIds(in: wax, cached: cached)
        return (sources.filter { !embedded.ids.contains($0.id) }, embedded.committed)
    }

    private static func embeddedFrameIds(
        in wax: Wax,
        cached: CommittedVectorCoverage?
    ) async throws -> (ids: Set<UInt64>, committed: CommittedVectorCoverage?) {
        let pending = await wax.pendingEmbeddingMutations(since: nil)
        func withPending(_ committedIds: Set<UInt64>) -> Set<UInt64> {
            committedIds
                .subtracting(pending.removedFrameIds)
                .union(pending.embeddings.map(\.frameId))
        }
        guard let manifest = await wax.committedVecIndexManifest() else {
            return (withPending([]), nil)
        }
        if let cached, cached.manifest == manifest {
            return (withPending(cached.frameIds), cached)
        }
        let committedIds = try await wax.committedVectorFrameIds()
        // Cache only if no commit replaced the index while we were reading it.
        let unchanged = await wax.committedVecIndexManifest() == manifest
        return (withPending(committedIds), unchanged ? CommittedVectorCoverage(manifest: manifest, frameIds: committedIds) : nil)
    }

    /// Internal only because of the file split; the backfill paths call it while holding `embeddingBackfillStoreMutex`.
    func refreshEmbeddingCoverage() async {
        guard case .ready = embedderLifecycle else {
            return
        }
        let generation = embedderLifecycleGeneration
        let degradedReason = await vectorCoverageDegradedReason()
        // Actor reentrancy: the lifecycle may have changed during the scan
        // (unavailable, or a different provider attached). Never resurrect or
        // swap the provider, and drop a reason computed for a superseded one.
        guard embedderLifecycleGeneration == generation,
              case .ready(let attached, _) = embedderLifecycle else {
            return
        }
        embedderLifecycle = .ready(attached: attached, degradedReason: supersededVectorsReason ?? degradedReason)
    }
}
