#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WaxCore
import WaxVectorSearch
import os

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Photos)
@preconcurrency import Photos
#endif

/// On-device (no cloud) retrieval-augmented generation (RAG) over videos.
///
/// `VideoRAGOrchestrator` ingests local videos (file URLs and optionally Photos videos offline-only),
/// computes segment keyframe embeddings, optionally indexes host-supplied transcripts, and serves
/// hybrid retrieval to assemble prompt-ready context.
package actor VideoRAGOrchestrator {
    static let photosVideoRequestTimeout: Duration = .seconds(10)
    static let scoreTieEpsilon: Float = 1e-3

    struct VideoSegmentTimeRange: Sendable, Equatable {
        var startMs: Int64
        var endMs: Int64

        init(startMs: Int64, endMs: Int64) {
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    enum MetaKey {
        static let source = VideoMetadataKey.source.rawValue
        static let sourceID = VideoMetadataKey.sourceID.rawValue
        static let fileURL = VideoMetadataKey.fileURL.rawValue
        static let captureMs = VideoMetadataKey.captureMs.rawValue
        static let durationMs = VideoMetadataKey.durationMs.rawValue
        static let isLocal = VideoMetadataKey.isLocal.rawValue
        static let pipelineVersion = VideoMetadataKey.pipelineVersion.rawValue
        static let transcriptStatus = VideoMetadataKey.transcriptStatus.rawValue

        static let segmentIndex = VideoMetadataKey.segmentIndex.rawValue
        static let segmentCount = VideoMetadataKey.segmentCount.rawValue
        static let segmentStartMs = VideoMetadataKey.segmentStartMs.rawValue
        static let segmentEndMs = VideoMetadataKey.segmentEndMs.rawValue
        static let segmentMidMs = VideoMetadataKey.segmentMidMs.rawValue
    }

    struct IndexState: Sendable {
        var rootByVideoID: [VideoID: UInt64] = [:]
        var segmentIdsByVideoID: [VideoID: Set<UInt64>] = [:]
        var rootMetaByVideoID: [VideoID: FrameMeta] = [:]
    }

    struct SegmentPlan: Sendable, Equatable {
        var startMs: Int64
        var endMs: Int64
        var midMs: Int64
        var index: Int
        var count: Int
    }

    static func _makeSegmentRangesForTesting(
        durationMs: Int64,
        segmentDurationSeconds: Double,
        segmentOverlapSeconds: Double,
        maxSegments: Int
    ) -> [VideoSegmentTimeRange] {
        let plans = makeSegments(
            durationMs: durationMs,
            segmentDurationSeconds: segmentDurationSeconds,
            segmentOverlapSeconds: segmentOverlapSeconds,
            maxSegments: maxSegments
        )
        return plans.map { VideoSegmentTimeRange(startMs: $0.startMs, endMs: $0.endMs) }
    }

    static func _mapTranscriptForTesting(
        chunks: [VideoTranscriptChunk],
        segments: [VideoSegmentTimeRange],
        maxBytes: Int
    ) -> [Int: String] {
        let plans = segments.enumerated().map { index, range in
            SegmentPlan(
                startMs: range.startMs,
                endMs: range.endMs,
                midMs: (range.startMs + range.endMs) / 2,
                index: index,
                count: segments.count
            )
        }
        return mapTranscript(chunks: chunks, segments: plans, maxBytes: maxBytes)
    }

    /// The underlying Wax store for frame storage and indexing.
    package let wax: Wax
    /// The active Wax session for reads and writes.
    package let session: WaxSession
    /// Configuration controlling segment duration, pixel sizes, transcript budgets, and search parameters.
    package let config: VideoRAGConfig

    let embedder: any MultimodalEmbeddingProvider
    let transcriptProvider: (any VideoTranscriptProvider)?
    private let queryEmbeddingCache: EmbeddingMemoizer?

    var index = IndexState()

    package init(
        storeURL: URL,
        config: VideoRAGConfig = .default,
        embedder: any MultimodalEmbeddingProvider,
        transcriptProvider: (any VideoTranscriptProvider)? = nil
    ) async throws {
        self.config = config
        self.embedder = embedder
        self.transcriptProvider = transcriptProvider

        if config.requireOnDeviceProviders {
            var checks: [ProviderValidation.ProviderCheck] = [
                .init(name: "embedding provider", executionMode: embedder.executionMode)
            ]
            if let transcriptProvider {
                checks.append(.init(name: "transcript provider", executionMode: transcriptProvider.executionMode))
            }
            try ProviderValidation.validateOnDevice(checks, orchestratorName: "VideoRAG")
        }

        if config.vectorEnginePreference != .cpuOnly, embedder.normalize == false {
            throw WaxError.io("Metal vector search requires normalized embeddings (set embedder.normalize=true or use cpuOnly)")
        }

        if FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)) {
            self.wax = try await Wax.open(at: storeURL)
        } else {
            self.wax = try await Wax.create(at: storeURL)
        }

        let sessionConfig = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: true,
            enableStructuredMemory: false,
            vectorEnginePreference: config.vectorEnginePreference,
            vectorMetric: .cosine,
            vectorDimensions: embedder.dimensions
        )
        self.session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        self.queryEmbeddingCache = EmbeddingMemoizer.fromConfig(capacity: config.queryEmbeddingCacheCapacity)

        try await rebuildIndex()
    }

    // MARK: - Delete / flush

    package func delete(videoID: VideoID) async throws {
        guard let rootId = index.rootByVideoID[videoID] else { return }

        var toDelete: [UInt64] = [rootId]
        if let segmentIds = index.segmentIdsByVideoID[videoID] {
            toDelete.append(contentsOf: segmentIds)
        }

        for frameId in toDelete {
            try await wax.delete(frameId: frameId)
        }
        try await removeSearchIndexes(frameIds: toDelete)
        try await session.commit()
        try await rebuildIndex()
    }

    package func flush() async throws {
        try await session.commit()
    }

    /// Flush pending writes, then close the session and the underlying store.
    ///
    /// The orchestrator must not be used after `close()` returns.
    package func close() async throws {
        try await flush()
        await session.close()
        try await wax.close()
    }

    /// Removes vector-index entries for a superseded root and its segment frames.
    /// Without this, superseded keyframe vectors stay searchable as ghost hits.
    func removeVectorsForRetiredTree(_ rootId: UInt64, videoID: VideoID) async throws {
        var ids: [UInt64] = [rootId]
        if let segmentIds = index.segmentIdsByVideoID[videoID] {
            ids.append(contentsOf: segmentIds)
        }
        try await removeSearchIndexes(frameIds: ids)
    }

    /// Deletes a tree whose ingest failed before it superseded the previous version, so the
    /// video keeps its previous version (or nothing) rather than a partial second live tree.
    /// Best-effort: the ingest error is what the caller reports.
    func discardPartialTree(rootId: UInt64) async {
        let children = await wax.frameMetasIncludingPending().filter { $0.parentId == rootId }
        let frameIds = [rootId] + children.map(\.id)
        do {
            for frameId in frameIds {
                try await wax.delete(frameId: frameId)
            }
            try await removeSearchIndexes(frameIds: frameIds)
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "VideoRAG partial-tree discard",
                fallback: "partial tree may stay live until the video is re-ingested"
            )
        }
    }

    /// Ends an ingest call that failed partway: commits the trees that completed and rebuilds
    /// the index so it matches the store. Best-effort: the ingest error is what the caller reports.
    func reconcileAfterFailedIngest() async {
        do {
            try await session.commit()
            try await rebuildIndex()
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "VideoRAG failed-ingest reconcile",
                fallback: "completed trees stay pending until the next flush"
            )
        }
    }

    /// Drops vector and text postings so deleted/superseded segments cannot
    /// satisfy a later transcript query in place of the live tree.
    private func removeSearchIndexes(frameIds: [UInt64]) async throws {
        for frameId in frameIds {
            try await session.removeVector(frameId: frameId)
            try await session.removeText(frameId: frameId)
        }
    }

    // MARK: - Indexing

    func rebuildIndex() async throws {
        let metas = await wax.frameMetas()

        var supersededRoots: Set<UInt64> = []
        supersededRoots.reserveCapacity(64)
        for meta in metas where FrameKind(rawKind: meta.kind) == .video(.root) {
            if meta.supersededBy != nil || meta.status == .deleted {
                supersededRoots.insert(meta.id)
            }
        }

        var next = IndexState()
        var retiredVectorIds: Set<UInt64> = []

        for meta in metas {
            guard meta.status != .deleted else {
                retiredVectorIds.insert(meta.id)
                continue
            }
            guard let kind = meta.kind else { continue }
            let frameKind = FrameKind(rawKind: kind)
            if frameKind != .video(.root) && frameKind != .video(.segment) { continue }
            guard let entries = meta.metadata?.entries else { continue }
            guard let source = entries[MetaKey.source],
                  let sourceID = entries[MetaKey.sourceID]
            else { continue }

            let src: VideoID.Source = (source == "photos") ? .photos : .file
            let vid = VideoID(source: src, id: sourceID)

            if frameKind == .video(.root) {
                guard meta.supersededBy == nil else {
                    retiredVectorIds.insert(meta.id)
                    continue
                }
                next.rootByVideoID[vid] = meta.id
                next.rootMetaByVideoID[vid] = meta
                continue
            }

            // Segment: only if parent root is current.
            if let parentId = meta.parentId {
                guard !supersededRoots.contains(parentId) else {
                    retiredVectorIds.insert(meta.id)
                    continue
                }
                if next.rootByVideoID[vid] == parentId {
                    next.segmentIdsByVideoID[vid, default: []].insert(meta.id)
                }
            }
        }

        index = next
        await sweepRetiredVectors(retiredVectorIds)
    }

    /// Removes vectors for frames outside the live index (superseded trees, deleted
    /// frames). Stores written before vector cleanup existed can otherwise keep serving
    /// ghost hits for retired frames. Best-effort: a sweep failure must not block
    /// opening or reindexing the store.
    private func sweepRetiredVectors(_ frameIds: Set<UInt64>) async {
        guard !frameIds.isEmpty else { return }
        for frameId in frameIds {
            do {
                try await session.removeVector(frameId: frameId)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "VideoRAG retired-vector sweep",
                    fallback: "stale vector may remain in the committed index"
                )
            }
            do {
                try await session.removeText(frameId: frameId)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "VideoRAG retired-text sweep",
                    fallback: "stale text posting may remain in the committed index"
                )
            }
        }
    }

    // MARK: - Query embedding

    func buildQueryEmbedding(text: String?) async throws -> [Float]? {
        guard let text, !text.isEmpty else { return nil }
        let key = EmbeddingKey.make(
            text: text,
            identity: embedder.identity,
            dimensions: embedder.dimensions,
            normalized: embedder.normalize
        )
        if let cached = await queryEmbeddingCache?.get(key) {
            return cached
        }
        var vec = try await embedder.embed(text: text)
        if embedder.normalize, !vec.isEmpty { vec = VectorMath.normalizeL2(vec) }
        guard vec.count == embedder.dimensions else {
            throw VideoIngestError.embedderDimensionMismatch(expected: embedder.dimensions, got: vec.count)
        }
        await queryEmbeddingCache?.set(key, value: vec)
        return vec
    }
}

#endif // canImport(ImageIO)
