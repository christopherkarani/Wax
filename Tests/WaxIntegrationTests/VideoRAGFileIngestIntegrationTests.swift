import Foundation
import Testing
import Wax

private struct TestVideoEmbedder: MultimodalEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 8
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(provider: "Test", model: "Multimodal", dimensions: 8, normalized: true)

    func embed(text: String) async throws -> [Float] {
        let hash = text.utf8.reduce(0) { $0 &+ Int($1) }
        let raw = (0..<dimensions).map { i in Float((hash &+ i) % 97) / 97.0 }
        return VectorMath.normalizeL2(raw)
    }

    func embed(image: CGImage) async throws -> [Float] {
        let hash = (image.width &* 31) &+ image.height
        let raw = (0..<dimensions).map { i in Float((hash &+ i &* 13) % 101) / 101.0 }
        return VectorMath.normalizeL2(raw)
    }
}

private struct TestTranscriptProvider: VideoTranscriptProvider {
    static let token = "INGEST_TOKEN"
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        _ = request
        return [
            .init(startMs: 0, endMs: 60_000, text: "\(Self.token) hello wax")
        ]
    }
}

@Test
func videoRAGFileIngestWritesSearchableTranscriptAndRecallFindsIt() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 2, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 60
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 1
        config.searchTopK = 20

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        try await rag.ingest(files: [VideoFile(id: "fixture", url: mp4Url, captureDate: nil)])
        try await rag.flush()

        let query = VideoQuery(
            text: TestTranscriptProvider.token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 5,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)

        #expect(ctx.items.count == 1)
        #expect(ctx.items.first?.summaryText.contains(TestTranscriptProvider.token) == true)
    }
}

@Test
func videoRAGFileIngestRecallWithThumbsIsDeterministic() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 4, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 1
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 2
        config.searchTopK = 30
        config.includeThumbnailsInContext = true

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        try await rag.ingest(files: [VideoFile(id: "fixture", url: mp4Url, captureDate: nil)])
        try await rag.flush()

        let query = VideoQuery(
            text: TestTranscriptProvider.token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 5,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 2, maxTranscriptLinesPerSegment: 2)
        )

        let first = try await rag.recall(query)
        let second = try await rag.recall(query)

        #expect(first == second)
        #expect(first.items.count == 1)
        #expect(first.items.first?.summaryText.contains(TestTranscriptProvider.token) == true)

        let firstThumbnails = first.items.flatMap(\.segments).compactMap(\.thumbnail)
        let secondThumbnails = second.items.flatMap(\.segments).compactMap(\.thumbnail)

        #expect(firstThumbnails == secondThumbnails)
        #expect(firstThumbnails.isEmpty == false)
    }
}

private struct SegmentScopedTranscriptProvider: VideoTranscriptProvider {
    static let token = "SEGMENT_TOKEN"
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        _ = request
        // Overlaps the second segment ([1s, 2s]) by 400ms, and the first segment by 0ms.
        return [
            .init(startMs: 1_200, endMs: 1_600, text: "\(Self.token) second segment only")
        ]
    }
}

private struct NetworkTranscriptProvider: VideoTranscriptProvider {
    var executionMode: ProviderExecutionMode { .mayUseNetwork }

    func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
        _ = request
        return []
    }
}

private struct OpposingLaneEmbedder: MultimodalEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = .init(provider: "Test", model: "OpposingLane", dimensions: 4, normalized: true)

    func embed(text: String) async throws -> [Float] {
        _ = text
        return VectorMath.normalizeL2([0, 1, 0, 0])
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return VectorMath.normalizeL2([1, 0, 0, 0])
    }
}

