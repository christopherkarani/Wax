import CoreGraphics
import Foundation
import Testing
@testable import Wax

// MARK: - Shared test stubs

private struct StubEmbedder: MultimodalEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(provider: "stub", model: "stub", dimensions: 4, normalized: true)

    func embed(text: String) async throws -> [Float] { [1, 0, 0, 0] }
    func embed(image: CGImage) async throws -> [Float] { [0, 1, 0, 0] }
}

private struct NetworkEmbedder: MultimodalEmbeddingProvider {
    var executionMode: ProviderExecutionMode { .mayUseNetwork }
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = nil

    func embed(text: String) async throws -> [Float] { [1, 0, 0, 0] }
    func embed(image: CGImage) async throws -> [Float] { [0, 1, 0, 0] }
}

private struct NetworkCaptionProvider: CaptionProvider {
    var executionMode: ProviderExecutionMode { .mayUseNetwork }

    func caption(for image: CGImage) async throws -> String { "caption" }
}

// MARK: - PhotoRAG init validation

@Test
func photoRAGRejectsNetworkEmbedderByDefault() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await PhotoRAGOrchestrator(
                storeURL: url,
                config: .default,
                embedder: NetworkEmbedder()
            )
            Issue.record("Expected WaxError for network embedding provider")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("on-device embedding provider"))
        }
    }
}

@Test
func photoRAGRejectsNetworkCaptionProviderByDefault() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await PhotoRAGOrchestrator(
                storeURL: url,
                config: .default,
                embedder: StubEmbedder(),
                captioner: NetworkCaptionProvider()
            )
            Issue.record("Expected WaxError for network caption provider")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("on-device caption provider"))
        }
    }
}

// MARK: - VideoRAG init validation

@Test
func videoRAGRejectsNetworkEmbedderByDefault() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await VideoRAGOrchestrator(
                storeURL: url,
                config: .default,
                embedder: NetworkEmbedder()
            )
            Issue.record("Expected WaxError for network embedding provider")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("on-device embedding provider"))
        }
    }
}

// MARK: - PhotoRAG delete

@Test
func photoRAGDeleteRemovesAssetFrames() async throws {
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

        var metaA = Metadata()
        metaA.entries["photos.asset_id"] = "A"
        metaA.entries["photo.capture_ms"] = String(captureMs)
        _ = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaA),
            compression: .plain,
            timestampMs: captureMs
        )

        var metaB = Metadata()
        metaB.entries["photos.asset_id"] = "B"
        metaB.entries["photo.capture_ms"] = String(captureMs)
        _ = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaB),
            compression: .plain,
            timestampMs: captureMs
        )

        try await session.commit()
        await session.close()
        try await wax.close()

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: StubEmbedder()
        )

        // Delete asset A
        try await orchestrator.delete(assetID: "A")

        // Recall should only find asset B
        let query = PhotoQuery(
            text: nil,
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 10,
            contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        )

        let ctx = try await orchestrator.recall(query)
        let assetIDs = ctx.items.map(\.assetID)
        #expect(!assetIDs.contains("A"))
        try await orchestrator.flush()
    }
}

// MARK: - PhotoRAG dedupeAssetIDs edge cases

@Test
func photoRAGDedupeEmptyArrayReturnsEmpty() {
    let output = PhotoRAGOrchestrator.dedupeAssetIDs([])
    #expect(output.isEmpty)
}

@Test
func photoRAGDedupeSingleElementReturnsSame() {
    let output = PhotoRAGOrchestrator.dedupeAssetIDs(["X"])
    #expect(output == ["X"])
}

@Test
func photoRAGDedupePreservesOrderOfFirstOccurrence() {
    let input = ["C", "A", "B", "A", "C"]
    let output = PhotoRAGOrchestrator.dedupeAssetIDs(input)
    #expect(output == ["C", "A", "B"])
}

// MARK: - VideoRAG segment range calculation

@Test
func videoRAGSegmentRangesForShortVideo() {
    let ranges = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 5_000,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 0,
        maxSegments: 10
    )
    // 5s video with 10s segments: should produce exactly 1 segment covering [0, 5000]
    #expect(ranges.count == 1)
    #expect(ranges[0].startMs == 0)
    #expect(ranges[0].endMs == 5_000)
}

