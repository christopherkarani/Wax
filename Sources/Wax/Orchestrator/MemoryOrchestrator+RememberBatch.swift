import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// A batch document that is new and fits in one chunk: written by ``remember(batch:)``
    /// with batched embedding and frame writes instead of a ``remember(_:metadata:)`` call.
    private struct SimpleRemember {
        let content: Data
        let chunk: String
        let docMeta: Metadata
    }

    /// What the remember dedup probe compares: content hash and metadata without the
    /// creation timestamp.
    private struct RememberBatchKey: Hashable {
        let contentHash: String
        let metadata: [String: String]

        init(contentHash: String, docMeta: Metadata) {
            self.contentHash = contentHash
            var metadata = docMeta.entries
            metadata.removeValue(forKey: "wax.created_at_ms")
            self.metadata = metadata
        }
    }

    /// Remembers each document in order and returns one frame ID per document: what
    /// ``remember(_:metadata:)`` would return for each in turn.
    ///
    /// Runs of new single-chunk documents are embedded and written in batches. Every other
    /// document (empty, multi-chunk, already stored, or repeated in the batch) goes through
    /// ``remember(_:metadata:)`` after the run before it is written, so it sees that run.
    ///
    /// - Important: Not atomic. On a throw, earlier documents may already be saved.
    @discardableResult
    package func remember(batch documents: [(text: String, metadata: [String: String])]) async throws -> [UInt64] {
        lastWriteActivityAt = .now
        var ids: [UInt64] = []
        ids.reserveCapacity(documents.count)
        var run: [SimpleRemember] = []
        var seen: Set<RememberBatchKey> = []

        for document in documents {
            if let simple = await simpleRemember(document.text, metadata: document.metadata, seen: &seen) {
                run.append(simple)
                continue
            }
            ids += try await rememberSimpleRun(run)
            run.removeAll(keepingCapacity: true)
            ids.append(try await remember(document.text, metadata: document.metadata).frameId)
        }
        ids += try await rememberSimpleRun(run)
        lastWriteActivityAt = .now
        return ids
    }

    /// The document as a ``SimpleRemember`` when it is one chunk, not stored yet and not a
    /// repeat of an earlier batch document; otherwise `nil`.
    private func simpleRemember(
        _ text: String,
        metadata: [String: String],
        seen: inout Set<RememberBatchKey>
    ) async -> SimpleRemember? {
        let content = Data(text.utf8)
        let contentHash = ContentHasher.hash(content).hexString
        let docMeta = rememberDocumentMetadata(metadata, contentHash: contentHash)
        guard seen.insert(RememberBatchKey(contentHash: contentHash, docMeta: docMeta)).inserted else {
            return nil
        }
        let chunks = await ingestChunks(for: text)
        guard chunks.count == 1 else { return nil }
        let existing = await wax.rememberDedupProbe(
            contentHash: contentHash,
            metadata: docMeta.entries,
            expectedChunkCount: 1,
            embeddingIdentity: Self.rememberDedupEmbeddingIdentity(from: readyEmbedderSnapshot?.identity)
        )
        guard existing == nil else { return nil }
        return SimpleRemember(content: content, chunk: chunks[0], docMeta: docMeta)
    }

    /// Embeds and writes a run of new single-chunk documents, as ``remember(_:metadata:)``
    /// would one by one.
    private func rememberSimpleRun(_ run: [SimpleRemember]) async throws -> [UInt64] {
        guard !run.isEmpty else { return [] }
        let attached = readyEmbedderSnapshot
        let useVectorSearch = config.enableVectorSearch
        if useVectorSearch, attached == nil {
            if requiresEmbedderForSave {
                throw WaxError.missingEmbedder
            }
            // Text-only save while waiting for the provider; the eventual attach
            // must report degraded instead of active.
            if case .loading = embedderLifecycle {
                embedderLifecycle = .loading(wroteTextOnly: true)
            }
        }
        let embedder = useVectorSearch ? attached : nil
        let binding = attached?.identity.map { MemoryBindingCompatibility.binding(from: $0) }
        let walBudget = await wax.walStats().walSize / 2
        let embedBatchSize = max(1, config.ingestBatchSize)

        var ids: [UInt64] = []
        ids.reserveCapacity(run.count)
        for start in stride(from: 0, to: run.count, by: embedBatchSize) {
            let group = run[start..<min(start + embedBatchSize, run.count)]
            let embeddings: [[Float]]? = if let embedder {
                try await Self.prepareEmbeddingsBatchOptimized(
                    chunks: group.map(\.chunk),
                    attached: embedder,
                    cache: embeddingCache,
                    timeout: config.ingestEmbeddingTimeout
                )
            } else {
                nil
            }
            let itemBytes = group.enumerated().map { offset, item in
                Self.estimatedWalBytes(
                    searchTexts: [item.chunk],
                    metadata: item.docMeta.entries,
                    embeddingDimensions: embeddings?[offset].count
                )
            }
            for range in Self.walBudgetRanges(itemBytes: itemBytes, budget: walBudget) {
                ids += try await writeSimpleRemembers(
                    Array(group[(group.startIndex + range.lowerBound)..<(group.startIndex + range.upperBound)]),
                    embeddings: embeddings.map { Array($0[range]) },
                    walBytes: itemBytes[range].reduce(0, +),
                    binding: binding
                )
            }
        }
        return ids
    }

    /// Writes one WAL-sized sub-batch: document frames, then vectors, text index and
    /// enrichment, in the order ``remember(_:metadata:)`` writes a single-chunk document.
    private func writeSimpleRemembers(
        _ items: [SimpleRemember],
        embeddings: [[Float]]?,
        walBytes: UInt64,
        binding: MemoryBinding?
    ) async throws -> [UInt64] {
        if embeddings != nil {
            try await commitIfWalPressure(incomingBytes: walBytes)
        }
        // Put without identity so doc metadata stays user keys + hash, which the
        // remember dedup probe compares exactly.
        let options = items.map { item in
            var option = FrameMetaSubset(role: .document, metadata: item.docMeta)
            option.searchText = item.chunk
            return option
        }
        let frameIds = try await session.putBatch(contents: items.map(\.content), options: options)
        if let embeddings {
            try await wax.putEmbeddingBatch(frameIds: frameIds, vectors: embeddings)
            try await ensureMemoryBindingIfNeeded(binding)
        }
        let texts = items.map(\.chunk)
        if config.enableTextSearch {
            try await session.indexTextBatch(frameIds: frameIds, texts: texts)
        }
        if let enrichmentPipeline {
            for (frameId, text) in zip(frameIds, texts) {
                try await enrichmentPipeline.enqueue(EnrichmentTask(frameId: frameId, text: text))
            }
        }
        return frameIds
    }

    /// Splits consecutive items into ranges whose estimated WAL bytes stay within `budget`;
    /// an item larger than the budget gets a range of its own. Internal for tests.
    static func walBudgetRanges(itemBytes: [UInt64], budget: UInt64) -> [Range<Int>] {
        var ranges: [Range<Int>] = []
        var start = 0
        var total: UInt64 = 0
        for (index, bytes) in itemBytes.enumerated() {
            if index > start, total + bytes > budget {
                ranges.append(start..<index)
                start = index
                total = 0
            }
            total += bytes
        }
        if start < itemBytes.count {
            ranges.append(start..<itemBytes.count)
        }
        return ranges
    }
}
