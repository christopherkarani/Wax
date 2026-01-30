import Foundation

/// Explicit time context for structured memory queries.
public struct StructuredMemoryAsOf: Sendable, Equatable {
    public var systemTimeMs: Int64
    public var validTimeMs: Int64

    public init(systemTimeMs: Int64, validTimeMs: Int64) {
        self.systemTimeMs = systemTimeMs
        self.validTimeMs = validTimeMs
    }

    /// Convenience initializer that sets valid and system to the same timestamp.
    public init(asOfMs: Int64) {
        self.systemTimeMs = asOfMs
        self.validTimeMs = asOfMs
    }

    /// Deterministic "latest" sentinel (never wall-clock).
    public static var latest: StructuredMemoryAsOf {
        StructuredMemoryAsOf(asOfMs: Int64.max)
    }
}
