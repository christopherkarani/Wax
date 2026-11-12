import Foundation
import WaxCore
import WaxVectorSearch

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM
#endif

#if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
import WaxVectorSearchArctic
#endif

#if E5Embeddings && canImport(WaxVectorSearchE5) && canImport(CoreML)
import WaxVectorSearchE5
#endif

/// Single compile path for built-in MiniLM / Arctic / e5 providers.
package enum BuiltInEmbeddingCompiler {
    /// The built-ins this build and OS can load, with the identity each records in a store.
    package static func bindingIdentities() -> [BuiltInEmbeddingProvider: EmbeddingIdentity] {
        var identities: [BuiltInEmbeddingProvider: EmbeddingIdentity] = [:]
        guard #available(macOS 15.0, iOS 18.0, *) else { return identities }
        #if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
        identities[.miniLM] = MiniLMEmbedder.bindingIdentity
        #endif
        #if ArcticEmbeddings && canImport(WaxVectorSearchArctic) && canImport(CoreML)
        identities[.arctic] = ArcticEmbedder.bindingIdentity
        #endif
        #if E5Embeddings && canImport(WaxVectorSearchE5) && canImport(CoreML)
        identities[.e5] = E5Embedder.bindingIdentity
        #endif
        return identities
    }

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
        case .e5:
            #if E5Embeddings && canImport(WaxVectorSearchE5) && canImport(CoreML)
            guard #available(macOS 15.0, iOS 18.0, *) else {
                throw BuiltInEmbeddingProviderError.unavailable(provider)
            }
            return try await E5Embedder.makeCommandLineEmbedder(
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
