import Foundation
import USearch
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

    package func toUSearchMetric() -> USearchMetric {
        switch self {
        case .cosine:
            return .cos
        case .dot:
            return .ip
        case .l2:
            return .l2sq
        }
    }

    package func score(fromDistance d: Float) -> Float {
        guard d.isFinite else { return 0 }
        switch self {
        case .cosine:
            // USearch returns a distance; expose score where higher is better.
            // For cosine distance, common distance is (1 - cosineSimilarity).
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
