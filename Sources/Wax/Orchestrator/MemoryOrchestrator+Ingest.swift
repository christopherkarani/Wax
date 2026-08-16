import Foundation
import WaxCore
import WaxVectorSearch

package extension MemoryOrchestrator {
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
    package func remember(_ content: String, metadata: [String: String] = [:]) async throws {
        lastWriteActivityAt = .now
        let contentData = Data(content.utf8)
        let contentHash = ContentHasher.hash(contentData).hexString
        let chunks = await TextChunker.chunk(text: content, strategy: config.chunking)
        let localEmbedder = embedder

        var docMeta = Metadata(metadata)
        docMeta.entries[Self.contentHashMetadataKey] = contentHash
        if docMeta.entries["session_id"] == nil, let session = currentSessionId {
            docMeta.entries["session_id"] = session.uuidString
        }
        let effectiveSessionId = docMeta.entries["session_id"]
        if let existingProbe = await wax.rememberDedupProbe(
            contentHash: contentHash,
            metadata: docMeta.entries,
            expectedChunkCount: chunks.count,
            embeddingIdentity: Self.rememberDedupEmbeddingIdentity(from: localEmbedder?.identity)
        ), existingProbe.isComplete {
            return
        }

        let chunkCount = chunks.count
        let localSession = session
        let cache = embeddingCache
        let batchSize = max(1, config.ingestBatchSize)
        let useVectorSearch = config.enableVectorSearch
        let bindingForEmbedderIdentity: MemoryBinding?
        if let identity = localEmbedder?.identity {
            bindingForEmbedderIdentity = MemoryBindingCompatibility.binding(from: identity)
        } else {
            bindingForEmbedderIdentity = nil
        }

        guard !chunks.isEmpty else {
            _ = try await localSession.put(
                contentData,
                options: FrameMetaSubset(
                    role: .document,
                    metadata: docMeta
                )
            )
            return
        }

        if useVectorSearch, localEmbedder == nil {
            throw WaxError.missingEmbedder
        }

        if chunkCount == 1 {
            let chunk = chunks[0]
            let chunkData = Data(chunk.utf8)

            var chunkMeta = Metadata(metadata)
            if let effectiveSessionId {
                chunkMeta.entries["session_id"] = effectiveSessionId
            }

            let chunkEmbedding: [Float]?
            if useVectorSearch {
                guard let localEmbedder else {
                    throw WaxError.missingEmbedder
                }
                chunkEmbedding = try await Self.embedOne(
                    chunk,
                    embedder: localEmbedder,
                    cache: cache,
                    timeout: config.ingestEmbeddingTimeout
                )
            } else {
                chunkEmbedding = nil
            }

            let docId = try await localSession.put(
                contentData,
                options: FrameMetaSubset(
                    role: .document,
                    metadata: docMeta
                )
            )

            var option = FrameMetaSubset()
            option.role = .chunk
            option.parentId = docId
            option.chunkIndex = 0
            option.chunkCount = 1
            option.searchText = chunk
            option.metadata = chunkMeta

            if let chunkEmbedding {
                guard let localEmbedder else {
                    throw WaxError.missingEmbedder
                }
                let frameId = try await localSession.put(
                    chunkData,
                    embedding: chunkEmbedding,
                    identity: localEmbedder.identity,
                    options: option
                )
                try await ensureMemoryBindingIfNeeded(bindingForEmbedderIdentity)
                if config.enableTextSearch {
                    try await localSession.indexText(frameId: frameId, text: chunk)
                }
                if let enrichmentPipeline {
                    try await enrichmentPipeline.enqueue(
                        EnrichmentTask(frameId: frameId, text: chunk)
                    )
                }
            } else {
                let frameId = try await localSession.put(chunkData, options: option)
                if config.enableTextSearch {
                    try await localSession.indexText(frameId: frameId, text: chunk)
                }
                if let enrichmentPipeline {
                    try await enrichmentPipeline.enqueue(
                        EnrichmentTask(frameId: frameId, text: chunk)
                    )
                }
            }
            return
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
        let ingestTimeout = config.ingestEmbeddingTimeout

        var preparedEmbeddingsByBatch: [Int: [[Float]]] = [:]
        preparedEmbeddingsByBatch.reserveCapacity(batchRanges.count)
        var preparedBatchCount = 0

        try await withThrowingTaskGroup(of: IngestBatchResult.self) { group in
            func enqueue(_ entry: (index: Int, range: Range<Int>)) {
                group.addTask {
                    let batchChunks = Array(chunks[entry.range])

                    if let localEmbedder = localEmbedder, useVectorSearch {
                        let embeddings = try await Self.prepareEmbeddingsBatchOptimized(
                            chunks: batchChunks,
                            embedder: localEmbedder,
                            cache: cache,
                            timeout: ingestTimeout
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
                    preparedEmbeddingsByBatch[result.index] = embeddings
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
        if useVectorSearch, preparedEmbeddingsByBatch.count != batchRanges.count {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) prepared embedding batches, got \(preparedEmbeddingsByBatch.count)"
            )
        }
        let docId = try await localSession.put(
            contentData,
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
                if let effectiveSessionId {
                    chunkMeta.entries["session_id"] = effectiveSessionId
                }
                option.metadata = chunkMeta
                options.append(option)
            }

            if useVectorSearch {
                guard let embeddings = preparedEmbeddingsByBatch[entry.index] else {
                    throw WaxError.io("missing prepared embeddings for batch \(entry.index)")
                }
                let frameIds = try await localSession.putBatch(
                    contents: batchContents,
                    embeddings: embeddings,
                    identity: localEmbedder?.identity,
                    options: options
                )
                try await ensureMemoryBindingIfNeeded(bindingForEmbedderIdentity)

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
                if let enrichmentPipeline {
                    for (offset, frameId) in frameIds.enumerated() {
                        try await enrichmentPipeline.enqueue(
                            EnrichmentTask(frameId: frameId, text: batchChunks[offset])
                        )
                    }
                }
            } else {
                let frameIds = try await localSession.putBatch(contents: batchContents, options: options)

                if config.enableTextSearch {
                    try await localSession.indexTextBatch(frameIds: frameIds, texts: batchChunks)
                }
                if let enrichmentPipeline {
                    for (offset, frameId) in frameIds.enumerated() {
                        try await enrichmentPipeline.enqueue(
                            EnrichmentTask(frameId: frameId, text: batchChunks[offset])
                        )
                    }
                }
            }
        }
    }

    private static func rememberDedupEmbeddingIdentity(
        from identity: EmbeddingIdentity?
    ) -> RememberDedupEmbeddingIdentity? {
        guard let identity else { return nil }
        return RememberDedupEmbeddingIdentity(
            provider: identity.provider,
            model: identity.model,
            dimensions: identity.dimensions,
            normalized: identity.normalized
        )
    }

    static func persistEnrichmentResult(
        _ result: EnrichmentResult,
        in session: WaxSession
    ) async throws {
        guard !result.keywords.isEmpty || !result.entities.isEmpty else {
            return
        }

        var metadata = Metadata()
        metadata.entries["wax.enrichment.source_frame_id"] = String(result.frameId)
        if !result.keywords.isEmpty {
            metadata.entries["wax.enrichment.keywords"] = result.keywords.joined(separator: ",")
        }
        if !result.entities.isEmpty {
            metadata.entries["wax.enrichment.entities"] = result.entities
                .map { "\($0.subject)|\($0.predicate)|\($0.object)" }
                .joined(separator: "\n")
        }

        _ = try await session.put(
            Data(renderEnrichmentResult(result).utf8),
            options: FrameMetaSubset(
                kind: "enrichment",
                role: .system,
                parentId: result.frameId,
                searchText: result.keywords.joined(separator: " "),
                metadata: metadata
            )
        )
    }

    private static func renderEnrichmentResult(_ result: EnrichmentResult) -> String {
        var lines: [String] = []
        if !result.keywords.isEmpty {
            lines.append("keywords: \(result.keywords.joined(separator: ", "))")
        }
        if !result.entities.isEmpty {
            lines.append("entities:")
            lines.append(contentsOf: result.entities.map { "- \($0.subject) \($0.predicate) \($0.object)" })
        }
        return lines.joined(separator: "\n")
    }

    private func ensureMemoryBindingIfNeeded(_ binding: MemoryBinding?) async throws {
        guard let binding, !binding.isEmpty, !hasEnsuredMemoryBinding else { return }
        hasEnsuredMemoryBinding = true
#if DEBUG
        Self._recordMemoryBindingEnsureCallForTests()
#endif
        do {
            try await wax.setMemoryBindingIfMissing(binding)
        } catch {
            hasEnsuredMemoryBinding = false
            throw error
        }
    }

    /// Optimized batch embedding preparation with cache-aware batching.
    /// Minimizes cache lookups and maximizes batch embedding efficiency.
    private static func prepareEmbeddingsBatchOptimized(
        chunks: [String],
        embedder: some EmbeddingProvider,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil
    ) async throws -> [[Float]] {
#if DEBUG
        Self._recordBatchPreparationPathCallForTests()
#endif
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
            let textsToEmbed = missingTexts // let-bind for @Sendable capture

            // Prefer batch embedding for significantly better throughput
            if let batchEmbedder = embedder as? any BatchEmbeddingProvider {
                if let timeout {
                    vectors = try await AsyncTimeout.run(timeout: timeout, operation: "batch ingest embed") {
                        try await batchEmbedder.embed(batch: textsToEmbed)
                    }
                } else {
                    vectors = try await batchEmbedder.embed(batch: textsToEmbed)
                }
            } else {
                var sequentialVectors: [[Float]] = []
                sequentialVectors.reserveCapacity(textsToEmbed.count)
                for text in textsToEmbed {
                    let vector: [Float]
                    if let timeout {
                        let textCopy = text
                        vector = try await AsyncTimeout.run(timeout: timeout, operation: "ingest embed") {
                            try await embedder.embed(textCopy)
                        }
                    } else {
                        vector = try await embedder.embed(text)
                    }
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
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil
    ) async throws -> [[Float]] {
        try await prepareEmbeddingsBatchOptimized(chunks: chunks, embedder: embedder, cache: cache, timeout: timeout)
    }

}
