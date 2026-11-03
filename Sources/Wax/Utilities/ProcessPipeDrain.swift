#if os(macOS) || os(Linux)
import Dispatch
import Foundation

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

/// Reads a child's stdout and stderr concurrently while it runs.
///
/// A pipe holds about 64 KB. Reading the streams one after another, or only
/// after `waitUntilExit()`, deadlocks once the child fills the unread one.
/// Start the drain right after `Process.run()`, then call `wait()` (or
/// `wait(until:)`) to collect both streams once the child closes them.
///
/// Reads are non-blocking dispatch sources, so a deadline can stop the drain
/// even while a grandchild still holds a pipe open; no reader thread stays
/// parked on it. Each stream keeps at most `maxBytesPerStream`; the rest is
/// read and discarded so the writer never blocks.
package final class ProcessPipeDrain: @unchecked Sendable {
    package struct Output: Sendable {
        package var stdout: Data
        package var stderr: Data
        package var stdoutTruncated: Bool
        package var stderrTruncated: Bool
    }

    private let group = DispatchGroup()
    private let queue = DispatchQueue(label: "wax.process-pipe-drain")
    private let maxBytesPerStream: Int
    // Mutated only on `queue`.
    private var buffers = [Data(), Data()]
    private var truncated = [false, false]
    private var sources: [DispatchSourceRead] = []

    package init(stdout: Pipe, stderr: Pipe, maxBytesPerStream: Int = .max) {
        self.maxBytesPerStream = max(0, maxBytesPerStream)
        queue.sync {
            start(stream: 0, handle: stdout.fileHandleForReading)
            start(stream: 1, handle: stderr.fileHandleForReading)
        }
    }

    /// Blocks until both streams reach EOF.
    package func wait() -> Output {
        group.wait()
        return snapshot()
    }

    /// Blocks until both streams reach EOF or `deadline` passes, then stops
    /// reading and returns what arrived.
    package func wait(until deadline: DispatchTime) -> Output {
        if group.wait(timeout: deadline) == .timedOut {
            queue.sync { sources.forEach { $0.cancel() } }
            group.wait()
        }
        return snapshot()
    }

    private func snapshot() -> Output {
        queue.sync {
            Output(
                stdout: buffers[0],
                stderr: buffers[1],
                stdoutTruncated: truncated[0],
                stderrTruncated: truncated[1]
            )
        }
    }

    private func start(stream: Int, handle: FileHandle) {
        let descriptor = handle.fileDescriptor
        _ = fcntl(descriptor, F_SETFL, fcntl(descriptor, F_GETFL) | O_NONBLOCK)
        let source = DispatchSource.makeReadSource(fileDescriptor: descriptor, queue: queue)
        group.enter()
        // Strong `self`: the drain must run to EOF or cancellation even if the
        // caller drops it; dispatch releases the handler once cancelled.
        source.setEventHandler { [self, weak source] in
            if readAvailable(stream: stream, descriptor: descriptor) {
                source?.cancel()
            }
        }
        // The handle owns the descriptor; keep it open until reading stops.
        source.setCancelHandler { [group] in
            withExtendedLifetime(handle) {}
            group.leave()
        }
        sources.append(source)
        source.resume()
    }

    /// Reads everything available. Returns true at EOF or on a read error.
    private func readAvailable(stream: Int, descriptor: Int32) -> Bool {
        var chunk = [UInt8](repeating: 0, count: 64 * 1024)
        while true {
            let count = chunk.withUnsafeMutableBytes { read(descriptor, $0.baseAddress, $0.count) }
            if count > 0 {
                append(chunk[..<count], to: stream)
                continue
            }
            if count == 0 { return true }
            if errno == EINTR { continue }
            return errno != EAGAIN && errno != EWOULDBLOCK
        }
    }

    private func append(_ bytes: ArraySlice<UInt8>, to stream: Int) {
        let room = maxBytesPerStream - buffers[stream].count
        guard room > 0 else {
            truncated[stream] = true
            return
        }
        if bytes.count > room {
            buffers[stream].append(contentsOf: bytes.prefix(room))
            truncated[stream] = true
        } else {
            buffers[stream].append(contentsOf: bytes)
        }
    }
}
#endif
