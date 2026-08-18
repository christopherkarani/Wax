import Foundation
import WaxCore
import WaxVectorSearch

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import WaxVectorSearchArctic
#endif

/// Single compile path for built-in MiniLM / Arctic providers.
package enum BuiltInEmbeddingCompiler {
    package static func loadKey(
        _ provider: BuiltInEmbeddingProvider,
        options: BuiltInEmbeddingProviderOptions
    ) -> EmbeddingLoadKey {
        EmbeddingLoadKey(
            provider: provider.rawValue,
            configuration: options.tuning.brokerCacheKey
        )
    }

    package static func compile(
        _ provider: BuiltInEmbeddingProvider,
        options: BuiltInEmbeddingProviderOptions,
        skipPrewarm: Bool = false
    ) async throws -> any EmbeddingProvider {
        switch provider {
        case .miniLM:
            #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
            guard #available(macOS 15.0, iOS 18.0, *) else {
                throw BuiltInEmbeddingProviderError.unavailable(provider)
            }
            return try await MiniLMEmbedder.makeCommandLineEmbedder(
                prewarmBatchSize: options.prewarmBatchSize,
                skipPrewarm: skipPrewarm,
                tuning: options.tuning
            )
            #else
            throw BuiltInEmbeddingProviderError.unavailable(provider)
            #endif
        case .arctic:
            #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
            guard #available(macOS 15.0, iOS 18.0, *) else {
                throw BuiltInEmbeddingProviderError.unavailable(provider)
            }
            return try await ArcticEmbedder.makeCommandLineEmbedder(
                prewarmBatchSize: options.prewarmBatchSize,
                skipPrewarm: skipPrewarm,
                tuning: options.tuning
            )
            #else
            throw BuiltInEmbeddingProviderError.unavailable(provider)
            #endif
        }
    }
}
