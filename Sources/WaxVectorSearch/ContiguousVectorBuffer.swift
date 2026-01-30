//
//  ContiguousVectorBuffer.swift
//  Wax
//
//  A pre-allocated, contiguous buffer for vector storage optimized for
//  SIMD operations and GPU memory transfer. Eliminates array reallocation
//  overhead and provides cache-friendly memory layout.
//

import Foundation
import Accelerate

/// A contiguous, pre-allocated buffer for storing dense vectors.
/// Optimized for:
/// - SIMD operations via Accelerate/vDSP
/// - Zero-copy GPU transfer via MTLBuffer
/// - Cache-friendly sequential access patterns
///
/// Thread-safety: This type is NOT thread-safe. External synchronization required.
public struct ContiguousVectorBuffer: Sendable {
    /// Underlying storage - contiguous Float memory
    private var storage: [Float]
    
    /// Number of dimensions per vector
    public let dimensions: Int
    
    /// Current number of vectors stored
    public private(set) var count: Int
    
    /// Maximum vectors that can be stored without reallocation
    public var capacity: Int {
        storage.count / dimensions
    }
    
    /// Total number of floats stored
    public var floatCount: Int {
        count * dimensions
    }
    
    /// Initialize with specified dimensions and initial capacity
    /// - Parameters:
    ///   - dimensions: Number of dimensions per vector
    ///   - initialCapacity: Initial number of vectors to reserve space for
    public init(dimensions: Int, initialCapacity: Int = 64) {
        precondition(dimensions > 0, "dimensions must be > 0")
        precondition(initialCapacity >= 0, "initialCapacity must be >= 0")
        
        self.dimensions = dimensions
        self.count = 0
        self.storage = [Float](repeating: 0, count: dimensions * max(initialCapacity, 1))
    }
    
    /// Reserve capacity for at least the specified number of vectors
    public mutating func reserveCapacity(_ minimumCapacity: Int) {
        let requiredFloats = minimumCapacity * dimensions
        if storage.count >= requiredFloats { return }
        
        // Grow by doubling to amortize allocation cost
        var newCapacity = max(storage.count, dimensions)
        while newCapacity < requiredFloats {
            newCapacity = newCapacity &* 2
            if newCapacity <= 0 { // Overflow protection
                newCapacity = requiredFloats
                break
            }
        }
        
        var newStorage = [Float](repeating: 0, count: newCapacity)
        newStorage.withUnsafeMutableBufferPointer { dst in
            storage.withUnsafeBufferPointer { src in
                dst.baseAddress!.initialize(from: src.baseAddress!, count: floatCount)
            }
        }
        storage = newStorage
    }
    
    /// Append a vector to the buffer
    /// - Parameter vector: Vector to append (must match dimensions)
    /// - Returns: Index of the appended vector
    @discardableResult
    public mutating func append(_ vector: [Float]) -> Int {
        precondition(vector.count == dimensions, "Vector dimension mismatch")
        
        if count >= capacity {
            reserveCapacity(count + 1)
        }
        
        let offset = count * dimensions
        storage.withUnsafeMutableBufferPointer { buffer in
            vector.withUnsafeBufferPointer { src in
                buffer.baseAddress!.advanced(by: offset).initialize(from: src.baseAddress!, count: dimensions)
            }
        }
        count += 1
        return count - 1
    }
    
    /// Append a pre-normalized vector (SIMD-optimized)
    /// - Parameter vector: Vector to append and normalize in-place
    /// - Returns: Index of the appended vector
    @discardableResult
    public mutating func appendNormalized(_ vector: [Float]) -> Int {
        precondition(vector.count == dimensions, "Vector dimension mismatch")
        
        if count >= capacity {
            reserveCapacity(count + 1)
        }
        
        let offset = count * dimensions
        storage.withUnsafeMutableBufferPointer { buffer in
            let dst = buffer.baseAddress!.advanced(by: offset)
            
            // Copy vector
            vector.withUnsafeBufferPointer { src in
                dst.initialize(from: src.baseAddress!, count: dimensions)
            }
            
            // Normalize using vDSP for SIMD acceleration
            var sumSquared: Float = 0
            vDSP_dotpr(dst, 1, dst, 1, &sumSquared, vDSP_Length(dimensions))
            
            if sumSquared > 1e-12 {
                var invMagnitude = 1.0 / sqrtf(sumSquared)
                vDSP_vsmul(dst, 1, &invMagnitude, dst, 1, vDSP_Length(dimensions))
            }
        }
        count += 1
        return count - 1
    }
    
    /// Update vector at specified index
    /// - Parameters:
    ///   - index: Vector index to update
    ///   - vector: New vector values
    public mutating func update(at index: Int, with vector: [Float]) {
        precondition(index >= 0 && index < count, "Index out of bounds")
        precondition(vector.count == dimensions, "Vector dimension mismatch")
        
        let offset = index * dimensions
        storage.withUnsafeMutableBufferPointer { buffer in
            vector.withUnsafeBufferPointer { src in
                buffer.baseAddress!.advanced(by: offset).assign(from: src.baseAddress!, count: dimensions)
            }
        }
    }
    
