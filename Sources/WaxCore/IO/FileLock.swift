import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

public enum LockMode: Sendable {
    case shared
    case exclusive
}

/// Advisory whole-file lock backed by `flock`.
public final class FileLock {
    private let fd: Int32
    private let url: URL
    public private(set) var mode: LockMode
    private var isReleased = false

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

    public static func acquire(at url: URL, mode: LockMode) throws -> FileLock {
        let fd = try openFile(at: url, mode: mode)
        do {
            _ = try lock(fd: fd, mode: mode, nonBlocking: false)
            return FileLock(fd: fd, url: url, mode: mode)
        } catch {
            _ = close(fd)
            throw error
        }
    }

    public static func tryAcquire(at url: URL, mode: LockMode) throws -> FileLock? {
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

    public func upgrade() throws {
        try ensureActive()
        if mode == .exclusive { return }
        _ = try Self.lock(fd: fd, mode: .exclusive, nonBlocking: false)
        mode = .exclusive
    }

    public func downgrade() throws {
        try ensureActive()
        if mode == .shared { return }
        _ = try Self.lock(fd: fd, mode: .shared, nonBlocking: false)
        mode = .shared
    }

    public func release() throws {
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

    // MARK: - Helpers

    private static func openFile(at url: URL, mode: LockMode) throws -> Int32 {
        return try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw WaxError.io("Invalid file path: \(url.path)")
            }
            let flags: Int32 = switch mode {
            case .shared: O_RDONLY
            case .exclusive: O_RDWR
            }
            let descriptor = open(path, flags | O_CLOEXEC)
            guard descriptor >= 0 else {
                throw WaxError.io("open failed for \(url.path): \(stringError())")
            }
            return descriptor
        }
    }

    private static func lock(fd: Int32, mode: LockMode, nonBlocking: Bool) throws -> Bool {
        var flags: Int32 = (mode == .exclusive) ? LOCK_EX : LOCK_SH
        if nonBlocking { flags |= LOCK_NB }

        while true {
            if flock(fd, flags) == 0 {
                return true
            }
            let err = errno
            if err == EINTR { continue }
            if nonBlocking && (err == EWOULDBLOCK || err == EAGAIN) {
                return false
            }
            throw WaxError.lockUnavailable("flock failed: \(String(cString: strerror(err)))")
        }
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
