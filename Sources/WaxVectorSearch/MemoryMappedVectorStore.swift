//
//  MemoryMappedVectorStore.swift
//  Wax
//
//  Memory-mapped file backing for vector storage.
//  Provides near-instant index loading and reduced memory footprint.
//

import Foundation
import WaxCore

/// A memory-mapped file-backed vector store for fast loading and reduced memory pressure.
///
/// Benefits:
/// - Near-instant index loading (no deserialization)
/// - OS manages paging - only accessed pages loaded into RAM
/// - Automatic write-back to disk
/// - Efficient for large indices that exceed available RAM
///
/// Thread-safety: Read-only access is thread-safe. Writes require external synchronization.
public final class MemoryMappedVectorStore: @unchecked Sendable {
    
    /// File header structure (64 bytes)
    private struct Header {
        static let magic: UInt32 = 0x57415856  // "WAXV"
        static let version: UInt16 = 1
        static let headerSize: Int = 64
        
        var magic: UInt32 = Header.magic
        var version: UInt16 = Header.version
        var dimensions: UInt32 = 0
        var vectorCount: UInt64 = 0
        var isNormalized: UInt8 = 0
        var reserved: (UInt8, UInt8, UInt8, UInt8, UInt8, UInt8, UInt8) = (0, 0, 0, 0, 0, 0, 0)
        // Frame IDs follow header
        // Vectors follow frame IDs
    }
    
    private let fileHandle: FileHandle
    private let mappedData: Data
    private let header: Header
    
    /// Number of dimensions per vector
    public var dimensions: Int { Int(header.dimensions) }
    
    /// Number of vectors stored
    public var count: Int { Int(header.vectorCount) }
    
    /// Whether vectors are pre-normalized
    public var isNormalized: Bool { header.isNormalized != 0 }
    
    /// Offset to frame IDs section
    private var frameIdsOffset: Int { Header.headerSize }
    
    /// Offset to vectors section
    private var vectorsOffset: Int {
        frameIdsOffset + count * MemoryLayout<UInt64>.stride
    }
    
    /// Initialize by memory-mapping an existing index file
    /// - Parameter url: Path to the index file
    public init(url: URL) throws {
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw WaxError.io("Index file not found: \(url.path)")
        }
        
        self.fileHandle = try FileHandle(forReadingFrom: url)
        
        // Memory-map the file
        guard let data = try fileHandle.availableData as Data?,
              data.count >= Header.headerSize else {
            throw WaxError.invalidToc(reason: "Index file too small")
        }
        
        // Re-map as memory-mapped data for efficiency
        self.mappedData = try Data(contentsOf: url, options: .mappedIfSafe)
        
        // Parse header
        var header = Header()
        mappedData.withUnsafeBytes { bytes in
            header.magic = bytes.load(fromByteOffset: 0, as: UInt32.self)
            header.version = bytes.load(fromByteOffset: 4, as: UInt16.self)
            header.dimensions = bytes.load(fromByteOffset: 6, as: UInt32.self)
            header.vectorCount = bytes.load(fromByteOffset: 10, as: UInt64.self)
            header.isNormalized = bytes.load(fromByteOffset: 18, as: UInt8.self)
        }
        
        guard header.magic == Header.magic else {
            throw WaxError.invalidToc(reason: "Invalid index file magic")
        }
        guard header.version == Header.version else {
            throw WaxError.invalidToc(reason: "Unsupported index version: \(header.version)")
        }
        
