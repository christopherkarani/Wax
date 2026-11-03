import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// Total lifecycle of the embedding provider. Replaces the former
    /// `(embedder?, embeddingStatus, text-only-write flag)` triple so illegal
    /// combinations are unrepresentable.
    /// Internal only because of the file split.
    enum EmbedderLifecycle: Sendable {
        case disabled
        /// Provider still compiling. `wroteTextOnly` records that saves persisted
        /// without vectors while waiting, forcing the first attach to report degraded.
        case loading(wroteTextOnly: Bool)
        case ready(
            attached: any EmbeddingProvider,
            degradedReason: String?
        )
        case unavailable(reason: String)
    }

    /// Externally visible status, derived from ``embedderLifecycle`` so wire
    /// values stay identical to the pre-lifecycle behavior.
    /// Internal only because of the file split.
    var embeddingStatus: EmbeddingStatus {
        switch embedderLifecycle {
        case .disabled:
            .disabled
        case .loading:
            .loading
        case .ready(let attached, let degradedReason):
            if let degradedReason {
                .degraded(attached.identity, reason: degradedReason)
            } else {
                .active(attached.identity)
            }
        case .unavailable(let reason):
            .unavailable(reason: reason)
        }
    }

    /// Atomic snapshot of the ready provider so a concurrent attach cannot
    /// pair one generation's provider with another's.
    /// Ingest uses ``EmbeddingProvider/embed(batch:)``; query uses
    /// ``EmbeddingProvider/embedQuery`` so Arctic prefixes survive erasure.
    /// Internal only because of the file split.
    var readyEmbedderSnapshot: (any EmbeddingProvider)? {
        if case .ready(let attached, _) = embedderLifecycle {
            return attached
        }
        return nil
    }

    /// Stays open for `config.queryEmbeddingCircuitCooldown` after a query-embedding
    /// timeout, then allows one half-open probe; probe success closes the circuit,
    /// another timeout re-opens it for a fresh cooldown window.
    /// Internal only because of the file split.
    var queryEmbeddingCircuitOpen: Bool {
        guard let openedAtMs = queryEmbeddingCircuitOpenedAtMs else { return false }
        return max(0, nowProvider() - openedAtMs) < Self.circuitCooldownMs(config.queryEmbeddingCircuitCooldown)
    }

    /// Circuit uses wall-clock epoch ms with the same open/half-open thresholds;
    /// sub-ms `Duration` components truncate. A backward system-clock step can
    /// extend an open window until wall time catches up (self-heals on next probe).
    private static func circuitCooldownMs(_ duration: Duration) -> Int64 {
        duration.components.seconds * 1000
            + duration.components.attoseconds / 1_000_000_000_000_000
    }

    /// Internal only because of the file split.
    var requiresEmbedderForSave: Bool {
        switch embeddingStatus {
        case .active, .degraded, .unavailable:
            true
        case .disabled, .loading:
            false
        }
    }
}
