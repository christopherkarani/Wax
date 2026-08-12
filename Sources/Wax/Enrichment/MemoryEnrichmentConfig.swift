import Foundation

public extension Memory {
    /// Selects whether the built-in keyword/entity enrichment pipeline runs.
    enum EnrichmentPolicy: Sendable, Equatable {
        /// Do not start the enrichment pipeline.
        case disabled
        /// Run deterministic keyword and entity extraction after ingest.
        case builtIn
    }

    /// Snapshot of enrichment pipeline progress.
    ///
    /// Returned from ``Memory/Stats-swift.struct/enrichment`` when the store was
    /// opened with ``EnrichmentPolicy/builtIn``; `nil` when enrichment is disabled.
    struct EnrichmentStats: Sendable, Equatable {
        public var processedCount: UInt64
        public var pendingCount: UInt64
        public var isRunning: Bool

        public init(processedCount: UInt64, pendingCount: UInt64, isRunning: Bool) {
            self.processedCount = processedCount
            self.pendingCount = pendingCount
            self.isRunning = isRunning
        }
    }
}
