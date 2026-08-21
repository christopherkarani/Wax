import Foundation

/// Shared broker argument limits used by decode and handlers.
///
/// Kept independent of ``AgentBrokerService`` so ``BrokerCommand`` decode
/// does not depend on the service actor.
package enum BrokerLimits {
    package static let maxContentBytes = 128 * 1024
    package static let maxTopK = 200
    package static let maxRecallLimit = 100
    package static let maxGraphLimit = 500
    package static let maxGraphIdentifierBytes = 256
    package static let maxGraphKindBytes = 64
    package static let maxMemoryIDBytes = 512
    package static let maxPathBytes = 4096
    package static let maxCompactContextTokenBudget = 32_000
}
