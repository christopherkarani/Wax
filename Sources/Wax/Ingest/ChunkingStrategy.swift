import Foundation

package enum ChunkingStrategy: Sendable, Equatable {
    case tokenCount(targetTokens: Int, overlapTokens: Int)
}
