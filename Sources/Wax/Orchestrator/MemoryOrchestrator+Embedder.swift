import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// True when query embedding can run now (``.active`` / ``.degraded``).
    package func isQueryEmbedderReady() async -> Bool {
        embeddingStatus.isQueryEmbedderConfigured
    }

    package func shouldDeferRememberUntilEmbedderReady() async -> Bool {
        guard config.enableVectorSearch else { return false }
        if case .loading = embeddingStatus { return true }
        return false
    }

    /// Wait until automatic compile has attached, or throw if it failed.
    ///
    /// Do not call ``remember(_:metadata:)`` while the status is ``.loading``
    /// with no provider attached — that path persists text-only until explicit
    /// backfill or the broker's automatic repair completes.
    package func waitUntilReadyForRemember() async throws {
        try Task.checkCancellation()
        if readinessFollowInFlight {
            switch embeddingStatus {
            case .loading, .unavailable:
                let waiterID = UUID()
                try await withTaskCancellationHandler {
                    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                        if Task.isCancelled {
                            continuation.resume(throwing: CancellationError())
                        } else {
                            readinessWaiters[waiterID] = continuation
                        }
                    }
                } onCancel: {
                    // Only this caller stops waiting; the shared provider load continues.
                    Task { await self.cancelReadinessWaiter(waiterID) }
                }
            default:
                break
            }
        }
        try Task.checkCancellation()
        switch embeddingStatus {
        case .active, .degraded, .disabled:
            return
        case .loading:
            throw WaxError.io("embedding provider is still loading")
        case .unavailable(let reason):
            throw WaxError.io(reason)
        }
    }

    private func cancelReadinessWaiter(_ id: UUID) {
        readinessWaiters.removeValue(forKey: id)?.resume(throwing: CancellationError())
    }

    private func finishReadinessWaiters() {
        let waiters = readinessWaiters.values
        readinessWaiters.removeAll()
        for waiter in waiters { waiter.resume() }
    }

    package func followReadiness(_ session: EmbeddingReadinessSession) {
        readinessFollowTask?.cancel()
        readinessFollowInFlight = true
        readinessFollowTask = Task {
            defer { markReadinessFollowFinished() }
            let result = await session.waitUntilCompileFinished()
            guard !Task.isCancelled else { return }
            switch result {
            case .success(let provider):
                await self.attachEmbedder(provider)
            case .failure(let error):
                self.markUnavailable(error.localizedDescription)
            }
        }
    }

    private func markReadinessFollowFinished() {
        readinessFollowInFlight = false
        finishReadinessWaiters()
    }

    package func attachEmbedder(_ provider: any EmbeddingProvider) async {
        guard !isClosed else { return }
        if config.requireOnDeviceProviders {
            do {
                try ProviderValidation.validateOnDevice(
                    [.init(name: "embedding provider", executionMode: provider.executionMode)],
                    orchestratorName: "MemoryOrchestrator"
                )
            } catch {
                markUnavailable(error.localizedDescription)
                return
            }
        }
        let binding = await wax.memoryBinding()
        guard !isClosed else { return }
        if let binding, !binding.isEmpty, provider.identity == nil {
            markUnavailable("memory binding requires an identifiable embedder provider")
            return
        }
        if let identity = provider.identity {
            switch await Self.bindingVerdict(binding, identity: identity, wax: wax) {
            case .compatible:
                supersededVectorsReason = nil
            case .needsReembed(let reason):
                supersededVectorsReason = reason
                await loadSupersededReembedProgress(targetModel: identity.model)
            case .incompatible(let mismatch):
                markUnavailable("memory binding mismatch with embedder identity (\(mismatch))")
                return
            }
            guard !isClosed else { return }
        }
        if config.enableVectorSearch {
            do {
                try await session.ensureVectorEngine(
                    dimensions: provider.dimensions,
                    metric: VectorMetric(provider.similarity)
                )
            } catch {
                markUnavailable(error.localizedDescription)
                return
            }
        }
        guard !isClosed else { return }
        if embeddingCache == nil {
            embeddingCache = EmbeddingMemoizer.fromConfig(
                capacity: config.embeddingCacheCapacity,
                enabled: true
            )
        }
        let generation = embedderLifecycleGeneration
        var degradedReason: String?
        if case .loading(true) = embedderLifecycle {
            degradedReason = Self.missingVectorsReason
        } else {
            degradedReason = await vectorCoverageDegradedReason()
        }
        guard !isClosed else { return }
        // Actor reentrancy: the scan suspended. A markUnavailable or a newer
        // attach that landed meanwhile wins; do not overwrite it.
        guard embedderLifecycleGeneration == generation else { return }
        // A text-only remember may also have run; re-read its flag.
        if case .loading(true) = embedderLifecycle {
            degradedReason = Self.missingVectorsReason
        }
        transitionEmbedderLifecycle(
            to: .ready(attached: provider, degradedReason: supersededVectorsReason ?? degradedReason)
        )
        finishReadinessWaiters()
        scheduleAutomaticEmbeddingBackfillIfReady()
    }

    package func markUnavailable(_ reason: String) {
        transitionEmbedderLifecycle(to: .unavailable(reason: reason))
        finishReadinessWaiters()
    }

    package func markUnavailableIfStillLoading(_ reason: String) {
        guard case .loading = embedderLifecycle else { return }
        transitionEmbedderLifecycle(to: .unavailable(reason: reason))
        finishReadinessWaiters()
    }

    /// Provider transitions (attach, unavailable) bump the generation so a
    /// suspended attach or coverage refresh can tell it was superseded.
    /// Reason-only updates and the text-only flag do not.
    private func transitionEmbedderLifecycle(to lifecycle: EmbedderLifecycle) {
        embedderLifecycle = lifecycle
        embedderLifecycleGeneration &+= 1
    }
}