        self.header = header
    }
    
    /// Get frame ID at index (zero-copy)
    public func frameId(at index: Int) -> UInt64 {
        precondition(index >= 0 && index < count, "Index out of bounds")
        
        let offset = frameIdsOffset + index * MemoryLayout<UInt64>.stride
        return mappedData.withUnsafeBytes { bytes in
            bytes.load(fromByteOffset: offset, as: UInt64.self)
        }
    }
    
    /// Get all frame IDs
    public func allFrameIds() -> [UInt64] {
        guard count > 0 else { return [] }
        
        return mappedData.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.advanced(by: frameIdsOffset)
                .assumingMemoryBound(to: UInt64.self)
            return Array(UnsafeBufferPointer(start: ptr, count: count))
        }
    }
    
    /// Get vector at index as a pointer (zero-copy)
    public func vectorPointer(at index: Int) -> UnsafeBufferPointer<Float> {
        precondition(index >= 0 && index < count, "Index out of bounds")
        
        let offset = vectorsOffset + index * dimensions * MemoryLayout<Float>.stride
        return mappedData.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.advanced(by: offset)
                .assumingMemoryBound(to: Float.self)
            return UnsafeBufferPointer(start: ptr, count: dimensions)
        }
    }
    
    /// Get vector at index as array (allocates)
    public func vector(at index: Int) -> [Float] {
        Array(vectorPointer(at: index))
    }
    
    /// Access all vectors as contiguous buffer (zero-copy)
    public func withVectorsBuffer<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        try mappedData.withUnsafeBytes { bytes in
            let ptr = bytes.baseAddress!.advanced(by: vectorsOffset)
                .assumingMemoryBound(to: Float.self)
            let buffer = UnsafeBufferPointer(start: ptr, count: count * dimensions)
            return try body(buffer)
        }
    }
    
    /// Create a VectorSearchSnapshot from memory-mapped data
    public func createSnapshot() -> VectorSearchSnapshot {
        let frameIds = allFrameIds()
        var vectors = [Float]()
        vectors.reserveCapacity(count * dimensions)
        
        withVectorsBuffer { buffer in
            vectors.append(contentsOf: buffer)
        }
        
        return VectorSearchSnapshot(
            vectors: vectors,
            frameIds: frameIds,
            dimensions: dimensions,
            isNormalized: isNormalized,
            generation: UInt64(count)
        )
    }
    
    deinit {
        try? fileHandle.close()
    }
}

// MARK: - Writing memory-mapped index files

extension MemoryMappedVectorStore {
    /// Write vectors and frame IDs to a memory-mappable index file
    /// - Parameters:
    ///   - vectors: Contiguous vector data
    ///   - frameIds: Frame ID array
    ///   - dimensions: Dimensions per vector
    ///   - isNormalized: Whether vectors are pre-normalized
    ///   - url: Output file URL
    public static func write(
        vectors: [Float],
        frameIds: [UInt64],
        dimensions: Int,
        isNormalized: Bool,
        to url: URL
    ) throws {
        guard !frameIds.isEmpty else { return }
        guard vectors.count == frameIds.count * dimensions else {
            throw WaxError.encodingError(reason: "Vector/frameId count mismatch")
        }
        
        var data = Data()
        
        // Write header
        var magic = Header.magic.littleEndian
        var version = Header.version.littleEndian
        var dims = UInt32(dimensions).littleEndian
        var count = UInt64(frameIds.count).littleEndian
        var normalized: UInt8 = isNormalized ? 1 : 0
        
        withUnsafeBytes(of: &magic) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &dims) { data.append(contentsOf: $0) }
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }
        data.append(normalized)
        
        // Pad header to 64 bytes
        let headerPadding = Header.headerSize - data.count
        data.append(contentsOf: [UInt8](repeating: 0, count: headerPadding))
        
        // Write frame IDs
        frameIds.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: buffer.count * MemoryLayout<UInt64>.stride
            ))
        }
        
        // Write vectors
        vectors.withUnsafeBufferPointer { buffer in
            data.append(UnsafeBufferPointer(
                start: UnsafeRawPointer(buffer.baseAddress!).assumingMemoryBound(to: UInt8.self),
                count: buffer.count * MemoryLayout<Float>.stride
            ))
        }
        
        try data.write(to: url)
    }
}
