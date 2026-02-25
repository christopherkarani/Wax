//
//  MetalVectorEngine.swift
//  Wax
//
//  Metal-accelerated vector search engine using GPU compute shaders.
//  Provides drop-in replacement for USearchVectorEngine with cosine similarity.
//
//  Zero-Copy Optimization:
//  - Stores vectors directly in MTLBuffer (Unified Memory) to avoid CPU-RAM duplication.
//  - Eliminates O(N) copy latency during search synchronization.
//

#if canImport(Metal)
import Foundation
import Metal
import WaxCore

public actor MetalVectorEngine {
    private static let maxResults = 10_000
    private static let initialReserve: UInt32 = 64
    private static let maxThreadsPerThreadgroup = 256
    private static let gpuTopKThreshold = 1_000
    
    /// Threshold for switching to SIMD8 kernel (optimal for MiniLM 384-dim vectors)
    private static let simd8DimensionThreshold = 384

    private struct TopKEntry {
        var distance: Float
        var index: UInt32
    }

    private struct TopKResult {
        var frameId: UInt64
        var score: Float
    }

    private struct TransientBuffers {
        let query: MTLBuffer
        let distances: MTLBuffer
        let count: MTLBuffer
        let capacity: Int
    }

    struct BufferPoolStats: Sendable {
        var transientAllocations: Int
        var reuseCount: Int
    }

    private let metric: VectorMetric
    public let dimensions: Int

    private var vectorCount: UInt64
    private var reservedCapacity: UInt32
    // Zero-Copy: 'vectors' array removed. Primary storage is `vectorsBuffer`.
    
    private var frameIds: [UInt64]
    private let opLock = AsyncReadWriteLock()
    private var dirty: Bool

    private func withWriteLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.writeLock()
        do {
            let value = try await body()
            await opLock.writeUnlock()
            return value
        } catch {
            await opLock.writeUnlock()
            throw error
        }
    }

    private func withReadLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.readLock()
        do {
            let value = try await body()
            await opLock.readUnlock()
            return value
        } catch {
            await opLock.readUnlock()
            throw error
        }
    }
    private var gpuBufferNeedsSync: Bool = false // Deprecated/Unused but kept if logic needs refactor

    private func acquireTransientBuffers(vectorCount: Int) throws -> TransientBuffers {
        if let index = transientBufferPool.firstIndex(where: { $0.capacity >= vectorCount }) {
            transientReuseCount += 1
            return transientBufferPool.remove(at: index)
        }

        transientAllocations += 1
        let capacity = max(vectorCount, Int(Self.initialReserve))

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

    private func releaseTransientBuffers(_ buffers: TransientBuffers) {
        transientBufferPool.append(buffers)
    }

    func debugBufferPoolStats() -> BufferPoolStats {
        BufferPoolStats(transientAllocations: transientAllocations, reuseCount: transientReuseCount)
    }
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    /// Secondary pipeline for SIMD8 kernel (used for high-dimensional vectors 384+)
    private let computePipelineSIMD8: MTLComputePipelineState?
    private let topKReduceDistancesPipeline: MTLComputePipelineState
    private let topKReduceEntriesPipeline: MTLComputePipelineState
    /// Whether to use SIMD8 kernel based on dimensions
    private let useSIMD8: Bool
    
    // Metal Buffers
    private var vectorsBuffer: MTLBuffer
    private var distancesBuffer: MTLBuffer
    private var queryBuffer: MTLBuffer
    private let vectorCountBuffer: MTLBuffer
    private let dimensionsBuffer: MTLBuffer

    private var transientBufferPool: [TransientBuffers] = []
    private var transientAllocations: Int = 0
    private var transientReuseCount: Int = 0
    
    public static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    /// Initialize MetalVectorEngine with given metric and dimensions.
    /// - Parameters:
    ///   - metric: Vector similarity metric (only cosine is supported initially)
    ///   - dimensions: Vector dimensionality
    /// - Throws: WaxError if Metal initialization fails or dimensions are invalid
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
        guard metric == .cosine else {
            throw WaxError.invalidToc(reason: "MetalVectorEngine currently only supports cosine similarity")
        }

        guard let device = MTLCreateSystemDefaultDevice() else {
            throw WaxError.invalidToc(reason: "Metal device not available")
        }
        self.device = device

        guard let commandQueue = device.makeCommandQueue() else {
            throw WaxError.invalidToc(reason: "Failed to create Metal command queue")
        }
        self.commandQueue = commandQueue

        let library: MTLLibrary
        do {
            library = try Self.loadMetalLibrary(device: device)
        } catch {
            throw WaxError.invalidToc(reason: "Failed to load Metal library: \(error)")
        }

        // Select optimal kernel based on dimensions:
        let useSIMD8 = dimensions >= Self.simd8DimensionThreshold
        self.useSIMD8 = useSIMD8
        
        guard let simd4Function = library.makeFunction(name: "cosineDistanceKernelSIMD4") else {
            throw WaxError.invalidToc(reason: "Failed to find cosineDistanceKernelSIMD4 function")
        }

        do {
            self.computePipeline = try device.makeComputePipelineState(function: simd4Function)
        } catch {
            throw WaxError.invalidToc(reason: "Failed to create Metal compute pipeline: \(error)")
        }
        
        // Try to load SIMD8 kernel for high-dimensional vectors
        if useSIMD8, let simd8Function = library.makeFunction(name: "cosineDistanceKernelSIMD8") {
            self.computePipelineSIMD8 = try? device.makeComputePipelineState(function: simd8Function)
        } else {
            self.computePipelineSIMD8 = nil
        }

        guard let topKDistancesFunction = library.makeFunction(name: "topKReduceDistances") else {
            throw WaxError.invalidToc(reason: "Failed to find topKReduceDistances function")
        }
        guard let topKEntriesFunction = library.makeFunction(name: "topKReduceEntries") else {
            throw WaxError.invalidToc(reason: "Failed to find topKReduceEntries function")
        }
        do {
            self.topKReduceDistancesPipeline = try device.makeComputePipelineState(function: topKDistancesFunction)
            self.topKReduceEntriesPipeline = try device.makeComputePipelineState(function: topKEntriesFunction)
        } catch {
            throw WaxError.invalidToc(reason: "Failed to create top-k reduction pipeline: \(error)")
        }

        self.metric = metric
        self.dimensions = dimensions
        self.vectorCount = 0
        self.reservedCapacity = Self.initialReserve
        self.frameIds = []
        self.dirty = false

        let initialCapacity = Int(Self.initialReserve) * dimensions * MemoryLayout<Float>.stride
        guard let vectorsBuffer = device.makeBuffer(length: initialCapacity, options: .storageModeShared) else {
            throw WaxError.invalidToc(reason: "Failed to allocate vectors buffer")
        }
        self.vectorsBuffer = vectorsBuffer

        // Allocated but unused in transient search, kept for structure
        guard let distancesBuffer = device.makeBuffer(
            length: Int(Self.initialReserve) * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate distances buffer")
        }
        self.distancesBuffer = distancesBuffer

        guard let queryBuffer = device.makeBuffer(
            length: dimensions * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate query buffer")
        }
        self.queryBuffer = queryBuffer

        guard let vectorCountBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate vector count buffer")
        }
        self.vectorCountBuffer = vectorCountBuffer

        guard let dimensionsBuffer = device.makeBuffer(
            length: MemoryLayout<UInt32>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate dimensions buffer")
        }
        self.dimensionsBuffer = dimensionsBuffer

        dimensionsBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee = UInt32(dimensions)

        transientBufferPool = [
            TransientBuffers(
                query: queryBuffer,
                distances: distancesBuffer,
                count: vectorCountBuffer,
                capacity: Int(Self.initialReserve)
            )
        ]
    }


    private static func loadMetalLibrary(device: MTLDevice) throws -> MTLLibrary {
        #if SWIFT_PACKAGE
        let bundle = Bundle.module
        #else
        let bundle = Bundle(for: MetalVectorEngine.self)
        #endif

        if let library = try? device.makeDefaultLibrary(bundle: bundle) {
            return library
        }

        func resolveShaderURL(named name: String) throws -> URL {
            let defaultURL = bundle.bundleURL.appendingPathComponent("\(name).metal")
            if FileManager.default.fileExists(atPath: defaultURL.path) {
                return defaultURL
            }
            if let fallback = bundle.urls(forResourcesWithExtension: "metal", subdirectory: nil)?
                .first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
                return fallback
            }
            if let fallback = bundle.urls(forResourcesWithExtension: "metal", subdirectory: "Shaders")?
                .first(where: { $0.deletingPathExtension().lastPathComponent == name }) {
                return fallback
            }
            throw WaxError.invalidToc(reason: "Metal shader resource not found: \(name)")
        }

        let cosineURL = try resolveShaderURL(named: "CosineDistance")
        let topKURL = try resolveShaderURL(named: "TopKReduction")
        let cosineSource = try String(contentsOf: cosineURL, encoding: .utf8)
        let topKSource = try String(contentsOf: topKURL, encoding: .utf8)
        let source = cosineSource + "\n" + topKSource
        let options = MTLCompileOptions()
        #if os(macOS)
        options.languageVersion = .version3_0
        #endif

        return try device.makeLibrary(source: source, options: options)
    }

    /// Load engine from Wax persistence layer.
    public static func load(from wax: Wax, metric: VectorMetric, dimensions: Int) async throws -> MetalVectorEngine {
        let engine = try MetalVectorEngine(metric: metric, dimensions: dimensions)
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

            if let existingIndex = frameIds.firstIndex(of: frameId) {
                // Determine offset in shared buffer
                let offset = existingIndex * dimensions
                let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)
                for dim in 0..<dimensions {
                    basePtr[offset + dim] = vector[dim]
                }
            } else {
                try await reserveIfNeeded(for: vectorCount + 1)
                
                // Append using pointer arithmetic on shared buffer
                let offset = Int(vectorCount) * dimensions
                let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)
                for dim in 0..<dimensions {
                    basePtr[offset + dim] = vector[dim]
                }
                
                frameIds.append(frameId)
                vectorCount += 1
            }

            dirty = true
        }
    }

    public func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatch: frameIds.count != vectors.count")
        }

        try await withWriteLock {
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

            let maxNewCount = vectorCount + UInt64(frameIds.count)
            try await reserveIfNeeded(for: maxNewCount)
            
            let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)

            for (frameId, vector) in zip(frameIds, vectors) {
                if let existingIndex = self.frameIds.firstIndex(of: frameId) {
                    let offset = existingIndex * dimensions
                    for dim in 0..<dimensions {
                        basePtr[offset + dim] = vector[dim]
                    }
                } else {
                    let offset = Int(vectorCount) * dimensions
                    for dim in 0..<dimensions {
                        basePtr[offset + dim] = vector[dim]
                    }
                    self.frameIds.append(frameId)
                    vectorCount += 1
                }
            }

            dirty = true
        }
    }

    public func addBatchStreaming(frameIds: [UInt64], vectors: [[Float]], chunkSize: Int = 256) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatchStreaming: frameIds.count != vectors.count")
        }

        guard frameIds.count > chunkSize else {
            try await addBatch(frameIds: frameIds, vectors: vectors)
            return
        }

        for start in stride(from: 0, to: frameIds.count, by: chunkSize) {
            let end = min(start + chunkSize, frameIds.count)
            let chunkFrameIds = Array(frameIds[start..<end])
            let chunkVectors = Array(vectors[start..<end])
            try await addBatch(frameIds: chunkFrameIds, vectors: chunkVectors)
        }
    }

    public func remove(frameId: UInt64) async throws {
        await withWriteLock {
            guard vectorCount > 0 else { return }
            guard let index = frameIds.firstIndex(of: frameId) else { return }

            // To efficiently remove, we need to shift all subsequent vectors.
            // memmove is efficient for this.
            
            let countAfter = Int(vectorCount) - 1 - index
            if countAfter > 0 {
                let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)
                let dst = basePtr.advanced(by: index * dimensions)
                let src = basePtr.advanced(by: (index + 1) * dimensions)
                // Overlap exists, move is required
                dst.moveUpdate(from: src, count: countAfter * dimensions)
            }
            
            frameIds.remove(at: index)
            vectorCount -= 1
            dirty = true
        }
    }

    public func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        try await withReadLock {
            guard vectorCount > 0 else { return [] }
            try validate(vector)
            let limit = Self.clampTopK(topK)
            let topKCount = min(limit, Int(vectorCount))
            let reductionThreadsPerThreadgroup = Self.reductionThreadgroupSize(
                maxThreads: topKReduceDistancesPipeline.maxTotalThreadsPerThreadgroup
            )
            let useGpuTopK = Int(vectorCount) >= Self.gpuTopKThreshold && topKCount <= reductionThreadsPerThreadgroup
            
            // Zero-Copy: No sync needed. vectorsBuffer is always up to date.

            // Allocate transient buffers for concurrency safety
            let transientBuffers = try acquireTransientBuffers(vectorCount: Int(vectorCount))
            defer { releaseTransientBuffers(transientBuffers) }

            let transientQueryBuffer = transientBuffers.query
            let transientDistancesBuffer = transientBuffers.distances
            let transientCountBuffer = transientBuffers.count

            let queryPtr = transientQueryBuffer.contents().assumingMemoryBound(to: Float.self)
            queryPtr.update(from: vector, count: vector.count)

            var currentVectorCount = UInt32(vectorCount)
            withUnsafeBytes(of: &currentVectorCount) { raw in
                transientCountBuffer.contents().copyMemory(from: raw.baseAddress!, byteCount: raw.count)
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw WaxError.invalidToc(reason: "Failed to create command buffer")
            }

            var reductionBuffers: [MTLBuffer] = []
            var finalTopKBuffer: MTLBuffer?
            defer { _ = reductionBuffers.count }

            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw WaxError.invalidToc(reason: "Failed to create compute encoder")
            }

            computeEncoder.setBuffer(vectorsBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(transientQueryBuffer, offset: 0, index: 1)
            computeEncoder.setBuffer(transientDistancesBuffer, offset: 0, index: 2)
            computeEncoder.setBuffer(transientCountBuffer, offset: 0, index: 3)
            computeEncoder.setBuffer(dimensionsBuffer, offset: 0, index: 4)

            let threadgroupMemorySize = dimensions * MemoryLayout<Float>.stride
            computeEncoder.setThreadgroupMemoryLength(threadgroupMemorySize, index: 0)

            let activePipeline = (useSIMD8 && computePipelineSIMD8 != nil) ? computePipelineSIMD8! : computePipeline
            computeEncoder.setComputePipelineState(activePipeline)

            let maxThreads = activePipeline.maxTotalThreadsPerThreadgroup
            let threadsPerThreadgroup = min(maxThreads, Self.maxThreadsPerThreadgroup)
            let threadgroups = MTLSize(
                width: (Int(vectorCount) + threadsPerThreadgroup - 1) / threadsPerThreadgroup,
                height: 1,
                depth: 1
            )
            let threadgroupSize = MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)

            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()

            if useGpuTopK {
                // GPU top-k reduction: per-threadgroup bitonic sort on chunks,
                // then iteratively merge until a single sorted top-k remains.
                let threadgroupSize = reductionThreadsPerThreadgroup
                let groupCount = (Int(vectorCount) + threadgroupSize - 1) / threadgroupSize
                let stage1Count = groupCount * topKCount
                let stage1Length = stage1Count * MemoryLayout<TopKEntry>.stride
                guard let stage1Buffer = device.makeBuffer(length: stage1Length, options: .storageModeShared) else {
                    throw WaxError.invalidToc(reason: "Failed to allocate top-k stage1 buffer")
                }
                reductionBuffers.append(stage1Buffer)

                guard let reduceEncoder = commandBuffer.makeComputeCommandEncoder() else {
                    throw WaxError.invalidToc(reason: "Failed to create top-k reduction encoder")
                }
                reduceEncoder.setComputePipelineState(topKReduceDistancesPipeline)
                reduceEncoder.setBuffer(transientDistancesBuffer, offset: 0, index: 0)
                var vectorCount32 = UInt32(vectorCount)
                var topK32 = UInt32(topKCount)
                reduceEncoder.setBytes(&vectorCount32, length: MemoryLayout<UInt32>.stride, index: 1)
                reduceEncoder.setBytes(&topK32, length: MemoryLayout<UInt32>.stride, index: 2)
                reduceEncoder.setBuffer(stage1Buffer, offset: 0, index: 3)
                reduceEncoder.setThreadgroupMemoryLength(
                    threadgroupSize * MemoryLayout<TopKEntry>.stride,
                    index: 0
                )
                let reduceGroups = MTLSize(width: groupCount, height: 1, depth: 1)
                let reduceGroupSize = MTLSize(width: threadgroupSize, height: 1, depth: 1)
                reduceEncoder.dispatchThreadgroups(reduceGroups, threadsPerThreadgroup: reduceGroupSize)
                reduceEncoder.endEncoding()

                var currentBuffer = stage1Buffer
                var currentCount = stage1Count
                while currentCount > topKCount {
                    let nextGroupCount = (currentCount + threadgroupSize - 1) / threadgroupSize
                    let nextCount = nextGroupCount * topKCount
                    let nextLength = nextCount * MemoryLayout<TopKEntry>.stride
                    guard let nextBuffer = device.makeBuffer(length: nextLength, options: .storageModeShared) else {
                        throw WaxError.invalidToc(reason: "Failed to allocate top-k merge buffer")
                    }
                    reductionBuffers.append(nextBuffer)

                    guard let mergeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                        throw WaxError.invalidToc(reason: "Failed to create top-k merge encoder")
                    }
                    mergeEncoder.setComputePipelineState(topKReduceEntriesPipeline)
                    mergeEncoder.setBuffer(currentBuffer, offset: 0, index: 0)
                    var entryCount32 = UInt32(currentCount)
                    mergeEncoder.setBytes(&entryCount32, length: MemoryLayout<UInt32>.stride, index: 1)
                    mergeEncoder.setBytes(&topK32, length: MemoryLayout<UInt32>.stride, index: 2)
                    mergeEncoder.setBuffer(nextBuffer, offset: 0, index: 3)
                    mergeEncoder.setThreadgroupMemoryLength(
                        threadgroupSize * MemoryLayout<TopKEntry>.stride,
                        index: 0
                    )
                    let mergeGroups = MTLSize(width: nextGroupCount, height: 1, depth: 1)
                    mergeEncoder.dispatchThreadgroups(mergeGroups, threadsPerThreadgroup: reduceGroupSize)
                    mergeEncoder.endEncoding()

                    currentBuffer = nextBuffer
                    currentCount = nextCount
                }

                finalTopKBuffer = currentBuffer
            }

            await withCheckedContinuation { continuation in
                commandBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
                commandBuffer.commit()
            }

            if useGpuTopK, let finalTopKBuffer {
                guard let resultsBuffer = device.makeBuffer(
                    length: topKCount * MemoryLayout<TopKResult>.stride,
                    options: .storageModeShared
                ) else {
                    throw WaxError.invalidToc(reason: "Failed to allocate top-k results buffer")
                }

                let entriesPtr = finalTopKBuffer.contents().assumingMemoryBound(to: TopKEntry.self)
                let resultsPtr = resultsBuffer.contents().assumingMemoryBound(to: TopKResult.self)
                var resultCount = 0
                for i in 0..<topKCount {
                    let entry = entriesPtr[i]
                    if entry.index == UInt32.max || !entry.distance.isFinite { continue }
                    let index = Int(entry.index)
                    if index >= frameIds.count { continue }
                    let score = metric.score(fromDistance: entry.distance)
                    resultsPtr[resultCount] = TopKResult(frameId: frameIds[index], score: score)
                    resultCount += 1
                }

                var results: [(UInt64, Float)] = []
                results.reserveCapacity(resultCount)
                for i in 0..<resultCount {
                    let entry = resultsPtr[i]
                    results.append((entry.frameId, entry.score))
                }
                return results
            }

            let distancesPtr = transientDistancesBuffer.contents().assumingMemoryBound(to: Float.self)
            let topResults = Self.topK(distances: distancesPtr, count: Int(vectorCount), k: limit)

            var results: [(UInt64, Float)] = []
            results.reserveCapacity(topResults.count)

            for (index, distance) in topResults {
                let score = metric.score(fromDistance: distance)
                results.append((frameIds[index], score))
            }

            return results
        }
    }

    /// O(n log k) partial selection to avoid full sort of distance buffer.
    private static func topK(distances: UnsafePointer<Float>, count: Int, k: Int) -> [(Int, Float)] {
        guard k > 0, count > 0 else { return [] }
        var heap: [(Float, Int)] = [] // (distance, index)
        heap.reserveCapacity(k)

        func siftDown(_ start: Int, _ end: Int) {
            var root = start
            while true {
                let child = root * 2 + 1
                if child > end { break }
                var swap = root
                if heap[swap].0 < heap[child].0 { swap = child }
                if child + 1 <= end, heap[swap].0 < heap[child + 1].0 { swap = child + 1 }
                if swap == root { return }
                heap.swapAt(root, swap)
                root = swap
            }
        }

        func siftUp(_ index: Int) {
            var child = index
            while child > 0 {
                let parent = (child - 1) / 2
                if heap[parent].0 >= heap[child].0 { break }
                heap.swapAt(parent, child)
                child = parent
            }
        }

        let initial = min(k, count)
        for i in 0..<initial {
            heap.append((distances[i], i))
        }
        // Build max-heap
        for i in stride(from: (heap.count / 2), through: 0, by: -1) {
            siftDown(i, heap.count - 1)
        }

        if initial < count {
            for i in initial..<count {
                let value = distances[i]
                if value >= heap[0].0 { continue }
                heap[0] = (value, i)
                siftDown(0, heap.count - 1)
            }
        }

        // Heap contains k smallest distances unordered; sort ascending
        heap.sort { $0.0 < $1.0 }
        return heap.map { ($0.1, $0.0) }
    }

    public func serialize() async throws -> Data {
        await withReadLock {
            var data = Data()

            data.append(contentsOf: [0x4D, 0x56, 0x32, 0x56])
            var version = UInt16(1).littleEndian
            withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
            data.append(UInt8(2))
            data.append(metric.toVecSimilarity().rawValue)
            var dims = UInt32(dimensions).littleEndian
            withUnsafeBytes(of: &dims) { data.append(contentsOf: $0) }
            var vecCount = vectorCount.littleEndian
            withUnsafeBytes(of: &vecCount) { data.append(contentsOf: $0) }

            // Read from Shared Vector Buffer
            let vectorDataCount = Int(vectorCount) * dimensions * MemoryLayout<Float>.stride
            var vecDataCountLE = UInt64(vectorDataCount).littleEndian
            withUnsafeBytes(of: &vecDataCountLE) { data.append(contentsOf: $0) }
            data.append(contentsOf: Data(repeating: 0, count: 8))
            
            // Should be efficient memcpy
            let basePtr = vectorsBuffer.contents()
            let vectorsData = Data(bytes: basePtr, count: vectorDataCount)
            data.append(vectorsData)

            let frameIdDataCount = frameIds.count * MemoryLayout<UInt64>.stride
            var frameIdDataCountLE = UInt64(frameIdDataCount).littleEndian
            withUnsafeBytes(of: &frameIdDataCountLE) { data.append(contentsOf: $0) }
            data.append(contentsOf: frameIds.withUnsafeBufferPointer { Data(buffer: $0) })

            return data
        }
    }

    public func deserialize(_ data: Data) async throws {
        try await withWriteLock {
            guard data.count >= 36 else {
                throw WaxError.invalidToc(reason: "Metal segment too small: \(data.count) bytes")
            }

            var offset = 0

            // Read and verify magic
            let magic = data[offset..<offset+4]
            offset += 4
            guard magic == Data([0x4D, 0x56, 0x32, 0x56]) else {
                throw WaxError.invalidToc(reason: "Metal segment magic mismatch")
            }

            // Read version
            let version = UInt16(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt16.self)
            })
            offset += 2
            guard version == 1 else {
                throw WaxError.invalidToc(reason: "Unsupported Metal segment version \(version)")
            }

            // Read encoding
            let encoding = data[offset]
            offset += 1
            guard encoding == 2 else {
                throw WaxError.invalidToc(reason: "Unsupported Metal segment encoding \(encoding)")
            }

            // Read similarity
            let similarityRaw = data[offset]
            offset += 1
            guard let similarity = VecSimilarity(rawValue: similarityRaw),
                  similarity == metric.toVecSimilarity() else {
                throw WaxError.invalidToc(reason: "Metric mismatch: expected \(metric.toVecSimilarity()), got \(similarityRaw)")
            }

            // Read dimensions
            let savedDimensions = UInt32(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt32.self)
            })
            offset += 4
            guard savedDimensions == UInt32(dimensions) else {
                throw WaxError.invalidToc(reason: "Dimension mismatch: expected \(dimensions), got \(savedDimensions)")
            }

            // Read vector count
            let savedVectorCount = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += 8

            let vectorLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += 8
            
            // Read reserved bytes
            let reserved = data[offset..<offset + 8]
            offset += 8
            guard reserved == Data(repeating: 0, count: 8) else {
                throw WaxError.invalidToc(reason: "Metal segment reserved bytes must be zero")
            }

            guard vectorLength == savedVectorCount * UInt64(dimensions) * UInt64(MemoryLayout<Float>.stride) else {
                throw WaxError.invalidToc(reason: "Vector data length mismatch")
            }
            guard data.count >= offset + Int(vectorLength) + MemoryLayout<UInt64>.stride else {
                throw WaxError.invalidToc(reason: "Metal segment missing frameId length")
            }
            
            // Resize buffer and copy vectors directly
            vectorCount = savedVectorCount
            reservedCapacity = max(reservedCapacity, UInt32(min(vectorCount, UInt64(UInt32.max))))
            try resizeBuffersIfNeeded(for: reservedCapacity)
            
            let destPtr = vectorsBuffer.contents()
            data.withUnsafeBytes { srcBuffer in
                 if let srcBase = srcBuffer.baseAddress {
                     destPtr.copyMemory(from: srcBase.advanced(by: offset), byteCount: Int(vectorLength))
                 }
            }
            offset += Int(vectorLength)

            let frameIdLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += 8
            guard frameIdLength == savedVectorCount * UInt64(MemoryLayout<UInt64>.stride) else {
                throw WaxError.invalidToc(reason: "FrameId data length mismatch")
            }
            frameIds = Array(data[offset..<offset+Int(frameIdLength)].withUnsafeBytes {
                Array($0.bindMemory(to: UInt64.self))
            })

            dirty = false
        }
    }

    /// Stage current state for commit to Wax.
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

    private static func reductionThreadgroupSize(maxThreads: Int) -> Int {
        let capped = min(maxThreads, maxThreadsPerThreadgroup)
        var size = 1
        while size * 2 <= capped {
            size *= 2
        }
        return size
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

        try resizeBuffersIfNeeded(for: reservedCapacity)
    }

    private func resizeBuffersIfNeeded(for capacity: UInt32) throws {
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

extension MetalVectorEngine: VectorSearchEngine {}
#endif // canImport(Metal)
