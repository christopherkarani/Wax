#if canImport(Metal)
import Foundation
import Metal
import WaxCore

extension MetalVectorEngine {
    func acquireTransientBuffers(vectorCount: Int) throws -> TransientBuffers {
        // Best fit: the smallest pooled set that can hold this search.
        let bestFit = transientBufferPool.indices
            .filter { transientBufferPool[$0].capacity >= vectorCount }
            .min { transientBufferPool[$0].capacity < transientBufferPool[$1].capacity }
        if let index = bestFit {
            transientReuseCount += 1
            return transientBufferPool.remove(at: index)
        }

        transientAllocations += 1
        let capacity = Self.transientCapacity(for: vectorCount)

        guard let query = device.makeBuffer(
            length: dimensions * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate transient query buffer")
        }
        guard let distances = device.makeBuffer(
            length: capacity * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate transient distances buffer")
        }
        guard let count = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate transient count buffer")
        }

        return TransientBuffers(query: query, distances: distances, count: count, capacity: capacity)
    }

    func releaseTransientBuffers(_ buffers: TransientBuffers) {
        transientBufferPool.append(buffers)
        // Keep the pool bounded; the smallest sets are the least likely to fit future searches.
        while transientBufferPool.count > Self.maxPooledTransientBufferSets {
            guard let smallest = transientBufferPool.indices.min(by: {
                transientBufferPool[$0].capacity < transientBufferPool[$1].capacity
            }) else { break }
            transientBufferPool.remove(at: smallest)
        }
    }

    /// Geometric growth (next power of two, at least `initialReserve`) so alternating
    /// add/search allocates O(log n) transient sets instead of one per new vector count.
    private static func transientCapacity(for vectorCount: Int) -> Int {
        var capacity = Int(initialReserve)
        while capacity < vectorCount {
            let (doubled, overflow) = capacity.multipliedReportingOverflow(by: 2)
            if overflow { return vectorCount }
            capacity = doubled
        }
        return capacity
    }

    func debugBufferPoolStats() -> BufferPoolStats {
        BufferPoolStats(
            transientAllocations: transientAllocations,
            reuseCount: transientReuseCount,
            pooledBufferSets: transientBufferPool.count
        )
    }

    func reserveIfNeeded(for requiredCount: UInt64) async throws {
        guard requiredCount <= UInt64(UInt32.max) else {
            throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: requiredCount)
        }
        if requiredCount <= UInt64(reservedCapacity) { return }
        var next = reservedCapacity == 0 ? Self.initialReserve : reservedCapacity
        while requiredCount > UInt64(next) {
            let doubled = next &* 2
            next = doubled > next ? doubled : UInt32.max
            if next == UInt32.max { break }
        }
        reservedCapacity = max(reservedCapacity, next)

        try resizeBuffersIfNeeded(for: reservedCapacity)
    }

    func resizeBuffersIfNeeded(for capacity: UInt32) throws {
        let requiredVectorsLength = Int(capacity) * dimensions * MemoryLayout<Float>.stride
        
        // Check if resize needed for vectors
        if vectorsBuffer.length < requiredVectorsLength {
             guard let newVectorsBuffer = device.makeBuffer(length: requiredVectorsLength, options: .storageModeShared) else {
                throw WaxError.invalidToc(reason: "Failed to resize vectors buffer")
            }
            // Copy existing data
            if vectorCount > 0 {
                newVectorsBuffer.contents().copyMemory(
                    from: vectorsBuffer.contents(),
                    byteCount: Int(vectorCount) * dimensions * MemoryLayout<Float>.stride
                )
            }
            vectorsBuffer = newVectorsBuffer
        }
    }
}

#endif // canImport(Metal)
