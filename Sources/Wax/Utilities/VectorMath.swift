#if canImport(Accelerate)
import Accelerate
#endif
import Foundation

/// High-performance vector math operations.
/// Uses Accelerate vDSP on Apple platforms; falls back to scalar loops on Linux.
public enum VectorMath {

    // MARK: - L2 Normalization

    /// Normalizes a vector to unit length (L2 norm = 1).
    /// Returns the original vector if it's empty or has zero magnitude.
    @inlinable
    public static func normalizeL2(_ vector: [Float]) -> [Float] {
        guard !vector.isEmpty else { return vector }

        #if canImport(Accelerate)
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let magnitude = sqrt(sumOfSquares)
        guard magnitude > 0 else { return vector }
        let inverseMagnitude = 1.0 / magnitude
        var result = [Float](repeating: 0, count: vector.count)
        var scalar = inverseMagnitude
        vDSP_vsmul(vector, 1, &scalar, &result, 1, vDSP_Length(vector.count))
        return result
        #else
        let sumOfSquares = vector.reduce(0) { $0 + $1 * $1 }
        let mag = sqrt(sumOfSquares)
        guard mag > 0 else { return vector }
        let inv = 1.0 / mag
        return vector.map { $0 * inv }
        #endif
    }

    /// Normalizes a vector in-place to unit length (L2 norm = 1).
    @inlinable
    public static func normalizeL2InPlace(_ vector: inout [Float]) {
        guard !vector.isEmpty else { return }

        #if canImport(Accelerate)
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        let magnitude = sqrt(sumOfSquares)
        guard magnitude > 0 else { return }
        var scalar = 1.0 / magnitude
        vDSP_vsmul(vector, 1, &scalar, &vector, 1, vDSP_Length(vector.count))
        #else
        let sumOfSquares = vector.reduce(0) { $0 + $1 * $1 }
        let mag = sqrt(sumOfSquares)
        guard mag > 0 else { return }
        let inv = 1.0 / mag
        for i in vector.indices { vector[i] *= inv }
        #endif
    }

    // MARK: - Dot Product

    /// Computes the dot product of two vectors.
    @inlinable
    public static func dotProduct(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vector dimensions must match")
        guard !a.isEmpty else { return 0 }

        #if canImport(Accelerate)
        var result: Float = 0
        vDSP_dotpr(a, 1, b, 1, &result, vDSP_Length(a.count))
        return result
        #else
        return zip(a, b).reduce(0) { $0 + $1.0 * $1.1 }
        #endif
    }

    // MARK: - Cosine Similarity

    /// Computes cosine similarity between two vectors.
    /// Assumes vectors are already normalized for best performance.
    @inlinable
    public static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        dotProduct(a, b)
    }

    /// Computes cosine similarity, normalizing vectors first if needed.
    @inlinable
    public static func cosineSimilarityNormalized(_ a: [Float], _ b: [Float]) -> Float {
        let normA = normalizeL2(a)
        let normB = normalizeL2(b)
        return dotProduct(normA, normB)
    }

    // MARK: - Euclidean Distance

    /// Computes squared Euclidean distance between two vectors.
    @inlinable
    public static func squaredEuclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        precondition(a.count == b.count, "Vector dimensions must match")
        guard !a.isEmpty else { return 0 }

        #if canImport(Accelerate)
        var diff = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &diff, 1, vDSP_Length(a.count))
        var result: Float = 0
        vDSP_svesq(diff, 1, &result, vDSP_Length(diff.count))
        return result
        #else
        return zip(a, b).reduce(0) { acc, pair in
            let d = pair.0 - pair.1
            return acc + d * d
        }
        #endif
    }

    /// Computes Euclidean distance between two vectors.
    @inlinable
    public static func euclideanDistance(_ a: [Float], _ b: [Float]) -> Float {
        sqrt(squaredEuclideanDistance(a, b))
    }

    // MARK: - Magnitude

    /// Computes the L2 magnitude (length) of a vector.
    @inlinable
    public static func magnitude(_ vector: [Float]) -> Float {
        guard !vector.isEmpty else { return 0 }

        #if canImport(Accelerate)
        var sumOfSquares: Float = 0
        vDSP_svesq(vector, 1, &sumOfSquares, vDSP_Length(vector.count))
        return sqrt(sumOfSquares)
        #else
        return sqrt(vector.reduce(0) { $0 + $1 * $1 })
        #endif
    }

    /// Returns true if the vector is approximately unit length.
    @inlinable
    public static func isNormalizedL2(_ vector: [Float], tolerance: Float = 1e-3) -> Bool {
        guard !vector.isEmpty else { return false }
        let length = magnitude(vector)
        return abs(length - 1.0) <= tolerance
    }

    // MARK: - Vector Addition/Subtraction

    /// Adds two vectors element-wise.
    @inlinable
    public static func add(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == b.count, "Vector dimensions must match")
        guard !a.isEmpty else { return [] }

        #if canImport(Accelerate)
        var result = [Float](repeating: 0, count: a.count)
        vDSP_vadd(a, 1, b, 1, &result, 1, vDSP_Length(a.count))
        return result
        #else
        return zip(a, b).map(+)
        #endif
    }

    /// Subtracts vector b from vector a element-wise.
    @inlinable
    public static func subtract(_ a: [Float], _ b: [Float]) -> [Float] {
        precondition(a.count == b.count, "Vector dimensions must match")
        guard !a.isEmpty else { return [] }

        #if canImport(Accelerate)
        var result = [Float](repeating: 0, count: a.count)
        vDSP_vsub(b, 1, a, 1, &result, 1, vDSP_Length(a.count))
        return result
        #else
        return zip(a, b).map(-)
        #endif
    }

    // MARK: - Scalar Operations

    /// Multiplies a vector by a scalar.
    @inlinable
    public static func scale(_ vector: [Float], by scalar: Float) -> [Float] {
        guard !vector.isEmpty else { return vector }

        #if canImport(Accelerate)
        var result = [Float](repeating: 0, count: vector.count)
        var s = scalar
        vDSP_vsmul(vector, 1, &s, &result, 1, vDSP_Length(vector.count))
        return result
        #else
        return vector.map { $0 * scalar }
        #endif
    }
}
