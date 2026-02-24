import Foundation
@preconcurrency import USearch
import WaxCore

public actor USearchVectorEngine {
    private static let maxResults = 10_000
    private static let connectivity: UInt32 = 16
    private static let initialReserve: UInt32 = 64

    private let metric: VectorMetric
    public let dimensions: Int

    private var vectorCount: UInt64
    private var reservedCapacity: UInt32
    private let index: USearchIndex
    private let io: BlockingIOExecutor
    private let opLock = AsyncReadWriteLock()
    private var dirty: Bool

    private func withWriteLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.writeLock()
        do {
            let result = try await body()
            await opLock.writeUnlock()
            return result
        } catch {
            await opLock.writeUnlock()
            throw error
        }
    }

    private func withReadLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.readLock()
        do {
            let result = try await body()
            await opLock.readUnlock()
            return result
        } catch {
            await opLock.readUnlock()
            throw error
        }
    }

    public init(metric: VectorMetric, dimensions: Int) throws {
        guard dimensions > 0 else {
            throw WaxError.invalidToc(reason: "dimensions must be > 0")
        }
        guard dimensions <= Constants.maxEmbeddingDimensions else {
            throw WaxError.capacityExceeded(
                limit: UInt64(Constants.maxEmbeddingDimensions),
                requested: UInt64(dimensions)
            )
        }

        self.metric = metric
        self.dimensions = dimensions
        self.vectorCount = 0
        self.reservedCapacity = Self.initialReserve
        self.dirty = false
        self.index = try USearchIndex.make(
            metric: metric.toUSearchMetric(),
            dimensions: UInt32(dimensions),
            connectivity: Self.connectivity,
            quantization: .f32
        )
        self.io = BlockingIOExecutor(label: "com.wax.usearch", qos: .userInitiated)
        try index.reserve(reservedCapacity)
    }

    public static func load(from wax: Wax, metric: VectorMetric, dimensions: Int) async throws -> USearchVectorEngine {
        let engine = try USearchVectorEngine(metric: metric, dimensions: dimensions)
        if let bytes = try await wax.readCommittedVecIndexBytes() {
            try await engine.deserialize(bytes)
        }
        let pending = await wax.pendingEmbeddingMutations()
        for embedding in pending {
            try await engine.add(frameId: embedding.frameId, vector: embedding.vector)
        }
        return engine
    }

    public func add(frameId: UInt64, vector: [Float]) async throws {
        try await withWriteLock {
            try validate(vector)
            let index = self.index
            let isEmpty = vectorCount == 0
            let removed: UInt32 = try await io.run {
                if isEmpty { return 0 }
                return try index.remove(key: frameId)
            }
            if removed == 0 {
                try await reserveIfNeeded(for: vectorCount &+ 1)
                vectorCount &+= 1
            }
            try await io.run {
                try index.add(key: frameId, vector: vector)
            }
            dirty = true
        }
    }

    /// Batch add multiple vectors in a single operation.
    /// This amortizes lock acquisition and I/O overhead across all vectors.
    /// Optimized for high-throughput ingest with minimal actor contention.
    public func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatch: frameIds.count != vectors.count")
        }

        try await withWriteLock {
            // Validate all vectors first (fast, no I/O)
            let expectedDims = dimensions
            for vector in vectors {
                guard vector.count == expectedDims else {
                    throw WaxError.encodingError(reason: "vector dimension mismatch: expected \(expectedDims), got \(vector.count)")
                }
                guard vector.count <= Constants.maxEmbeddingDimensions else {
                    throw WaxError.capacityExceeded(
                        limit: UInt64(Constants.maxEmbeddingDimensions),
                        requested: UInt64(vector.count)
                    )
                }
            }

            let index = self.index
            let isEmpty = vectorCount == 0
            
            // Pre-calculate required capacity to avoid multiple reserve calls
            let maxNewCount = vectorCount &+ UInt64(frameIds.count)
            try await reserveIfNeeded(for: maxNewCount)

            // Capture arrays for Sendable closure - avoid capturing self
            let frameIdArray = frameIds
            let vectorArray = vectors

            // Single I/O block for all operations - minimizes async context switches
            let addedCount = try await io.run { () throws -> Int in
                var added = 0
                
                // Optimized loop - avoid redundant checks when index is empty
                if isEmpty {
                    // Fast path: no need to check for existing keys
                    for (frameId, vector) in zip(frameIdArray, vectorArray) {
                        try index.add(key: frameId, vector: vector)
                        added += 1
                    }
                } else {
                    // Standard path: check and remove existing keys
                    for (frameId, vector) in zip(frameIdArray, vectorArray) {
                        let removed = try index.remove(key: frameId)
                        if removed == 0 {
                            added += 1
                        }
                        try index.add(key: frameId, vector: vector)
                    }
                }
                return added
            }

            vectorCount &+= UInt64(addedCount)
            dirty = true
        }
    }
    
    /// High-throughput batch add optimized for large ingestion workloads.
    /// Processes vectors in chunks to balance memory usage with throughput.
    public func addBatchStreaming(frameIds: [UInt64], vectors: [[Float]], chunkSize: Int = 256) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatchStreaming: frameIds.count != vectors.count")
        }
        
        // For small batches, use standard batch add
        guard frameIds.count > chunkSize else {
            try await addBatch(frameIds: frameIds, vectors: vectors)
            return
        }
        
        // Process in chunks to avoid holding lock for too long
        for start in stride(from: 0, to: frameIds.count, by: chunkSize) {
            let end = min(start + chunkSize, frameIds.count)
            let chunkFrameIds = Array(frameIds[start..<end])
            let chunkVectors = Array(vectors[start..<end])
            try await addBatch(frameIds: chunkFrameIds, vectors: chunkVectors)
        }
    }

    public func remove(frameId: UInt64) async throws {
        try await withWriteLock {
            guard vectorCount > 0 else { return }
            let index = self.index
            let removed = try await io.run { try index.remove(key: frameId) }
            if removed > 0 {
                vectorCount = vectorCount == 0 ? 0 : (vectorCount &- 1)
                dirty = true
            }
        }
    }

    public func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        try await withReadLock {
            guard vectorCount > 0 else { return [] }
            try validate(vector)
            let limit = Self.clampTopK(topK)

            let index = self.index
            let (keys, distances) = try await io.run { try index.search(vector: vector, count: limit) }
            var results: [(UInt64, Float)] = []
            results.reserveCapacity(min(keys.count, distances.count))
            for (key, distance) in zip(keys, distances) {
                results.append((key, metric.score(fromDistance: distance)))
            }
            return results
        }
    }

    public func serialize() async throws -> Data {
        try await withReadLock {
            let index = self.index
            let metric = self.metric
            let dimensions = self.dimensions
            let vectorCount = self.vectorCount
            return try await io.run {
                try VectorSerializer.serializeUSearchIndex(
                    index,
                    metric: metric,
                    dimensions: dimensions,
                    vectorCount: vectorCount
                )
            }
        }
    }

    public func deserialize(_ data: Data) async throws {
        try await withWriteLock {
            let decoded = try VectorSerializer.decodeVecSegment(from: data)
            switch decoded {
            case .uSearch(let info, let payload):
                guard info.dimension == UInt32(dimensions) else {
                    throw WaxError.invalidToc(
                        reason: "vec dimension mismatch: expected \(dimensions), got \(info.dimension)"
                    )
                }
                guard info.similarity == metric.toVecSimilarity() else {
                    throw WaxError.invalidToc(
                        reason: "vec similarity mismatch: expected \(metric.toVecSimilarity()), got \(info.similarity)"
                    )
                }

                let index = self.index
                try await io.run { try VectorSerializer.loadUSearchIndex(index, fromPayload: payload) }
                vectorCount = info.vectorCount
                reservedCapacity = max(reservedCapacity, UInt32(min(vectorCount, UInt64(UInt32.max))))
                let reserve = reservedCapacity
                try await io.run { try index.reserve(reserve) }
                dirty = false
            case .metal(let info, let vectors, let frameIds):
                guard info.dimension == UInt32(dimensions) else {
                    throw WaxError.invalidToc(
                        reason: "vec dimension mismatch: expected \(dimensions), got \(info.dimension)"
                    )
                }
                guard info.similarity == metric.toVecSimilarity() else {
                    throw WaxError.invalidToc(
                        reason: "vec similarity mismatch: expected \(metric.toVecSimilarity()), got \(info.similarity)"
                    )
                }
                guard vectors.count == Int(info.vectorCount) * dimensions else {
                    throw WaxError.invalidToc(reason: "vec vector count mismatch")
                }
                guard frameIds.count == Int(info.vectorCount) else {
                    throw WaxError.invalidToc(reason: "vec frameId count mismatch")
                }

                let index = self.index
                vectorCount = 0
                reservedCapacity = max(reservedCapacity, UInt32(min(info.vectorCount, UInt64(UInt32.max))))
                let reserve = reservedCapacity
                try await io.run { try index.reserve(reserve) }

                let frameIdArray = frameIds
                let vectorArray = vectors
                let dims = dimensions

                try await io.run {
                    var scratch = [Float](repeating: 0, count: dims)
                    try vectorArray.withUnsafeBufferPointer { src in
                        guard let srcBase = src.baseAddress else { return }
                        for i in 0..<frameIdArray.count {
                            let start = i * dims
                            scratch.withUnsafeMutableBufferPointer { dst in
                                guard let dstBase = dst.baseAddress else { return }
                                dstBase.update(from: srcBase.advanced(by: start), count: dims)
                            }
                            try index.add(key: frameIdArray[i], vector: scratch)
                        }
                    }
                }

                vectorCount = info.vectorCount
                dirty = false
            }
        }
    }

    public func stageForCommit(into wax: Wax) async throws {
        if !dirty { return }
        let blob = try await serialize()
        try await wax.stageVecIndexForNextCommit(
            bytes: blob,
            vectorCount: vectorCount,
            dimension: UInt32(dimensions),
            similarity: metric.toVecSimilarity()
        )
        dirty = false
    }

    private func validate(_ vector: [Float]) throws {
        guard vector.count == dimensions else {
            throw WaxError.encodingError(reason: "vector dimension mismatch: expected \(dimensions), got \(vector.count)")
        }
        guard vector.count <= Constants.maxEmbeddingDimensions else {
            throw WaxError.capacityExceeded(
                limit: UInt64(Constants.maxEmbeddingDimensions),
                requested: UInt64(vector.count)
            )
        }
    }

    private static func clampTopK(_ topK: Int) -> Int {
        if topK < 1 { return 1 }
        if topK > maxResults { return maxResults }
        return topK
    }

    private func reserveIfNeeded(for requiredCount: UInt64) async throws {
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
        let index = self.index
        let reserve = reservedCapacity
        try await io.run { try index.reserve(reserve) }
    }
}

extension USearchVectorEngine: VectorSearchEngine {}
