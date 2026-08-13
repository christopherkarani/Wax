import Foundation
import WaxCore

package enum EmbeddingValidation {
    /// Validates width, finiteness, and magnitude.
    ///
    /// Zero-norm vectors are always rejected: cosine similarity is undefined on a
    /// zero vector, so they are malformed for this index regardless of `requireNonZero`.
    package static func validate(
        _ vector: [Float],
        dimensions: Int,
        requireNonZero: Bool = true
    ) throws {
        guard vector.count == dimensions else {
            throw WaxError.invalidEmbedding(
                reason: "dimension mismatch: expected \(dimensions), got \(vector.count)"
            )
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw WaxError.invalidEmbedding(reason: "vector contains non-finite values")
        }
        // Cosine is undefined on a zero vector; reject even when callers pass false.
        _ = requireNonZero
        let magnitudeSquared = vector.reduce(Float.zero) { $0 + $1 * $1 }
        guard magnitudeSquared.isFinite, magnitudeSquared > 0 else {
            throw WaxError.invalidEmbedding(reason: "vector has zero or invalid magnitude")
        }
    }

    /// Single ingest predicate: provider width, identity width (when declared), finite, non-zero.
    package static func validateIngest(
        _ vector: [Float],
        dimensions: Int,
        identity: EmbeddingIdentity?
    ) throws {
        try validate(vector, dimensions: dimensions, requireNonZero: true)
        if let identityDimensions = identity?.dimensions, identityDimensions != vector.count {
            throw WaxError.invalidEmbedding(
                reason: "dimension mismatch: expected \(identityDimensions), got \(vector.count)"
            )
        }
    }
}
