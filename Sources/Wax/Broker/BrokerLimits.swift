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
    package static let maxEntityResolveLimit = 100
    package static let maxGraphIdentifierBytes = 256
    package static let maxGraphKindBytes = 64
    package static let maxMemoryIDBytes = 512
    package static let maxPathBytes = 4096
    package static let maxCompactContextTokenBudget = 32_000
    package static let maxCompactContextItems = 64
    /// Bounds for the handoff projection returned by `session_open`.
    ///
    /// The token limit is intentionally a deterministic whitespace-token
    /// estimate. It keeps the session bootstrap path independent of the BPE
    /// tokenizer while still preventing unbounded model input.
    package static let maxSessionOpenHandoffContentBytes = 2_048
    package static let maxSessionOpenHandoffContentTokens = 256
    package static let maxSessionOpenPendingTasks = 3
    package static let maxSessionOpenPendingTaskBytes = 256
}
