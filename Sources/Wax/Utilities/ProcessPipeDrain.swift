#if os(macOS) || os(Linux)
import Foundation

/// Reads a child's stdout and stderr concurrently while it runs.
///
/// A pipe holds about 64 KB. Reading the streams one after another, or only
/// after `waitUntilExit()`, deadlocks once the child fills the unread one.
/// Start the drain right after `Process.run()` and call `wait()` to collect
/// both streams once the child closes them.
package final class ProcessPipeDrain: @unchecked Sendable {
    private let group = DispatchGroup()
    private let lock = NSLock()
    private var stdoutData = Data()
    private var stderrData = Data()

    package init(stdout: Pipe, stderr: Pipe) {
        read(stdout.fileHandleForReading) { [self] data in
            lock.lock()
            stdoutData = data
            lock.unlock()
        }
        read(stderr.fileHandleForReading) { [self] data in
            lock.lock()
            stderrData = data
            lock.unlock()
        }
    }

    /// Blocks until both streams reach EOF.
    package func wait() -> (stdout: Data, stderr: Data) {
        group.wait()
        lock.lock()
        defer { lock.unlock() }
        return (stdoutData, stderrData)
    }

    private func read(_ handle: FileHandle, store: @escaping @Sendable (Data) -> Void) {
        group.enter()
        DispatchQueue.global(qos: .utility).async { [group] in
            store(handle.readDataToEndOfFile())
            group.leave()
        }
    }
}
#endif
