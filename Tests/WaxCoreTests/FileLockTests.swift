import Foundation
import Testing
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif
@testable import WaxCore

@Test func exclusiveLockAcquires() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.acquire(at: url, mode: .exclusive)
        #expect(lock.mode == .exclusive)
        try lock.release()
    }
}

@Test func sharedLockAcquires() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.acquire(at: url, mode: .shared)
        #expect(lock.mode == .shared)
        try lock.release()
    }
}

@Test func sharedLockAcquiresOnReadOnlyFile() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw WaxError.io("Invalid file path: \(url.path)") }
            guard chmod(path, mode_t(0o444)) == 0 else {
                throw WaxError.io("chmod failed: \(String(cString: strerror(errno)))")
            }
        }

        let lock = try FileLock.acquire(at: url, mode: .shared)
        #expect(lock.mode == .shared)
        try lock.release()
    }
}

@Test func exclusiveLockThrowsOnReadOnlyFile() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)
        try url.withUnsafeFileSystemRepresentation { path in
            guard let path else { throw WaxError.io("Invalid file path: \(url.path)") }
            guard chmod(path, mode_t(0o444)) == 0 else {
                throw WaxError.io("chmod failed: \(String(cString: strerror(errno)))")
            }
        }

        do {
            _ = try FileLock.acquire(at: url, mode: .exclusive)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }
    }
}

@Test func tryLockExclusiveReturnsNilWhenLocked() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock1 = try FileLock.acquire(at: url, mode: .exclusive)
        let lock2 = try FileLock.tryAcquire(at: url, mode: .exclusive)
        #expect(lock2 == nil)
        try lock1.release()
    }
}

@Test func multipleSharedLocksAllowed() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock1 = try FileLock.acquire(at: url, mode: .shared)
        let lock2 = try FileLock.tryAcquire(at: url, mode: .shared)
        #expect(lock2 != nil)

        try lock1.release()
        try lock2?.release()
    }
}

@Test func exclusiveBlockedByShared() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let sharedLock = try FileLock.acquire(at: url, mode: .shared)
        let exclusiveLock = try FileLock.tryAcquire(at: url, mode: .exclusive)
        #expect(exclusiveLock == nil)
        try sharedLock.release()
    }
}

@Test func upgradeToExclusive() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.acquire(at: url, mode: .shared)
        try lock.upgrade()
        #expect(lock.mode == .exclusive)
        try lock.release()
    }
}

@Test func downgradeToShared() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.acquire(at: url, mode: .exclusive)
        try lock.downgrade()
        #expect(lock.mode == .shared)
        try lock.release()
    }
}

@Test func lockReleasedOnDeinit() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        do {
            _ = try FileLock.acquire(at: url, mode: .exclusive)
        }

        let newLock = try FileLock.tryAcquire(at: url, mode: .exclusive)
        #expect(newLock != nil)
        try newLock?.release()
    }
}

// MARK: - Additional try-lock / lifecycle coverage

@Test func tryAcquireSharedSucceedsWhenFree() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.tryAcquire(at: url, mode: .shared)
        #expect(lock != nil)
        #expect(lock?.mode == .shared)
        try lock?.release()
    }
}

@Test func tryAcquireExclusiveSucceedsWhenFree() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.tryAcquire(at: url, mode: .exclusive)
        #expect(lock != nil)
        #expect(lock?.mode == .exclusive)
        try lock?.release()
    }
}

@Test func upgradeFromExclusiveIsNoOp() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.acquire(at: url, mode: .exclusive)
        // Upgrading an already-exclusive lock is a no-op
        try lock.upgrade()
        #expect(lock.mode == .exclusive)
        try lock.release()
    }
}

@Test func downgradeFromSharedIsNoOp() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.acquire(at: url, mode: .shared)
        // Downgrading an already-shared lock is a no-op
        try lock.downgrade()
        #expect(lock.mode == .shared)
        try lock.release()
    }
}

@Test func releaseIsIdempotent() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)

        let lock = try FileLock.acquire(at: url, mode: .exclusive)
        try lock.release()
        // Second release must not throw
        try lock.release()
    }
}

@Test func tryAcquireOnNonexistentFileThrows() throws {
    let url = TempFiles.uniqueURL()
    // File does not exist; open will fail

    do {
        _ = try FileLock.tryAcquire(at: url, mode: .exclusive)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .io = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func acquireOnNonexistentFileThrows() throws {
    let url = TempFiles.uniqueURL()

    do {
        _ = try FileLock.acquire(at: url, mode: .exclusive)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .io = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func exclusiveLockIsBlockedAcrossProcesses() throws {
    try TempFiles.withTempFile { url in
        FileManager.default.createFile(atPath: url.path, contents: nil)
        let harnessURL = try lockHarnessBinaryURL()

        let process = Process()
        process.executableURL = harnessURL
        process.arguments = ["--lock-hold", url.path, "--hold-seconds", "5"]
        process.environment = ProcessInfo.processInfo.environment
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        try process.run()
        defer {
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
            }
        }

        let deadline = Date().addingTimeInterval(2.0)
        var observedBlocked = false
        while Date() < deadline {
            let probe = try FileLock.tryAcquire(at: url, mode: .exclusive)
            if probe == nil {
                observedBlocked = true
                break
            }
            try probe?.release()
            usleep(50_000)
        }

        #expect(observedBlocked)

        process.terminate()
        process.waitUntilExit()

        let after = try FileLock.tryAcquire(at: url, mode: .exclusive)
        #expect(after != nil)
        try after?.release()
    }
}

private enum LockHarnessResolutionError: Error, CustomStringConvertible {
    case notFound([URL])

    var description: String {
        switch self {
        case .notFound(let candidates):
            let attempted = candidates.map(\.path).joined(separator: "\n")
            return "Could not find WaxCrashHarness binary. Tried:\n\(attempted)"
        }
    }
}

private func lockHarnessBinaryURL() throws -> URL {
    let env = ProcessInfo.processInfo.environment
    if let override = env["WAX_CRASH_HARNESS_BIN"], !override.isEmpty {
        return URL(fileURLWithPath: override)
    }

    let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()
        .deletingLastPathComponent()
        .deletingLastPathComponent()
    let bundleDebugDir = Bundle(for: LockHarnessBundleToken.self)
        .bundleURL
        .deletingLastPathComponent()

    let candidates = [
        bundleDebugDir.appendingPathComponent("WaxCrashHarness"),
        packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("arm64-apple-macosx")
            .appendingPathComponent("debug")
            .appendingPathComponent("WaxCrashHarness"),
        packageRoot
            .appendingPathComponent(".build")
            .appendingPathComponent("debug")
            .appendingPathComponent("WaxCrashHarness"),
    ]

    for candidate in candidates where FileManager.default.isExecutableFile(atPath: candidate.path) {
        return candidate
    }

    throw LockHarnessResolutionError.notFound(candidates)
}

private final class LockHarnessBundleToken {}
