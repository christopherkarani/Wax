import Foundation
import WaxCore
import WaxVectorSearch

#if MiniLMReranker && canImport(WaxRerankerMiniLM) && canImport(CoreML)
import CoreML
import WaxRerankerMiniLM
#endif

/// Single load path for built-in rerankers.
package enum BuiltInRerankerCompiler {
    package static func compile(
        _ reranker: BuiltInReranker,
        computeUnit: BuiltInEmbeddingComputeUnit,
        timeout: Duration
    ) async throws -> any RerankingProvider {
        switch reranker {
        case .msMarcoMiniLM:
            #if MiniLMReranker && canImport(WaxRerankerMiniLM) && canImport(CoreML)
            guard #available(macOS 15.0, iOS 18.0, *) else {
                throw BuiltInRerankerError.unavailable(reranker)
            }
            do {
                return try await MiniLMReranker.make(
                    computeUnits: computeUnit.commandLineValue.coreMLValue,
                    timeout: timeout
                )
            } catch is AsyncTimeout.TimeoutError {
                throw BuiltInRerankerError.timedOut(reranker)
            }
            #else
            throw BuiltInRerankerError.unavailable(reranker)
            #endif
        }
    }

    /// The stage `source` selects, loading a built-in reranker; `nil` when reranking is off.
    ///
    /// - Parameter automaticProvider: the reranker ``Memory/RerankingSource/automatic`` uses, or
    ///   `nil` when this build has none.
    package static func stage(
        for source: Memory.RerankingSource,
        automaticProvider: @Sendable () -> (any RerankingProvider)? = BuiltInRerankerCompiler.automaticProvider
    ) async throws -> RerankStage? {
        switch source {
        case .automatic:
            guard let provider = automaticProvider() else { return nil }
            return RerankStage(
                provider: provider,
                options: .default,
                scope: .hybridOnly,
                keepsRetrievalOrderOnFailure: true
            )
        case .disabled:
            return nil
        case .builtIn(let reranker, let options):
            let provider = try await BuiltInRerankers.make(reranker)
            return RerankStage(provider: provider, options: options)
        case .custom(let provider, let options):
            return RerankStage(provider: provider, options: options)
        }
    }

    /// Compute unit for the automatic reranker.
    package static let automaticComputeUnit: BuiltInEmbeddingComputeUnit = .cpuOnly

    /// The built-in reranker ``Memory/RerankingSource/automatic`` uses, loaded on first use;
    /// `nil` when the build or OS cannot run it.
    package static func automaticProvider() -> (any RerankingProvider)? {
        #if MiniLMReranker && canImport(WaxRerankerMiniLM) && canImport(CoreML)
        guard #available(macOS 15.0, iOS 18.0, *) else { return nil }
        return LazyBuiltInReranker(.msMarcoMiniLM, computeUnit: automaticComputeUnit)
        #else
        return nil
        #endif
    }
}

/// Loads a built-in reranker on its first use. The model load is cached for the process, so a
/// failed or timed-out load is retried on a later search.
package actor LazyBuiltInReranker: RerankingProvider {
    private let reranker: BuiltInReranker
    private let computeUnit: BuiltInEmbeddingComputeUnit
    private var loading: Task<any RerankingProvider, any Error>?

    package init(_ reranker: BuiltInReranker, computeUnit: BuiltInEmbeddingComputeUnit) {
        self.reranker = reranker
        self.computeUnit = computeUnit
    }

    package func scores(query: String, documents: [String]) async throws -> [Float] {
        try await loaded().scores(query: query, documents: documents)
    }

    private func loaded() async throws -> any RerankingProvider {
        if let loading {
            return try await loading.value
        }
        let reranker = reranker
        let computeUnit = computeUnit
        let task = Task { try await BuiltInRerankers.make(reranker, computeUnit: computeUnit) }
        loading = task
        do {
            return try await task.value
        } catch {
            loading = nil
            throw error
        }
    }
}
