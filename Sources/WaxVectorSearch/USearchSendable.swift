@preconcurrency import USearch
import USearchC
import Foundation
#if canImport(ObjectiveC)
import ObjectiveC
#endif

extension USearchIndex: @retroactive @unchecked Sendable {}

// MARK: - Buffer-Based Serialization

/// Internal error for buffer serialization operations
private enum BufferSerializationError: Error {
    case failedToGetHandle
    case serializationFailed(String)
    case bufferAllocationFailed
}

#if canImport(ObjectiveC)

extension USearchIndex {
    /// Returns the expected serialized size in bytes.
    /// This avoids needing to serialize twice to determine buffer size.
    public var serializedLength: Int {
        get throws {
            let nativeIndex = try getNativeIndexHandle()
            var errorPtr: UnsafePointer<CChar>?
            let size = usearch_serialized_length(nativeIndex, &errorPtr)
            if let errorPtr = errorPtr {
                let message = String(cString: errorPtr)
                throw BufferSerializationError.serializationFailed(message)
            }
            return size
        }
    }

    /// Saves the index directly to an in-memory buffer, avoiding temp file I/O.
    /// - Parameter buffer: Pre-allocated mutable buffer of at least `serializedLength` bytes
    public func saveToBuffer(_ buffer: UnsafeMutableRawPointer, length: Int) throws {
        let nativeIndex = try getNativeIndexHandle()
        var errorPtr: UnsafePointer<CChar>?
        usearch_save_buffer(nativeIndex, buffer, length, &errorPtr)
        if let errorPtr = errorPtr {
            let message = String(cString: errorPtr)
            throw BufferSerializationError.serializationFailed(message)
        }
    }

    /// Loads the index directly from an in-memory buffer, avoiding temp file I/O.
    /// - Parameter buffer: Buffer containing serialized index data
    public func loadFromBuffer(_ buffer: UnsafeRawPointer, length: Int) throws {
        let nativeIndex = try getNativeIndexHandle()
        var errorPtr: UnsafePointer<CChar>?
        usearch_load_buffer(nativeIndex, buffer, length, &errorPtr)
        if let errorPtr = errorPtr {
            let message = String(cString: errorPtr)
            throw BufferSerializationError.serializationFailed(message)
        }
    }

    /// Serializes the index to Data using in-memory buffer operations.
    /// This is ~10-100x faster than file-based serialization.
    public func serializeToData() throws -> Data {
        let size = try serializedLength
        guard size > 0 else {
            return Data()
        }
        var data = Data(count: size)
        try data.withUnsafeMutableBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw BufferSerializationError.bufferAllocationFailed
            }
            try saveToBuffer(baseAddress, length: size)
        }
        return data
    }

    /// Deserializes the index from Data using in-memory buffer operations.
    /// This is ~10-100x faster than file-based deserialization.
    public func deserializeFromData(_ data: Data) throws {
        guard !data.isEmpty else { return }
        try data.withUnsafeBytes { buffer in
            guard let baseAddress = buffer.baseAddress else {
                throw BufferSerializationError.bufferAllocationFailed
            }
            try loadFromBuffer(baseAddress, length: data.count)
        }
    }

    /// Access to the underlying native index handle for C API calls.
    /// Uses Objective-C runtime to access the private ivar directly.
    private func getNativeIndexHandle() throws -> UnsafeMutableRawPointer {
        // USearchIndex stores nativeIndex as a private usearch_index_t (UnsafeMutableRawPointer)
        // We use the Objective-C runtime to access the ivar directly
        guard let ivar = class_getInstanceVariable(type(of: self), "nativeIndex") else {
            throw BufferSerializationError.failedToGetHandle
        }
        let ptr = Unmanaged.passUnretained(self).toOpaque()
        let offset = ivar_getOffset(ivar)
        let ivarPtr = ptr.advanced(by: offset)

        // The nativeIndex is stored as usearch_index_t which is UnsafeMutableRawPointer
        let handle = ivarPtr.assumingMemoryBound(to: UnsafeMutableRawPointer?.self).pointee
        guard let handle = handle else {
            throw BufferSerializationError.failedToGetHandle
        }
        return handle
    }
}

#else

// Linux fallback: ObjectiveC runtime is unavailable, so use file-based I/O
// instead of the in-memory buffer path. Performance is lower but correctness
// is preserved on all platforms.
extension USearchIndex {
    public func serializeToData() throws -> Data {
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usearch").path
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        try save(path: tmpPath)
        guard let data = FileManager.default.contents(atPath: tmpPath) else {
            throw BufferSerializationError.serializationFailed("failed to read temp serialization file")
        }
        return data
    }

    public func deserializeFromData(_ data: Data) throws {
        guard !data.isEmpty else { return }
        let tmpPath = FileManager.default.temporaryDirectory
            .appendingPathComponent("\(UUID().uuidString).usearch").path
        defer { try? FileManager.default.removeItem(atPath: tmpPath) }
        guard FileManager.default.createFile(atPath: tmpPath, contents: data, attributes: nil) else {
            throw BufferSerializationError.serializationFailed("failed to write temp deserialization file")
        }
        try load(path: tmpPath)
    }
}

#endif
