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
    static let initialReserve: UInt32 = 64
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
    var reservedCapacity: UInt32
    // Zero-Copy: 'vectors' array removed. Primary storage is `vectorsBuffer`.
    
    var frameIds: [UInt64]
    var positions: [UInt64: Int]
    private let opLock = AsyncReadWriteLock()
    var dirty: Bool

    func withWriteLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
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

    var transientBufferPool: [TransientBuffers] = []
    var transientAllocations: Int = 0
    var transientReuseCount: Int = 0
    
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
}

extension MetalVectorEngine: VectorSearchEngine {}
#endif // canImport(Metal)
