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

extension VideoRAGOrchestrator {
    // MARK: - Recall

    package func recall(_ query: VideoQuery) async throws -> VideoRAGContext {
        let cleanedText = query.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = (cleanedText?.isEmpty == false) ? cleanedText : nil

        let queryEmbedding = try await buildQueryEmbedding(text: queryText)
        let isConstraintOnly = (queryText == nil && queryEmbedding == nil)

        let resolvedMode: SearchMode = {
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
        let lane = try SearchLane.from(mode: resolvedMode, embedding: queryEmbedding)

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

        let request = try SearchRequest(
            query: queryText,
            lane: lane,
            vectorEnginePreference: config.vectorEnginePreference,
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
            if FrameKind(rawKind: rootMeta.kind) != .video(.root) { continue }
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
            if FrameKind(rawKind: meta.kind) == .video(.segment) {
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
        let transcriptUnavailableCount = itemsWithThumbs.filter { isTranscriptUnavailable(videoID: $0.videoID) }.count
        let diagnostics = VideoRAGContext.Diagnostics(
            usedTextTokens: usedTokens,
            degradedVideoCount: degradedCount,
            transcriptUnavailableVideoCount: transcriptUnavailableCount
        )
        return VideoRAGContext(query: query, items: itemsWithThumbs, diagnostics: diagnostics)
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

    private static func toWaxTimeRange(_ range: ClosedRange<Date>?) -> SearchTimeRange? {
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
        return SearchTimeRange(after: after, before: beforeExclusive)
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
}

#endif // canImport(ImageIO)
