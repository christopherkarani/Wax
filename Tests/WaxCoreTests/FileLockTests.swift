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
