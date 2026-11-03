//
//  MetalVectorEngine.swift
//  Wax
//
//  Metal-accelerated vector search engine using GPU compute shaders.
//  Provides Metal-backed cosine similarity search.
//
//  Zero-Copy Optimization:
//  - Stores vectors directly in MTLBuffer (Unified Memory) to avoid CPU-RAM duplication.
//  - Eliminates O(N) copy latency during search synchronization.
//

#if canImport(Metal)
import Foundation
import Metal
import WaxCore

package actor MetalVectorEngine {
    static let maxResults = 10_000
    private static let initialReserve: UInt32 = 64
    static let maxThreadsPerThreadgroup = 256
    static let gpuTopKThreshold = 1_000
    /// Upper bound on idle transient buffer sets kept for reuse across searches.
    static let maxPooledTransientBufferSets = 4
    
    /// Threshold for switching to SIMD8 kernel (optimal for MiniLM 384-dim vectors)
    private static let simd8DimensionThreshold = 384

    struct TopKEntry {
        var distance: Float
        var index: UInt32
    }

    struct TopKResult {
        var frameId: UInt64
        var score: Float
    }

    struct TransientBuffers {
        let query: MTLBuffer
        let distances: MTLBuffer
        let count: MTLBuffer
        let capacity: Int
    }

    struct BufferPoolStats: Sendable {
        var transientAllocations: Int
        var reuseCount: Int
        var pooledBufferSets: Int
    }

    let metric: VectorMetric
    package let dimensions: Int

    var vectorCount: UInt64
    private var reservedCapacity: UInt32
    // Zero-Copy: 'vectors' array removed. Primary storage is `vectorsBuffer`.
    
    var frameIds: [UInt64]
    private var positions: [UInt64: Int]
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

    func withReadLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
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
    
    let device: MTLDevice
    let commandQueue: MTLCommandQueue
    let computePipeline: MTLComputePipelineState
    /// Secondary pipeline for SIMD8 kernel (used for high-dimensional vectors 384+)
    let computePipelineSIMD8: MTLComputePipelineState?
    let topKReduceDistancesPipeline: MTLComputePipelineState
    let topKReduceEntriesPipeline: MTLComputePipelineState
    /// Whether to use SIMD8 kernel based on dimensions
    let useSIMD8: Bool
    
    // Metal Buffers
    var vectorsBuffer: MTLBuffer
    private var distancesBuffer: MTLBuffer
    private var queryBuffer: MTLBuffer
    private let vectorCountBuffer: MTLBuffer
    let dimensionsBuffer: MTLBuffer

    private var transientBufferPool: [TransientBuffers] = []
    private var transientAllocations: Int = 0
    private var transientReuseCount: Int = 0
    
    package static var isAvailable: Bool {
        MTLCreateSystemDefaultDevice() != nil
    }

    /// Initialize MetalVectorEngine with given metric and dimensions.
    /// - Parameters:
    ///   - metric: Vector similarity metric (only cosine is supported initially)
    ///   - dimensions: Vector dimensionality
    /// - Throws: WaxError if Metal initialization fails or dimensions are invalid
    package init(metric: VectorMetric, dimensions: Int) throws {
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
        self.positions = [:]
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
        let bundle = WaxBundleResolver.resolveModule(
            named: "Wax_WaxVectorSearch.bundle",
            moduleFallback: .module
        )
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
    package static func load(from wax: Wax, metric: VectorMetric, dimensions: Int) async throws -> MetalVectorEngine {
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

    package func add(frameId: UInt64, vector: [Float]) async throws {
        try await withWriteLock {
            try validate(vector)

            if let existingIndex = positions[frameId] {
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
                
                positions[frameId] = frameIds.count
                frameIds.append(frameId)
                vectorCount += 1
            }

            dirty = true
        }
    }

    package func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatch: frameIds.count != vectors.count")
        }

        try await withWriteLock {
            for vector in vectors {
                try validate(vector)
            }

            let maxNewCount = vectorCount + UInt64(frameIds.count)
            try await reserveIfNeeded(for: maxNewCount)
            
            let basePtr = vectorsBuffer.contents().assumingMemoryBound(to: Float.self)

            self.positions.reserveCapacity(Int(maxNewCount))
            for (frameId, vector) in zip(frameIds, vectors) {
                if let existingIndex = self.positions[frameId] {
                    let offset = existingIndex * dimensions
                    for dim in 0..<dimensions {
                        basePtr[offset + dim] = vector[dim]
                    }
                } else {
                    let offset = Int(vectorCount) * dimensions
                    for dim in 0..<dimensions {
                        basePtr[offset + dim] = vector[dim]
                    }
                    self.positions[frameId] = self.frameIds.count
                    self.frameIds.append(frameId)
                    vectorCount += 1
                }
            }

            dirty = true
        }
    }

    package func addBatchStreaming(frameIds: [UInt64], vectors: [[Float]], chunkSize: Int = 256) async throws {
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

    package func remove(frameId: UInt64) async throws {
        await withWriteLock {
            guard vectorCount > 0 else { return }
            guard let index = positions[frameId] else { return }

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
            
            positions.removeValue(forKey: frameId)
            frameIds.remove(at: index)
            for next in index..<frameIds.count {
                positions[frameIds[next]] = next
            }
            vectorCount -= 1
            dirty = true
        }
    }

    package func serialize() async throws -> Data {
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

    package func deserialize(_ data: Data) async throws {
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

            let vectorElementCount = savedVectorCount.multipliedReportingOverflow(by: UInt64(dimensions))
            let expectedVectorLength = vectorElementCount.partialValue.multipliedReportingOverflow(
                by: UInt64(MemoryLayout<Float>.stride)
            )
            guard !vectorElementCount.overflow,
                  !expectedVectorLength.overflow,
                  vectorLength == expectedVectorLength.partialValue,
                  vectorLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "Vector data length mismatch")
            }
            let vectorLengthInt = Int(vectorLength)
            guard data.count - offset >= vectorLengthInt + MemoryLayout<UInt64>.stride else {
                throw WaxError.invalidToc(reason: "Metal segment missing frameId length")
            }
            
            // Resize buffer for deserialized vectors.
            // Keep vectorCount = 0 during resize so resizeBuffersIfNeeded() does NOT
            // try to copy from the old (undersized) buffer — there are no existing
            // vectors to preserve during deserialization.
            reservedCapacity = max(reservedCapacity, UInt32(min(savedVectorCount, UInt64(UInt32.max))))
            try resizeBuffersIfNeeded(for: reservedCapacity)
            
            let destPtr = vectorsBuffer.contents()
            data.withUnsafeBytes { srcBuffer in
                 if let srcBase = srcBuffer.baseAddress {
                     destPtr.copyMemory(from: srcBase.advanced(by: offset), byteCount: vectorLengthInt)
                 }
            }
            offset += vectorLengthInt

            let frameIdLength = UInt64(littleEndian: data.withUnsafeBytes {
                $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)
            })
            offset += 8
            let expectedFrameIdLength = savedVectorCount.multipliedReportingOverflow(
                by: UInt64(MemoryLayout<UInt64>.stride)
            )
            guard !expectedFrameIdLength.overflow,
                  frameIdLength == expectedFrameIdLength.partialValue,
                  frameIdLength <= UInt64(Int.max) else {
                throw WaxError.invalidToc(reason: "FrameId data length mismatch")
            }
            let frameIdLengthInt = Int(frameIdLength)
            guard data.count - offset >= frameIdLengthInt else {
                throw WaxError.invalidToc(reason: "Metal segment missing frameId data")
            }
            let decodedFrameIds = data.withUnsafeBytes { rawBuffer in
                var decoded: [UInt64] = []
                decoded.reserveCapacity(Int(savedVectorCount))
                for byteOffset in stride(from: offset, to: offset + frameIdLengthInt, by: MemoryLayout<UInt64>.stride) {
                    decoded.append(UInt64(littleEndian: rawBuffer.loadUnaligned(fromByteOffset: byteOffset, as: UInt64.self)))
                }
                return decoded
            }
            try VectorSerializer.validateUniqueFrameIds(decodedFrameIds)
            offset += frameIdLengthInt
            guard offset == data.count else {
                throw WaxError.invalidToc(reason: "Metal segment has trailing bytes")
            }

            // Set vectorCount AFTER all structural validation succeeds.
            vectorCount = savedVectorCount
            frameIds = decodedFrameIds
            positions.removeAll(keepingCapacity: true)
            positions.reserveCapacity(decodedFrameIds.count)
            for (index, id) in decodedFrameIds.enumerated() {
                positions[id] = index
            }
            dirty = false
        }
    }

    /// Stage current state for commit to Wax.
    package func stageForCommit(into wax: Wax) async throws {
        if !dirty { return }
        let blob = try await serialize()
        try await wax.stageVecIndexForNextCommit(
            bytes: blob,
            vectorCount: vectorCount,
            dimension: UInt32(dimensions),
            similarity: metric.toVecSimilarity(),
            coverage: .latestPending
        )
        dirty = false
    }

    func validate(_ vector: [Float]) throws {
        try VectorValidation.validate(vector, dimensions: dimensions)
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
