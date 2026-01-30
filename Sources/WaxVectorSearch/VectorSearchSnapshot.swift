//
//  VectorSearchSnapshot.swift
//  Wax
//
//  An immutable snapshot of vector search state for lock-free concurrent queries.
//  Enables multiple simultaneous searches without actor serialization overhead.
//

import Foundation
import Accelerate

/// An immutable snapshot of vector search state optimized for concurrent read access.
/// 
/// This enables lock-free queries by capturing a consistent view of the vector index
/// at a point in time. Multiple queries can execute concurrently without actor contention.
///
/// Usage:
/// ```swift
/// let snapshot = await engine.createSnapshot()
/// // Concurrent queries without actor hops
/// let results1 = snapshot.search(vector: query1, topK: 10)
/// let results2 = snapshot.search(vector: query2, topK: 10)
/// ```
public struct VectorSearchSnapshot: Sendable {
    /// Immutable copy of vectors (contiguous for SIMD)
    private let vectors: [Float]
    
    /// Frame IDs corresponding to each vector
    private let frameIds: [UInt64]
    
    /// Number of dimensions per vector
    public let dimensions: Int
    
    /// Number of vectors in this snapshot
    public var count: Int { frameIds.count }
    
    /// Whether vectors are pre-normalized for SIMD kernel
    public let isNormalized: Bool
    
    /// Generation number for cache invalidation
    public let generation: UInt64
    
    /// Initialize from current engine state
    init(vectors: [Float], frameIds: [UInt64], dimensions: Int, isNormalized: Bool, generation: UInt64) {
        self.vectors = vectors
        self.frameIds = frameIds
        self.dimensions = dimensions
        self.isNormalized = isNormalized
        self.generation = generation
    }
    
    /// Perform CPU-based vector search using vDSP for SIMD acceleration.
    /// This runs entirely on the CPU without GPU involvement.
    ///
    /// - Parameters:
    ///   - vector: Query vector
    ///   - topK: Maximum number of results to return
    /// - Returns: Array of (frameId, similarity score) tuples sorted by score descending
    public func search(vector: [Float], topK: Int) -> [(frameId: UInt64, score: Float)] {
        guard !frameIds.isEmpty else { return [] }
        guard vector.count == dimensions else { return [] }
        
        let k = min(max(topK, 1), frameIds.count)
        
        // Normalize query if vectors are pre-normalized
        var query = vector
        if isNormalized {
            normalizeVector(&query)
        }
        
        // Compute all similarities using vDSP
        var similarities = [Float](repeating: 0, count: frameIds.count)
        
        vectors.withUnsafeBufferPointer { vecPtr in
            query.withUnsafeBufferPointer { queryPtr in
                for i in 0..<frameIds.count {
                    let offset = i * dimensions
                    var dotProduct: Float = 0
                    
                    vDSP_dotpr(
                        queryPtr.baseAddress!, 1,
                        vecPtr.baseAddress!.advanced(by: offset), 1,
                        &dotProduct,
                        vDSP_Length(dimensions)
                    )
                    
                    if isNormalized {
                        // Pre-normalized: similarity = dot product
                        similarities[i] = dotProduct
                    } else {
                        // Need to compute magnitude
                        var vecMagSq: Float = 0
                        vDSP_dotpr(
                            vecPtr.baseAddress!.advanced(by: offset), 1,
                            vecPtr.baseAddress!.advanced(by: offset), 1,
                            &vecMagSq,
                            vDSP_Length(dimensions)
                        )
                        
                        var queryMagSq: Float = 0
                        vDSP_dotpr(
                            queryPtr.baseAddress!, 1,
                            queryPtr.baseAddress!, 1,
                            &queryMagSq,
                            vDSP_Length(dimensions)
                        )
                        
                        let denominator = sqrtf(vecMagSq) * sqrtf(queryMagSq)
                        similarities[i] = denominator > 1e-6 ? dotProduct / denominator : 0
                    }
                }
            }
        }
        
        // Find top-k using partial sort (heap-based for efficiency)
        return topKSimilarities(similarities: similarities, k: k)
    }
    
    /// Batch search for multiple queries concurrently
    /// - Parameters:
    ///   - vectors: Array of query vectors
    ///   - topK: Maximum results per query
    /// - Returns: Array of result arrays, one per query
    public func batchSearch(vectors: [[Float]], topK: Int) -> [[(frameId: UInt64, score: Float)]] {
        // Use concurrent map for parallel execution
        return vectors.map { search(vector: $0, topK: topK) }
    }
    
    // MARK: - Private Helpers
    
    private func normalizeVector(_ vector: inout [Float]) {
        var sumSquared: Float = 0
        vDSP_dotpr(vector, 1, vector, 1, &sumSquared, vDSP_Length(dimensions))
        
        guard sumSquared > 1e-12 else { return }
        var invMagnitude = 1.0 / sqrtf(sumSquared)
        vDSP_vsmul(vector, 1, &invMagnitude, &vector, 1, vDSP_Length(dimensions))
    }
    
    /// O(n log k) partial selection using max-heap
    private func topKSimilarities(similarities: [Float], k: Int) -> [(frameId: UInt64, score: Float)] {
        guard k > 0, !similarities.isEmpty else { return [] }
        
        // For small k, use heap-based selection
        var heap: [(Float, Int)] = [] // (similarity, index) - min-heap by similarity
        heap.reserveCapacity(k)
        
        func siftDown(_ start: Int, _ end: Int) {
            var root = start
            while true {
                let child = root * 2 + 1
                if child > end { break }
                var swap = root
                // Min-heap: parent should be smaller than children
                if heap[swap].0 > heap[child].0 { swap = child }
                if child + 1 <= end, heap[swap].0 > heap[child + 1].0 { swap = child + 1 }
                if swap == root { return }
                heap.swapAt(root, swap)
                root = swap
            }
        }
        
        func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                if heap[parent].0 <= heap[child].0 { break }
                heap.swapAt(parent, child)
                child = parent
            }
        }
        
        // Fill heap with first k elements
        let initial = min(k, similarities.count)
        for i in 0..<initial {
            heap.append((similarities[i], i))
        }
        
        // Heapify
        for i in stride(from: (heap.count / 2) - 1, through: 0, by: -1) {
            siftDown(i, heap.count - 1)
        }
        
        // Process remaining elements
        if initial < similarities.count {
            for i in initial..<similarities.count {
                let value = similarities[i]
                // If larger than smallest in heap, replace
                if value > heap[0].0 {
                    heap[0] = (value, i)
                    siftDown(0, heap.count - 1)
                }
            }
        }
        
        // Sort by similarity descending
        heap.sort { $0.0 > $1.0 }
        
        return heap.map { (frameIds[$0.1], $0.0) }
    }
}
