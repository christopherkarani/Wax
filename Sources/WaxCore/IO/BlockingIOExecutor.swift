import Dispatch

/// Runs blocking POSIX I/O off the cooperative thread pool on a concurrent dispatch queue.
/// Callers (the owning actor) are responsible for ordering writes.
package final class BlockingIOExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    package init(label: String, qos: DispatchQoS = .userInitiated) {
        // Use concurrent queue for parallel read operations
        self.queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent)
    }

    /// Execute blocking work on the I/O queue. Multiple calls can run in parallel.
    package func run<T>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    /// Execute non-throwing blocking work on the I/O queue.
    package func run<T>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
}
