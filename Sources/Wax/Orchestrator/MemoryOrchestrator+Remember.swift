import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
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
    @discardableResult
    package func remember(_ content: String, metadata: [String: String] = [:]) async throws -> RememberResult {
        lastWriteActivityAt = .now
        let contentData = Data(content.utf8)
        let contentHash = ContentHasher.hash(contentData).hexString
        let chunks = await ingestChunks(for: content)
        let attached = readyEmbedderSnapshot
        let localEmbedder = attached

        let docMeta = rememberDocumentMetadata(metadata, contentHash: contentHash)
        let effectiveSessionId = docMeta.entries["session_id"]
        if let existingProbe = await wax.rememberDedupProbe(
            contentHash: contentHash,
            metadata: docMeta.entries,
            expectedChunkCount: chunks.count,
            embeddingIdentity: Self.rememberDedupEmbeddingIdentity(from: localEmbedder?.identity)
        ) {
            if existingProbe.isComplete {
                return RememberResult(
                    frameId: existingProbe.documentId,
                    framesAdded: 0,
                    deduplicated: true,
                    searchable: !chunks.isEmpty && (
                        config.enableTextSearch || (config.enableVectorSearch && localEmbedder != nil)
                    )
                )
            }
            // Single-chunk remember writes only the document. A matching
            // document is not complete unless it is actually searchable. A document stored as
            // one chunk under other chunk sizing keeps its own text.
            if let text = chunks.count == 1 ? chunks[0] : existingProbe.singleChunkText {
                try await ensureSingleChunkDocumentSearchable(
                    documentId: existingProbe.documentId,
                    text: text
                )
                return RememberResult(
                    frameId: existingProbe.documentId,
                    framesAdded: 0,
                    deduplicated: true,
                    searchable: true
                )
            }
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
            let frameId = try await localSession.put(
                contentData,
                options: FrameMetaSubset(
                    role: .document,
                    metadata: docMeta
                )
            )
            return RememberResult(
                frameId: frameId,
                framesAdded: 1,
                deduplicated: false,
                searchable: false
            )
        }

        if useVectorSearch, localEmbedder == nil {
            if requiresEmbedderForSave {
                throw WaxError.missingEmbedder
            }
            // Text-only save while waiting for the provider; the eventual attach
            // must report degraded instead of active.
            if case .loading = embedderLifecycle {
                embedderLifecycle = .loading(wroteTextOnly: true)
            }
        }

        if chunkCount == 1 {
            let chunk = chunks[0]
            var docOptions = FrameMetaSubset(
                role: .document,
                metadata: docMeta
            )
            docOptions.searchText = chunk

            let chunkEmbedding: [Float]?
            if useVectorSearch, let attached {
                chunkEmbedding = try await Self.embedOne(
                    chunk,
                    attached: attached,
                    cache: cache,
                    timeout: config.ingestEmbeddingTimeout
                )
            } else {
                chunkEmbedding = nil
            }

            if let chunkEmbedding {
                try await commitIfWalPressure(incomingBytes: Self.estimatedWalBytes(
                    searchTexts: [chunk],
                    metadata: docMeta.entries,
                    embeddingDimensions: chunkEmbedding.count
                ))
            }
            // Put without identity so doc metadata stays user keys + hash.
            // `put(..., identity:)` stamps wax.embedding.* and the rematch
            // probe uses exact metadata equality without those keys.
            let frameId = try await localSession.put(contentData, options: docOptions)
            if let chunkEmbedding {
                try await wax.putEmbedding(frameId: frameId, vector: chunkEmbedding)
                try await ensureMemoryBindingIfNeeded(bindingForEmbedderIdentity)
            }

            if config.enableTextSearch {
                try await localSession.indexText(frameId: frameId, text: chunk)
            }
            if let enrichmentPipeline {
                try await enrichmentPipeline.enqueue(
                    EnrichmentTask(frameId: frameId, text: chunk)
                )
            }
            return RememberResult(
                frameId: frameId,
                framesAdded: 1,
                deduplicated: false,
                searchable: config.enableTextSearch || chunkEmbedding != nil
            )
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

                    if let attached, useVectorSearch {
                        let embeddings = try await Self.prepareEmbeddingsBatchOptimized(
                            chunks: batchChunks,
                            attached: attached,
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
        let writeVectors = useVectorSearch && localEmbedder != nil
        if writeVectors, preparedEmbeddingsByBatch.count != batchRanges.count {
            throw WaxError.io(
                "ingest batching incomplete: expected \(batchRanges.count) prepared embedding batches, got \(preparedEmbeddingsByBatch.count)"
            )
        }
        if writeVectors {
            try await commitIfWalPressure(incomingBytes: Self.estimatedWalBytes(
                searchTexts: [nil],
                metadata: docMeta.entries,
                embeddingDimensions: nil
            ))
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

            if writeVectors {
                guard let embeddings = preparedEmbeddingsByBatch[entry.index] else {
                    throw WaxError.io("missing prepared embeddings for batch \(entry.index)")
                }
                try await commitIfWalPressure(incomingBytes: Self.estimatedWalBytes(
                    searchTexts: batchChunks,
                    metadata: metadata,
                    embeddingDimensions: embeddings.first?.count
                ))
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
        return RememberResult(
            frameId: docId,
            framesAdded: UInt64(chunkCount + 1),
            deduplicated: false,
            searchable: config.enableTextSearch || writeVectors
        )
    }

    /// Internal only for tests.
    func ingestChunks(for content: String) async -> [String] {
        let strategy = config.chunking
        let fitsMiniLMInput = config.fitsChunksToMiniLMInput
        // Tokenizing never suspends and grows with the text: a long remember held a
        // cooperative thread for hundreds of milliseconds.
        return await BlockingWork.runAsync {
            let chunks = await TextChunker.chunk(text: content, strategy: strategy)
            guard fitsMiniLMInput else { return chunks }
            return await MiniLMChunkSizing.fit(chunks)
        }
    }

    /// Document metadata a remember writes: the caller's keys, the content hash and the
    /// current session unless the caller set one. Internal only because of the file split.
    func rememberDocumentMetadata(_ metadata: [String: String], contentHash: String) -> Metadata {
        var docMeta = Metadata(metadata)
        docMeta.entries[Self.contentHashMetadataKey] = contentHash
        if docMeta.entries["session_id"] == nil, let session = currentSessionId {
            docMeta.entries["session_id"] = session.uuidString
        }
        return docMeta
    }

    /// Internal only because of the file split.
    static func rememberDedupEmbeddingIdentity(
        from identity: EmbeddingIdentity?
    ) -> RememberDedupEmbeddingIdentity? {
        guard let identity else { return nil }
        return RememberDedupEmbeddingIdentity(
            provider: identity.provider,
            model: identity.model,
            dimensions: identity.dimensions,
            normalized: identity.normalized,
            supersededModels: MemoryBindingCompatibility.supersededModelNames(for: identity)
        )
    }

    /// What making an existing single-chunk document searchable takes: indexing its text,
    /// embedding it, both or neither. Internal only because of the file split.
    func singleChunkDocumentRepair(
        documentId: UInt64,
        text: String
    ) async -> (indexText: Bool, embed: Bool) {
        if await isSingleChunkDocumentSearchable(documentId: documentId, expectedText: text) {
            return (false, false)
        }
        let indexText = config.enableTextSearch
            ? !(await documentIsInTextIndex(documentId: documentId, text: text))
            : false
        let embed = config.enableVectorSearch
            ? !(await documentHasEmbedding(frameId: documentId))
            : false
        return (indexText, embed)
    }

    /// Re-index / re-embed an existing single-chunk document in place (0 new frames).
    /// `searchText` cannot be patched on a written frame; FTS and embeddings can.
    private func ensureSingleChunkDocumentSearchable(
        documentId: UInt64,
        text: String
    ) async throws {
        let repair = await singleChunkDocumentRepair(documentId: documentId, text: text)

        if repair.indexText {
            try await session.indexText(frameId: documentId, text: text)
        }

        if repair.embed {
            guard let attached = readyEmbedderSnapshot else {
                throw WaxError.missingEmbedder
            }
            let localEmbedder = attached
            let embedding = try await Self.embedOne(
                text,
                attached: attached,
                cache: embeddingCache,
                timeout: config.ingestEmbeddingTimeout
            )
            try await wax.putEmbedding(frameId: documentId, vector: embedding)
            if let identity = localEmbedder.identity {
                try await ensureMemoryBindingIfNeeded(
                    MemoryBindingCompatibility.binding(from: identity)
                )
            }
        }
    }

    private func isSingleChunkDocumentSearchable(
        documentId: UInt64,
        expectedText: String
    ) async -> Bool {
        let meta: FrameMeta
        do {
            meta = try await wax.frameMetaIncludingPending(frameId: documentId)
        } catch {
            return false
        }
        let searchText = meta.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        guard !searchText.isEmpty else { return false }

        if config.enableTextSearch {
            let indexed = await documentIsInTextIndex(documentId: documentId, text: expectedText)
            guard indexed else { return false }
        }
        if config.enableVectorSearch {
            let embedded = await documentHasEmbedding(frameId: documentId)
            guard embedded else { return false }
        }
        return true
    }

    private func documentIsInTextIndex(documentId: UInt64, text: String) async -> Bool {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return false }
        do {
            let hits = try await session.searchText(query: query, topK: 64)
            return hits.contains { $0.frameId == documentId }
        } catch {
            return false
        }
    }

    private func documentHasEmbedding(frameId: UInt64) async -> Bool {
        do {
            return try await embeddedFrameIds().contains(frameId)
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "single-document vector coverage check",
                fallback: "re-embed this document"
            )
            return false
        }
    }

    /// Internal only because of the file split.
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
                kind: FrameKind.other("enrichment").storageValue,
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

    /// Optimized batch embedding preparation with cache-aware batching.
    /// Minimizes cache lookups and maximizes batch embedding efficiency.
    /// Internal only because of the file split.
    static func prepareEmbeddingsBatchOptimized(
        chunks: [String],
        attached: any EmbeddingProvider,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil
    ) async throws -> [[Float]] {
#if DEBUG
        Self._recordBatchPreparationPathCallForTests()
#endif
        let embedder = attached
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

        if !missingTexts.isEmpty {
            let vectors: [[Float]]
            let textsToEmbed = missingTexts // let-bind for @Sendable capture

            if let timeout {
                vectors = try await AsyncTimeout.run(timeout: timeout, operation: "batch ingest embed") {
                    try await embedder.embed(batch: textsToEmbed)
                }
            } else {
                vectors = try await embedder.embed(batch: textsToEmbed)
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
        attached: any EmbeddingProvider,
        cache: EmbeddingMemoizer?,
        timeout: Duration? = nil
    ) async throws -> [[Float]] {
        try await prepareEmbeddingsBatchOptimized(
            chunks: chunks,
            attached: attached,
            cache: cache,
            timeout: timeout
        )
    }

    func enrichmentStatsForTesting() async -> EnrichmentPipeline.Stats? {
        guard let enrichmentPipeline else { return nil }
        return await enrichmentPipeline.stats
    }
}
