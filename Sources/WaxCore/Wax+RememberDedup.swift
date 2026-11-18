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
    /// Frames the remember dedup probe has examined since this handle opened.
    package func rememberDedupFramesExaminedForTesting() async -> UInt64 {
        await withReadLock { rememberDedupFramesExamined }
    }

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

            if rememberDedupIndex == nil {
                rememberDedupIndex = RememberDedupIndex(
                    committedFrames: toc.frames,
                    orderedPendingMutations: orderedPendingMutationsLocked()
                )
            }
            guard let index = rememberDedupIndex else { return nil }
            let committedFrames = toc.frames
            var examined: UInt64 = 0
            defer { rememberDedupFramesExamined &+= examined }

            var requestedIdentity = metadata
            requestedIdentity.removeValue(forKey: "wax.created_at_ms")

            // Newest first, like a scan from the end of the frame list: the newest live
            // document with this content and metadata wins.
            for documentId in index.documentIds(contentHash: contentHash) {
                examined += 1
                guard let document = index.liveFrame(documentId, committedFrames: committedFrames),
                      let entries = document.metadata?.entries,
                      entries[RememberDedupIndex.contentHashKey] == contentHash else { continue }
                var storedIdentity = entries
                storedIdentity.removeValue(forKey: "wax.created_at_ms")
                guard storedIdentity == requestedIdentity else { continue }

                // Chunks are written after their document, so only newer frames count.
                var coverage = ChunkCoverage()
                for chunkId in index.chunkIds(parentId: documentId) where chunkId > documentId {
                    examined += 1
                    guard let chunk = index.liveFrame(chunkId, committedFrames: committedFrames) else { continue }
                    coverage.record(chunk, embeddingIdentity: embeddingIdentity)
                }
                // Only single-chunk remembers put searchText on the document itself.
                let ownText = document.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                return RememberDedupProbe(
                    documentId: documentId,
                    isComplete: coverage.isComplete(expectedChunkCount: expectedChunkCount),
                    singleChunkText: coverage.count == 0 && !ownText.isEmpty ? document.searchText : nil
                )
            }
            return nil
        }
    }
}