@Test
func videoRAGSegmentRangesForExactFit() {
    let ranges = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 10_000,
        segmentDurationSeconds: 5,
        segmentOverlapSeconds: 0,
        maxSegments: 10
    )
    // 10s video with 5s segments, no overlap: should produce 2 segments
    #expect(ranges.count == 2)
    #expect(ranges[0].startMs == 0)
    #expect(ranges[0].endMs == 5_000)
    #expect(ranges[1].startMs == 5_000)
    #expect(ranges[1].endMs == 10_000)
}

@Test
func videoRAGSegmentRangesWithOverlap() {
    let ranges = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 15_000,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 5,
        maxSegments: 100
    )
    // Stride = 10s - 5s = 5s. With 15s duration: starts at 0, 5, 10 -> 3 segments
    #expect(ranges.count == 3)
    #expect(ranges[0].startMs == 0)
    #expect(ranges[0].endMs == 10_000)
    #expect(ranges[1].startMs == 5_000)
    #expect(ranges[1].endMs == 15_000)
    #expect(ranges[2].startMs == 10_000)
    #expect(ranges[2].endMs == 15_000)
}

@Test
func videoRAGSegmentRangesRespectsMaxSegments() {
    let ranges = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 600_000,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 0,
        maxSegments: 3
    )
    // 600s video, 10s segments, max 3
    #expect(ranges.count == 3)
}

@Test
func videoRAGSegmentRangesZeroDurationReturnsEmpty() {
    let ranges = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 0,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 0,
        maxSegments: 10
    )
    #expect(ranges.isEmpty)
}

// MARK: - VideoRAG delete

@Test
func videoRAGDeleteRemovesVideoFrames() async throws {
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
            embedder: StubEmbedder()
        )

        try await rag.ingest(files: [VideoFile(id: "fixture", url: mp4Url, captureDate: nil)])
        try await rag.flush()

        // Delete the video
        let videoID = VideoID(source: .file, id: "fixture")
        try await rag.delete(videoID: videoID)

        // Recall should return no results
        let query = VideoQuery(
            text: nil,
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

// MARK: - VideoRAG empty files ingest

@Test
func videoRAGIngestEmptyFilesArrayIsNoOp() async throws {
    try await TempFiles.withTempFile { url in
        var config = VideoRAGConfig.default
        config.requireOnDeviceProviders = false

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: StubEmbedder()
        )

        // Ingest empty array should not throw
        try await rag.ingest(files: [])
        try await rag.flush()
    }
}

// MARK: - VideoRAG missing file throws

@Test
func videoRAGIngestMissingFileThrows() async throws {
    try await TempFiles.withTempFile { url in
        var config = VideoRAGConfig.default
        config.requireOnDeviceProviders = false

        let rag = try await VideoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: StubEmbedder()
        )

        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("nonexistent_\(UUID().uuidString).mp4")

        do {
            try await rag.ingest(files: [VideoFile(id: "missing", url: missingURL, captureDate: nil)])
            Issue.record("Expected error for missing video file")
        } catch let error as VideoIngestError {
            guard case let .fileMissing(id, _) = error else {
                Issue.record("Expected .fileMissing, got \(error)")
                return
            }
            #expect(id == "missing")
        }
    }
}

// MARK: - FastRAGContextBuilder.validateExpansionPayloadSize

@Test
func validateExpansionPayloadSizeAcceptsMatchingSize() throws {
    // Should not throw for matching sizes within cap
    try FastRAGContextBuilder.validateExpansionPayloadSize(
        expectedBytes: 100,
        actualBytes: 100,
        maxBytes: 200
    )
}

@Test
func validateExpansionPayloadSizeRejectsOversizedPayload() {
    do {
        try FastRAGContextBuilder.validateExpansionPayloadSize(
            expectedBytes: 100,
            actualBytes: 300,
            maxBytes: 200
        )
        Issue.record("Expected error for oversized payload")
    } catch {
        // Expected: expansion payload exceeds cap
    }
}

