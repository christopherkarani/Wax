import Foundation
import SimilaritySearchKit
import SimilaritySearchKitMiniLMAll
import WaxCore
import WaxVectorSearch

extension MiniLMEmbeddings: @retroactive @unchecked Sendable {}

public actor MiniLMEmbedder: EmbeddingProvider {
    public nonisolated let dimensions: Int = 384
    public nonisolated let normalize: Bool = true
    public nonisolated let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "SimilaritySearchKit",
        model: "MiniLMAll",
        dimensions: 384,
        normalized: true
    )

    private let model: MiniLMEmbeddings

    public init() {
        self.model = MiniLMEmbeddings()
    }

    public init(model: MiniLMEmbeddings) {
        self.model = model
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard let vector = await model.encode(sentence: text) else {
            throw WaxError.io("MiniLMAll embedding failed to produce a vector.")
        }
        if vector.count != dimensions {
            throw WaxError.io("MiniLMAll produced \(vector.count) dims, expected \(dimensions).")
        }
        return vector
    }
}
