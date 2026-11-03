import Foundation

package actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterObservers: [(count: Int, continuation: CheckedContinuation<Void, Never>)] = []

    package init() {}

    /// Tasks parked in `lock()` behind the current holder.
    package var waiterCount: Int { waiters.count }

    package func lock() async {
        if !isLocked {
            isLocked = true
            return
        }

        await withCheckedContinuation { continuation in
            waiters.append(continuation)
            resumeSatisfiedWaiterObservers()
        }
    }

    /// Suspends until at least `count` tasks are parked in `lock()`. Lets a test
    /// order "B is queued behind A" without polling `waiterCount`.
    package func waitUntilWaiting(atLeast count: Int) async {
        if waiters.count >= count { return }
        await withCheckedContinuation { continuation in
            waiterObservers.append((count, continuation))
        }
    }

    private func resumeSatisfiedWaiterObservers() {
        guard !waiterObservers.isEmpty else { return }
        let parked = waiters.count
        let satisfied = waiterObservers.filter { $0.count <= parked }
        waiterObservers.removeAll { $0.count <= parked }
        for observer in satisfied { observer.continuation.resume() }
    }

    package func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.resume()
    }

    package func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async rethrows -> T {
        await lock()
        defer { unlock() }
        return try await body()
    }
}
