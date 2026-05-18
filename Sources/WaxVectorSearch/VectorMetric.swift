import Foundation
import WaxCore

package enum VectorMetric: Sendable, Equatable {
    case cosine
    case dot
    case l2

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
        guard d.isFinite else { return 0 }
        switch self {
        case .cosine:
            // Metal kernels return cosine distance; expose score where higher is better.
            return 1 - d
        case .dot, .l2:
            // For ip and L2 distances, lower is better.
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
