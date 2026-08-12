#if canImport(ImageIO)
import CoreGraphics
import Foundation
import Testing
import Wax
import XCTest

private struct PublicVideoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 8
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "test",
        model: "video-public",
        dimensions: 8,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(text: String) async throws -> [Float] {
        let hash = text.utf8.reduce(0) { $0 &+ Int($1) }
        let raw = (0..<dimensions).map { i in Float((hash &+ i) % 97) / 97.0 }
        return VectorMath.normalizeL2(raw)
    }

    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float] {
        _ = format
        let hash = imageData.count
        let raw = (0..<dimensions).map { i in Float((hash &+ i &* 13) % 101) / 101.0 }
        return VectorMath.normalizeL2(raw)
    }
}

private struct PublicTranscriptProvider: VideoTranscriptProvider {
    static let token = "PUBLIC_INGEST_TOKEN"
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func transcript(for request: VideoMemory.TranscriptRequest) async throws -> [VideoMemory.TranscriptChunk] {
        _ = request
        return [
            VideoMemory.TranscriptChunk(startMs: 0, endMs: 1_000, text: "\(Self.token) hello wax")
        ]
    }
}

private struct FixedKeyframeProvider: VideoKeyframePipelineProvider {
    func buildKeyframes(
        url: URL,
        config: VideoRAGConfig
    ) async throws -> (durationMs: Int64, keyframes: [CGImage]) {
        _ = url
        _ = config
        return (durationMs: 1_000, keyframes: [try makeSolidCGImage()])
    }
}

private func makeSolidCGImage() throws -> CGImage {
    let width = 8
    let height = 8
    let bytesPerRow = width * 4
    var pixels = [UInt8](repeating: 255, count: height * bytesPerRow)
    guard let space = CGColorSpace(name: CGColorSpace.sRGB),
          let ctx = CGContext(
            data: &pixels,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: space,
            bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
          ),
          let image = ctx.makeImage()
    else {
        throw WaxError.io("failed to create synthetic keyframe")
    }
    return image
}

@Suite("PublicVideoMemoryTests")
struct PublicVideoMemoryTests {
    private static var testConfig: VideoMemory.Config {
        VideoMemory.Config(
            segmentDurationSeconds: 60,
            segmentOverlapSeconds: 0,
            maxSegmentsPerVideo: 1,
            includeThumbnailsInContext: false,
            requireOnDeviceProviders: true,
            lockWaitTimeout: .zero
        )
    }

