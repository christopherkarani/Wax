import Foundation
import Darwin

/// POSIX file descriptor-backed file with offset-based I/O.
public final class FDFile {
    private let fd: Int32
    private let url: URL
    private var isClosed = false

    private init(fd: Int32, url: URL) {
        self.fd = fd
        self.url = url
    }

    deinit {
        if !isClosed {
            _ = Darwin.close(fd)
        }
    }

    // MARK: - Factory

    /// Create a new file (truncates if exists).
    public static func create(at url: URL) throws -> FDFile {
        let fd = try openFile(at: url, flags: O_RDWR | O_CREAT | O_TRUNC | O_CLOEXEC, mode: mode_t(0o644))
        return FDFile(fd: fd, url: url)
    }

    /// Open an existing file for read/write.
    public static func open(at url: URL) throws -> FDFile {
        let fd = try openFile(at: url, flags: O_RDWR | O_CLOEXEC, mode: nil)
        return FDFile(fd: fd, url: url)
    }

    /// Open an existing file for read-only access.
    public static func openReadOnly(at url: URL) throws -> FDFile {
        let fd = try openFile(at: url, flags: O_RDONLY | O_CLOEXEC, mode: nil)
        return FDFile(fd: fd, url: url)
    }

    // MARK: - Read/Write

    /// May short read at EOF.
    public func read(length: Int, at offset: UInt64) throws -> Data {
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
                let result = Darwin.pread(fd, base, length, startOffset)
                if result >= 0 { return result }
                if errno == EINTR { continue }
                throw WaxError.io("pread failed: \(stringError())")
            }
        }
        data.count = bytesRead
        return data
    }

    /// Must return exactly `length` bytes or throw.
    public func readExactly(length: Int, at offset: UInt64) throws -> Data {
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
                let remaining = length - totalRead
                let result = Darwin.pread(fd, base.advanced(by: totalRead), remaining, currentOffset)
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
    public func writeAll(_ data: Data, at offset: UInt64) throws {
        try ensureOpen()
        if data.isEmpty { return }

        var totalWritten = 0
        try data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else {
                throw WaxError.io("Unable to access write buffer")
            }
            while totalWritten < data.count {
                let currentOffset = try checkedOffset(offset, adding: totalWritten)
                let remaining = data.count - totalWritten
                let result = Darwin.pwrite(fd, base.advanced(by: totalWritten), remaining, currentOffset)
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

    // MARK: - Durability

    public func fsync() throws {
        try ensureOpen()
        #if os(macOS) || os(iOS) || os(tvOS) || os(watchOS)
        if fcntl(fd, F_FULLFSYNC, 0) == 0 { return }
        #endif
        guard Darwin.fsync(fd) == 0 else {
            throw WaxError.io("fsync failed: \(stringError())")
        }
    }

    // MARK: - Size / Lifecycle

    public func size() throws -> UInt64 {
        try ensureOpen()
        var info = stat()
        guard fstat(fd, &info) == 0 else {
            throw WaxError.io("fstat failed: \(stringError())")
        }
        return UInt64(info.st_size)
    }

    public func truncate(to size: UInt64) throws {
        try ensureOpen()
        guard size <= UInt64(Int64.max) else {
            throw WaxError.io("Invalid truncate size: \(size)")
        }
        guard ftruncate(fd, off_t(size)) == 0 else {
            throw WaxError.io("ftruncate failed: \(stringError())")
        }
    }

    /// Ensure the file is at least the requested size, extending with zeros if needed.
    public func ensureSize(atLeast size: UInt64) throws {
        let current = try self.size()
        if current < size {
            try truncate(to: size)
        }
    }

    /// Map a writable region of the file at the given offset and length.
    /// The returned region must be closed to unmap the memory.
    public func mapWritable(length: Int, at offset: UInt64) throws -> MappedWritableRegion {
        try ensureOpen()
        guard length > 0 else {
            throw WaxError.io("mapWritable length must be > 0")
        }
        let endOffset = offset + UInt64(length)
        try ensureSize(atLeast: endOffset)

        let pageSize = UInt64(getpagesize())
        let alignedOffset = (offset / pageSize) * pageSize
        let offsetDelta = Int(offset - alignedOffset)
        let mapLength = length + offsetDelta

        guard mapLength > 0 else {
            throw WaxError.io("mapWritable mapLength invalid: \(mapLength)")
        }
        guard mapLength <= Int.max else {
            throw WaxError.io("mapWritable mapLength exceeds Int.max: \(mapLength)")
        }

        let ptr = mmap(
            nil,
            mapLength,
            PROT_READ | PROT_WRITE,
            MAP_SHARED,
            fd,
            off_t(alignedOffset)
        )
        if ptr == MAP_FAILED {
            throw WaxError.io("mmap failed: \(stringError())")
        }

        guard let base = ptr else {
            munmap(ptr, mapLength)
            throw WaxError.io("mmap returned nil pointer")
        }
        let advanced = base.advanced(by: offsetDelta)
        return MappedWritableRegion(
            basePointer: base,
            mappedLength: mapLength,
            bufferPointer: UnsafeMutableRawBufferPointer(start: advanced, count: length)
        )
    }

    public func close() throws {
        if isClosed { return }
        let result = Darwin.close(fd)
        if result == 0 {
            isClosed = true
            return
        }
        if errno == EINTR {
            isClosed = true
            return
        }
        throw WaxError.io("close failed: \(stringError())")
    }

    public var fileDescriptor: Int32 { fd }

    // MARK: - Helpers

    private static func openFile(at url: URL, flags: Int32, mode: mode_t?) throws -> Int32 {
        return try url.withUnsafeFileSystemRepresentation { path in
            guard let path else {
                throw WaxError.io("Invalid file path: \(url.path)")
            }
            let descriptor: Int32
            if let mode {
                descriptor = Darwin.open(path, flags, mode)
            } else {
                descriptor = Darwin.open(path, flags)
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

    private static func stringError() -> String {
        String(cString: strerror(errno))
    }

    private func stringError() -> String {
        Self.stringError()
    }
}

extension FDFile: @unchecked Sendable {}

/// RAII wrapper around a writable mmap region.
public final class MappedWritableRegion: @unchecked Sendable {
    private let basePointer: UnsafeMutableRawPointer
    private let mappedLength: Int
    public let buffer: UnsafeMutableRawBufferPointer
    private var isClosed = false

    init(basePointer: UnsafeMutableRawPointer, mappedLength: Int, bufferPointer: UnsafeMutableRawBufferPointer) {
        self.basePointer = basePointer
        self.mappedLength = mappedLength
        self.buffer = bufferPointer
    }

    public func close() {
        if isClosed { return }
        _ = munmap(basePointer, mappedLength)
        isClosed = true
    }

    public func copyBytes(from data: Data) {
        precondition(data.count <= buffer.count, "data length exceeds mapped buffer")
        buffer.copyBytes(from: data)
    }

    deinit {
        if !isClosed {
            _ = munmap(basePointer, mappedLength)
        }
    }
}
