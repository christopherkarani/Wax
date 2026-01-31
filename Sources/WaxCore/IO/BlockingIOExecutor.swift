import Dispatch

/// High-performance I/O executor with concurrent reads and exclusive writes.
/// Uses a concurrent dispatch queue with barrier flags for write operations.
///
/// - Read operations execute concurrently for maximum throughput
/// - Write operations use barriers for exclusive access without blocking reads
public final class BlockingIOExecutor: @unchecked Sendable {
    private let queue: DispatchQueue

    public init(label: String, qos: DispatchQoS = .userInitiated) {
        // Use concurrent queue for parallel read operations
        self.queue = DispatchQueue(label: label, qos: qos, attributes: .concurrent)
    }

    /// Execute a read operation concurrently.
    /// Multiple reads can execute in parallel.
    public func run<T>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
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

    /// Execute a non-throwing read operation concurrently.
    public func run<T>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async {
                continuation.resume(returning: work())
            }
        }
    }
    
    /// Execute a write operation with exclusive access.
    /// Uses a barrier to ensure no other operations are running.
    public func runWrite<T>(_ work: @Sendable @escaping () throws -> T) async throws -> T {
        try await withCheckedThrowingContinuation { continuation in
            queue.async(flags: .barrier) {
                do {
                    continuation.resume(returning: try work())
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }
    
    /// Execute a non-throwing write operation with exclusive access.
    public func runWrite<T>(_ work: @Sendable @escaping () -> T) async -> T {
        await withCheckedContinuation { continuation in
            queue.async(flags: .barrier) {
                continuation.resume(returning: work())
            }
        }
    }
}
