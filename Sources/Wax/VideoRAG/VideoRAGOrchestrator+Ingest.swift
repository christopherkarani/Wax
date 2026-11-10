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
    #if canImport(Photos)
    /// Sync the Photos library videos into the local Wax store.
    ///
    /// Offline-only: iCloud-only assets are indexed as metadata-only and marked degraded.
    package func syncLibrary(scope: VideoScope) async throws {
        let ids: [String] = switch scope {
        case .assetIDs(let ids):
            ids.map(\.id)
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
        try await ingestMutex.withLock {
            try await self.ingest(photoAssetIDs: ids)
        }
    }
    #endif

    /// Ingest local file videos.
    package func ingest(files: [VideoFile]) async throws {
        try await ingestMutex.withLock {
            try await self.ingestUnderLock(files: files)
        }
    }

    /// Caller holds `ingestMutex`: each tree reads its previous root from the index, so a second
    /// ingest must not start writing until the first has committed and rebuilt it.
    private func ingestUnderLock(files: [VideoFile]) async throws {
        let unique = Self.dedupeFiles(files)
        guard !unique.isEmpty else { return }

        do {
            for file in unique {
                try Task.checkCancellation()
                try await ingestOneFile(file)
            }
        } catch {
            await reconcileAfterFailedIngest()
            throw error
        }

        try await session.commit()
        try await rebuildIndex()
    }

    #if canImport(Photos)
    /// Caller holds `ingestMutex`; see ``ingestUnderLock(files:)``.
    private func ingest(photoAssetIDs: [String]) async throws {
        let unique = Self.dedupeIDs(photoAssetIDs)
        guard !unique.isEmpty else { return }

        do {
            for assetID in unique {
                try await ingestOnePhoto(assetID: assetID)
            }
        } catch {
            await reconcileAfterFailedIngest()
            throw error
        }

        try await session.commit()
        try await rebuildIndex()
    }
    #endif

    // MARK: - Ingest internals

    private func ingestOneFile(_ file: VideoFile) async throws {
        var newRootId: UInt64?
        do {
            try await ingestTree(file: file, newRootId: &newRootId)
        } catch {
            if let newRootId { await discardPartialTree(rootId: newRootId) }
            throw error
        }
    }

    /// Writes a new tree for `file`. `newRootId` holds the new root from the moment it is
    /// written until it supersedes the previous version, so a failure in between can discard it.
    private func ingestTree(file: VideoFile, newRootId: inout UInt64?) async throws {
        guard file.url.isFileURL else {
            throw VideoIngestError.invalidVideo(reason: "file URL must be a file:// URL")
        }
        guard FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)) else {
            throw VideoIngestError.fileMissing(id: file.id, url: file.url)
        }

        let videoID = file.id
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

        let transcript = try await loadTranscript(
            videoID: videoID,
            localFileURL: file.url,
            durationMs: durationMs
        )
        let transcriptByIndex = Self.mapTranscript(chunks: transcript.chunks, segments: segments, maxBytes: config.maxTranscriptBytesPerSegment)

        var rootMeta = baseMetadata(
            videoID: videoID,
            captureMs: captureMs,
            durationMs: durationMs,
            pipelineVersion: config.pipelineVersion,
            isLocal: true,
            fileURL: file.url
        )
        if transcript.unavailable {
            rootMeta.entries[MetaKey.transcriptStatus] = Self.transcriptUnavailable
        }
        let rootOptions = FrameMetaSubset(kind: VideoFrameKind.root.rawValue, metadata: rootMeta)
        let rootId = try await session.put(Data(), options: rootOptions, compression: .plain, timestampMs: captureMs)
        newRootId = rootId

        // Segment frames (embedded + optional transcript payload)
        try await writeSegments(
            rootId: rootId,
            videoID: videoID,
            captureMs: captureMs,
            segments: segments,
            keyframes: keyframeImages,
            transcriptByIndex: transcriptByIndex
        )
        try await indexRolledUpTranscript(rootId: rootId, transcriptByIndex: transcriptByIndex)

        if let previousRoot {
            try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
            newRootId = nil
            try await removeVectorsForRetiredTree(previousRoot, videoID: videoID)
        }
    }

    #if canImport(Photos)
    private func ingestOnePhoto(assetID: String) async throws {
        var newRootId: UInt64?
        do {
            try await ingestTree(assetID: assetID, newRootId: &newRootId)
        } catch {
            if let newRootId { await discardPartialTree(rootId: newRootId) }
            throw error
        }
    }

    /// Writes a new tree for a Photos video; `newRootId` follows the same contract as in
    /// ``ingestTree(file:newRootId:)``.
    private func ingestTree(assetID: String, newRootId: inout UInt64?) async throws {
        let videoID = VideoID(source: .photos, id: assetID)
        let previousRoot = index.rootByVideoID[videoID]

        let record = try await Self.loadPhotosVideo(assetID: assetID)
        let captureMs = record.captureMs ?? Int64(Date().timeIntervalSince1970 * 1000)

        let durationMs: Int64
        let segments: [SegmentPlan]
        let keyframes: [CGImage]
        let transcriptByIndex: [Int: String]
        let transcriptUnavailable: Bool

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

            let transcript = try await loadTranscript(
                videoID: videoID,
                localFileURL: url,
                durationMs: durationMs
            )
            transcriptByIndex = Self.mapTranscript(chunks: transcript.chunks, segments: segments, maxBytes: config.maxTranscriptBytesPerSegment)
            transcriptUnavailable = transcript.unavailable
        } else {
            durationMs = record.durationMs
            segments = []
            keyframes = []
            transcriptByIndex = [:]
            transcriptUnavailable = false
        }

        var rootMeta = baseMetadata(
            videoID: videoID,
            captureMs: captureMs,
            durationMs: durationMs,
            pipelineVersion: config.pipelineVersion,
            isLocal: record.isLocal,
            fileURL: record.localFileURL
        )
        if transcriptUnavailable {
            rootMeta.entries[MetaKey.transcriptStatus] = Self.transcriptUnavailable
        }
        let rootOptions = FrameMetaSubset(kind: VideoFrameKind.root.rawValue, metadata: rootMeta)
        let rootId = try await session.put(Data(), options: rootOptions, compression: .plain, timestampMs: captureMs)
        newRootId = rootId

        if record.isLocal {
            try await writeSegments(
                rootId: rootId,
                videoID: videoID,
                captureMs: captureMs,
                segments: segments,
                keyframes: keyframes,
                transcriptByIndex: transcriptByIndex
            )
            try await indexRolledUpTranscript(rootId: rootId, transcriptByIndex: transcriptByIndex)
        }

        if let previousRoot {
            try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
            newRootId = nil
            try await removeVectorsForRetiredTree(previousRoot, videoID: videoID)
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

            let subset = FrameMetaSubset(kind: VideoFrameKind.segment.rawValue, role: .blob, parentId: rootId, metadata: meta)
            options.append(subset)
        }

        // Capture-time semantics: segment frames share the video's capture timestamp so
        // `VideoQuery.timeRange` behaves as a capture-time filter.
        let timestamps = Array(repeating: captureMs, count: segments.count)
        let batchSize = max(1, config.segmentWriteBatchSize)
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

    /// Indexes the concatenated transcript on the video root so a query that
    /// spans multiple segments (AND of all tokens) can still retrieve the clip.
    /// Segment frames keep their per-window text for timestamped hits.
    private func indexRolledUpTranscript(rootId: UInt64, transcriptByIndex: [Int: String]) async throws {
        let joined = transcriptByIndex.keys.sorted()
            .compactMap { transcriptByIndex[$0]?.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        guard !joined.isEmpty else { return }
        try await session.indexText(frameId: rootId, text: joined)
    }

    private static let transcriptUnavailable = "unavailable"

    /// Loads host-supplied transcript chunks. A provider failure degrades this video to
    /// frame-only indexing instead of failing the whole ingest: the root frame is tagged
    /// `video.transcript.status = unavailable` and recall reports it in
    /// `VideoRAGContext.Diagnostics.transcriptUnavailableVideoCount`. Cancellation propagates.
    private func loadTranscript(
        videoID: VideoID,
        localFileURL: URL,
        durationMs: Int64
    ) async throws -> (chunks: [VideoTranscriptChunk], unavailable: Bool) {
        guard let provider = transcriptProvider else { return ([], false) }
        let request = VideoTranscriptRequest(videoID: videoID, localFileURL: localFileURL, durationMs: durationMs)
        do {
            return (try await provider.transcript(for: request), false)
        } catch {
            if error is CancellationError || Task.isCancelled {
                throw CancellationError()
            }
            WaxDiagnostics.logSwallowed(
                error,
                context: "VideoRAG transcript provider",
                fallback: "ingesting keyframes without transcript text"
            )
            return ([], true)
        }
    }

    func isTranscriptUnavailable(videoID: VideoID) -> Bool {
        index.rootMetaByVideoID[videoID]?.metadata?.entries[MetaKey.transcriptStatus] == Self.transcriptUnavailable
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
        var seen: Set<VideoID> = []
        seen.reserveCapacity(files.count)
        var unique: [VideoFile] = []
        unique.reserveCapacity(files.count)
        for file in files where seen.insert(file.id).inserted {
            unique.append(file)
        }
        return unique
    }

    static func makeSegments(
        durationMs: Int64,
        segmentDurationSeconds: Double,
        segmentOverlapSeconds: Double,
        maxSegments: Int
    ) -> [SegmentPlan] {
        guard durationMs > 0 else { return [] }
        let segmentDurationMs = milliseconds(fromSeconds: segmentDurationSeconds)
        let overlapMs = milliseconds(fromSeconds: segmentOverlapSeconds)
        let strideMs = max(1, segmentDurationMs - overlapMs)
        guard segmentDurationMs > 0, maxSegments > 0 else { return [] }

        var segments: [SegmentPlan] = []
        segments.reserveCapacity(min(maxSegments, 64))

        var i = 0
        var startMs: Int64 = 0
        while i < maxSegments {
            if startMs >= durationMs { break }
            let endMs = startMs + min(segmentDurationMs, durationMs - startMs)
            let midMs = startMs + (endMs - startMs) / 2
            segments.append(SegmentPlan(startMs: startMs, endMs: endMs, midMs: midMs, index: i, count: 0))
            let (nextStartMs, overflow) = startMs.addingReportingOverflow(strideMs)
            if overflow { break }
            startMs = nextStartMs
            i += 1
        }

        let count = segments.count
        for idx in segments.indices {
            segments[idx].count = count
        }
        return segments
    }

    /// Config seconds to whole milliseconds without trapping: NaN and non-positive values
    /// become 0, and values past `Int64.max` milliseconds (including infinity) saturate.
    private static func milliseconds(fromSeconds seconds: Double) -> Int64 {
        let milliseconds = seconds * 1000
        guard milliseconds > 0 else { return 0 }
        guard milliseconds < Double(Int64.max) else { return Int64.max }
        return Int64(milliseconds)
    }

    static func mapTranscript(
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

        // Chunks are sorted by startMs, so endMs is not monotonic (a long chunk can end after
        // later, shorter ones). The running maximum of endMs is monotonic and lets a binary
        // search skip exactly the prefix of chunks that all end before a segment starts.
        var maxEndMsThrough: [Int64] = []
        maxEndMsThrough.reserveCapacity(normalized.count)
        for chunk in normalized {
            maxEndMsThrough.append(max(maxEndMsThrough.last ?? chunk.endMs, chunk.endMs))
        }

        var out: [Int: String] = [:]
        out.reserveCapacity(segments.count)

        for seg in segments {
            // Binary search for the first chunk whose prefix may still overlap the segment.
            var lo = 0, hi = normalized.count
            while lo < hi {
                let mid = (lo + hi) / 2
                if maxEndMsThrough[mid] <= seg.startMs {
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

    static func firstLines(_ text: String, maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        let lines = text.split(whereSeparator: \.isNewline)
        return lines.prefix(maxLines).joined(separator: "\n")
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

#endif // canImport(ImageIO)
