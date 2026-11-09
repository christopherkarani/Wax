import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    /// Documents an import plans, embeds and writes at a time.
    static let importWindowSize = 1_024

    /// How many times an import flushes and retries when writes that were already in flight
    /// keep landing between its flush and the start of the import.
    private static let importOpenAttempts = 8

    /// A frame an import writes, before its embedding (if any) is known.
    private struct ImportFrame {
        let content: Data
        var options: FrameMetaSubset
        /// Text the frame is indexed under; `nil` for frames that are not searchable.
        let searchText: String?
        /// Whether the frame's text is embedded, and its vector identity stamped on it.
        let embedsWithIdentity: Bool
    }

    /// Everything an import adds, gathered across its windows.
    private struct ImportAdditions {
        /// Text of the new searchable frames: indexed at the commit, then enriched.
        var texts: [(frameId: UInt64, text: String)] = []
        /// Text of stored documents the import indexes because their index entry is missing.
        var repairTexts: [(frameId: UInt64, text: String)] = []
        var hasVectors = false
        var wroteTextOnly = false
    }

    /// What the dedup probe compares: content hash and metadata without the creation timestamp.
    private struct ImportKey: Hashable {
        let contentHash: String
        let metadata: [String: String]

        init(contentHash: String, docMeta: Metadata) {
            self.contentHash = contentHash
            var metadata = docMeta.entries
            metadata.removeValue(forKey: "wax.created_at_ms")
            self.metadata = metadata
        }
    }

    /// Writes `documents` as ``remember(batch:)`` would, but as one atomic commit outside the
    /// WAL: nothing is visible or durable until it returns, and on a throw the store is as it
    /// was. Flushes pending writes first. Flushes and other writes wait for it; reads do not.
    @discardableResult
    package func importDocuments(_ documents: [(text: String, metadata: [String: String])]) async throws -> [UInt64] {
        guard !documents.isEmpty else { return [] }
        return try await flushMutex.withLock { [self] in
            try await importDocumentsSerialized(documents)
        }
    }

    private func importDocumentsSerialized(
        _ documents: [(text: String, metadata: [String: String])]
    ) async throws -> [UInt64] {
        lastWriteActivityAt = .now
        try await openFrameImport()
        var additions = ImportAdditions()
        let ids: [UInt64]
        do {
            ids = try await writeImport(documents, additions: &additions)
            var binding: MemoryBinding?
            if additions.hasVectors, let embedder = readyEmbedderSnapshot {
                try await session.ensureVectorEngine(
                    dimensions: embedder.dimensions,
                    metric: VectorMetric(embedder.similarity)
                )
                // The binding is replaced only after every live frame is re-embedded.
                if supersededVectorsReason == nil {
                    binding = embedder.identity.map { MemoryBindingCompatibility.binding(from: $0) }
                }
            }
            try await session.commitFrameImport(
                texts: additions.repairTexts + additions.texts,
                hasVectors: additions.hasVectors,
                memoryBinding: binding
            )
            if let binding, !binding.isEmpty {
                markMemoryBindingEnsured()
            }
        } catch {
            await wax.abandonFrameImport()
            throw error
        }
        if additions.wroteTextOnly, case .loading = embedderLifecycle {
            embedderLifecycle = .loading(wroteTextOnly: true)
        }
        if let enrichmentPipeline {
            do {
                for item in additions.texts {
                    try await enrichmentPipeline.enqueue(EnrichmentTask(frameId: item.frameId, text: item.text))
                }
            } catch {
                // The import is committed; enrichment is best-effort metadata on top of it.
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "import enrichment enqueue",
                    fallback: "imported frames stay searchable without enrichment frames"
                )
            }
        }
        lastWriteActivityAt = .now
        return ids
    }

    /// Commits pending writes, then opens the store's frame import.
    private func openFrameImport() async throws {
        for _ in 0..<Self.importOpenAttempts {
            try await flushSerialized()
            if try await wax.beginFrameImport() { return }
        }
        throw WaxError.io("import could not start: writes kept landing after each flush")
    }

    /// Plans, embeds and writes the documents window by window into the open import, and
    /// returns one frame ID per document.
    private func writeImport(
        _ documents: [(text: String, metadata: [String: String])],
        additions: inout ImportAdditions
    ) async throws -> [UInt64] {
        let attached = readyEmbedderSnapshot
        let embedder = config.enableVectorSearch ? attached : nil
        var nextFrameId = await wax.stats().frameCount
        var seen: [ImportKey: UInt64] = [:]
        var ids: [UInt64] = []
        ids.reserveCapacity(documents.count)

        for start in stride(from: 0, to: documents.count, by: Self.importWindowSize) {
            let window = documents[start..<min(start + Self.importWindowSize, documents.count)]
            var frames: [ImportFrame] = []
            var repairEmbeddings: [(frameId: UInt64, text: String)] = []
            for document in window {
                let id = try await planImport(
                    document,
                    firstFrameId: nextFrameId + UInt64(frames.count),
                    attached: attached,
                    seen: &seen,
                    frames: &frames,
                    repairEmbeddings: &repairEmbeddings,
                    additions: &additions
                )
                ids.append(id)
            }
            try await writeImportWindow(
                frames,
                firstFrameId: nextFrameId,
                repairEmbeddings: repairEmbeddings,
                embedder: embedder,
                additions: &additions
            )
            nextFrameId += UInt64(frames.count)
        }
        return ids
    }

    /// Appends the frames `document` adds to `frames` (numbered from `firstFrameId`), and
    /// returns its frame ID: what ``remember(_:metadata:)`` would return for it now.
    private func planImport(
        _ document: (text: String, metadata: [String: String]),
        firstFrameId: UInt64,
        attached: (any EmbeddingProvider)?,
        seen: inout [ImportKey: UInt64],
        frames: inout [ImportFrame],
        repairEmbeddings: inout [(frameId: UInt64, text: String)],
        additions: inout ImportAdditions
    ) async throws -> UInt64 {
        let content = Data(document.text.utf8)
        let contentHash = ContentHasher.hash(content).hexString
        let docMeta = rememberDocumentMetadata(document.metadata, contentHash: contentHash)
        let key = ImportKey(contentHash: contentHash, docMeta: docMeta)
        if let earlier = seen[key] { return earlier }

        let chunks = await ingestChunks(for: document.text)
        if let existing = await wax.rememberDedupProbe(
            contentHash: contentHash,
            metadata: docMeta.entries,
            expectedChunkCount: chunks.count,
            embeddingIdentity: Self.rememberDedupEmbeddingIdentity(from: attached?.identity)
        ) {
            if existing.isComplete {
                seen[key] = existing.documentId
                return existing.documentId
            }
            if let text = chunks.count == 1 ? chunks[0] : existing.singleChunkText {
                let repair = await singleChunkDocumentRepair(documentId: existing.documentId, text: text)
                if repair.indexText {
                    additions.repairTexts.append((existing.documentId, text))
                }
                if repair.embed {
                    guard attached != nil else { throw WaxError.missingEmbedder }
                    repairEmbeddings.append((existing.documentId, text))
                }
                seen[key] = existing.documentId
                return existing.documentId
            }
        }

        seen[key] = firstFrameId
        guard !chunks.isEmpty else {
            frames.append(ImportFrame(
                content: content,
                options: FrameMetaSubset(role: .document, metadata: docMeta),
                searchText: nil,
                embedsWithIdentity: false
            ))
            return firstFrameId
        }
        if config.enableVectorSearch, attached == nil {
            if requiresEmbedderForSave {
                throw WaxError.missingEmbedder
            }
            additions.wroteTextOnly = true
        }
        if chunks.count == 1 {
            var options = FrameMetaSubset(role: .document, metadata: docMeta)
            options.searchText = chunks[0]
            frames.append(ImportFrame(content: content, options: options, searchText: chunks[0], embedsWithIdentity: false))
            return firstFrameId
        }

        frames.append(ImportFrame(
            content: content,
            options: FrameMetaSubset(role: .document, metadata: docMeta),
            searchText: nil,
            embedsWithIdentity: false
        ))
        let sessionId = docMeta.entries["session_id"]
        for (index, chunk) in chunks.enumerated() {
            var options = FrameMetaSubset()
            options.role = .chunk
            options.parentId = firstFrameId
            options.chunkIndex = UInt32(index)
            options.chunkCount = UInt32(chunks.count)
            options.searchText = chunk
            var chunkMeta = Metadata(document.metadata)
            if let sessionId {
                chunkMeta.entries["session_id"] = sessionId
            }
            options.metadata = chunkMeta
            frames.append(ImportFrame(content: Data(chunk.utf8), options: options, searchText: chunk, embedsWithIdentity: true))
        }
        return firstFrameId
    }

    /// Embeds a window's searchable frames (and the stored documents it repairs), then
    /// writes the frames and vectors into the open import.
    private func writeImportWindow(
        _ frames: [ImportFrame],
        firstFrameId: UInt64,
        repairEmbeddings: [(frameId: UInt64, text: String)],
        embedder: (any EmbeddingProvider)?,
        additions: inout ImportAdditions
    ) async throws {
        var embedFrameIds: [UInt64] = []
        var embedTexts: [String] = []
        for (offset, frame) in frames.enumerated() {
            guard let text = frame.searchText else { continue }
            let frameId = firstFrameId + UInt64(offset)
            additions.texts.append((frameId, text))
            embedFrameIds.append(frameId)
            embedTexts.append(text)
        }
        embedFrameIds += repairEmbeddings.map(\.frameId)
        embedTexts += repairEmbeddings.map(\.text)

        var vectors: [[Float]] = []
        if let embedder, !embedTexts.isEmpty {
            vectors.reserveCapacity(embedTexts.count)
            let batchSize = max(1, config.ingestBatchSize)
            for start in stride(from: 0, to: embedTexts.count, by: batchSize) {
                vectors += try await Self.prepareEmbeddingsBatchOptimized(
                    chunks: Array(embedTexts[start..<min(start + batchSize, embedTexts.count)]),
                    attached: embedder,
                    cache: embeddingCache,
                    timeout: config.ingestEmbeddingTimeout
                )
            }
        }
        let vectorByFrameId: [UInt64: [Float]] = vectors.isEmpty
            ? [:]
            : Dictionary(zip(embedFrameIds, vectors), uniquingKeysWith: { (first: [Float], _: [Float]) -> [Float] in first })

        var options: [FrameMetaSubset] = []
        options.reserveCapacity(frames.count)
        for (offset, frame) in frames.enumerated() {
            guard frame.embedsWithIdentity,
                  let identity = embedder?.identity,
                  let vector = vectorByFrameId[firstFrameId + UInt64(offset)] else {
                options.append(frame.options)
                continue
            }
            options.append(try WaxSession.mergeOptions(frame.options, identity: identity, embeddingCount: vector.count))
        }
        let written = try await wax.importFrames(frames.map(\.content), options: options)
        guard written == (0..<frames.count).map({ firstFrameId + UInt64($0) }) else {
            throw WaxError.io("import wrote frames \(written.first.map(String.init) ?? "none")... but planned them from \(firstFrameId)")
        }
        if !vectors.isEmpty {
            try await wax.importEmbeddings(frameIds: embedFrameIds, vectors: vectors)
            additions.hasVectors = true
        }
    }
}