@Test
func videoRAGFileIngestRespectsCaptureTimeRangeForSegmentSearch() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 4, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 1
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 2
        config.searchTopK = 50

        let captureDate = Date(timeIntervalSince1970: 10)
        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: SegmentScopedTranscriptProvider()
        )

        try await rag.ingest(files: [VideoFile(id: "fixture", url: mp4Url, captureDate: captureDate)])
        try await rag.flush()

        let timeRange = captureDate...(captureDate.addingTimeInterval(0.5))
        let query = VideoQuery(
            text: SegmentScopedTranscriptProvider.token,
            timeRange: timeRange,
            videoIDs: nil,
            resultLimit: 5,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)

        #expect(ctx.items.count == 1)
        #expect(ctx.items.first?.summaryText.contains(SegmentScopedTranscriptProvider.token) == true)
    }
}

@Test
func videoRAGRejectsNetworkTranscriptProviderByDefault() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await VideoRAGOrchestrator(
                storeURL: url,
                config: .default,
                embedder: TestVideoEmbedder(),
                transcriptProvider: NetworkTranscriptProvider()
            )
            Issue.record("Expected WaxError for network transcript provider")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("on-device transcript provider"))
        }
    }
}

@Test
func videoRAGIngestFailureRollsBackPendingWritesBeforeFlush() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 2, fps: 2)
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 60
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 1
        config.searchTopK = 20
        config.ingestConcurrency = 2

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        do {
            try await rag.ingest(
                files: [
                    VideoFile(id: "valid", url: mp4Url, captureDate: nil),
                    VideoFile(id: "missing", url: missingURL, captureDate: nil),
                ]
            )
            Issue.record("Expected ingest failure for missing file")
        } catch {
            // Expected: one file is missing and should fail the ingest batch.
        }

        // Flush should not resurrect partially written frames from the failed ingest.
        try await rag.flush()

        let query = VideoQuery(
            text: TestTranscriptProvider.token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 5,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)
        #expect(ctx.items.isEmpty)
    }
}

@Test
func videoRAGFileIngestWithConcurrentEmbeddingIsDeterministic() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 6, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 1
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 3
        config.searchTopK = 50
        config.segmentEmbeddingConcurrency = 4
        config.keyframeExtractionBatchSize = 3

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        try await rag.ingest(files: [VideoFile(id: "fixture", url: mp4Url, captureDate: nil)])
        try await rag.flush()

        let query = VideoQuery(
            text: TestTranscriptProvider.token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 5,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )

        let first = try await rag.recall(query)
        let second = try await rag.recall(query)
        #expect(first == second)
    }
}

@Test
func videoRAGFileIngestSupportsBoundedConcurrentIngest() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 2, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 60
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 1
        config.searchTopK = 100
        config.ingestConcurrency = 2

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let files = (0..<10).map { index in
            VideoFile(
                id: "fixture-\(index)",
                url: mp4Url,
                captureDate: baseDate.addingTimeInterval(Double(index))
            )
        }

        try await rag.ingest(files: files)
        try await rag.flush()

        let query = VideoQuery(
            text: nil,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 20,
            segmentLimitPerVideo: 0,
            contextBudget: VideoContextBudget(maxTextTokens: 500, maxThumbnails: 0, maxTranscriptLinesPerSegment: 1)
        )
        let ctx = try await rag.recall(query)
        #expect(ctx.items.count == 10)
        #expect(Set(ctx.items.map(\.videoID.id)).count == 10)
    }
}

