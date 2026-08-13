import Foundation

package actor AsyncMutex {
    private struct Waiter {
        let id: UUID
        let continuation: CheckedContinuation<Void, Error>
    }

    private var isLocked = false
    private var waiters: [Waiter] = []
    /// IDs whose cancel landed before ``enqueue(id:continuation:)`` parked them.
    private var cancelledIDs: Set<UUID> = []

    package init() {}

    /// Number of tasks parked in ``lock()``. Test seam for generation-gate entry.
    package var waiterCount: Int { waiters.count }

    /// Acquires exclusive access. Cancelled waiters are removed from the FIFO and
    /// resume with ``CancellationError`` without taking the lock.
    package func lock() async throws {
        let id = UUID()
        try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
                self.enqueue(id: id, continuation: continuation)
            }
        } onCancel: {
            Task { await self.cancelWaiter(id: id) }
        }
    }

    package func unlock() {
        if waiters.isEmpty {
            isLocked = false
            return
        }
        let next = waiters.removeFirst()
        next.continuation.resume()
    }

    package func withLock<T: Sendable>(_ body: @Sendable () async throws -> T) async throws -> T {
        try await lock()
        defer { unlock() }
        return try await body()
    }

    private func enqueue(id: UUID, continuation: CheckedContinuation<Void, Error>) {
        if cancelledIDs.remove(id) != nil {
            continuation.resume(throwing: CancellationError())
            return
        }
        if Task.isCancelled {
            continuation.resume(throwing: CancellationError())
            return
        }
        if !isLocked {
            isLocked = true
            continuation.resume()
            return
        }
        waiters.append(Waiter(id: id, continuation: continuation))
    }

    private func cancelWaiter(id: UUID) {
        if let index = waiters.firstIndex(where: { $0.id == id }) {
            let waiter = waiters.remove(at: index)
            waiter.continuation.resume(throwing: CancellationError())
            return
        }
        cancelledIDs.insert(id)
    }
}
