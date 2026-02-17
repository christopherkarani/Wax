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