@Test
func validateExpansionPayloadSizeRejectsMismatch() {
    do {
        try FastRAGContextBuilder.validateExpansionPayloadSize(
            expectedBytes: 100,
            actualBytes: 80,
            maxBytes: 200
        )
        Issue.record("Expected error for payload length mismatch")
    } catch {
        // Expected: payload length mismatch
    }
}

@Test
func validateExpansionPayloadSizeZeroMaxBytesIsNoOp() throws {
    // maxBytes=0 is a no-op guard
    try FastRAGContextBuilder.validateExpansionPayloadSize(
        expectedBytes: 100,
        actualBytes: 300,
        maxBytes: 0
    )
}

// MARK: - PhotoRAG recall empty store

@Test
func photoRAGRecallOnEmptyStoreReturnsEmptyContext() async throws {
    try await TempFiles.withTempFile { url in
        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.vectorEnginePreference = .cpuOnly

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: StubEmbedder()
        )

        let query = PhotoQuery(
            text: "anything",
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: ContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(ctx.items.isEmpty)
        #expect(ctx.diagnostics.usedTextTokens == 0)
        try await orchestrator.flush()
    }
}

// MARK: - Wax.putBatch count mismatch throws

@Test
func waxPutBatchContentOptionsMismatchThrows() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        do {
            _ = try await wax.putBatch(
                [Data("a".utf8), Data("b".utf8)],
                options: [FrameMetaSubset(kind: "a")]
            )
            Issue.record("Expected error for contents/options count mismatch")
        } catch {
            // Expected: putBatch contents.count != options.count
        }

        try await wax.close()
    }
}

@Test
func waxPutBatchTimestampMismatchThrows() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        do {
            _ = try await wax.putBatch(
                [Data("a".utf8), Data("b".utf8)],
                options: [FrameMetaSubset(kind: "a"), FrameMetaSubset(kind: "b")],
                timestampsMs: [1000]
            )
            Issue.record("Expected error for contents/timestamps count mismatch")
        } catch {
            // Expected: putBatch contents.count != timestampsMs.count
        }

        try await wax.close()
    }
}

// MARK: - Wax.putBatch empty array

@Test
func waxPutBatchEmptyArrayReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)

        let ids = try await wax.putBatch([], options: [])
        #expect(ids.isEmpty)

        try await wax.close()
    }
}

// MARK: - PDFIngestError localized descriptions

#if canImport(PDFKit)
@Test
func pdfIngestErrorFileNotFoundDescription() {
    let url = URL(fileURLWithPath: "/tmp/test.pdf")
    let error = PDFIngestError.fileNotFound(url: url)
    #expect(error.errorDescription?.contains("not found") == true)
}

@Test
func pdfIngestErrorLoadFailedDescription() {
    let url = URL(fileURLWithPath: "/tmp/test.pdf")
    let error = PDFIngestError.loadFailed(url: url)
    #expect(error.errorDescription?.contains("could not be opened") == true)
}

@Test
func pdfIngestErrorNoExtractableTextDescription() {
    let url = URL(fileURLWithPath: "/tmp/test.pdf")
    let error = PDFIngestError.noExtractableText(url: url, pageCount: 5)
    #expect(error.errorDescription?.contains("no extractable text") == true)
    #expect(error.errorDescription?.contains("5") == true)
}
#endif

// MARK: - RerankingHelpers

@Test
func rerankingHelpersDetectsTentativeLaunchLanguage() {
    let positives = [
        "tentative launch date is March",
        "this is a draft proposal",
        "proposed timeline for beta",
        "pending approval from stakeholders",
        "target is Q3 2025",
        "target date for release",
        "it could be next month",
        "current estimate is June",
    ]
    for text in positives {
        #expect(RerankingHelpers.containsTentativeLaunchLanguage(text), "Expected true for: \(text)")
    }
}

@Test
func rerankingHelpersRejectsNonTentativeText() {
    let negatives = [
        "public launch is march 15, 2025",
        "the official release date",
        "confirmed deployment on friday",
        "atlas moved to seattle",
        "person18 owns deployment readiness",
    ]
    for text in negatives {
        #expect(!RerankingHelpers.containsTentativeLaunchLanguage(text), "Expected false for: \(text)")
    }
}