@Test
func videoRAGRecallTracksThumbnailUnavailableDiagnosticsForPhotosBackedItems() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await VideoRAGTestSupport.openWritableTextOnlySession(wax: wax)

        let captureMs: Int64 = 1_700_000_000_000
        var rootMeta = Metadata()
        rootMeta.entries[VideoMetadataKey.source.rawValue] = "photos"
        rootMeta.entries[VideoMetadataKey.sourceID.rawValue] = "photos-fixture"
        rootMeta.entries[VideoMetadataKey.captureMs.rawValue] = String(captureMs)
        rootMeta.entries[VideoMetadataKey.durationMs.rawValue] = "1000"
        rootMeta.entries[VideoMetadataKey.isLocal.rawValue] = "false"
        rootMeta.entries[VideoMetadataKey.pipelineVersion.rawValue] = "test"

        let rootId = try await session.put(
            Data(),
            options: FrameMetaSubset(kind: VideoFrameKind.root.rawValue, metadata: rootMeta),
            compression: .plain,
            timestampMs: captureMs
        )

        var segMeta = rootMeta
        segMeta.entries[VideoMetadataKey.segmentIndex.rawValue] = "0"
        segMeta.entries[VideoMetadataKey.segmentCount.rawValue] = "1"
        segMeta.entries[VideoMetadataKey.segmentStartMs.rawValue] = "0"
        segMeta.entries[VideoMetadataKey.segmentEndMs.rawValue] = "1000"
        segMeta.entries[VideoMetadataKey.segmentMidMs.rawValue] = "500"

        let token = "PHOTOS_THUMBNAIL_TOKEN"
        let segmentId = try await session.put(
            Data(token.utf8),
            options: FrameMetaSubset(kind: VideoFrameKind.segment.rawValue, role: .blob, parentId: rootId, metadata: segMeta),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: segmentId, text: token)

        try await session.commit()
        await session.close()
        try await wax.close()

        var config = VideoRAGConfig.default
        config.searchTopK = 20
        config.includeThumbnailsInContext = true

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: nil
        )

        let query = VideoQuery(
            text: token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 1,
            segmentLimitPerVideo: 1,
            contextBudget: VideoContextBudget(maxTextTokens: 120, maxThumbnails: 1, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)
        #expect(ctx.items.count == 1)
        #expect(ctx.diagnostics.thumbnailRequestedCount == 1)
        #expect(ctx.diagnostics.thumbnailAttachedCount == 0)
        #expect(ctx.diagnostics.thumbnailUnavailableCount == 1)
    }
}

@Test
func videoRAGThumbnailBudgetDoesNotConsumeOnUnavailableBeforeFileBackedItems() async throws {
    try await TempFiles.withTempFile { url in
        let token = "MIXED_THUMB_BUDGET_TOKEN"
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }
        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 2, fps: 2)

        // Seed a photos-backed root first so it has a lower rootId than the file-backed ingest.
        do {
            let wax = try await Wax.create(at: url)
            let session = try await VideoRAGTestSupport.openWritableTextOnlySession(wax: wax)
            let captureMs: Int64 = 1_700_000_000_000
            var rootMeta = Metadata()
            rootMeta.entries[VideoMetadataKey.source.rawValue] = "photos"
            rootMeta.entries[VideoMetadataKey.sourceID.rawValue] = "photos-first"
            rootMeta.entries[VideoMetadataKey.captureMs.rawValue] = String(captureMs)
            rootMeta.entries[VideoMetadataKey.durationMs.rawValue] = "1000"
            rootMeta.entries[VideoMetadataKey.isLocal.rawValue] = "false"
            rootMeta.entries[VideoMetadataKey.pipelineVersion.rawValue] = "test"

            let rootId = try await session.put(
                Data(),
                options: FrameMetaSubset(kind: VideoFrameKind.root.rawValue, metadata: rootMeta),
                compression: .plain,
                timestampMs: captureMs
            )

            var segMeta = rootMeta
            segMeta.entries[VideoMetadataKey.segmentIndex.rawValue] = "0"
            segMeta.entries[VideoMetadataKey.segmentCount.rawValue] = "1"
            segMeta.entries[VideoMetadataKey.segmentStartMs.rawValue] = "0"
            segMeta.entries[VideoMetadataKey.segmentEndMs.rawValue] = "1000"
            segMeta.entries[VideoMetadataKey.segmentMidMs.rawValue] = "500"

            let segmentId = try await session.put(
                Data("\(token) \(token) \(token)".utf8),
                options: FrameMetaSubset(kind: VideoFrameKind.segment.rawValue, role: .blob, parentId: rootId, metadata: segMeta),
                compression: .plain,
                timestampMs: captureMs
            )
            try await session.indexText(frameId: segmentId, text: token)
            try await session.commit()
            await session.close()
            try await wax.close()
        }

        struct FixedTokenTranscriptProvider: VideoTranscriptProvider {
            let executionMode: ProviderExecutionMode = .onDeviceOnly
            let token: String

            func transcript(for request: VideoTranscriptRequest) async throws -> [VideoTranscriptChunk] {
                _ = request
                return [.init(startMs: 0, endMs: 60_000, text: token)]
            }
        }

        var config = VideoRAGConfig.default
        config.searchTopK = 50
        config.segmentDurationSeconds = 60
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 1
        config.hybridAlpha = 1.0
        config.includeThumbnailsInContext = true

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: FixedTokenTranscriptProvider(token: token)
        )
        try await rag.ingest(files: [VideoFile(id: "file-second", url: mp4Url, captureDate: nil)])
        try await rag.flush()

        let query = VideoQuery(
            text: token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 2,
            segmentLimitPerVideo: 1,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 1, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)

        #expect(ctx.items.count == 2)
        #expect(ctx.items.first?.videoID.source == .photos)
        let fileItem = ctx.items.first(where: { $0.videoID.source == .file })
        #expect(fileItem != nil)
        #expect(fileItem?.segments.first?.thumbnail != nil)
        #expect(ctx.diagnostics.thumbnailRequestedCount == 2)
        #expect(ctx.diagnostics.thumbnailAttachedCount == 1)
        #expect(ctx.diagnostics.thumbnailUnavailableCount == 1)
    }
}

