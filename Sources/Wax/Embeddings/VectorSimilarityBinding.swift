import Foundation
import WaxCore
import WaxVectorSearch

/// The store's vector index records the similarity it was built with (the vec segment and
/// its manifest carry it). That record binds the store: an embedder that declares another
/// similarity cannot use the stored vectors, because cosine stores keep only unit-length
/// vectors and a dot-product ranking needs the original lengths.
enum VectorSimilarityBinding {
    /// The similarity of the committed vector index, else the one recorded for the first
    /// commit; `nil` when the store has neither (pending embeddings alone record no similarity).
    static func storedMetric(in wax: Wax) async -> VectorMetric? {
        guard let configuration = await wax.vectorIndexConfiguration() else { return nil }
        return VectorMetric(vecSimilarity: configuration.similarity)
    }

    static func mismatchReason(stored: VectorMetric, declared: VectorMetric) -> String {
        "vector similarity mismatch: the store's vectors are indexed for \(stored.similarityName), "
            + "but the embedder declares \(declared.similarityName); "
            + "open this store with an embedder that declares \(stored.similarityName), or use a new store"
    }
}
