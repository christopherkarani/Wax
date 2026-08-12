import Foundation
import WaxCore

package enum EmbeddingValidation {
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
        if requireNonZero {
            let magnitudeSquared = vector.reduce(Float.zero) { $0 + $1 * $1 }
            guard magnitudeSquared.isFinite, magnitudeSquared > 0 else {
                throw WaxError.invalidEmbedding(reason: "vector has zero or invalid magnitude")
            }
        }
    }
}