@Test
func videoRAGConfigIncludeThumbnailsFalseProducesNoThumbnails() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 2, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 60
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 1
        config.searchTopK = 20
        config.includeThumbnailsInContext = false  // thumbnails disabled

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        try await rag.ingest(files: [VideoFile(id: "fixture", url: mp4Url, captureDate: nil)])
        try await rag.flush()

        let query = VideoQuery(
            text: TestTranscriptProvider.token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 5,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 5, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)
        #expect(ctx.items.count >= 1)

        let allSegments = ctx.items.flatMap(\.segments)
        #expect(allSegments.allSatisfy { $0.thumbnail == nil },
                "No thumbnails when includeThumbnailsInContext=false")
    }
}

@Test
func videoRAGFileIngestQueryWithVideoIDFilterReturnsOnlyMatchingVideos() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 2, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 60
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 1
        config.searchTopK = 50
        config.ingestConcurrency = 2

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        // Ingest two different video files with different IDs
        let baseDate = Date(timeIntervalSince1970: 1_700_000_000)
        let files = [
            VideoFile(id: "video-alpha", url: mp4Url, captureDate: baseDate),
            VideoFile(id: "video-beta", url: mp4Url, captureDate: baseDate.addingTimeInterval(1))
        ]
        try await rag.ingest(files: files)
        try await rag.flush()

        // Query filtering to only "video-alpha"
        let query = VideoQuery(
            text: nil,
            timeRange: nil,
            videoIDs: [VideoID(source: .file, id: "video-alpha")],
            resultLimit: 10,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 300, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)
        let videoIDs = Set(ctx.items.map(\.videoID.id))
        #expect(videoIDs == ["video-alpha"], "Only video-alpha should be returned when filtered")
    }
}

@Test
func videoRAGDiagnosticsThumbnailCountsForFileBacked() async throws {
    try await TempFiles.withTempFile { url in
        let mp4Url = FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mp4")
        defer { try? FileManager.default.removeItem(at: mp4Url) }

        try await VideoRAGTestVideoGenerator.writeTinyMP4(to: mp4Url, width: 32, height: 32, frameCount: 4, fps: 2)

        var config = VideoRAGConfig.default
        config.segmentDurationSeconds = 1
        config.segmentOverlapSeconds = 0
        config.maxSegmentsPerVideo = 2
        config.searchTopK = 30
        config.includeThumbnailsInContext = true

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: TestVideoEmbedder(),
            transcriptProvider: TestTranscriptProvider()
        )

        try await rag.ingest(files: [VideoFile(id: "fixture", url: mp4Url, captureDate: nil)])
        try await rag.flush()

        let query = VideoQuery(
            text: TestTranscriptProvider.token,
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 5,
            segmentLimitPerVideo: 5,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 5, maxTranscriptLinesPerSegment: 2)
        )
        let ctx = try await rag.recall(query)
        #expect(ctx.items.count >= 1)
        // For file-backed videos, thumbnails are available (not photos-backed)
        #expect(ctx.diagnostics.thumbnailUnavailableCount == 0,
                "File-backed videos should have available thumbnails")
        #expect(ctx.diagnostics.thumbnailRequestedCount >= 1,
                "Should have requested at least one thumbnail")
    }
}

