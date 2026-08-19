import Foundation
import WaxCore
import WaxVectorSearch

/// How a store should obtain its embedding provider.
package enum EmbeddingReadinessSource: Sendable {
    case disabled
    case custom(any EmbeddingProvider)
    case automatic(
        key: EmbeddingLoadKey,
        waitTimeout: Duration?,
        factory: @Sendable () async throws -> any EmbeddingProvider
    )
    case builtIn(
        key: EmbeddingLoadKey,
        waitTimeout: Duration?,
        factory: @Sendable () async throws -> any EmbeddingProvider
    )
}

/// Process-wide embedding readiness: keyed compile, wait, status, and missing-provider rule.
package actor EmbeddingReadiness {
    package typealias WaitError = EmbeddingLoadCoordinator.WaitError

    package static let shared = EmbeddingReadiness()

    private let coordinator = EmbeddingLoadCoordinator()

    package init() {}

    /// Compile or reuse a provider. A timed-out waiter does not cancel the work.
    package func compile(
        key: EmbeddingLoadKey,
        timeout: Duration? = nil,
        factory: @escaping @Sendable () async throws -> any EmbeddingProvider
    ) async throws -> any EmbeddingProvider {
        try await coordinator.provider(for: key, timeout: timeout, factory: factory)
    }

    /// Begin readiness for one store. `.automatic` returns while status is `loading`.
    /// `.builtIn` waits and throws if load fails. `.custom` is already `active`.
    package func open(
        _ source: EmbeddingReadinessSource
    ) async throws -> EmbeddingReadinessSession {
        switch source {
        case .disabled:
            return EmbeddingReadinessSession(status: .disabled, provider: nil)
        case .custom(let provider):
            return EmbeddingReadinessSession(status: .active(provider.identity), provider: provider)
        case .automatic(let key, let waitTimeout, let factory):
            if let ready = await coordinator.readyProvider(for: key) {
                return EmbeddingReadinessSession(
                    status: .active(ready.identity),
                    provider: ready,
                    compileResult: .success(ready)
                )
            }
            let session = EmbeddingReadinessSession(status: .loading, provider: nil)
            await coordinator.start(key: key, factory: factory)
            Task {
                do {
                    let provider = try await self.compile(key: key, timeout: nil, factory: factory)
                    await session.applySuccess(provider)
                } catch {
                    await session.applyFailure(error)
                }
            }
            if let waitTimeout {
                Task {
                    try? await Task.sleep(for: waitTimeout)
                    await session.applyWaitTimeout()
                }
            }
            return session
        case .builtIn(let key, let waitTimeout, let factory):
            let provider = try await compile(key: key, timeout: waitTimeout, factory: factory)
            return EmbeddingReadinessSession(
                status: .active(provider.identity),
                provider: provider,
                compileResult: .success(provider)
            )
        }
    }
}

/// One store's view of embedding readiness. Compile work is process-wide and keyed.
package actor EmbeddingReadinessSession {
    package private(set) var status: EmbeddingStatus
    private var provider: (any EmbeddingProvider)?
    private var waiters: [CheckedContinuation<EmbeddingStatus, Never>] = []
    private var compileResult: Result<any EmbeddingProvider, any Error>?
    private var compileWaiters: [CheckedContinuation<Result<any EmbeddingProvider, any Error>, Never>] = []

    package init(
        status: EmbeddingStatus,
        provider: (any EmbeddingProvider)?,
        compileResult: Result<any EmbeddingProvider, any Error>? = nil
    ) {
        self.status = status
        self.provider = provider
        self.compileResult = compileResult
    }

    package func currentProvider() -> (any EmbeddingProvider)? {
        provider
    }

    package func snapshot() -> (status: EmbeddingStatus, provider: (any EmbeddingProvider)?) {
        (status, provider)
    }

    package func waitUntilSettled() async -> EmbeddingStatus {
        if isSettled(status) {
            return status
        }
        return await withCheckedContinuation { continuation in
            waiters.append(continuation)
        }
    }

    package func waitUntilCompileFinished() async -> Result<any EmbeddingProvider, any Error> {
        if let compileResult {
            return compileResult
        }
        return await withCheckedContinuation { continuation in
            compileWaiters.append(continuation)
        }
    }

    package func applySuccess(_ provider: any EmbeddingProvider) {
        self.provider = provider
        status = .active(provider.identity)
        compileResult = .success(provider)
        finishCompileWaiters()
        finishStatusWaiters()
    }

    package func applyFailure(_ error: Error) {
        provider = nil
        status = .unavailable(reason: error.localizedDescription)
        compileResult = .failure(error)
        finishCompileWaiters()
        finishStatusWaiters()
    }

    /// Store-level timeout: hybrid becomes text, but compile keeps running and can still attach.
    package func applyWaitTimeout() {
        guard case .loading = status else { return }
        status = .unavailable(reason: "embedding provider load timed out")
        finishStatusWaiters()
    }

    private func finishStatusWaiters() {
        let current = status
        for waiter in waiters {
            waiter.resume(returning: current)
        }
        waiters.removeAll()
    }

    private func finishCompileWaiters() {
        guard let compileResult else { return }
        for waiter in compileWaiters {
            waiter.resume(returning: compileResult)
        }
        compileWaiters.removeAll()
    }

    private func isSettled(_ status: EmbeddingStatus) -> Bool {
        switch status {
        case .loading:
            false
        case .disabled, .active, .degraded, .unavailable:
            true
        }
    }
}

