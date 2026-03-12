import Foundation

/// Explicit time context for structured memory queries.
package struct StructuredMemoryAsOf: Sendable, Equatable {
    package var systemTimeMs: Int64
    package var validTimeMs: Int64

    package init(systemTimeMs: Int64, validTimeMs: Int64) {
        self.systemTimeMs = systemTimeMs
        self.validTimeMs = validTimeMs
    }

    /// Convenience initializer that sets valid and system to the same timestamp.
    package init(asOfMs: Int64) {
        self.systemTimeMs = asOfMs
        self.validTimeMs = asOfMs
    }

    /// Deterministic "latest" sentinel (never wall-clock).
    package static var latest: StructuredMemoryAsOf {
        StructuredMemoryAsOf(asOfMs: Int64.max)
    }
}
