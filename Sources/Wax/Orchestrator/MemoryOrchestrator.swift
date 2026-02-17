import Foundation
import WaxCore
import WaxVectorSearch

/// High-level orchestrator for text memory RAG, managing ingest, recall, and lifecycle on a Wax store.
public actor MemoryOrchestrator {
    /// Policy controlling when to compute query embeddings for vector search.
    public enum QueryEmbeddingPolicy: Sendable, Equatable {
        case never
        case ifAvailable
        case always
    }

    let wax: Wax
    private let config: OrchestratorConfig
    private let ragBuilder: FastRAGContextBuilder

    let session: WaxSession
    private let embedder: (any EmbeddingProvider)?
    private let embeddingCache: EmbeddingMemoizer?

    private var currentSessionId: UUID?

    public init(
        at url: URL,
        config: OrchestratorConfig = .default,
        embedder: (any EmbeddingProvider)? = nil
    ) async throws {
        // Prewarm tokenizer in parallel with Wax file operations
        // This overlaps BPE loading (~9-13ms) with I/O-bound file operations
        async let tokenizerPrewarm: Bool = { 
            do {
                _ = try await TokenCounter.preload()
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "tokenizer prewarm",
                    fallback: "cold start on first use"
                )
            }
            return true
        }()

        if config.requireOnDeviceProviders, let localEmbedder = embedder {
            try ProviderValidation.validateOnDevice(
                [.init(name: "embedding provider", executionMode: localEmbedder.executionMode)],
                orchestratorName: "MemoryOrchestrator"
            )
        }
        
        if FileManager.default.fileExists(atPath: url.path) {
            self.wax = try await Wax.open(at: url)
        } else {
            self.wax = try await Wax.create(at: url)
        }

        self.config = config
        self.ragBuilder = FastRAGContextBuilder()
        self.embedder = embedder
        self.embeddingCache = EmbeddingMemoizer.fromConfig(
            capacity: config.embeddingCacheCapacity,
            enabled: embedder != nil
        )

        if config.enableVectorSearch, embedder == nil, await wax.committedVecIndexManifest() == nil {
            throw WaxError.io("enableVectorSearch=true requires an EmbeddingProvider for ingest-time embeddings")
        }

        let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly
        let sessionConfig = WaxSession.Config(
            enableTextSearch: config.enableTextSearch,
            enableVectorSearch: config.enableVectorSearch,
            enableStructuredMemory: false,
            vectorEnginePreference: preference,
            vectorMetric: .cosine,
            vectorDimensions: embedder?.dimensions
        )
        self.session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)
        
        // Wait for tokenizer prewarm to complete (should already be done by now)
        _ = await tokenizerPrewarm
    }


    // MARK: - Session tagging (v1)

    public func startSession() -> UUID {
        let id = UUID()
        currentSessionId = id
        return id
    }

    public func endSession() {
        currentSessionId = nil
    }

    // MARK: - Ingestion

    /// Ingest text content into the memory store, chunking and embedding as configured.
    ///
    /// Content is split into chunks and written in batches. Each batch is committed
    /// independently to the underlying store.
    ///
    /// - Important: Batch writes are **not atomic**. If a failure occurs mid-ingest
    ///   (e.g., embedding provider error, I/O failure), earlier batches may already be
    ///   committed while later batches are lost. The committed state remains consistent
    ///   (WAL guarantees crash safety), but the ingested content may be incomplete.
    ///   Callers requiring all-or-nothing semantics should validate post-ingest or
    ///   implement their own rollback by superseding the document frame on failure.
    public func remember(_ content: String, metadata: [String: String] = [:]) async throws {
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)

        var docMeta = Metadata(metadata)
        if let session = currentSessionId {
            docMeta.entries["session_id"] = session.uuidString
        }

        let chunkCount = chunks.count
        let localSession = session
        let localEmbedder = embedder
        let cache = embeddingCache
        let sessionId = currentSessionId
        let batchSize = max(1, config.ingestBatchSize)
        let useVectorSearch = config.enableVectorSearch
        let fileManager = FileManager.default

        guard !chunks.isEmpty else {
            _ = try await localSession.put(
                Data(content.utf8),
                options: FrameMetaSubset(
                    role: .document,
                    metadata: docMeta
                )
            )
            return
        }

        if useVectorSearch, localEmbedder == nil {
            throw WaxError.io("enableVectorSearch=true requires an EmbeddingProvider for ingest-time embeddings")
        }

        struct IngestBatchResult {
            let index: Int
            let embeddings: [[Float]]?
        }

        let batchRanges: [(index: Int, range: Range<Int>)] = stride(from: 0, to: chunkCount, by: batchSize)
            .enumerated()
            .map { idx, start in
                let end = min(start + batchSize, chunkCount)
                return (idx, start..<end)
            }

        let parallelism = max(1, config.ingestConcurrency)

        let stagingDirectory = fileManager.temporaryDirectory
            .appendingPathComponent("wax-ingest-\(UUID().uuidString)", isDirectory: true)
        defer { try? fileManager.removeItem(at: stagingDirectory) }
        if useVectorSearch {
            try fileManager.createDirectory(at: stagingDirectory, withIntermediateDirectories: true)
        }

        var stagedEmbeddingFiles: [Int: URL] = [:]
        stagedEmbeddingFiles.reserveCapacity(batchRanges.count)
        var preparedBatchCount = 0

        try await withThrowingTaskGroup(of: IngestBatchResult.self) { group in
            func enqueue(_ entry: (index: Int, range: Range<Int>)) {
                group.addTask {
                    let batchChunks = Array(chunks[entry.range])

                    if let localEmbedder = localEmbedder, useVectorSearch {
                        let embeddings = try await Self.prepareEmbeddingsBatchOptimized(
                            chunks: batchChunks,
                            embedder: localEmbedder,
                            cache: cache
                        )
                        return IngestBatchResult(
                            index: entry.index,
                            embeddings: embeddings
                        )
                    }

                    return IngestBatchResult(
                        index: entry.index,
                        embeddings: nil
                    )
                }
            }

            var iterator = batchRanges.makeIterator()
            let initial = min(parallelism, batchRanges.count)
            var inFlight = 0
            for _ in 0..<initial {
                if let next = iterator.next() {
                    enqueue(next)
                    inFlight += 1
                }
            }

            while inFlight > 0 {
                guard let result = try await group.next() else { break }
                inFlight -= 1

                if let embeddings = result.embeddings {
                    let fileURL = stagingDirectory.appendingPathComponent("batch-\(result.index).emb")
                    try Self.writeEmbeddings(embeddings, to: fileURL)
                    stagedEmbeddingFiles[result.index] = fileURL
                }
                preparedBatchCount += 1

                if let next = iterator.next() {
                    enqueue(next)
                    inFlight += 1
                }
            }
        }

        guard preparedBatchCount == batchRanges.count else {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) prepared batches, got \(preparedBatchCount)"
            )
        }
        if useVectorSearch, stagedEmbeddingFiles.count != batchRanges.count {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) staged embedding batches, got \(stagedEmbeddingFiles.count)"
            )
        }

        let docId = try await localSession.put(
            Data(content.utf8),
            options: FrameMetaSubset(
                role: .document,
                metadata: docMeta
            )
        )

        for entry in batchRanges {
            let batchChunks = Array(chunks[entry.range])
            let batchContents = batchChunks.map { Data($0.utf8) }
            var options: [FrameMetaSubset] = []
            options.reserveCapacity(batchChunks.count)
            for (localIdx, globalIdx) in entry.range.enumerated() {
                var option = FrameMetaSubset()
                option.role = .chunk
                option.parentId = docId
                option.chunkIndex = UInt32(globalIdx)
                option.chunkCount = UInt32(chunkCount)
                option.searchText = batchChunks[localIdx]

                var chunkMeta = Metadata(metadata)
                if let sessionId {
                    chunkMeta.entries["session_id"] = sessionId.uuidString
                }
                option.metadata = chunkMeta
                options.append(option)
            }

            if useVectorSearch {
                guard let fileURL = stagedEmbeddingFiles[entry.index] else {
                    throw WaxError.io("missing staged embeddings for batch \(entry.index)")
                }
                let embeddings = try Self.readEmbeddings(from: fileURL)
                let frameIds = try await localSession.putBatch(
                    contents: batchContents,
                    embeddings: embeddings,
                    identity: localEmbedder?.identity,
                    options: options
                )

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
            } else {
                let frameIds = try await localSession.putBatch(contents: batchContents, options: options)

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
            }
        }
    }

    /// Optimized batch embedding preparation with cache-aware batching.
    /// Minimizes cache lookups and maximizes batch embedding efficiency.
    private static func prepareEmbeddingsBatchOptimized(
        chunks: [String],
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [[Float]] {
        var results: [[Float]] = Array(repeating: [], count: chunks.count)
        let cacheKeys: [UInt64]? = if cache != nil {
            chunks.map {
                EmbeddingKey.make(
                    text: $0,
                    identity: embedder.identity,
                    dimensions: embedder.dimensions,
                    normalized: embedder.normalize
                )
            }
        } else {
            nil
        }
        var missingIndices: [Int] = []
        var missingTexts: [String] = []
        missingIndices.reserveCapacity(chunks.count)
        missingTexts.reserveCapacity(chunks.count)

        if let cache, let cacheKeys {
            let cachedValues = await cache.getBatch(cacheKeys)
            for (index, key) in cacheKeys.enumerated() {
                if let cached = cachedValues[key] {
                    results[index] = cached
                } else {
                    missingIndices.append(index)
                    missingTexts.append(chunks[index])
                }
            }
        } else {
            missingIndices = Array(0..<chunks.count)
            missingTexts = chunks
        }

        // Compute missing embeddings using batch API when available
        if !missingTexts.isEmpty {
            let vectors: [[Float]]
            
            // Prefer batch embedding for significantly better throughput
            if let batchEmbedder = embedder as? any BatchEmbeddingProvider {
                // Use optimized batch embedding - 3-8x faster than sequential
                vectors = try await batchEmbedder.embed(batch: missingTexts)
            } else {
                var sequentialVectors: [[Float]] = []
                sequentialVectors.reserveCapacity(missingTexts.count)
                for text in missingTexts {
                    let vector = try await embedder.embed(text)
                    sequentialVectors.append(vector)
                }
                vectors = sequentialVectors
            }

            guard vectors.count == missingIndices.count else {
                throw WaxError.encodingError(
                    reason: "batch embedding returned \(vectors.count) vectors for \(missingIndices.count) inputs"
                )
            }

            // Normalize (if needed) and cache results
            let shouldNormalize = embedder.normalize
            var cacheItems: [(key: UInt64, value: [Float])] = []
            cacheItems.reserveCapacity(missingIndices.count)
            for (localIdx, globalIdx) in missingIndices.enumerated() {
                var vec = vectors[localIdx]
                if shouldNormalize && !vec.isEmpty {
                    vec = normalizedL2(vec)
                }
                results[globalIdx] = vec

                if let cacheKeys {
                    cacheItems.append((key: cacheKeys[globalIdx], value: vec))
                }
            }

            if let cache, !cacheItems.isEmpty {
                await cache.setBatch(cacheItems)
            }
        }

        return results
    }
    
    /// Legacy method for backward compatibility
    private static func prepareEmbeddingsBatch(
        chunks: [String],
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [[Float]] {
        try await prepareEmbeddingsBatchOptimized(chunks: chunks, embedder: embedder, cache: cache)
    }

    // MARK: - Recall (Fast RAG)

    public func recall(query: String) async throws -> RAGContext {
        let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly
        let embedding = try await queryEmbedding(for: query, policy: .ifAvailable)
        return try await ragBuilder.build(
            query: query,
            embedding: embedding,
            vectorEnginePreference: preference,
            wax: wax,
            session: session,
            config: config.rag
        )
    }

    public func recall(query: String, embedding: [Float]) async throws -> RAGContext {
        let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly
        return try await ragBuilder.build(
            query: query,
            embedding: embedding,
            vectorEnginePreference: preference,
            wax: wax,
            session: session,
            config: config.rag
        )
    }

    public func recall(query: String, embeddingPolicy: QueryEmbeddingPolicy) async throws -> RAGContext {
        let embedding = try await queryEmbedding(for: query, policy: embeddingPolicy)
        if let embedding {
            let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly
            return try await ragBuilder.build(
                query: query,
                embedding: embedding,
                vectorEnginePreference: preference,
                wax: wax,
                session: session,
                config: config.rag
            )
        }
        let preference: VectorEnginePreference = config.useMetalVectorSearch ? .metalPreferred : .cpuOnly
        return try await ragBuilder.build(
            query: query,
            vectorEnginePreference: preference,
            wax: wax,
            session: session,
            config: config.rag
        )
    }

    // MARK: - Persistence lifecycle

    public func flush() async throws {
        try await session.commit()
    }

    public func close() async throws {
        try await flush()
        await session.close()
        try await wax.close()
    }

    // MARK: - Math helpers

    /// L2 normalization using Accelerate framework for optimal SIMD performance.
    @inline(__always)
    private static func normalizedL2(_ vector: [Float]) -> [Float] {
        VectorMath.normalizeL2(vector)
    }

    private static func writeEmbeddings(_ embeddings: [[Float]], to url: URL) throws {
        var data = Data()
        data.reserveCapacity(8 + embeddings.reduce(0) { $0 + ($1.count * 4) })

        var count = UInt32(embeddings.count).littleEndian
        withUnsafeBytes(of: &count) { data.append(contentsOf: $0) }

        for vector in embeddings {
            guard vector.count <= Int(UInt32.max) else {
                throw WaxError.encodingError(reason: "embedding dimension exceeds UInt32.max")
            }
            var dimension = UInt32(vector.count).littleEndian
            withUnsafeBytes(of: &dimension) { data.append(contentsOf: $0) }
            for value in vector {
                var bits = value.bitPattern.littleEndian
                withUnsafeBytes(of: &bits) { data.append(contentsOf: $0) }
            }
        }

        try data.write(to: url, options: .atomic)
    }

    private static func readEmbeddings(from url: URL) throws -> [[Float]] {
        let data = try Data(contentsOf: url)
        var offset = 0

        func readUInt32() throws -> UInt32 {
            guard data.count - offset >= 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var raw: UInt32 = 0
            _ = withUnsafeMutableBytes(of: &raw) { destination in
                data.copyBytes(to: destination, from: offset..<(offset + 4))
            }
            let value = UInt32(littleEndian: raw)
            offset += 4
            return value
        }

        let count = try Int(readUInt32())
        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(count)

        for _ in 0..<count {
            let dimension = try Int(readUInt32())
            guard dimension >= 0 else {
                throw WaxError.decodingError(reason: "invalid embedding dimension")
            }
            guard data.count - offset >= dimension * 4 else {
                throw WaxError.decodingError(reason: "invalid embedding batch payload")
            }
            var vector: [Float] = []
            vector.reserveCapacity(dimension)
            for _ in 0..<dimension {
                var raw: UInt32 = 0
                _ = withUnsafeMutableBytes(of: &raw) { destination in
                    data.copyBytes(to: destination, from: offset..<(offset + 4))
                }
                let bits = UInt32(littleEndian: raw)
                vector.append(Float(bitPattern: bits))
                offset += 4
            }
            embeddings.append(vector)
        }

        guard offset == data.count else {
            throw WaxError.decodingError(reason: "invalid embedding batch payload trailing bytes")
        }

        return embeddings
    }

    private func queryEmbedding(for query: String, policy: QueryEmbeddingPolicy) async throws -> [Float]? {
        switch policy {
        case .never:
            return nil
        case .ifAvailable:
            guard config.enableVectorSearch, let embedder else { return nil }
            return try await Self.embedOne(query, embedder: embedder, cache: embeddingCache)
        case .always:
            guard config.enableVectorSearch else {
                throw WaxError.io("query embedding requested but vector search is disabled")
            }
            guard let embedder else {
                throw WaxError.io("query embedding requested but no EmbeddingProvider configured")
            }
            return try await Self.embedOne(query, embedder: embedder, cache: embeddingCache)
        }
    }

    private static func embedOne(
        _ text: String,
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [Float] {
        let key = EmbeddingKey.make(
            text: text,
            identity: embedder.identity,
            dimensions: embedder.dimensions,
            normalized: embedder.normalize
        )
        if let cached = await cache?.get(key) {
            return cached
        }

        var vector = try await embedder.embed(text)
        if embedder.normalize {
            vector = normalizedL2(vector)
        }
        await cache?.set(key, value: vector)
        return vector
    }

    private static func prepareEmbeddings(
        chunks: [String],
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?
    ) async throws -> [Int: [Float]] {
        var out: [Int: [Float]] = [:]
        out.reserveCapacity(chunks.count)

        var missingTexts: [String] = []
        var missingIndices: [Int] = []
        missingTexts.reserveCapacity(chunks.count)
        missingIndices.reserveCapacity(chunks.count)

        for (idx, chunk) in chunks.enumerated() {
            let key = EmbeddingKey.make(
                text: chunk,
                identity: embedder.identity,
                dimensions: embedder.dimensions,
                normalized: embedder.normalize
            )
            if let cached = await cache?.get(key) {
                out[idx] = cached
            } else {
                missingTexts.append(chunk)
                missingIndices.append(idx)
            }
        }

        if missingTexts.isEmpty {
            return out
        }

        if let batch = embedder as? any BatchEmbeddingProvider {
            let vectors = try await batch.embed(batch: missingTexts)
            guard vectors.count == missingTexts.count else {
                throw WaxError.io("batch embedding count mismatch: expected \(missingTexts.count), got \(vectors.count)")
            }
            for (position, idx) in missingIndices.enumerated() {
                var vector = vectors[position]
                if embedder.normalize {
                    vector = normalizedL2(vector)
                }
                out[idx] = vector
                let key = EmbeddingKey.make(
                    text: chunks[idx],
                    identity: embedder.identity,
                    dimensions: embedder.dimensions,
                    normalized: embedder.normalize
                )
                await cache?.set(key, value: vector)
            }
        } else {
            for (position, idx) in missingIndices.enumerated() {
                let chunk = missingTexts[position]
                let vector = try await embedOne(chunk, embedder: embedder, cache: cache)
                out[idx] = vector
            }
        }

        return out
    }
}
