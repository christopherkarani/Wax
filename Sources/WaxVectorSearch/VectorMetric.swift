import Foundation
import WaxCore

package enum VectorMetric: Sendable, Equatable {
    case cosine
    case dot
    case l2

    package init(_ similarity: VectorSimilarity) {
        switch similarity {
        case .cosine:
            self = .cosine
        case .dotProduct:
            self = .dot
        }
    }

    /// The public ``VectorSimilarity`` spelling (`l2` has none), for error messages.
    package var similarityName: String {
        switch self {
        case .cosine:
            return VectorSimilarity.cosine.rawValue
        case .dot:
            return VectorSimilarity.dotProduct.rawValue
        case .l2:
            return "l2"
        }
    }

    package init?(vecSimilarity: VecSimilarity) {
        switch vecSimilarity {
        case .cosine:
            self = .cosine
        case .dot:
            self = .dot
        case .l2:
            self = .l2
        }
    }

    package func score(fromDistance d: Float) -> Float {
        // A non-finite distance is never a meaningful match: rank it below every real score.
        // (0 would outrank all L2 scores, which are <= 0, and negative dot products.)
        guard d.isFinite else { return -.infinity }
        switch self {
        case .cosine:
            // Metal kernels return cosine distance; expose score where higher is better.
            return 1 - d
        case .dot, .l2:
            // Inner-product distance is -dot and L2 distance is squared Euclidean;
            // negating both matches AccelerateVectorEngine (dot, -squared distance).
            return -d
        }
    }

    func toVecSimilarity() -> VecSimilarity {
        switch self {
        case .cosine:
            return .cosine
        case .dot:
            return .dot
        case .l2:
            return .l2
        }
    }
}
