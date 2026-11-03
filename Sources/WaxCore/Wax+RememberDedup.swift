import Foundation

package struct RememberDedupEmbeddingIdentity: Equatable, Sendable {
    package var provider: String?
    package var model: String?
    package var dimensions: Int?
    package var normalized: Bool?
    /// Trimmed, lowercased model names whose chunks also count as a match: revisions that
    /// `model` supersedes. Chunk metadata is immutable, so chunks written before a re-embed
    /// keep the old model name even after their vectors are replaced.
    package var supersededModels: Set<String>

    package init(
        provider: String? = nil,
        model: String? = nil,
        dimensions: Int? = nil,
        normalized: Bool? = nil,
        supersededModels: Set<String> = []
    ) {
        self.provider = provider
        self.model = model
        self.dimensions = dimensions
        self.normalized = normalized
        self.supersededModels = supersededModels
    }

    fileprivate func matches(metadataEntries: [String: String]) -> Bool {
        if let provider, metadataEntries["wax.embedding.provider"] != provider {
            return false
        }
        if let model, metadataEntries["wax.embedding.model"] != model {
            let recorded = metadataEntries["wax.embedding.model"]?
                .trimmingCharacters(in: .whitespacesAndNewlines)
                .lowercased()
            guard let recorded, supersededModels.contains(recorded) else { return false }
        }
        if let dimensions, metadataEntries["wax.embedding.dimension"] != String(dimensions) {
            return false
        }
        if let normalized, metadataEntries["wax.embedding.normalized"] != String(normalized) {
            return false
        }
        return true
    }
}

package struct RememberDedupProbe: Equatable, Sendable {
    package var documentId: UInt64
    package var isComplete: Bool
    /// The indexed text of a document stored as a single chunk (no chunk frames), whatever the
    /// current chunking would cut the content into.
    package var singleChunkText: String?

    package init(documentId: UInt64, isComplete: Bool, singleChunkText: String? = nil) {
        self.documentId = documentId
        self.isComplete = isComplete
        self.singleChunkText = singleChunkText
    }
}

extension Wax {
    package func rememberDedupProbe(
        contentHash: String,
        metadata: [String: String],
        expectedChunkCount: Int,
        embeddingIdentity: RememberDedupEmbeddingIdentity?
    ) async -> RememberDedupProbe? {
        await withReadLock {
            /// A document is complete by its own record: every chunk agrees on one chunk count and
            /// all of them are present. The current chunking may cut the content differently
            /// (MiniLM's smaller target), which must not turn a stored document into a duplicate.
            struct ChunkCoverage {
                var count = 0
                var indices: Set<Int> = []
                var recordedChunkCounts: Set<Int> = []
                var indicesAreValid = true
                var embeddingIdentityMatches = true

                mutating func record(
                    _ chunk: FrameMeta,
                    embeddingIdentity: RememberDedupEmbeddingIdentity?
                ) {
                    count += 1
                    guard let chunkCount = chunk.chunkCount, let chunkIndex = chunk.chunkIndex else {
                        indicesAreValid = false
                        return
                    }
                    recordedChunkCounts.insert(Int(chunkCount))
                    guard indices.insert(Int(chunkIndex)).inserted else {
                        indicesAreValid = false
                        return
                    }

                    if let embeddingIdentity,
                       embeddingIdentity.matches(metadataEntries: chunk.metadata?.entries ?? [:]) == false {
                        embeddingIdentityMatches = false
                    }
                }

                func isComplete(expectedChunkCount: Int) -> Bool {
                    guard expectedChunkCount > 0 else { return true }
                    guard indicesAreValid, embeddingIdentityMatches,
                          recordedChunkCounts.count == 1,
                          let recorded = recordedChunkCounts.first, recorded > 0 else { return false }
                    return count == recorded && indices == Set(0..<recorded)
                }
            }

            var chunkCoverageByDocument: [UInt64: ChunkCoverage] = [:]

            let orderedPending = orderedPendingMutationsLocked()
            let cappedPendingPuts = min(
                pendingMutationSummary.putFrameCount,
                UInt64(pendingMutations.count)
            )
            let pendingPutCapacity = Int(cappedPendingPuts)
            var pendingPutMetas: [UInt64: FrameMeta] = [:]
            pendingPutMetas.reserveCapacity(pendingPutCapacity)
            var pendingPutIds: [UInt64] = []
            pendingPutIds.reserveCapacity(pendingPutCapacity)
            var pendingDeleted = Set<UInt64>()
            var pendingSupersededBy: [UInt64: UInt64] = [:]
            var pendingSupersedes: [UInt64: UInt64] = [:]

            for mutation in orderedPending {
                switch mutation.entry {
                case .putFrame(let put):
                    guard let meta = try? FrameMeta.fromPut(put) else { continue }
                    pendingPutMetas[meta.id] = meta
                    pendingPutIds.append(meta.id)
                case .deleteFrame(let delete):
                    pendingDeleted.insert(delete.frameId)
                case .supersedeFrame(let supersede):
                    pendingSupersededBy[supersede.supersededId] = supersede.supersedingId
                    pendingSupersedes[supersede.supersedingId] = supersede.supersededId
                case .putEmbedding:
                    continue
                }
            }

            func pendingVisibleMeta(_ meta: FrameMeta) -> FrameMeta {
                var visible = meta
                if pendingDeleted.contains(meta.id) {
                    visible.status = .deleted
                }
                if let supersededBy = pendingSupersededBy[meta.id] {
                    visible.supersededBy = supersededBy
                }
                if let supersedes = pendingSupersedes[meta.id] {
                    visible.supersedes = supersedes
                }
                return visible
            }

            func visit(_ meta: FrameMeta) -> RememberDedupProbe? {
                guard meta.status == .active, meta.supersededBy == nil else { return nil }

                if meta.role == .chunk, let parentId = meta.parentId {
                    var coverage = chunkCoverageByDocument[parentId] ?? ChunkCoverage()
                    coverage.record(meta, embeddingIdentity: embeddingIdentity)
                    chunkCoverageByDocument[parentId] = coverage
                    return nil
                }

                guard meta.role == .document else { return nil }
                guard let entries = meta.metadata?.entries else { return nil }
                guard entries["wax.content.hash"] == contentHash else { return nil }
                var storedIdentity = entries
                var requestedIdentity = metadata
                storedIdentity.removeValue(forKey: "wax.created_at_ms")
                requestedIdentity.removeValue(forKey: "wax.created_at_ms")
                guard storedIdentity == requestedIdentity else { return nil }

                let coverage = chunkCoverageByDocument[meta.id] ?? ChunkCoverage()
                // Only single-chunk remembers put searchText on the document itself.
                let ownText = meta.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return RememberDedupProbe(
                    documentId: meta.id,
                    isComplete: coverage.isComplete(expectedChunkCount: expectedChunkCount),
                    singleChunkText: coverage.count == 0 && !ownText.isEmpty ? meta.searchText : nil
                )
            }

            for frameId in pendingPutIds.reversed() {
                guard let meta = pendingPutMetas[frameId] else { continue }
                if let probe = visit(pendingVisibleMeta(meta)) {
                    return probe
                }
            }

            for meta in toc.frames.reversed() {
                if let probe = visit(pendingVisibleMeta(meta)) {
                    return probe
                }
            }

            return nil
        }
    }
}