/// Maps existing host flags onto embedding-readiness sources. No new flags.
package enum HostEmbeddingReadiness {
    package static func resolveProvider(_ embedderChoice: String) throws -> BuiltInEmbeddingProvider {
        let choice = embedderChoice.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        switch choice {
        case "auto", "minilm", "":
            return .miniLM
        case "arctic":
            return .arctic
        default:
            throw WaxError.encodingError(
                reason: "Invalid embedder choice '\(embedderChoice)'. Expected minilm, arctic, or auto."
            )
        }
    }

    package static func request(
        noEmbedder: Bool,
        requireVector: Bool,
        embedderChoice: String,
        options: BuiltInEmbeddingProviderOptions = .default
    ) throws -> EmbeddingOpenRequest {
        if noEmbedder {
            return .disabled
        }
        let provider = try resolveProvider(embedderChoice)
        if requireVector {
            return .builtIn(provider, options)
        }
        return .automatic(provider, options)
    }
}

/// Caller-facing request used to open a store with embedding readiness.
package enum EmbeddingOpenRequest: Sendable, Equatable {
    case disabled
    case automatic(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions)
    case builtIn(BuiltInEmbeddingProvider, BuiltInEmbeddingProviderOptions)
    case custom(any EmbeddingProvider)

    package static func == (lhs: Self, rhs: Self) -> Bool {
        switch (lhs, rhs) {
        case (.disabled, .disabled):
            true
        case let (.automatic(leftProvider, leftOptions), .automatic(rightProvider, rightOptions)):
            leftProvider == rightProvider && leftOptions == rightOptions
        case let (.builtIn(leftProvider, leftOptions), .builtIn(rightProvider, rightOptions)):
            leftProvider == rightProvider && leftOptions == rightOptions
        case let (.custom(leftProvider), .custom(rightProvider)):
            leftProvider.identity == rightProvider.identity
        default:
            false
        }
    }
}

/// Opens a ``MemoryOrchestrator`` bound to embedding readiness (load, status, attach).
package enum EmbeddingReadinessBinding {
    /// Typed store/provider failures stay typed under `--require-vector`.
    package static func isTypedOpenFailure(_ error: Error) -> Bool {
        error is BuiltInEmbeddingProviderError || error is WaxError
    }

    package static func openOrchestrator(
        at url: URL,
        config: OrchestratorConfig,
        request: EmbeddingOpenRequest,
        waxOptions: WaxOptions = .init(),
        readiness: EmbeddingReadiness = .shared,
        factoryOverride: (@Sendable () async throws -> any EmbeddingProvider)? = nil,
        createWalSize: UInt64? = nil
    ) async throws -> MemoryOrchestrator {
        switch request {
        case .disabled:
            var disabled = config
            disabled.enableVectorSearch = false
            return try await MemoryOrchestrator(
                at: url,
                config: disabled,
                embedder: nil,
                waxOptions: waxOptions,
                initialEmbeddingStatus: .disabled,
                createWalSize: createWalSize
            )
        case .custom(let provider):
            return try await MemoryOrchestrator(
                at: url,
                config: config,
                embedder: provider,
                waxOptions: waxOptions,
                initialEmbeddingStatus: .active(provider.identity),
                createWalSize: createWalSize
            )
        case .automatic(let provider, let options):
            let factory = factoryOverride ?? {
                try await BuiltInEmbeddingCompiler.compile(provider, options: options, skipPrewarm: true)
            }
            let session = try await readiness.open(
                .automatic(
                    key: BuiltInEmbeddingCompiler.loadKey(provider, options: options),
                    waitTimeout: options.tuning.timeoutDuration,
                    factory: factory
                )
            )
            return try await openBound(
                at: url,
                config: config,
                session: session,
                waxOptions: waxOptions,
                createWalSize: createWalSize
            )
        case .builtIn(let provider, let options):
            let factory = factoryOverride ?? {
                try await BuiltInEmbeddingCompiler.compile(provider, options: options, skipPrewarm: false)
            }
            do {
                let session = try await readiness.open(
                    .builtIn(
                        key: BuiltInEmbeddingCompiler.loadKey(provider, options: options),
                        waitTimeout: options.tuning.timeoutDuration,
                        factory: factory
                    )
                )
                return try await openBound(
                    at: url,
                    config: config,
                    session: session,
                    waxOptions: waxOptions,
                    createWalSize: createWalSize
                )
            } catch is EmbeddingReadiness.WaitError {
                throw BuiltInEmbeddingProviderError.timedOut(provider)
            }
        }
    }

    private static func openBound(
        at url: URL,
        config: OrchestratorConfig,
        session: EmbeddingReadinessSession,
        waxOptions: WaxOptions,
        createWalSize: UInt64? = nil
    ) async throws -> MemoryOrchestrator {
        let snapshot = await session.snapshot()
        let orchestrator = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: snapshot.provider,
            waxOptions: waxOptions,
            initialEmbeddingStatus: snapshot.status,
            createWalSize: createWalSize
        )
        let latest = await session.snapshot()
        switch latest.status {
        case .active, .degraded:
            if let provider = latest.provider {
                await orchestrator.attachEmbedder(provider)
            }
        case .unavailable(let reason):
            await orchestrator.markUnavailableIfStillLoading(reason)
        case .disabled, .loading:
            break
        }
        await orchestrator.followReadiness(session)
        return orchestrator
    }
}
