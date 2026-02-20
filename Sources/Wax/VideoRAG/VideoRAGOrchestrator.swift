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
public actor VideoRAGOrchestrator {
    private static let photosVideoRequestTimeout: Duration = .seconds(10)
    private static let scoreTieEpsilon: Float = 1e-3

    struct VideoSegmentTimeRange: Sendable, Equatable {
        var startMs: Int64
        var endMs: Int64

        init(startMs: Int64, endMs: Int64) {
            self.startMs = startMs
            self.endMs = endMs
        }
    }

    private enum FrameKind {
        static let root = VideoFrameKind.root.rawValue
        static let segment = VideoFrameKind.segment.rawValue
    }

    private enum MetaKey {
        static let source = VideoMetadataKey.source.rawValue
        static let sourceID = VideoMetadataKey.sourceID.rawValue
        static let fileURL = VideoMetadataKey.fileURL.rawValue
        static let captureMs = VideoMetadataKey.captureMs.rawValue
        static let durationMs = VideoMetadataKey.durationMs.rawValue
        static let isLocal = VideoMetadataKey.isLocal.rawValue
        static let pipelineVersion = VideoMetadataKey.pipelineVersion.rawValue

        static let segmentIndex = VideoMetadataKey.segmentIndex.rawValue
        static let segmentCount = VideoMetadataKey.segmentCount.rawValue
        static let segmentStartMs = VideoMetadataKey.segmentStartMs.rawValue
        static let segmentEndMs = VideoMetadataKey.segmentEndMs.rawValue
        static let segmentMidMs = VideoMetadataKey.segmentMidMs.rawValue
    }

    private struct IndexState: Sendable {
        var rootByVideoID: [VideoID: UInt64] = [:]
        var segmentIdsByVideoID: [VideoID: Set<UInt64>] = [:]
        var rootMetaByVideoID: [VideoID: FrameMeta] = [:]
    }

    private struct SegmentPlan: Sendable, Equatable {
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

    /// The underlying Wax store for frame storage and indexing.
    public let wax: Wax
    /// The active Wax session for reads and writes.
    public let session: WaxSession
    /// Configuration controlling segment duration, pixel sizes, transcript budgets, and search parameters.
    public let config: VideoRAGConfig

    private let embedder: any MultimodalEmbeddingProvider
    private let transcriptProvider: (any VideoTranscriptProvider)?
    private let queryEmbeddingCache: EmbeddingMemoizer?

    private var index = IndexState()

    public init(
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

    #if canImport(Photos)
    /// Scope for syncing videos from the Photos library.
    public enum VideoScope: Sendable, Equatable {
        case fullLibrary
        case assetIDs([String])
    }

    /// Sync the Photos library videos into the local Wax store.
    ///
    /// Offline-only: iCloud-only assets are indexed as metadata-only and marked degraded.
    public func syncLibrary(scope: VideoScope) async throws {
        let ids: [String] = switch scope {
        case .assetIDs(let ids):
            ids
        case .fullLibrary:
            await MainActor.run {
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                let result = PHAsset.fetchAssets(with: .video, options: opts)
                if result.count == 0 { return [] }
                var ids: [String] = []
                ids.reserveCapacity(result.count)
                for index in 0..<result.count {
                    ids.append(result.object(at: index).localIdentifier)
                }
                return ids
            }
        }
        try await ingest(photoAssetIDs: ids)
    }
    #endif

    /// Ingest local file videos.
    public func ingest(files: [VideoFile]) async throws {
        let unique = Self.dedupeFiles(files)
        guard !unique.isEmpty else { return }

        for file in unique {
            try Task.checkCancellation()
            try await ingestOneFile(file)
        }

        try await session.commit()
        try await rebuildIndex()
    }

    #if canImport(Photos)
    private func ingest(photoAssetIDs: [String]) async throws {
        let unique = Self.dedupeIDs(photoAssetIDs)
        guard !unique.isEmpty else { return }

        for assetID in unique {
            try await ingestOnePhoto(assetID: assetID)
        }

        try await session.commit()
        try await rebuildIndex()
    }
    #endif

    // MARK: - Recall

    public func recall(_ query: VideoQuery) async throws -> VideoRAGContext {
        let cleanedText = query.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = (cleanedText?.isEmpty == false) ? cleanedText : nil

        let queryEmbedding = try await buildQueryEmbedding(text: queryText)
        let isConstraintOnly = (queryText == nil && queryEmbedding == nil)

        let mode: SearchMode = {
            switch (queryText, queryEmbedding) {
            case (nil, nil):
                return .textOnly
            case (nil, _?):
                return .vectorOnly
            case (_?, nil):
                return .textOnly
            case (_?, _?):
                return .hybrid(alpha: config.hybridAlpha)
            }
        }()

        let timeRange = Self.toWaxTimeRange(query.timeRange)

        let frameFilter: FrameFilter? = {
            // Constraint-only queries use timeline fallback; filter to roots to avoid returning all segment frames.
            if isConstraintOnly {
                let roots: Set<UInt64> = if let allowlist = query.videoIDs {
                    Set(allowlist.compactMap { index.rootByVideoID[$0] })
                } else {
                    Set(index.rootByVideoID.values)
                }
                return FrameFilter(frameIds: roots)
            }

            if let allowlist = query.videoIDs {
                var ids: Set<UInt64> = []
                ids.reserveCapacity(allowlist.count * 16)
                for videoID in allowlist {
                    if let segs = index.segmentIdsByVideoID[videoID] {
                        ids.formUnion(segs)
                    }
                }
                return FrameFilter(frameIds: ids)
            }
            return nil
        }()

        let topK = max(config.searchTopK, query.resultLimit * max(1, query.segmentLimitPerVideo) * 8)
        let timelineFallbackLimit = max(config.timelineFallbackLimit, query.resultLimit * 4)

        let request = SearchRequest(
            query: queryText,
            embedding: queryEmbedding,
            vectorEnginePreference: config.vectorEnginePreference,
            mode: mode,
            topK: topK,
            timeRange: timeRange,
            frameFilter: frameFilter,
            previewMaxBytes: 1024,
            allowTimelineFallback: isConstraintOnly,
            timelineFallbackLimit: timelineFallbackLimit
        )

        let response = try await session.search(request)
        guard !response.results.isEmpty else {
            return VideoRAGContext(query: query, items: [], diagnostics: .init())
        }

        let frameIds = response.results.map(\.frameId)
        let metaById = await wax.frameMetasIncludingPending(frameIds: frameIds)

        var rootIds: Set<UInt64> = []
        rootIds.reserveCapacity(response.results.count)
        for result in response.results {
            if let meta = metaById[result.frameId] {
                rootIds.insert(meta.parentId ?? meta.id)
            }
        }
        let rootMetaById = await wax.frameMetasIncludingPending(frameIds: Array(rootIds))

        struct SegmentCandidate: Sendable {
            var frameId: UInt64
            var rootId: UInt64
            var score: Float
            var evidence: [VideoSegmentHit.Evidence]
            var startMs: Int64?
            var endMs: Int64?
        }

        struct RootCandidate: Sendable {
            var rootId: UInt64
            var score: Float
            var evidence: [VideoSegmentHit.Evidence]
            var segmentsByIndex: [Int: SegmentCandidate]
        }

        func evidence(from result: SearchResponse.Result) -> [VideoSegmentHit.Evidence] {
            var out: [VideoSegmentHit.Evidence] = []
            if result.sources.contains(.timeline) { out.append(.timeline) }
            if result.sources.contains(.vector) { out.append(.vector) }
            if result.sources.contains(.text) { out.append(.text(snippet: result.previewText)) }
            return out
        }

        var candidates: [UInt64: RootCandidate] = [:]
        candidates.reserveCapacity(rootIds.count)

        for result in response.results {
            guard let meta = metaById[result.frameId] else { continue }
            let rootId = meta.parentId ?? meta.id
            guard let rootMeta = rootMetaById[rootId] else { continue }
            if rootMeta.kind != FrameKind.root { continue }
            if rootMeta.status == .deleted { continue }
            if rootMeta.supersededBy != nil { continue }

            let ev = evidence(from: result)
            var entry = candidates[rootId] ?? RootCandidate(
                rootId: rootId,
                score: result.score,
                evidence: [],
                segmentsByIndex: [:]
            )
            entry.score = max(entry.score, result.score)
            for e in ev where !entry.evidence.contains(e) {
                entry.evidence.append(e)
            }

            // Timeline fallback can return roots; only record segment hits for segment-kind frames.
            if meta.kind == FrameKind.segment {
                let entries = meta.metadata?.entries ?? [:]
                let idx = Int(entries[MetaKey.segmentIndex].flatMap(Int.init) ?? -1)
                let startMs = entries[MetaKey.segmentStartMs].flatMap(Int64.init)
                let endMs = entries[MetaKey.segmentEndMs].flatMap(Int64.init)

                let seg = SegmentCandidate(
                    frameId: result.frameId,
                    rootId: rootId,
                    score: result.score,
                    evidence: ev,
                    startMs: startMs,
                    endMs: endMs
                )
                if idx >= 0 {
                    if let existing = entry.segmentsByIndex[idx] {
                        if seg.score > existing.score + Self.scoreTieEpsilon {
                            entry.segmentsByIndex[idx] = seg
                        } else if abs(seg.score - existing.score) <= Self.scoreTieEpsilon,
                                  seg.frameId < existing.frameId {
                            entry.segmentsByIndex[idx] = seg
                        }
                    } else {
                        entry.segmentsByIndex[idx] = seg
                    }
                }
            }

            candidates[rootId] = entry
        }

        func isTimelineOnly(_ candidate: RootCandidate) -> Bool {
            !candidate.evidence.isEmpty && candidate.evidence.allSatisfy {
                if case .timeline = $0 { return true }
                return false
            }
        }

        func captureMs(for rootId: UInt64) -> Int64? {
            guard let rootMeta = rootMetaById[rootId] else { return nil }
            guard let entries = rootMeta.metadata?.entries else { return nil }
            return entries[MetaKey.captureMs].flatMap(Int64.init)
        }

        // Deterministic ordering across videos.
        let sorted = candidates.values.sorted { a, b in
            if isTimelineOnly(a), isTimelineOnly(b) {
                // Constraint-only timeline fallback should preserve strict temporal ordering.
                if a.score != b.score { return a.score > b.score }
                let aCapture = captureMs(for: a.rootId) ?? .min
                let bCapture = captureMs(for: b.rootId) ?? .min
                if aCapture != bCapture { return aCapture > bCapture }
                return a.rootId < b.rootId
            }
            if abs(a.score - b.score) > Self.scoreTieEpsilon { return a.score > b.score }
            return a.rootId < b.rootId
        }

        let picked = Array(sorted.prefix(query.resultLimit))
        let rootIdsPicked = picked.map(\.rootId)

        // Parse root -> videoID.
        func videoID(from rootMeta: FrameMeta) -> VideoID? {
            guard let entries = rootMeta.metadata?.entries else { return nil }
            guard let source = entries[MetaKey.source],
                  let sourceID = entries[MetaKey.sourceID]
            else { return nil }
            let src: VideoID.Source = (source == "photos") ? .photos : .file
            return VideoID(source: src, id: sourceID)
        }

        // Load segment transcripts for selected segments (batch).
        var selectedSegmentFrameIds: [UInt64] = []
        selectedSegmentFrameIds.reserveCapacity(picked.count * max(1, query.segmentLimitPerVideo))
        for root in picked {
            let segs = root.segmentsByIndex
                .sorted { a, b in
                    if abs(a.value.score - b.value.score) > Self.scoreTieEpsilon {
                        return a.value.score > b.value.score
                    }
                    return a.key < b.key
                }
                .prefix(query.segmentLimitPerVideo)
            selectedSegmentFrameIds.append(contentsOf: segs.map { $0.value.frameId })
        }
        let segmentContents = try await wax.frameContents(frameIds: selectedSegmentFrameIds)

        func transcriptText(frameId: UInt64) -> String? {
            guard let data = segmentContents[frameId] else { return nil }
            let text = String(data: data, encoding: .utf8)
            return text?.trimmingCharacters(in: .whitespacesAndNewlines)
        }

        var items: [VideoRAGItem] = []
        items.reserveCapacity(rootIdsPicked.count)

        for rootCandidate in picked {
            guard let rootMeta = rootMetaById[rootCandidate.rootId] else { continue }
            guard let vid = videoID(from: rootMeta) else { continue }

            let segmentCandidates = rootCandidate.segmentsByIndex
                .sorted { a, b in
                    if abs(a.value.score - b.value.score) > Self.scoreTieEpsilon {
                        return a.value.score > b.value.score
                    }
                    return a.key < b.key
                }
                .prefix(query.segmentLimitPerVideo)

            var segmentHits: [VideoSegmentHit] = []
            segmentHits.reserveCapacity(segmentCandidates.count)

            for seg in segmentCandidates {
                let start = seg.value.startMs ?? 0
                let end = seg.value.endMs ?? start
                let snippet = transcriptText(frameId: seg.value.frameId).flatMap {
                    Self.firstLines($0, maxLines: query.contextBudget.maxTranscriptLinesPerSegment)
                }
                segmentHits.append(
                    VideoSegmentHit(
                        startMs: start,
                        endMs: end,
                        score: seg.value.score,
                        evidence: seg.value.evidence,
                        transcriptSnippet: snippet,
                        thumbnail: nil
                    )
                )
            }

            let summary = Self.buildSummaryText(
                rootMeta: rootMeta,
                segments: segmentHits,
                maxLinesPerSegment: query.contextBudget.maxTranscriptLinesPerSegment
            )

            items.append(
                VideoRAGItem(
                    videoID: vid,
                    score: rootCandidate.score,
                    evidence: rootCandidate.evidence,
                    summaryText: summary,
                    segments: segmentHits
                )
            )
        }

        // Apply text budget deterministically.
        let counter = try await TokenCounter.shared()
        let perItemCap = max(1, query.contextBudget.maxTextTokens / max(1, items.count))
        let processed = await counter.countAndTruncateBatch(items.map(\.summaryText), maxTokens: perItemCap)
        assert(processed.count == items.count, "countAndTruncateBatch must return exactly one result per input")
        guard processed.count == items.count else { return VideoRAGContext(query: query, items: [], diagnostics: .init()) }

        var usedTokens = 0
        var budgeted: [VideoRAGItem] = []
        budgeted.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let (tokens, capped) = processed[index]
            guard usedTokens + tokens <= query.contextBudget.maxTextTokens else { break }
            usedTokens += tokens
            var updated = item
            updated.summaryText = capped
            budgeted.append(updated)
        }

        let itemsWithThumbs = try await attachThumbnailsIfNeeded(
            items: budgeted,
            rootMetaById: rootMetaById,
            maxThumbnails: query.contextBudget.maxThumbnails
        )

        let degradedCount = itemsWithThumbs.filter { isDegraded(videoID: $0.videoID) }.count
        let diagnostics = VideoRAGContext.Diagnostics(usedTextTokens: usedTokens, degradedVideoCount: degradedCount)
        return VideoRAGContext(query: query, items: itemsWithThumbs, diagnostics: diagnostics)
    }

    // MARK: - Delete / flush

    public func delete(videoID: VideoID) async throws {
        guard let rootId = index.rootByVideoID[videoID] else { return }

        var toDelete: [UInt64] = [rootId]
        if let segmentIds = index.segmentIdsByVideoID[videoID] {
            toDelete.append(contentsOf: segmentIds)
        }

        for frameId in toDelete {
            try await wax.delete(frameId: frameId)
        }
        try await session.commit()
        try await rebuildIndex()
    }

    public func flush() async throws {
        try await session.commit()
    }

    // MARK: - Ingest internals

    private func ingestOneFile(_ file: VideoFile) async throws {
        guard file.url.isFileURL else {
            throw VideoIngestError.invalidVideo(reason: "file URL must be a file:// URL")
        }
        guard FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)) else {
            throw VideoIngestError.fileMissing(id: file.id, url: file.url)
        }

        let videoID = VideoID(source: .file, id: file.id)
        let previousRoot = index.rootByVideoID[videoID]

        let (durationMs, keyframeImages) = try await buildKeyframes(url: file.url)
        let captureMs = file.captureDate.map { Int64($0.timeIntervalSince1970 * 1000) }
            ?? Int64(Date().timeIntervalSince1970 * 1000)

        let segments = Self.makeSegments(
            durationMs: durationMs,
            segmentDurationSeconds: config.segmentDurationSeconds,
            segmentOverlapSeconds: config.segmentOverlapSeconds,
            maxSegments: config.maxSegmentsPerVideo
        )

        let transcriptChunks = try await loadTranscript(
            videoID: videoID,
            localFileURL: file.url,
            durationMs: durationMs
        )
        let transcriptByIndex = Self.mapTranscript(chunks: transcriptChunks, segments: segments, maxBytes: config.maxTranscriptBytesPerSegment)

        let rootMeta = baseMetadata(
            videoID: videoID,
            captureMs: captureMs,
            durationMs: durationMs,
            pipelineVersion: config.pipelineVersion,
            isLocal: true,
            fileURL: file.url
        )
        let rootOptions = FrameMetaSubset(kind: FrameKind.root, metadata: rootMeta)
        let rootId = try await session.put(Data(), options: rootOptions, compression: .plain, timestampMs: captureMs)

        // Segment frames (embedded + optional transcript payload)
        try await writeSegments(
            rootId: rootId,
            videoID: videoID,
            captureMs: captureMs,
            segments: segments,
            keyframes: keyframeImages,
            transcriptByIndex: transcriptByIndex
        )

        if let previousRoot {
            try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
        }
    }

    #if canImport(Photos)
    private func ingestOnePhoto(assetID: String) async throws {
        let videoID = VideoID(source: .photos, id: assetID)
        let previousRoot = index.rootByVideoID[videoID]

        let record = try await Self.loadPhotosVideo(assetID: assetID)
        let captureMs = record.captureMs ?? Int64(Date().timeIntervalSince1970 * 1000)

        let durationMs: Int64
        let segments: [SegmentPlan]
        let keyframes: [CGImage]
        let transcriptByIndex: [Int: String]

        if record.isLocal, let url = record.localFileURL {
            let extracted = try await buildKeyframes(url: url)
            durationMs = extracted.durationMs
            segments = Self.makeSegments(
                durationMs: durationMs,
                segmentDurationSeconds: config.segmentDurationSeconds,
                segmentOverlapSeconds: config.segmentOverlapSeconds,
                maxSegments: config.maxSegmentsPerVideo
            )
            keyframes = extracted.keyframes

            let transcriptChunks = try await loadTranscript(
                videoID: videoID,
                localFileURL: url,
                durationMs: durationMs
            )
            transcriptByIndex = Self.mapTranscript(chunks: transcriptChunks, segments: segments, maxBytes: config.maxTranscriptBytesPerSegment)
        } else {
            durationMs = record.durationMs
            segments = []
            keyframes = []
            transcriptByIndex = [:]
        }

        let rootMeta = baseMetadata(
            videoID: videoID,
            captureMs: captureMs,
            durationMs: durationMs,
            pipelineVersion: config.pipelineVersion,
            isLocal: record.isLocal,
            fileURL: nil
        )
        let rootOptions = FrameMetaSubset(kind: FrameKind.root, metadata: rootMeta)
        let rootId = try await session.put(Data(), options: rootOptions, compression: .plain, timestampMs: captureMs)

        if record.isLocal {
            try await writeSegments(
                rootId: rootId,
                videoID: videoID,
                captureMs: captureMs,
                segments: segments,
                keyframes: keyframes,
                transcriptByIndex: transcriptByIndex
            )
        }

        if let previousRoot {
            try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
        }
    }
    #endif

    private func writeSegments(
        rootId: UInt64,
        videoID: VideoID,
        captureMs: Int64,
        segments: [SegmentPlan],
        keyframes: [CGImage],
        transcriptByIndex: [Int: String]
    ) async throws {
        guard !segments.isEmpty else { return }
        guard segments.count == keyframes.count else {
            throw VideoIngestError.invalidVideo(reason: "segment/keyframe count mismatch")
        }

        var embeddings: [[Float]] = []
        embeddings.reserveCapacity(segments.count)
        var contents: [Data] = []
        contents.reserveCapacity(segments.count)
        var options: [FrameMetaSubset] = []
        options.reserveCapacity(segments.count)

        for (idx, segment) in segments.enumerated() {
            try Task.checkCancellation()
            var vec = try await embedder.embed(image: keyframes[idx])
            if embedder.normalize, !vec.isEmpty { vec = VectorMath.normalizeL2(vec) }
            guard vec.count == embedder.dimensions else {
                throw VideoIngestError.embedderDimensionMismatch(expected: embedder.dimensions, got: vec.count)
            }
            embeddings.append(vec)

            let text = transcriptByIndex[segment.index] ?? ""
            contents.append(Data(text.utf8))

            var meta = baseMetadata(
                videoID: videoID,
                captureMs: captureMs,
                durationMs: nil,
                pipelineVersion: config.pipelineVersion,
                isLocal: true,
                fileURL: nil
            )
            meta.entries[MetaKey.segmentIndex] = String(segment.index)
            meta.entries[MetaKey.segmentCount] = String(segment.count)
            meta.entries[MetaKey.segmentStartMs] = String(segment.startMs)
            meta.entries[MetaKey.segmentEndMs] = String(segment.endMs)
            meta.entries[MetaKey.segmentMidMs] = String(segment.midMs)

            let subset = FrameMetaSubset(kind: FrameKind.segment, role: .blob, parentId: rootId, metadata: meta)
            options.append(subset)
        }

        // Capture-time semantics: segment frames share the video's capture timestamp so
        // `VideoQuery.timeRange` behaves as a capture-time filter.
        let timestamps = Array(repeating: captureMs, count: segments.count)
        let batchSize = config.segmentWriteBatchSize
        var allFrameIds: [UInt64] = []
        allFrameIds.reserveCapacity(segments.count)

        for start in stride(from: 0, to: segments.count, by: batchSize) {
            let end = min(start + batchSize, segments.count)
            let batchFrameIds = try await session.putBatch(
                contents: Array(contents[start..<end]),
                embeddings: Array(embeddings[start..<end]),
                identity: embedder.identity,
                options: Array(options[start..<end]),
                timestampsMs: Array(timestamps[start..<end]),
                compression: .plain
            )
            guard batchFrameIds.count == end - start else {
                throw WaxError.io(
                    "segment batch write count mismatch: expected \(end - start), got \(batchFrameIds.count)"
                )
            }
            allFrameIds.append(contentsOf: batchFrameIds)
        }

        // Index segments that have transcript text.
        var textFrameIds: [UInt64] = []
        var texts: [String] = []
        textFrameIds.reserveCapacity(allFrameIds.count)
        texts.reserveCapacity(allFrameIds.count)
        for (idx, frameId) in allFrameIds.enumerated() {
            let text = String(data: contents[idx], encoding: .utf8) ?? ""
            if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { continue }
            textFrameIds.append(frameId)
            texts.append(text)
        }
        if !textFrameIds.isEmpty {
            try await session.indexTextBatch(frameIds: textFrameIds, texts: texts)
        }
    }

    private func loadTranscript(videoID: VideoID, localFileURL: URL, durationMs: Int64) async throws -> [VideoTranscriptChunk] {
        guard let provider = transcriptProvider else { return [] }
        let request = VideoTranscriptRequest(videoID: videoID, localFileURL: localFileURL, durationMs: durationMs)
        return try await provider.transcript(for: request)
    }

    // MARK: - Indexing

    private func rebuildIndex() async throws {
        let metas = await wax.frameMetas()

        var supersededRoots: Set<UInt64> = []
        supersededRoots.reserveCapacity(64)
        for meta in metas where meta.kind == FrameKind.root {
            if meta.supersededBy != nil || meta.status == .deleted {
                supersededRoots.insert(meta.id)
            }
        }

        var next = IndexState()

        for meta in metas {
            guard meta.status != .deleted else { continue }
            guard let kind = meta.kind else { continue }
            if kind != FrameKind.root && kind != FrameKind.segment { continue }
            guard let entries = meta.metadata?.entries else { continue }
            guard let source = entries[MetaKey.source],
                  let sourceID = entries[MetaKey.sourceID]
            else { continue }

            let src: VideoID.Source = (source == "photos") ? .photos : .file
            let vid = VideoID(source: src, id: sourceID)

            if kind == FrameKind.root {
                guard meta.supersededBy == nil else { continue }
                next.rootByVideoID[vid] = meta.id
                next.rootMetaByVideoID[vid] = meta
                continue
            }

            // Segment: only if parent root is current.
            if let parentId = meta.parentId {
                guard !supersededRoots.contains(parentId) else { continue }
                if next.rootByVideoID[vid] == parentId {
                    next.segmentIdsByVideoID[vid, default: []].insert(meta.id)
                }
            }
        }

        index = next
    }

    private func isDegraded(videoID: VideoID) -> Bool {
        guard let rootMeta = index.rootMetaByVideoID[videoID],
              let entries = rootMeta.metadata?.entries
        else { return true }
        return entries[MetaKey.isLocal] != "true"
    }

    // MARK: - Query embedding

    private func buildQueryEmbedding(text: String?) async throws -> [Float]? {
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

    // MARK: - Media helpers

    #if canImport(AVFoundation)
    private func buildKeyframes(url: URL) async throws -> (durationMs: Int64, keyframes: [CGImage]) {
        let asset = AVURLAsset(url: url)
        let duration = try await asset.load(.duration)
        let durationMs = Int64(duration.seconds * 1000)
        if durationMs <= 0 {
            throw VideoIngestError.invalidVideo(reason: "duration must be > 0")
        }

        let segments = Self.makeSegments(
            durationMs: durationMs,
            segmentDurationSeconds: config.segmentDurationSeconds,
            segmentOverlapSeconds: config.segmentOverlapSeconds,
            maxSegments: config.maxSegmentsPerVideo
        )
        let times = segments.map { CMTime(seconds: Double($0.midMs) / 1000.0, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: config.embedMaxPixelSize, height: config.embedMaxPixelSize)
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol

        var images: [CGImage] = []
        images.reserveCapacity(times.count)
        for time in times {
            let cg = try await cgImage(generator: generator, for: time)
            images.append(cg)
        }

        return (durationMs: durationMs, keyframes: images)
    }
    #else
    private func buildKeyframes(url: URL) async throws -> (durationMs: Int64, keyframes: [CGImage]) {
        _ = url
        throw VideoIngestError.unsupportedPlatform(reason: "AVFoundation is unavailable on this platform")
    }
    #endif

    #if canImport(Photos)
    private struct PhotosVideoRecord: Sendable {
        var captureMs: Int64?
        var durationMs: Int64
        var isLocal: Bool
        var localFileURL: URL?
    }

    @MainActor
    private static func loadPhotosVideo(assetID: String) async throws -> PhotosVideoRecord {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else {
            throw WaxError.io("PHAsset not found for id: \(assetID)")
        }

        let captureMs = asset.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        let durationMs = Int64(asset.duration * 1000)

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let manager = PHImageManager.default()
            var requestID: PHImageRequestID = PHInvalidImageRequestID

            requestID = manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }

                let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                let error = info?[PHImageErrorKey] as? NSError

                if cancelled || inCloud || error != nil || avAsset == nil {
                    continuation.resume(
                        returning: PhotosVideoRecord(
                            captureMs: captureMs,
                            durationMs: durationMs,
                            isLocal: false,
                            localFileURL: nil
                        )
                    )
                    return
                }

                let url = (avAsset as? AVURLAsset)?.url
                continuation.resume(
                    returning: PhotosVideoRecord(
                        captureMs: captureMs,
                        durationMs: durationMs,
                        isLocal: (url != nil),
                        localFileURL: url
                    )
                )
            }

            Task { @MainActor in
                try? await Task.sleep(for: photosVideoRequestTimeout)
                guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }
                if requestID != PHInvalidImageRequestID {
                    manager.cancelImageRequest(requestID)
                }
                continuation.resume(
                    returning: PhotosVideoRecord(
                        captureMs: captureMs,
                        durationMs: durationMs,
                        isLocal: false,
                        localFileURL: nil
                    )
                )
            }
        }
    }
    #endif

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw WaxError.io("failed to create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WaxError.io("failed to encode PNG")
        }
        return data as Data
    }

    private func attachThumbnailsIfNeeded(
        items: [VideoRAGItem],
        rootMetaById: [UInt64: FrameMeta],
        maxThumbnails: Int
    ) async throws -> [VideoRAGItem] {
        guard config.includeThumbnailsInContext else { return items }
        guard maxThumbnails > 0 else { return items }
        guard !items.isEmpty else { return items }

        var updated = items
        var remaining = maxThumbnails

        for itemIndex in updated.indices where remaining > 0 {
            // Only file-backed videos have a stable file URL in v1.
            let videoID = updated[itemIndex].videoID
            guard let rootId = index.rootByVideoID[videoID],
                  let rootMeta = rootMetaById[rootId],
                  let fileURLString = rootMeta.metadata?.entries[MetaKey.fileURL],
                  let url = URL(string: fileURLString)
            else { continue }

            // Attach thumbnails to the first N segments, in existing order.
            for segIndex in updated[itemIndex].segments.indices where remaining > 0 {
                let startMs = updated[itemIndex].segments[segIndex].startMs
                let endMs = updated[itemIndex].segments[segIndex].endMs
                let midMs = (startMs + endMs) / 2

                do {
                    let thumb = try await keyframeThumbnail(url: url, midMs: midMs)
                    updated[itemIndex].segments[segIndex].thumbnail = thumb
                    remaining -= 1
                } catch {
                    WaxDiagnostics.logSwallowed(
                        error,
                        context: "video thumbnail extraction",
                        fallback: "skip thumbnail for this segment"
                    )
                }
            }
        }

        return updated
    }

    #if canImport(AVFoundation)
    private func keyframeThumbnail(url: URL, midMs: Int64) async throws -> VideoThumbnail {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: config.thumbnailMaxPixelSize, height: config.thumbnailMaxPixelSize)
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol
        let time = CMTime(seconds: Double(midMs) / 1000.0, preferredTimescale: 600)

        let cg = try await cgImage(generator: generator, for: time)

        let png = try Self.encodePNG(cg)
        return VideoThumbnail(data: png, format: .png, width: cg.width, height: cg.height)
    }
    #else
    private func keyframeThumbnail(url: URL, midMs: Int64) async throws -> VideoThumbnail {
        _ = url
        _ = midMs
        throw VideoIngestError.unsupportedPlatform(reason: "AVFoundation is unavailable on this platform")
    }
    #endif

    private func cgImage(generator: AVAssetImageGenerator, for time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, result, error in
                guard resumed.withLock({ state in
                    defer { state = true }
                    return !state
                }) else { return }
                switch result {
                case .succeeded:
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: WaxError.io("Video frame generation returned no image"))
                    }
                case .cancelled:
                    continuation.resume(throwing: WaxError.io("Video keyframe generation was cancelled"))
                case .failed:
                    continuation.resume(throwing: error ?? WaxError.io("Video keyframe generation failed"))
                @unknown default:
                    continuation.resume(throwing: WaxError.io("Video keyframe generation failed"))
                }
            }
        }
    }

    // MARK: - Pure helpers

    private static func dedupeIDs(_ ids: [String]) -> [String] {
        guard ids.count > 1 else { return ids }
        var seen: Set<String> = []
        seen.reserveCapacity(ids.count)
        var unique: [String] = []
        unique.reserveCapacity(ids.count)
        for id in ids where seen.insert(id).inserted {
            unique.append(id)
        }
        return unique
    }

    private static func dedupeFiles(_ files: [VideoFile]) -> [VideoFile] {
        guard files.count > 1 else { return files }
        var seen: Set<String> = []
        seen.reserveCapacity(files.count)
        var unique: [VideoFile] = []
        unique.reserveCapacity(files.count)
        for file in files where seen.insert(file.id).inserted {
            unique.append(file)
        }
        return unique
    }

    private static func toWaxTimeRange(_ range: ClosedRange<Date>?) -> TimeRange? {
        guard let range else { return nil }
        let after = Int64(range.lowerBound.timeIntervalSince1970 * 1000)
        let beforeInclusive = Int64(range.upperBound.timeIntervalSince1970 * 1000)
        
        // Handle unbounded ranges (e.g., Date...Date.distantFuture)
        // Check for very large dates that represent "no upper bound"
        let beforeExclusive: Int64
        if beforeInclusive > Int64.max - 1 {
            beforeExclusive = Int64.max
        } else {
            beforeExclusive = beforeInclusive + 1
        }
        return TimeRange(after: after, before: beforeExclusive)
    }

    private static func makeSegments(
        durationMs: Int64,
        segmentDurationSeconds: Double,
        segmentOverlapSeconds: Double,
        maxSegments: Int
    ) -> [SegmentPlan] {
        guard durationMs > 0 else { return [] }
        let segmentDurationMs = Int64(segmentDurationSeconds * 1000)
        let overlapMs = Int64(segmentOverlapSeconds * 1000)
        let strideMs = max(1, segmentDurationMs - overlapMs)
        guard segmentDurationMs > 0, maxSegments > 0 else { return [] }

        var segments: [SegmentPlan] = []
        segments.reserveCapacity(min(maxSegments, 64))

        var i = 0
        while i < maxSegments {
            let startMs = Int64(i) * strideMs
            if startMs >= durationMs { break }
            let endMs = min(startMs + segmentDurationMs, durationMs)
            let midMs = (startMs + endMs) / 2
            segments.append(SegmentPlan(startMs: startMs, endMs: endMs, midMs: midMs, index: i, count: 0))
            i += 1
        }

        let count = segments.count
        for idx in segments.indices {
            segments[idx].count = count
        }
        return segments
    }

    private static func mapTranscript(
        chunks: [VideoTranscriptChunk],
        segments: [SegmentPlan],
        maxBytes: Int
    ) -> [Int: String] {
        guard !chunks.isEmpty, !segments.isEmpty, maxBytes > 0 else { return [:] }

        let durationMs = max(0, segments.last?.endMs ?? 0)

        let normalized: [VideoTranscriptChunk] = chunks
            .compactMap { c in
                let t = c.text.trimmingCharacters(in: .whitespacesAndNewlines)
                guard !t.isEmpty else { return nil }
                let startMs = min(max(0, c.startMs), durationMs)
                let endMs = min(max(0, c.endMs), durationMs)
                let fixedEndMs = max(startMs, endMs)
                return VideoTranscriptChunk(startMs: startMs, endMs: fixedEndMs, text: t)
            }
            .sorted { a, b in
                if a.startMs != b.startMs { return a.startMs < b.startMs }
                if a.endMs != b.endMs { return a.endMs < b.endMs }
                return a.text < b.text
            }

        func overlapsAtLeast250ms(chunk: VideoTranscriptChunk, seg: SegmentPlan) -> Bool {
            let overlap = min(chunk.endMs, seg.endMs) - max(chunk.startMs, seg.startMs)
            return overlap >= 250
        }

        var out: [Int: String] = [:]
        out.reserveCapacity(segments.count)

        for seg in segments {
            // Binary search for first chunk that could overlap (chunk.startMs < seg.endMs)
            var lo = 0, hi = normalized.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if normalized[mid].endMs <= seg.startMs {
                    lo = mid + 1
                } else {
                    hi = mid
                }
            }
            let startIndex = lo

            var parts: [String] = []
            // Scan forward from startIndex until chunk.startMs >= seg.endMs
            for idx in startIndex..<normalized.count {
                let chunk = normalized[idx]
                if chunk.startMs >= seg.endMs { break }
                if overlapsAtLeast250ms(chunk: chunk, seg: seg) {
                    parts.append(chunk.text)
                }
            }

            guard !parts.isEmpty else { continue }
            let joined = parts.joined(separator: "\n")
            let capped = cappedUTF8(joined, maxBytes: maxBytes)
            if !capped.isEmpty {
                out[seg.index] = capped
            }
        }

        return out
    }

    private static func cappedUTF8(_ text: String, maxBytes: Int) -> String {
        guard maxBytes > 0 else { return "" }
        let data = Data(text.utf8)
        if data.count <= maxBytes { return text }
        var prefix = Data(data.prefix(maxBytes))
        while !prefix.isEmpty {
            if let s = String(data: prefix, encoding: .utf8) {
                return s
            }
            prefix.removeLast()
        }
        return ""
    }

    private static func firstLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.prefix(maxLines).joined(separator: "\n")
    }

    private static func buildSummaryText(rootMeta: FrameMeta, segments: [VideoSegmentHit], maxLinesPerSegment: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(max(1, segments.count))

        let hasTranscript = segments.contains { seg in
            let t = seg.transcriptSnippet?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return !t.isEmpty
        }

        if hasTranscript {
            for seg in segments {
                let label = "[\(formatMMSS(seg.startMs))–\(formatMMSS(seg.endMs))]"
                if let snippet = seg.transcriptSnippet, !snippet.isEmpty {
                    let lines = firstLines(snippet, maxLines: maxLinesPerSegment)
                    parts.append("\(label) \(lines)")
                } else {
                    parts.append("\(label)")
                }
            }
            return parts.joined(separator: "\n")
        }

        // Deterministic fallback summary using root metadata.
        let entries = rootMeta.metadata?.entries ?? [:]
        if let captureStr = entries[MetaKey.captureMs], let ms = Int64(captureStr) {
            let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            parts.append("Captured \(date.formatted(.iso8601))")
        }
        if let durationStr = entries[MetaKey.durationMs], let ms = Int64(durationStr) {
            parts.append("Duration \(formatMMSS(ms))")
        }
        if parts.isEmpty {
            return "Video context (no transcript)."
        }
        return parts.joined(separator: " • ")
    }

    private static func formatMMSS(_ ms: Int64) -> String {
        let totalSeconds = max(0, Int(ms / 1000))
        let minutes = totalSeconds / 60
        let seconds = totalSeconds % 60
        return String(format: "%02d:%02d", minutes, seconds)
    }

    private func baseMetadata(
        videoID: VideoID,
        captureMs: Int64,
        durationMs: Int64?,
        pipelineVersion: String,
        isLocal: Bool,
        fileURL: URL?
    ) -> Metadata {
        var meta = Metadata()
        meta.entries[MetaKey.source] = (videoID.source == .photos) ? "photos" : "file"
        meta.entries[MetaKey.sourceID] = videoID.id
        meta.entries[MetaKey.captureMs] = String(captureMs)
        if let durationMs {
            meta.entries[MetaKey.durationMs] = String(durationMs)
        }
        meta.entries[MetaKey.isLocal] = isLocal ? "true" : "false"
        meta.entries[MetaKey.pipelineVersion] = pipelineVersion
        if let fileURL {
            meta.entries[MetaKey.fileURL] = fileURL.absoluteString
        }
        return meta
    }
}