@Test
func videoRAGRecallBreaksEqualScoreTiesByRootID() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let sessionConfig = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: true,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: 4
        )
        let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        let captureMs: Int64 = 1_700_000_000_000
        let zetaID = VideoID(source: .file, id: "zeta")
        let alphaID = VideoID(source: .file, id: "alpha")

        let zetaRoot = try await VideoRAGTestSupport.putRoot(
            session: session,
            videoID: zetaID,
            captureTimestampMs: captureMs
        )
        let alphaRoot = try await VideoRAGTestSupport.putRoot(
            session: session,
            videoID: alphaID,
            captureTimestampMs: captureMs
        )

        func putSegmentWithEmbedding(
            rootId: UInt64,
            videoID: VideoID,
            transcript: String,
            embedding: [Float]
        ) async throws {
            var meta = Metadata()
            meta.entries[VideoMetadataKey.source.rawValue] = "file"
            meta.entries[VideoMetadataKey.sourceID.rawValue] = videoID.id
            meta.entries[VideoMetadataKey.captureMs.rawValue] = String(captureMs)
            meta.entries[VideoMetadataKey.isLocal.rawValue] = "true"
            meta.entries[VideoMetadataKey.pipelineVersion.rawValue] = "test"
            meta.entries[VideoMetadataKey.segmentIndex.rawValue] = "0"
            meta.entries[VideoMetadataKey.segmentCount.rawValue] = "1"
            meta.entries[VideoMetadataKey.segmentStartMs.rawValue] = "0"
            meta.entries[VideoMetadataKey.segmentEndMs.rawValue] = "1000"
            meta.entries[VideoMetadataKey.segmentMidMs.rawValue] = "500"

            let frameId = try await session.put(
                Data(transcript.utf8),
                embedding: embedding,
                identity: nil,
                options: FrameMetaSubset(kind: VideoFrameKind.segment.rawValue, role: .blob, parentId: rootId, metadata: meta),
                compression: .plain,
                timestampMs: captureMs
            )
            try await session.indexText(frameId: frameId, text: transcript)
        }

        // Both segments have identical transcripts and embeddings so RRF scores are equal.
        // Tie-break fires by rootId (ascending). zetaRoot was inserted first so it has
        // a lower rootId than alphaRoot, giving order ["zeta", "alpha"].
        let tieTranscript = "apple token"
        let tieEmbedding = VectorMath.normalizeL2([0, 1, 0, 0])
        try await putSegmentWithEmbedding(
            rootId: zetaRoot,
            videoID: zetaID,
            transcript: tieTranscript,
            embedding: tieEmbedding
        )
        try await putSegmentWithEmbedding(
            rootId: alphaRoot,
            videoID: alphaID,
            transcript: tieTranscript,
            embedding: tieEmbedding
        )

        try await session.commit()
        await session.close()
        try await wax.close()

        var config = VideoRAGConfig.default
        config.searchTopK = 10

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: OpposingLaneEmbedder(),
            transcriptProvider: nil
        )

        let ctx = try await rag.recall(
            VideoQuery(
                text: "apple token",
                timeRange: nil,
                videoIDs: nil,
                resultLimit: 2,
                segmentLimitPerVideo: 1,
                contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 0, maxTranscriptLinesPerSegment: 1)
            )
        )

        #expect(ctx.items.count == 2)
        #expect(abs(ctx.items[0].score - ctx.items[1].score) < 0.001)
        #expect(ctx.items.map(\.videoID.id) == ["zeta", "alpha"])
    }
}
