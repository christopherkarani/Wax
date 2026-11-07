import Foundation
import WaxCore
import WaxVectorSearch

/// The store's vector index records the similarity it was built with (the vec segment and
/// its manifest carry it). That record binds the store: an embedder that declares another
/// similarity cannot use the stored vectors, because cosine stores keep only unit-length
/// vectors and a dot-product ranking needs the original lengths.
enum VectorSimilarityBinding {
    /// The similarity of the staged vector index, else of the committed one; `nil` when the
    /// store has no vector index yet (pending embeddings alone record no similarity).
    static func storedMetric(in wax: Wax) async -> VectorMetric? {
        if let staged = await wax.readStagedVecIndexBytes() {
            return VectorMetric(vecSimilarity: staged.similarity)
        }
        if let manifest = await wax.committedVecIndexManifest() {
            return VectorMetric(vecSimilarity: manifest.similarity)
        }
        return nil
    }

    static func mismatchReason(stored: VectorMetric, declared: VectorMetric) -> String {
        "vector similarity mismatch: the store's vectors are indexed for \(stored.similarityName), "
            + "but the embedder declares \(declared.similarityName); "
            + "open this store with an embedder that declares \(stored.similarityName), or use a new store"
    }
}
