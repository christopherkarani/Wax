import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@inline(__always)
private func posixClose(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.close(fd)
    #else
    Glibc.close(fd)
    #endif
}

@inline(__always)
private func posixFsync(_ fd: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.fsync(fd)
    #else
    Glibc.fsync(fd)
    #endif
}

@inline(__always)
private func posixOpen(_ path: UnsafePointer<CChar>, _ flags: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, flags)
    #else
    Glibc.open(path, flags)
    #endif
}

@inline(__always)
private func posixOpen(_ path: UnsafePointer<CChar>, _ flags: Int32, _ mode: mode_t) -> Int32 {
    #if canImport(Darwin)
    Darwin.open(path, flags, mode)
    #else
    Glibc.open(path, flags, mode)
    #endif
}

enum FDFileReadFault: Sendable, Equatable {
    case eintr(retries: Int = 1)
    case eio
    case shortRead(maxBytes: Int)
}

enum FDFileWriteFault: Sendable, Equatable {
    case eintr(retries: Int = 1)
    case eio
    case shortWrite(maxBytes: Int)
}

/// A file operation observed while a fault plan with `recordsOperations` is installed.
enum FDFileOperation: Sendable, Equatable {
    case pwrite(offset: UInt64, length: Int)
    case fsync
}

struct FDFileFaultPlan: Sendable, Equatable {
    var pread: [FDFileReadFault]
    var pwrite: [FDFileWriteFault]
    /// Record every `pwrite` and `fsync`, in order, for ordering assertions in tests.
    var recordsOperations: Bool

    init(
        pread: [FDFileReadFault] = [],
        pwrite: [FDFileWriteFault] = [],
        recordsOperations: Bool = false
    ) {
        self.pread = pread
        self.pwrite = pwrite
        self.recordsOperations = recordsOperations
    }
}

