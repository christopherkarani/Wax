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
    package static func stage(for source: Memory.RerankingSource) async throws -> RerankStage? {
        switch source {
        case .disabled:
            return nil
        case .builtIn(let reranker, let options):
            let provider = try await BuiltInRerankers.make(reranker)
            return RerankStage(provider: provider, options: options)
        case .custom(let provider, let options):
            return RerankStage(provider: provider, options: options)
        }
    }
}
