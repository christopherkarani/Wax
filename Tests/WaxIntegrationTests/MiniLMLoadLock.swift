import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Process-wide lock so MiniLM-heavy tests do not starve each other under a
/// parallel `swift test` run (Core ML / ANE compile is a single machine resource).
enum MiniLMLoadLock {
    private static let queue = DispatchQueue(label: "wax.minilm.load.lock")

    static func withExclusiveLock<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async throws -> T {
        let path = "/tmp/wax-minilm-load.lock"
        let fd = open(path, O_CREAT | O_RDWR, 0o644)
        guard fd >= 0 else {
            return try await body()
        }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            queue.async {
                let status = flock(fd, LOCK_EX)
                if status == 0 {
                    continuation.resume()
                } else {
                    continuation.resume(throwing: POSIXError(.EDEADLK))
                }
            }
        }
        defer {
            flock(fd, LOCK_UN)
            close(fd)
        }
        return try await body()
    }
}
