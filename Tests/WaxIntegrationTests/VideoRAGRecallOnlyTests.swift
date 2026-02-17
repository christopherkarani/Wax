import Foundation
import Testing
@testable import Wax

private struct StubVideoEmbedder: MultimodalEmbeddingProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = .init(provider: "stub", model: "stub", dimensions: 4, normalized: true)

    func embed(text: String) async throws -> [Float] {
        // Deterministic vector derived from text bytes.
        let sum = text.utf8.reduce(0) { $0 &+ Int($1) }
        let raw: [Float] = [Float(sum % 7), 1, 0, 0]
        return VectorMath.normalizeL2(raw)
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return VectorMath.normalizeL2([0, 1, 0, 0])
    }
}

@Test
func videoRAGRecallGroupsSegmentsByVideoAndEnforcesPerVideoLimitAndBudgetsDeterministically() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await VideoRAGTestSupport.openWritableTextOnlySession(wax: wax)

        let videoA = VideoID(source: .file, id: "A")
        let videoB = VideoID(source: .file, id: "B")

        let captureA: Int64 = 1_700_000_000_000
        let captureB: Int64 = 1_700_000_100_000

        let rootA = try await VideoRAGTestSupport.putRoot(session: session, videoID: videoA, captureTimestampMs: captureA)
        let rootB = try await VideoRAGTestSupport.putRoot(session: session, videoID: videoB, captureTimestampMs: captureB)

        _ = try await VideoRAGTestSupport.putSegment(
            session: session,
            rootId: rootA,
            videoID: videoA,
            captureTimestampMs: captureA,
            segmentIndex: 0,
            segmentCount: 3,
            startMs: 0,
            endMs: 1_000,
            transcript: "Swift Swift Swift A0"
        )
        _ = try await VideoRAGTestSupport.putSegment(
            session: session,
            rootId: rootA,
            videoID: videoA,
            captureTimestampMs: captureA,
            segmentIndex: 1,
            segmentCount: 3,
            startMs: 1_000,
            endMs: 2_000,
            transcript: "Swift A1"
        )
        _ = try await VideoRAGTestSupport.putSegment(
            session: session,
            rootId: rootA,
            videoID: videoA,
            captureTimestampMs: captureA,
            segmentIndex: 2,
            segmentCount: 3,
            startMs: 2_000,
            endMs: 3_000,
            transcript: "Swift A2"
        )

        _ = try await VideoRAGTestSupport.putSegment(
            session: session,
            rootId: rootB,
            videoID: videoB,
            captureTimestampMs: captureB,
            segmentIndex: 0,
            segmentCount: 2,
            startMs: 0,
            endMs: 1_000,
            transcript: "Swift Swift Swift B0"
        )
        _ = try await VideoRAGTestSupport.putSegment(
            session: session,
            rootId: rootB,
            videoID: videoB,
            captureTimestampMs: captureB,
            segmentIndex: 1,
            segmentCount: 2,
            startMs: 1_000,
            endMs: 2_000,
            transcript: "Swift B1"
        )

        try await session.commit()
        await session.close()
        try await wax.close()

        let rag = try await VideoRAGOrchestrator(storeURL: url, config: .default, embedder: StubVideoEmbedder(), transcriptProvider: nil)
        let query = VideoQuery(
            text: "Swift",
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 10,
            segmentLimitPerVideo: 1,
            contextBudget: VideoContextBudget(maxTextTokens: 80, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )

        let ctxA = try await rag.recall(query)
        let ctxB = try await rag.recall(query)
        #expect(ctxA == ctxB)

        #expect(ctxA.items.count == 2)
        #expect(Set(ctxA.items.map(\.videoID)) == [videoA, videoB])
        #expect(ctxA.items.allSatisfy { $0.segments.count <= 1 })

        #expect(ctxA.diagnostics.usedTextTokens <= query.contextBudget.maxTextTokens)

        // Highest-signal segment per video should be preferred.
        let summaryText = ctxA.items.map(\.summaryText).joined(separator: "\n")
        #expect(summaryText.contains("A0") == true)
        #expect(summaryText.contains("B0") == true)
    }
}

