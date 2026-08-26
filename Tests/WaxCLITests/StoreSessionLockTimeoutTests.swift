import Foundation
import Testing
@testable import wax_cli

struct StoreSessionLockTimeoutTests {
    @Test func emptyEnvironmentUsesThirtySecondCLILockWait() {
        let timeout = StoreSession.lockWaitTimeout(environment: [:])
        #expect(timeout == .milliseconds(30_000))
    }

    @Test func lockTimeoutEnvOverrideIsHonored() {
        let timeout = StoreSession.lockWaitTimeout(
            environment: ["WAX_LOCK_TIMEOUT_SECS": "10"]
        )
        #expect(timeout == .milliseconds(10_000))
    }

    @Test func remainingLockWaitPreservesSingleBudget() {
        #expect(
            StoreSession.remainingLockWait(budget: .milliseconds(30_000), elapsed: .zero)
                == .milliseconds(30_000)
        )
        #expect(
            StoreSession.remainingLockWait(
                budget: .milliseconds(30_000),
                elapsed: .milliseconds(12_000)
            ) == .milliseconds(18_000)
        )
        #expect(
            StoreSession.remainingLockWait(
                budget: .milliseconds(30_000),
                elapsed: .milliseconds(40_000)
            ) == .zero
        )
        #expect(
            StoreSession.remainingLockWait(budget: nil, elapsed: .milliseconds(5_000)) == nil
        )
    }
}
