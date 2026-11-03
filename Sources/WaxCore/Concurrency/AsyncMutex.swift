import Foundation

package actor AsyncMutex {
    private var isLocked = false
    private var waiters: [CheckedContinuation<Void, Never>] = []
    private var waiterObservers: [UInt64: (count: Int, continuation: CheckedContinuation<Void, Never>)] = [:]
    private var nextObserverID: UInt64 = 0

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

    /// Suspends until at least `count` tasks are parked in `lock()`, or the caller
    /// is cancelled. Lets a test order "B is queued behind A" without polling
    /// `waiterCount`; check `waiterCount` afterwards if cancellation matters.
    package func waitUntilWaiting(atLeast count: Int) async {
        if waiters.count >= count { return }
        let id = nextObserverID
        nextObserverID &+= 1
        await withTaskCancellationHandler {
            await withCheckedContinuation { continuation in
                if Task.isCancelled {
                    continuation.resume()
                    return
                }
                waiterObservers[id] = (count, continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiterObserver(id) }
        }
    }

    private func cancelWaiterObserver(_ id: UInt64) {
        waiterObservers.removeValue(forKey: id)?.continuation.resume()
    }

    private func resumeSatisfiedWaiterObservers() {
        guard !waiterObservers.isEmpty else { return }
        let parked = waiters.count
        let satisfied = waiterObservers.filter { $0.value.count <= parked }
        for id in satisfied.keys { waiterObservers.removeValue(forKey: id) }
        for observer in satisfied.values { observer.continuation.resume() }
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
