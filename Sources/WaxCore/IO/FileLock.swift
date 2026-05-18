import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package enum LockMode: Sendable {
    case shared
    case exclusive
}

/// Advisory whole-file lock backed by `flock`.
package final class FileLock {
    private let fd: Int32
    private let url: URL
    package private(set) var mode: LockMode
    private var isReleased = false
    private let releaseLock = NSLock()

    private init(fd: Int32, url: URL, mode: LockMode) {
        self.fd = fd
        self.url = url
        self.mode = mode
    }

    deinit {
        if !isReleased {
            while true {
                if flock(fd, LOCK_UN) == 0 { break }
                if errno == EINTR { continue }
                break
            }
            _ = close(fd)
        }
    }

    package static func acquire(at url: URL, mode: LockMode) throws -> FileLock {
        try acquire(at: url, mode: mode, timeout: nil)
    }

    package static func acquire(at url: URL, mode: LockMode, timeout: Duration?) throws -> FileLock {
        let fd = try openFile(at: url, mode: mode)
        do {
            _ = try lock(fd: fd, mode: mode, nonBlocking: false, timeout: timeout, url: url)
            return FileLock(fd: fd, url: url, mode: mode)
        } catch {
            _ = close(fd)
            throw error
        }
    }

    package static func acquireExclusiveOrCreate(at url: URL, timeout: Duration?) throws -> FileLock {
        let mode = LockMode.exclusive
        let fd = try openFile(at: url, mode: mode, createIfMissing: true)
        do {
            _ = try lock(fd: fd, mode: mode, nonBlocking: false, timeout: timeout, url: url)
            return FileLock(fd: fd, url: url, mode: mode)
        } catch {
            _ = close(fd)
            throw error
        }
    }

    package static func tryAcquire(at url: URL, mode: LockMode) throws -> FileLock? {
        let fd = try openFile(at: url, mode: mode)
        do {
            let acquired = try lock(fd: fd, mode: mode, nonBlocking: true)
            if acquired {
                return FileLock(fd: fd, url: url, mode: mode)
            }
            _ = close(fd)
            return nil
        } catch {
            _ = close(fd)
            throw error
        }
    }

    package func upgrade() throws {
        try ensureActive()
        if mode == .exclusive { return }
        _ = try Self.lock(fd: fd, mode: .exclusive, nonBlocking: false)
        mode = .exclusive
    }

    package func downgrade() throws {
        try ensureActive()
        if mode == .shared { return }
        _ = try Self.lock(fd: fd, mode: .shared, nonBlocking: false)
        mode = .shared
    }

    package func release() throws {
        try releaseLock.withLock {
            if isReleased { return }

            var unlockError: WaxError?
            while true {
                if flock(fd, LOCK_UN) == 0 { break }
                if errno == EINTR { continue }
                unlockError = WaxError.lockUnavailable("unlock failed: \(stringError())")
                break
            }

            var closeError: WaxError?
            if close(fd) != 0, errno != EINTR {
                closeError = WaxError.io("close failed: \(stringError())")
            }

            isReleased = true

            if let error = unlockError ?? closeError {
                throw error
            }
        }
    }

    // MARK: - Helpers

    private static func openFile(
        at url: URL,
        mode: LockMode,
        createIfMissing: Bool = false
    ) throws -> Int32 {
        return try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw WaxError.io("Invalid file path: \(url.path)")
            }
            let flags: Int32 = switch mode {
            case .shared: O_RDONLY
            case .exclusive: O_RDWR
            }
            let openFlags = flags | O_CLOEXEC | (createIfMissing ? O_CREAT : 0)
            let descriptor: Int32
            if createIfMissing {
                descriptor = open(path, openFlags, mode_t(0o644))
            } else {
                descriptor = open(path, openFlags)
            }
            guard descriptor >= 0 else {
                throw WaxError.io("open failed for \(url.path): \(stringError())")
            }
            return descriptor
        }
    }

    private static func lock(
        fd: Int32,
        mode: LockMode,
        nonBlocking: Bool,
        timeout: Duration? = nil,
        url: URL? = nil
    ) throws -> Bool {
        var flags: Int32 = (mode == .exclusive) ? LOCK_EX : LOCK_SH
        if nonBlocking { flags |= LOCK_NB }

        let timeoutNanoseconds = timeout.flatMap(durationNanoseconds(_:))
        let useTimedPolling = !nonBlocking && timeoutNanoseconds != nil
        let pollIntervalMicros: useconds_t = 50_000
        let deadline: UInt64? = {
            guard let timeoutNanoseconds else { return nil }
            return DispatchTime.now().uptimeNanoseconds &+ timeoutNanoseconds
        }()

        while true {
            let attemptFlags = useTimedPolling ? (flags | LOCK_NB) : flags
            if flock(fd, attemptFlags) == 0 {
                return true
            }
            let err = errno
            if err == EINTR { continue }
            if err == EWOULDBLOCK || err == EAGAIN {
                if nonBlocking {
                    return false
                }
                if let deadline, DispatchTime.now().uptimeNanoseconds >= deadline {
                    throw WaxError.lockUnavailable(lockTimeoutMessage(url: url, mode: mode, timeout: timeout))
                }
                usleep(pollIntervalMicros)
                continue
            }
            throw WaxError.lockUnavailable("flock failed: \(String(cString: strerror(err)))")
        }
    }

    private static func durationNanoseconds(_ duration: Duration) -> UInt64? {
        let components = duration.components
        guard components.seconds >= 0, components.attoseconds >= 0 else {
            return 0
        }

        let seconds = UInt64(components.seconds)
        let attoseconds = UInt64(components.attoseconds)
        let nanosFromAttoseconds = attoseconds / 1_000_000_000
        let (scaledSeconds, overflowedSeconds) = seconds.multipliedReportingOverflow(by: 1_000_000_000)
        if overflowedSeconds {
            return UInt64.max
        }
        let (total, overflowedTotal) = scaledSeconds.addingReportingOverflow(nanosFromAttoseconds)
        return overflowedTotal ? UInt64.max : total
    }

    private static func lockTimeoutMessage(url: URL?, mode: LockMode, timeout: Duration?) -> String {
        let modeLabel = switch mode {
        case .shared: "shared"
        case .exclusive: "exclusive"
        }
        let target = url?.path ?? "<unknown>"
        let timeoutLabel = timeout.map(formatDuration(_:)) ?? "the configured timeout"
        return "timed out waiting for \(modeLabel) lock on \(target) after \(timeoutLabel)"
    }

    private static func formatDuration(_ duration: Duration) -> String {
        let components = duration.components
        let seconds = Double(components.seconds) + (Double(components.attoseconds) / 1_000_000_000_000_000_000)
        if seconds == 0 {
            return "0s"
        }
        return String(format: "%.2fs", seconds)
    }

    private func ensureActive() throws {
        if isReleased {
            throw WaxError.lockUnavailable("Lock already released for \(url.path)")
        }
    }

    private static func stringError() -> String {
        String(cString: strerror(errno))
    }

    private func stringError() -> String {
        Self.stringError()
    }
}

extension FileLock: @unchecked Sendable {}