    /// Update and normalize vector at specified index
    public mutating func updateNormalized(at index: Int, with vector: [Float]) {
        precondition(index >= 0 && index < count, "Index out of bounds")
        precondition(vector.count == dimensions, "Vector dimension mismatch")
        
        let offset = index * dimensions
        storage.withUnsafeMutableBufferPointer { buffer in
            let dst = buffer.baseAddress!.advanced(by: offset)
            
            vector.withUnsafeBufferPointer { src in
                dst.assign(from: src.baseAddress!, count: dimensions)
            }
            
            // Normalize using vDSP
            var sumSquared: Float = 0
            vDSP_dotpr(dst, 1, dst, 1, &sumSquared, vDSP_Length(dimensions))
            
            if sumSquared > 1e-12 {
                var invMagnitude = 1.0 / sqrtf(sumSquared)
                vDSP_vsmul(dst, 1, &invMagnitude, dst, 1, vDSP_Length(dimensions))
            }
        }
    }
    
    /// Remove vector at index using swap-with-last pattern (O(1))
    /// - Parameter index: Index of vector to remove
    /// - Returns: The frame ID that was swapped into this position (if any)
    public mutating func swapRemove(at index: Int) {
        precondition(index >= 0 && index < count, "Index out of bounds")
        
        let lastIndex = count - 1
        if index != lastIndex {
            // Swap with last vector
            let srcOffset = lastIndex * dimensions
            let dstOffset = index * dimensions
            
            storage.withUnsafeMutableBufferPointer { buffer in
                let src = buffer.baseAddress!.advanced(by: srcOffset)
                let dst = buffer.baseAddress!.advanced(by: dstOffset)
                
                // Copy last to removed position
                dst.assign(from: src, count: dimensions)
            }
        }
        
        count -= 1
    }
    
    /// Get vector at index as an array (allocates - use sparingly)
    public func getVector(at index: Int) -> [Float] {
        precondition(index >= 0 && index < count, "Index out of bounds")
        
        let offset = index * dimensions
        return Array(storage[offset..<(offset + dimensions)])
    }
    
    /// Compute dot product between query and vector at index using vDSP
    /// - Parameters:
    ///   - query: Query vector
    ///   - index: Index of stored vector
    /// - Returns: Dot product value
    public func dotProduct(query: [Float], at index: Int) -> Float {
        precondition(query.count == dimensions, "Query dimension mismatch")
        precondition(index >= 0 && index < count, "Index out of bounds")
        
        let offset = index * dimensions
        var result: Float = 0
        
        storage.withUnsafeBufferPointer { buffer in
            query.withUnsafeBufferPointer { q in
                vDSP_dotpr(
                    q.baseAddress!, 1,
                    buffer.baseAddress!.advanced(by: offset), 1,
                    &result,
                    vDSP_Length(dimensions)
                )
            }
        }
        
        return result
    }
    
    /// Compute cosine similarity with pre-normalized vectors
    /// Since ||q|| = ||v|| = 1, cosine_sim = dot(q, v)
    /// - Parameters:
    ///   - normalizedQuery: Pre-normalized query vector
    ///   - index: Index of stored (pre-normalized) vector
    /// - Returns: Cosine similarity score [0, 1]
    public func cosineSimilarity(normalizedQuery: [Float], at index: Int) -> Float {
        dotProduct(query: normalizedQuery, at: index)
    }
    
    /// Access raw storage for GPU transfer
    /// - Parameter body: Closure receiving pointer to contiguous float data
    public func withUnsafeBufferPointer<R>(_ body: (UnsafeBufferPointer<Float>) throws -> R) rethrows -> R {
        let totalFloats = floatCount
        return try storage.withUnsafeBufferPointer { buffer in
            let slice = UnsafeBufferPointer(start: buffer.baseAddress, count: totalFloats)
            return try body(slice)
        }
    }
    
    /// Access raw storage for mutation
    public mutating func withUnsafeMutableBufferPointer<R>(_ body: (UnsafeMutableBufferPointer<Float>) throws -> R) rethrows -> R {
        let totalFloats = floatCount
        return try storage.withUnsafeMutableBufferPointer { buffer in
            let slice = UnsafeMutableBufferPointer(start: buffer.baseAddress, count: totalFloats)
            return try body(slice)
        }
    }
    
    /// Serialize buffer to Data
    public func serialize() -> Data {
        storage.withUnsafeBufferPointer { buffer in
            Data(bytes: buffer.baseAddress!, count: floatCount * MemoryLayout<Float>.stride)
        }
    }
    
    /// Deserialize from Data
    public mutating func deserialize(from data: Data, vectorCount: Int) {
        let expectedBytes = vectorCount * dimensions * MemoryLayout<Float>.stride
        precondition(data.count >= expectedBytes, "Insufficient data for deserialization")
        
        reserveCapacity(vectorCount)
        
        data.withUnsafeBytes { bytes in
            storage.withUnsafeMutableBufferPointer { buffer in
                buffer.baseAddress!.initialize(
                    from: bytes.baseAddress!.assumingMemoryBound(to: Float.self),
                    count: vectorCount * dimensions
                )
            }
        }
        count = vectorCount
    }
    
    /// Clear all vectors while retaining capacity
    public mutating func removeAll(keepingCapacity: Bool = true) {
        count = 0
        if !keepingCapacity {
            storage = [Float](repeating: 0, count: dimensions)
        }
    }
}
