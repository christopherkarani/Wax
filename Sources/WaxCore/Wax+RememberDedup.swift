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

    package init(documentId: UInt64, isComplete: Bool) {
        self.documentId = documentId
        self.isComplete = isComplete
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
            struct ChunkCoverage {
                var count = 0
                var indices: Set<Int> = []
                var indicesAreValid = true
                var chunkCountsMatch = true
                var embeddingIdentityMatches = true

                mutating func record(
                    _ chunk: FrameMeta,
                    expectedChunkCount: Int,
                    embeddingIdentity: RememberDedupEmbeddingIdentity?
                ) {
                    count += 1
                    guard expectedChunkCount > 0 else { return }

                    guard let chunkCount = chunk.chunkCount, Int(chunkCount) == expectedChunkCount else {
                        chunkCountsMatch = false
                        return
                    }
                    guard let chunkIndex = chunk.chunkIndex else {
                        indicesAreValid = false
                        return
                    }

                    let index = Int(chunkIndex)
                    guard (0..<expectedChunkCount).contains(index) else {
                        indicesAreValid = false
                        return
                    }
                    guard indices.insert(index).inserted else {
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
                    guard count == expectedChunkCount else { return false }
                    guard indices.count == expectedChunkCount else { return false }
                    return indicesAreValid && chunkCountsMatch && embeddingIdentityMatches
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
                    coverage.record(
                        meta,
                        expectedChunkCount: expectedChunkCount,
                        embeddingIdentity: embeddingIdentity
                    )
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
                return RememberDedupProbe(
                    documentId: meta.id,
                    isComplete: coverage.isComplete(expectedChunkCount: expectedChunkCount)
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
