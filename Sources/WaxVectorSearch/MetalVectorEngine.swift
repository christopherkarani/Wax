//
//  MetalVectorEngine.swift
//  Wax
//
//  Metal-accelerated vector search engine using GPU compute shaders.
//  Provides drop-in replacement for USearchVectorEngine with cosine similarity.
//

import Foundation
import Metal
import WaxCore

public actor MetalVectorEngine {
    private static let maxResults = 10_000
    private static let initialReserve: UInt32 = 64
    private static let maxThreadsPerThreadgroup = 256

    private let metric: VectorMetric
    public let dimensions: Int

    private var vectorCount: UInt64
    private var reservedCapacity: UInt32
    private var vectors: [Float]
    private var frameIds: [UInt64]
    private let opLock = AsyncMutex()
    private var dirty: Bool
    
    /// Tracks whether the GPU vectors buffer needs to be synced from CPU.
    /// This enables lazy synchronization - vectors are only copied to GPU when
    /// actually needed for search, not on every add/remove operation.
    private var gpuBufferNeedsSync: Bool
    
    private let device: MTLDevice
    private let commandQueue: MTLCommandQueue
    private let computePipeline: MTLComputePipelineState
    private var vectorsBuffer: MTLBuffer
    private var distancesBuffer: MTLBuffer
    private let vectorCountBuffer: MTLBuffer
    private let dimensionsBuffer: MTLBuffer
    
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

        guard let function = library.makeFunction(name: "cosineDistanceKernelOptimized") else {
            throw WaxError.invalidToc(reason: "Failed to find cosineDistanceKernelOptimized function")
        }

        do {
            self.computePipeline = try device.makeComputePipelineState(function: function)
        } catch {
            throw WaxError.invalidToc(reason: "Failed to create Metal compute pipeline: \(error)")
        }

        self.metric = metric
        self.dimensions = dimensions
        self.vectorCount = 0
        self.reservedCapacity = Self.initialReserve
        self.vectors = []
        self.frameIds = []
        self.dirty = false
        self.gpuBufferNeedsSync = true  // Start with sync needed (empty state)

        let initialCapacity = Int(Self.initialReserve) * dimensions * MemoryLayout<Float>.stride
        guard let vectorsBuffer = device.makeBuffer(length: initialCapacity, options: .storageModeShared) else {
            throw WaxError.invalidToc(reason: "Failed to allocate vectors buffer")
        }
        self.vectorsBuffer = vectorsBuffer

        guard let distancesBuffer = device.makeBuffer(
            length: Int(Self.initialReserve) * MemoryLayout<Float>.stride,
            options: .storageModeShared
        ) else {
            throw WaxError.invalidToc(reason: "Failed to allocate distances buffer")
        }
        self.distancesBuffer = distancesBuffer

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

        let defaultShaderURL = bundle.bundleURL.appendingPathComponent("CosineDistance.metal")
        let shaderURL: URL
        if FileManager.default.fileExists(atPath: defaultShaderURL.path) {
            shaderURL = defaultShaderURL
        } else if let fallback = bundle.urls(forResourcesWithExtension: "metal", subdirectory: nil)?
            .first(where: { $0.deletingPathExtension().lastPathComponent == "CosineDistance" }) {
            shaderURL = fallback
        } else if let fallback = bundle.urls(forResourcesWithExtension: "metal", subdirectory: "Shaders")?
            .first(where: { $0.deletingPathExtension().lastPathComponent == "CosineDistance" }) {
            shaderURL = fallback
        } else {
            throw WaxError.invalidToc(reason: "Metal shader resource not found")
        }

        let source = try String(contentsOf: shaderURL, encoding: .utf8)
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
        try await withOpLock {
            try validate(vector)

            if let existingIndex = frameIds.firstIndex(of: frameId) {
                let offset = existingIndex * dimensions
                for dim in 0..<dimensions {
                    vectors[offset + dim] = vector[dim]
                }
            } else {
                try await reserveIfNeeded(for: vectorCount + 1)

                for dim in 0..<dimensions {
                    vectors.append(vector[dim])
                }
                frameIds.append(frameId)
                vectorCount += 1
            }

            dirty = true
            gpuBufferNeedsSync = true  // Mark GPU buffer as stale
        }
    }

    public func addBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "addBatch: frameIds.count != vectors.count")
        }

        try await withOpLock {
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

            for (frameId, vector) in zip(frameIds, vectors) {
                if let existingIndex = self.frameIds.firstIndex(of: frameId) {
                    let offset = existingIndex * dimensions
                    for dim in 0..<dimensions {
                        self.vectors[offset + dim] = vector[dim]
                    }
                } else {
                    for dim in 0..<dimensions {
                        self.vectors.append(vector[dim])
                    }
                    self.frameIds.append(frameId)
                    vectorCount += 1
                }
            }

            dirty = true
            gpuBufferNeedsSync = true  // Mark GPU buffer as stale
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
        await withOpLock {
            guard vectorCount > 0 else { return }
            guard let index = frameIds.firstIndex(of: frameId) else { return }

            let offset = index * dimensions
            for _ in 0..<dimensions {
                vectors.remove(at: offset)
            }
            frameIds.remove(at: index)
            vectorCount -= 1
            dirty = true
            gpuBufferNeedsSync = true  // Mark GPU buffer as stale
        }
    }

    public func search(vector: [Float], topK: Int) async throws -> [(frameId: UInt64, score: Float)] {
        try await withOpLock {
            guard vectorCount > 0 else { return [] }
            try validate(vector)
            let limit = Self.clampTopK(topK)

            // Only sync vectors to GPU if they've changed since last search
            // This eliminates redundant memory bandwidth for read-heavy workloads
            if gpuBufferNeedsSync {
                syncVectorsToGPU()
                gpuBufferNeedsSync = false
            }

            guard let queryBuffer = device.makeBuffer(
                length: dimensions * MemoryLayout<Float>.stride,
                options: .storageModeShared
            ) else {
                throw WaxError.invalidToc(reason: "Failed to allocate query buffer")
            }
            vector.withUnsafeBufferPointer { buffer in
                queryBuffer.contents().copyMemory(
                    from: buffer.baseAddress!,
                    byteCount: buffer.count * MemoryLayout<Float>.stride
                )
            }

            vectorCountBuffer.contents().assumingMemoryBound(to: UInt32.self).pointee = UInt32(vectorCount)

            let requiredDistancesSize = Int(vectorCount) * MemoryLayout<Float>.stride
            if distancesBuffer.length < requiredDistancesSize {
                throw WaxError.invalidToc(reason: "Distances buffer too small")
            }

            guard let commandBuffer = commandQueue.makeCommandBuffer() else {
                throw WaxError.invalidToc(reason: "Failed to create command buffer")
            }

            guard let computeEncoder = commandBuffer.makeComputeCommandEncoder() else {
                throw WaxError.invalidToc(reason: "Failed to create compute encoder")
            }

            computeEncoder.setBuffer(vectorsBuffer, offset: 0, index: 0)
            computeEncoder.setBuffer(queryBuffer, offset: 0, index: 1)
            computeEncoder.setBuffer(distancesBuffer, offset: 0, index: 2)
            computeEncoder.setBuffer(vectorCountBuffer, offset: 0, index: 3)
            computeEncoder.setBuffer(dimensionsBuffer, offset: 0, index: 4)

            let threadgroupMemorySize = dimensions * MemoryLayout<Float>.stride
            computeEncoder.setThreadgroupMemoryLength(threadgroupMemorySize, index: 0)

            computeEncoder.setComputePipelineState(computePipeline)

            let maxThreads = computePipeline.maxTotalThreadsPerThreadgroup
            let threadsPerThreadgroup = min(maxThreads, Self.maxThreadsPerThreadgroup)
            let threadgroups = MTLSize(
                width: (Int(vectorCount) + threadsPerThreadgroup - 1) / threadsPerThreadgroup,
                height: 1,
                depth: 1
            )
            let threadgroupSize = MTLSize(width: threadsPerThreadgroup, height: 1, depth: 1)

            computeEncoder.dispatchThreadgroups(threadgroups, threadsPerThreadgroup: threadgroupSize)
            computeEncoder.endEncoding()

            await withCheckedContinuation { continuation in
                commandBuffer.addCompletedHandler { _ in
                    continuation.resume()
                }
                commandBuffer.commit()
            }

            let distances = Array(
                UnsafeBufferPointer(
                    start: distancesBuffer.contents().assumingMemoryBound(to: Float.self),
                    count: Int(vectorCount)
                )
            )

            var indexedResults: [(index: Int, distance: Float)] = []
            for (index, distance) in distances.enumerated() {
                indexedResults.append((index, distance))
            }

            indexedResults.sort { $0.distance < $1.distance }

            let topResults = indexedResults.prefix(limit)
            var results: [(UInt64, Float)] = []
            results.reserveCapacity(topResults.count)

            for (index, distance) in topResults {
                let score = metric.score(fromDistance: distance)
                results.append((frameIds[index], score))
            }

            return results
        }
    }

    public func serialize() async throws -> Data {
        await withOpLock {
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

            let vectorDataCount = vectors.count * MemoryLayout<Float>.stride
            var vecDataCount = UInt64(vectorDataCount).littleEndian
            withUnsafeBytes(of: &vecDataCount) { data.append(contentsOf: $0) }
            data.append(contentsOf: Data(repeating: 0, count: 8))
            data.append(contentsOf: vectors.withUnsafeBufferPointer { Data(buffer: $0) })

            let frameIdDataCount = frameIds.count * MemoryLayout<UInt64>.stride
            var frameIdDataCountLE = UInt64(frameIdDataCount).littleEndian
            withUnsafeBytes(of: &frameIdDataCountLE) { data.append(contentsOf: $0) }
            data.append(contentsOf: frameIds.withUnsafeBufferPointer { Data(buffer: $0) })

            return data
        }
    }

    public func deserialize(_ data: Data) async throws {
        try await withOpLock {
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
            vectors = Array(data[offset..<offset+Int(vectorLength)].withUnsafeBytes {
                Array($0.bindMemory(to: Float.self))
            })
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

            vectorCount = savedVectorCount
            reservedCapacity = max(reservedCapacity, UInt32(min(vectorCount, UInt64(UInt32.max))))
            try resizeBuffersIfNeeded(for: reservedCapacity)
            dirty = false
            gpuBufferNeedsSync = true  // GPU buffer needs sync after loading new vectors
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

    private func withOpLock<T>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.lock()
        do {
            let value = try await body()
            await opLock.unlock()
            return value
        } catch {
            await opLock.unlock()
            throw error
        }
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
    
    /// Synchronizes CPU vector data to GPU buffer.
    /// Called lazily only when search is performed after vectors have changed.
    /// This optimization eliminates redundant memory copies for read-heavy workloads.
    private func syncVectorsToGPU() {
        guard !vectors.isEmpty else { return }
        vectors.withUnsafeBufferPointer { buffer in
            vectorsBuffer.contents().copyMemory(
                from: buffer.baseAddress!,
                byteCount: min(buffer.count * MemoryLayout<Float>.stride, vectorsBuffer.length)
            )
        }
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
        let requiredDistancesLength = Int(capacity) * MemoryLayout<Float>.stride
        if vectorsBuffer.length >= requiredVectorsLength,
           distancesBuffer.length >= requiredDistancesLength {
            return
        }

        guard let newVectorsBuffer = device.makeBuffer(length: requiredVectorsLength, options: .storageModeShared) else {
            throw WaxError.invalidToc(reason: "Failed to resize vectors buffer")
        }

        guard let newDistancesBuffer = device.makeBuffer(length: requiredDistancesLength, options: .storageModeShared) else {
            throw WaxError.invalidToc(reason: "Failed to resize distances buffer")
        }

        vectorsBuffer = newVectorsBuffer
        distancesBuffer = newDistancesBuffer
        gpuBufferNeedsSync = true
    }
}

extension MetalVectorEngine: VectorSearchEngine {}