@Test
func videoRAGConstraintOnlyTimeRangeReturnsRootsInReverseChronologicalOrder() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let sessionConfig = WaxSession.Config(
            enableTextSearch: false,
            enableVectorSearch: false,
            enableStructuredMemory: false,
            vectorEnginePreference: .cpuOnly,
            vectorMetric: .cosine,
            vectorDimensions: nil
        )
        let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        let v0 = VideoID(source: .file, id: "v0")
        let v1 = VideoID(source: .file, id: "v1")
        let v2 = VideoID(source: .file, id: "v2")

        _ = try await VideoRAGTestSupport.putRoot(session: session, videoID: v0, captureTimestampMs: 1_000, durationMs: 1_000)
        _ = try await VideoRAGTestSupport.putRoot(session: session, videoID: v1, captureTimestampMs: 2_000, durationMs: 1_000)
        _ = try await VideoRAGTestSupport.putRoot(session: session, videoID: v2, captureTimestampMs: 3_000, durationMs: 1_000)

        try await session.commit()
        await session.close()
        try await wax.close()

        let rag = try await VideoRAGOrchestrator(storeURL: url, config: .default, embedder: StubVideoEmbedder(), transcriptProvider: nil)

        let start = Date(timeIntervalSince1970: 1.5)
        let end = Date(timeIntervalSince1970: 3.5)
        let query = VideoQuery(
            text: nil,
            timeRange: start...end,
            videoIDs: nil,
            resultLimit: 10,
            segmentLimitPerVideo: 0,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )

        let ctx = try await rag.recall(query)
        #expect(ctx.items.map(\.videoID) == [v2, v1])
        #expect(ctx.items.allSatisfy { $0.segments.isEmpty })
    }
}

@Test
func videoRAGRecallIgnoresSegmentsWhoseRootIsSuperseded() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await VideoRAGTestSupport.openWritableTextOnlySession(wax: wax)

        let video = VideoID(source: .file, id: "X")
        let capture: Int64 = 1_700_000_000_000

        let oldRoot = try await VideoRAGTestSupport.putRoot(session: session, videoID: video, captureTimestampMs: capture, durationMs: 1_000)
        let newRoot = try await VideoRAGTestSupport.putRoot(session: session, videoID: video, captureTimestampMs: capture, durationMs: 1_000)

        _ = try await VideoRAGTestSupport.putSegment(
            session: session,
            rootId: oldRoot,
            videoID: video,
            captureTimestampMs: capture,
            segmentIndex: 0,
            segmentCount: 1,
            startMs: 0,
            endMs: 1_000,
            transcript: "Swift from OLD root"
        )
        _ = try await VideoRAGTestSupport.putSegment(
            session: session,
            rootId: newRoot,
            videoID: video,
            captureTimestampMs: capture,
            segmentIndex: 0,
            segmentCount: 1,
            startMs: 0,
            endMs: 1_000,
            transcript: "Swift from NEW root"
        )

        try await wax.supersede(supersededId: oldRoot, supersedingId: newRoot)

        try await session.commit()
        await session.close()
        try await wax.close()

        let rag = try await VideoRAGOrchestrator(storeURL: url, config: .default, embedder: StubVideoEmbedder(), transcriptProvider: nil)
        let query = VideoQuery(
            text: "Swift",
            timeRange: nil,
            videoIDs: nil,
            resultLimit: 10,
            segmentLimitPerVideo: 10,
            contextBudget: VideoContextBudget(maxTextTokens: 200, maxThumbnails: 0, maxTranscriptLinesPerSegment: 2)
        )

        let ctx = try await rag.recall(query)
        #expect(ctx.items.count == 1)
        #expect(ctx.items.first?.videoID == video)
        #expect(ctx.items.first?.summaryText.contains("OLD") == false)
        #expect(ctx.items.first?.summaryText.contains("NEW") == true)
    }
}