/// POSIX file descriptor-backed file with offset-based I/O.
package final class FDFile {
    private enum ReadDirective {
        case none
        case fail(errno: Int32)
        case short(maxBytes: Int)
    }

    private enum WriteDirective {
        case none
        case fail(errno: Int32)
        case short(maxBytes: Int)
    }

    private final class FaultInjectionState {
        private let lock = NSLock()
        private var preadPlan: [FDFileReadFault]
        private var pwritePlan: [FDFileWriteFault]
        private let recordsOperations: Bool
        private var operations: [FDFileOperation] = []

        init(plan: FDFileFaultPlan) {
            self.preadPlan = plan.pread
            self.pwritePlan = plan.pwrite
            self.recordsOperations = plan.recordsOperations
        }

        func record(_ operation: FDFileOperation) {
            guard recordsOperations else { return }
            lock.withLock { operations.append(operation) }
        }

        func recordedOperations() -> [FDFileOperation] {
            lock.withLock { operations }
        }

        func nextReadDirective() -> ReadDirective {
            lock.lock()
            defer { lock.unlock() }

            guard !preadPlan.isEmpty else { return .none }
            switch preadPlan[0] {
            case .eintr(let retries):
                if retries > 1 {
                    preadPlan[0] = .eintr(retries: retries - 1)
                } else {
                    preadPlan.removeFirst()
                }
                return .fail(errno: EINTR)
            case .eio:
                preadPlan.removeFirst()
                return .fail(errno: EIO)
            case .shortRead(let maxBytes):
                preadPlan.removeFirst()
                return .short(maxBytes: max(1, maxBytes))
            }
        }

        func nextWriteDirective() -> WriteDirective {
            lock.lock()
            defer { lock.unlock() }

            guard !pwritePlan.isEmpty else { return .none }
            switch pwritePlan[0] {
            case .eintr(let retries):
                if retries > 1 {
                    pwritePlan[0] = .eintr(retries: retries - 1)
                } else {
                    pwritePlan.removeFirst()
                }
                return .fail(errno: EINTR)
            case .eio:
                pwritePlan.removeFirst()
                return .fail(errno: EIO)
            case .shortWrite(let maxBytes):
                pwritePlan.removeFirst()
                return .short(maxBytes: max(1, maxBytes))
            }
        }
    }

    private let fd: Int32
    private let url: URL
    /// Guarded by `closeLock`; read it through `isClosed`.
    private var closed = false
    private let closeLock = NSLock()
    private var faultInjectionState: FaultInjectionState?

    /// Largest single `pread`/`pwrite`. Darwin rejects transfers over `INT_MAX` bytes with
    /// EINVAL, so larger buffers are moved in chunks. Tests may lower it at creation.
    static let defaultIOChunkLimit = 1 << 30
    let ioChunkLimit: Int

    private init(fd: Int32, url: URL, ioChunkLimit: Int = FDFile.defaultIOChunkLimit) {
        precondition(ioChunkLimit > 0, "ioChunkLimit must be positive")
        self.fd = fd
        self.url = url
        self.ioChunkLimit = ioChunkLimit
    }

    deinit {
        if !closed {
            _ = posixClose(fd)
        }
    }

    package var isClosed: Bool {
        closeLock.withLock { closed }
    }

    // MARK: - Factory

    /// Create a new file (truncates if exists).
    package static func create(at url: URL) throws -> FDFile {
        try create(at: url, ioChunkLimit: defaultIOChunkLimit)
    }

    static func create(at url: URL, ioChunkLimit: Int) throws -> FDFile {
        let fd = try openFile(at: url, flags: O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, mode: mode_t(0o644))
        return FDFile(fd: fd, url: url, ioChunkLimit: ioChunkLimit)
    }

    /// Open an existing file for read/write.
    package static func open(at url: URL) throws -> FDFile {
        let fd = try openFile(at: url, flags: O_RDWR | O_CLOEXEC, mode: nil)
        return FDFile(fd: fd, url: url)
    }

    /// Open an existing file for read-only access.
    package static func openReadOnly(at url: URL) throws -> FDFile {
        let fd = try openFile(at: url, flags: O_RDONLY | O_CLOEXEC, mode: nil)
        return FDFile(fd: fd, url: url)
    }

    func installFaultPlan(_ plan: FDFileFaultPlan) {
        faultInjectionState = FaultInjectionState(plan: plan)
    }

    func clearFaultPlan() {
        faultInjectionState = nil
    }

    func recordedOperations() -> [FDFileOperation] {
        faultInjectionState?.recordedOperations() ?? []
    }

    // MARK: - Read/Write

    /// May short read at EOF.
    package func read(length: Int, at offset: UInt64) throws -> Data {
        try ensureOpen()
        guard length >= 0 else {
            throw WaxError.io("Invalid read length: \(length)")
        }
        if length == 0 { return Data() }

        let startOffset = try checkedOffset(offset)
        var data = Data(count: length)
        let bytesRead: Int = try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw WaxError.io("Unable to access read buffer")
            }
            while true {
                let result = preadWithFaults(base: base, length: length, offset: startOffset)
                if result >= 0 { return result }
                if errno == EINTR { continue }
                throw WaxError.io("pread failed: \(stringError())")
            }
        }
        data.count = bytesRead
        return data
    }

    /// Must return exactly `length` bytes or throw.
    package func readExactly(length: Int, at offset: UInt64) throws -> Data {
        try ensureOpen()
        guard length >= 0 else {
            throw WaxError.io("Invalid read length: \(length)")
        }
        if length == 0 { return Data() }

        var data = Data(count: length)
        var totalRead = 0
        try data.withUnsafeMutableBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw WaxError.io("Unable to access read buffer")
            }
            while totalRead < length {
                let currentOffset = try checkedOffset(offset, adding: totalRead)
                let remaining = min(length - totalRead, ioChunkLimit)
                let result = preadWithFaults(
                    base: base.advanced(by: totalRead),
                    length: remaining,
                    offset: currentOffset
                )
                if result > 0 {
                    totalRead += result
                    continue
                }
                if result == 0 {
                    throw WaxError.io("Short read: expected \(length) bytes, got \(totalRead)")
                }
                if errno == EINTR { continue }
                throw WaxError.io("pread failed: \(stringError())")
            }
        }
        return data
    }

    /// Must write all bytes or throw.
    package func writeAll(_ data: Data, at offset: UInt64) throws {
        try ensureOpen()
        if data.isEmpty { return }

        var totalWritten = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw WaxError.io("Unable to access write buffer")
            }
            while totalWritten < data.count {
                let currentOffset = try checkedOffset(offset, adding: totalWritten)
                let remaining = min(data.count - totalWritten, ioChunkLimit)
                let result = pwriteWithFaults(
                    base: base.advanced(by: totalWritten),
                    length: remaining,
                    offset: currentOffset
                )
                if result > 0 {
                    totalWritten += result
                    continue
                }
                if result == 0 {
                    throw WaxError.io("pwrite returned 0 bytes")
                }
                if errno == EINTR { continue }
                throw WaxError.io("pwrite failed: \(stringError())")
            }
        }
    }

    /// Writes `parts` back to back from `offset`, as `writeAll` of their concatenation would,
    /// without first copying them into one buffer: one `pwritev` per chunk. Must write all
    /// bytes or throw.
    package func writeAll(contentsOf parts: [Data], at offset: UInt64) throws {
        try ensureOpen()
        let parts = parts.filter { !$0.isEmpty }
        guard parts.count > 1 else {
            if let part = parts.first {
                try writeAll(part, at: offset)
            }
            return
        }
        try Self.withBuffers(of: parts[...], pinned: []) { buffers in
            try writeAll(buffers: buffers, at: offset)
        }
    }

    /// Calls `body` with every part's bytes pinned at once.
    private static func withBuffers(
        of parts: ArraySlice<Data>,
        pinned: [UnsafeRawBufferPointer],
        _ body: ([UnsafeRawBufferPointer]) throws -> Void
    ) throws {
        guard let first = parts.first else {
            try body(pinned)
            return
        }
        try first.withUnsafeBytes { buffer in
            try withBuffers(of: parts.dropFirst(), pinned: pinned + [buffer], body)
        }
    }

    /// Most iovecs passed to one `pwritev`, well under `IOV_MAX` on Darwin and Linux.
    private static let maxIOVecCount = 64

    private func writeAll(buffers: [UnsafeRawBufferPointer], at offset: UInt64) throws {
        let total = buffers.reduce(0) { $0 + $1.count }
        var totalWritten = 0
        // Where the next unwritten byte is: buffers[part][partOffset].
        var part = 0
        var partOffset = 0
        while totalWritten < total {
            let currentOffset = try checkedOffset(offset, adding: totalWritten)
            var iov: [iovec] = []
            var budget = ioChunkLimit
            var index = part
            var start = partOffset
            while index < buffers.count, budget > 0, iov.count < Self.maxIOVecCount {
                guard let base = buffers[index].baseAddress else {
                    throw WaxError.io("Unable to access write buffer")
                }
                let length = min(buffers[index].count - start, budget)
                iov.append(iovec(iov_base: UnsafeMutableRawPointer(mutating: base + start), iov_len: length))
                budget -= length
                index += 1
                start = 0
            }
            let result = pwritevWithFaults(iov, offset: currentOffset)
            if result > 0 {
                totalWritten += result
                var advance = result
                while advance > 0 {
                    let left = buffers[part].count - partOffset
                    if advance < left {
                        partOffset += advance
                        break
                    }
                    advance -= left
                    part += 1
                    partOffset = 0
                }
                continue
            }
            if result == 0 {
                throw WaxError.io("pwritev returned 0 bytes")
            }
            if errno == EINTR { continue }
            throw WaxError.io("pwritev failed: \(stringError())")
        }
    }

    // MARK: - Durability

    package func fsync() throws {
        try ensureOpen()
        faultInjectionState?.record(.fsync)
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        if fcntl(fd, F_FULLFSYNC, 0) == 0 { return }
        #endif
        guard posixFsync(fd) == 0 else {
            throw WaxError.io("fsync failed: \(stringError())")
        }
    }

    // MARK: - Size / Lifecycle

    package func size() throws -> UInt64 {
        try ensureOpen()
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw WaxError.io("fstat failed: \(stringError())")
        }
        return UInt64(info.st_size)
    }

    package func truncate(to size: UInt64) throws {
        try ensureOpen()
        guard size <= UInt64(Int64.max) else {
            throw WaxError.io("Invalid truncate size: \(size)")
        }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw WaxError.io("ftruncate failed: \(stringError())")
        }
    }

    package func close() throws {
        try closeLock.withLock {
            if closed { return }
            let result = posixClose(fd)
            if result == 0 { closed = true; return }
            if errno == EINTR { closed = true; return }
            throw WaxError.io("close failed: \(Self.stringError())")
        }
    }

    package var fileDescriptor: Int32 { fd }

    /// Flush the directory entry of `url` so a newly created or renamed file survives a
    /// crash; `fsync` on the file itself does not persist its name.
    ///
    /// Some network and FUSE filesystems cannot sync a directory and return EINVAL or
    /// ENOTSUP; that is treated as success (there is nothing more to flush there). Any
    /// other failure throws.
    package static func fsyncParentDirectory(of url: URL) throws {
        let directory = url.deletingLastPathComponent()
        let descriptor = try openFile(at: directory, flags: O_RDONLY | O_CLOEXEC, mode: nil)
        defer { _ = posixClose(descriptor) }
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        if fcntl(descriptor, F_FULLFSYNC, 0) == 0 { return }
        #endif
        guard posixFsync(descriptor) == 0 else {
            if isDirectorySyncUnsupported(errno) { return }
            throw WaxError.io("fsync failed for directory \(directory.path): \(stringError())")
        }
    }

    static func isDirectorySyncUnsupported(_ code: Int32) -> Bool {
        code == EINVAL || code == ENOTSUP || code == EOPNOTSUPP
    }

    // MARK: - Helpers

    private static func openFile(at url: URL, flags: Int32, mode: mode_t?) throws -> Int32 {
        return try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw WaxError.io("Invalid file path: \(url.path)")
            }
            let descriptor: Int32
            if let mode {
                descriptor = posixOpen(path, flags, mode)
            } else {
                descriptor = posixOpen(path, flags)
            }
            guard descriptor >= 0 else {
                throw WaxError.io("open failed for \(url.path): \(stringError())")
            }
            return descriptor
        }
    }

    private func ensureOpen() throws {
        if isClosed {
            throw WaxError.io("File is closed: \(url.path)")
        }
    }

    private func checkedOffset(_ offset: UInt64) throws -> off_t {
        guard offset <= UInt64(Int64.max) else {
            throw WaxError.io("Offset too large: \(offset)")
        }
        return off_t(offset)
    }

    private func checkedOffset(_ offset: UInt64, adding delta: Int) throws -> off_t {
        guard delta >= 0 else {
            throw WaxError.io("Invalid offset delta: \(delta)")
        }
        let total = offset + UInt64(delta)
        guard total <= UInt64(Int64.max) else {
            throw WaxError.io("Offset too large: \(total)")
        }
        return off_t(total)
    }

    private func preadWithFaults(base: UnsafeMutableRawPointer, length: Int, offset: off_t) -> Int {
        let requestedLength: Int
        switch faultInjectionState?.nextReadDirective() ?? .none {
        case .none:
            requestedLength = length
        case .fail(let code):
            errno = code
            return -1
        case .short(let maxBytes):
            requestedLength = min(length, maxBytes)
        }
        return pread(fd, base, requestedLength, offset)
    }

    private func pwriteWithFaults(base: UnsafeRawPointer, length: Int, offset: off_t) -> Int {
        let requestedLength: Int
        switch faultInjectionState?.nextWriteDirective() ?? .none {
        case .none:
            requestedLength = length
        case .fail(let code):
            errno = code
            return -1
        case .short(let maxBytes):
            requestedLength = min(length, maxBytes)
        }
        faultInjectionState?.record(.pwrite(offset: UInt64(offset), length: requestedLength))
        return pwrite(fd, base, requestedLength, offset)
    }

    /// Like `pwriteWithFaults`: an injected short write keeps the first `maxBytes` bytes.
    private func pwritevWithFaults(_ iov: [iovec], offset: off_t) -> Int {
        let length = iov.reduce(0) { $0 + $1.iov_len }
        var vectors = iov
        var requestedLength = length
        switch faultInjectionState?.nextWriteDirective() ?? .none {
        case .none:
            break
        case .fail(let code):
            errno = code
            return -1
        case .short(let maxBytes):
            requestedLength = min(length, maxBytes)
            var remaining = requestedLength
            vectors = []
            for var vector in iov where remaining > 0 {
                vector.iov_len = min(vector.iov_len, remaining)
                remaining -= vector.iov_len
                vectors.append(vector)
            }
        }
        faultInjectionState?.record(.pwrite(offset: UInt64(offset), length: requestedLength))
        return vectors.withUnsafeBufferPointer { buffer in
            pwritev(fd, buffer.baseAddress, Int32(buffer.count), offset)
        }
    }

    private static func stringError() -> String {
        String(cString: strerror(errno))
    }

    private func stringError() -> String {
        Self.stringError()
    }
}

extension FDFile: @unchecked Sendable {}
