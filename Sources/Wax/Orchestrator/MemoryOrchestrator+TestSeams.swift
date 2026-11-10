import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    package func setSearchSnapshotHoldForTesting(_ duration: Duration?) {
        searchSnapshotHoldForTesting = duration
    }

    package func setCoverageScanHookForTesting(_ hook: (@Sendable () async -> Void)?) {
        coverageScanHookForTesting = hook
    }

    package func setCoverageReadFailureForTesting(_ error: (any Error)?) {
        coverageReadFailureForTesting = error
    }

    package func setDeleteStepHookForTesting(_ hook: (@Sendable (DeleteStep, UInt64) throws -> Void)?) {
        deleteStepHookForTesting = hook
    }

    package func setAccessStatsPersistenceHoldForTesting(_ duration: Duration?) {
        accessStatsPersistenceHoldForTesting = duration
    }

    /// True while `close()` waits for writes admitted before it began.
    package func isWaitingForWritesToDrainForTesting() -> Bool {
        isWaitingForInFlightWrites
    }
}