    @Test
    func codecIndependentIngestSearchDeleteReopenHasNoGhost() async throws {
        try await TempFiles.withTempFile { storeURL in
            let dummyURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-public-video-\(UUID().uuidString).bin")
            try Data("not-a-real-video".utf8).write(to: dummyURL)
            defer { try? FileManager.default.removeItem(at: dummyURL) }

            let files = [
                VideoMemory.File(id: "fixture", url: dummyURL, captureDate: Date(timeIntervalSince1970: 10))
            ]

            do {
                let videos = try await VideoMemory.open(
                    at: storeURL,
                    embedding: PublicVideoEmbedder(),
                    transcriptProvider: PublicTranscriptProvider(),
                    keyframeProvider: FixedKeyframeProvider(),
                    config: Self.testConfig
                )
                try await videos.ingest(files: files)

                let hits = try await videos.search(
                    VideoMemory.Query(text: PublicTranscriptProvider.token, resultLimit: 5)
                )
                #expect(hits.items.contains { $0.id.id == "fixture" })
                #expect(hits.items.first?.summaryText.contains(PublicTranscriptProvider.token) == true)

                try await videos.delete(videoID: VideoMemory.ID(source: .file, id: "fixture"))
                let afterDelete = try await videos.search(
                    VideoMemory.Query(text: PublicTranscriptProvider.token, resultLimit: 5)
                )
                #expect(afterDelete.items.allSatisfy { $0.id.id != "fixture" })

                try await videos.close()
            }

            do {
                let reopened = try await VideoMemory.open(
                    at: storeURL,
                    embedding: PublicVideoEmbedder(),
                    transcriptProvider: PublicTranscriptProvider(),
                    keyframeProvider: FixedKeyframeProvider(),
                    config: Self.testConfig
                )
                let afterReopen = try await reopened.search(
                    VideoMemory.Query(text: PublicTranscriptProvider.token, resultLimit: 5)
                )
                #expect(
                    afterReopen.items.allSatisfy { $0.id.id != "fixture" },
                    "deleted video must not return as a ghost after reopen"
                )

                try await reopened.ingest(files: files)
                let afterReingest = try await reopened.search(
                    VideoMemory.Query(text: PublicTranscriptProvider.token, resultLimit: 5)
                )
                #expect(afterReingest.items.contains { $0.id.id == "fixture" })
                #expect(afterReingest.items.filter { $0.id.id == "fixture" }.count == 1)

                try await reopened.close()
            }
        }
    }

    @Test
    func platformMediaIngestSkipsOnlyWithUnsupportedCodecReport() async throws {
        try await TempFiles.withTempFile { storeURL in
            let mp4URL = FileManager.default.temporaryDirectory
                .appendingPathComponent(UUID().uuidString)
                .appendingPathExtension("mp4")
            defer { try? FileManager.default.removeItem(at: mp4URL) }

            do {
                try await VideoRAGTestVideoGenerator.writeTinyMP4(
                    to: mp4URL,
                    width: 32,
                    height: 32,
                    frameCount: 2,
                    fps: 2
                )
            } catch {
                throw XCTSkip("unsupported-codec: H.264 encode is unavailable (\(error))")
            }

            let videos = try await VideoMemory.open(
                at: storeURL,
                embedding: PublicVideoEmbedder(),
                transcriptProvider: PublicTranscriptProvider(),
                config: Self.testConfig
            )
            try await videos.ingest(files: [
                VideoMemory.File(id: "media-fixture", url: mp4URL)
            ])
            let hits = try await videos.search(
                VideoMemory.Query(text: PublicTranscriptProvider.token, resultLimit: 5)
            )
            #expect(hits.items.contains { $0.id.id == "media-fixture" })
            try await videos.close()
        }
    }

    @Test
    func secondWriterReceivesLockUnavailableUntilOwnerCloses() async throws {
        try await TempFiles.withTempFile { storeURL in
            let first = try await VideoMemory.open(
                at: storeURL,
                embedding: PublicVideoEmbedder(),
                config: Self.testConfig
            )

            do {
                _ = try await VideoMemory.open(
                    at: storeURL,
                    embedding: PublicVideoEmbedder(),
                    config: Self.testConfig
                )
                Issue.record("second VideoMemory.open must fail while the owner holds the store lock")
            } catch let error as WaxError {
                guard case .lockUnavailable = error else {
                    Issue.record("expected WaxError.lockUnavailable, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxError.lockUnavailable, got \(error)")
            }

            try await first.close()

            let second = try await VideoMemory.open(
                at: storeURL,
                embedding: PublicVideoEmbedder(),
                config: Self.testConfig
            )
            try await second.close()
        }
    }

    @Test
    func invalidWALSizeThrowsInvalidConfiguration() async throws {
        try await TempFiles.withTempFile { storeURL in
            let config = VideoMemory.Config(walSizeBytes: 8)
            do {
                _ = try await VideoMemory.open(
                    at: storeURL,
                    embedding: PublicVideoEmbedder(),
                    config: config
                )
                Issue.record("undersized WAL must throw invalidConfiguration")
            } catch let error as WaxError {
                guard case .invalidConfiguration = error else {
                    Issue.record("expected WaxError.invalidConfiguration, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxError, got \(error)")
            }
        }
    }

    @Test
    func closeIsIdempotent() async throws {
        try await TempFiles.withTempFile { storeURL in
            let videos = try await VideoMemory.open(
                at: storeURL,
                embedding: PublicVideoEmbedder(),
                config: Self.testConfig
            )
            try await videos.close()
            try await videos.close()
        }
    }

    @Test
    func publicDTOsExposeMemberwiseInitializers() {
        let file = VideoMemory.File(
            id: "clip-1",
            url: URL(fileURLWithPath: "/tmp/clip.mp4"),
            captureDate: Date(timeIntervalSince1970: 1)
        )
        let id = VideoMemory.ID(source: .file, id: "clip-1")
        let query = VideoMemory.Query(text: "hello", resultLimit: 4, segmentLimitPerVideo: 2)
        let segment = VideoMemory.Segment(
            startMs: 0,
            endMs: 1_000,
            score: 0.8,
            transcriptSnippet: "hello wax"
        )
        let item = VideoMemory.Item(
            id: id,
            score: 0.8,
            summaryText: "hello wax",
            segments: [segment]
        )
        let results = VideoMemory.Results(items: [item], usedTextTokens: 2, degradedVideoCount: 0)
        let request = VideoMemory.TranscriptRequest(
            videoID: id,
            localFileURL: file.url,
            durationMs: 1_000
        )
        let chunk = VideoMemory.TranscriptChunk(startMs: 0, endMs: 250, text: "hi")

        #expect(file.id == "clip-1")
        #expect(id.source == .file)
        #expect(query.segmentLimitPerVideo == 2)
        #expect(results.items.count == 1)
        #expect(request.durationMs == 1_000)
        #expect(chunk.text == "hi")
        #expect(VideoMemory.Config().maxSegmentsPerVideo == 360)
    }
}
#endif
