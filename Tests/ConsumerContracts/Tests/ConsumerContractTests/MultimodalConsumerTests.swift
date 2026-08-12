import Foundation
import Testing
import Wax

private let tinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII=")!
private let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

private struct ConsumerPhotoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "consumer",
        model: "photo",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(text: String) async throws -> [Float] {
        text.localizedCaseInsensitiveContains("receipt")
            ? [0, 1, 0, 0]
            : [1, 0, 0, 0]
    }

    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float] {
        _ = imageData
        _ = format
        return [0, 1, 0, 0]
    }
}

private struct ConsumerCaptionProvider: PhotoCaptionProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func caption(for imageData: Data, format: WaxImageFormat) async throws -> String {
        _ = imageData
        _ = format
        return "local receipt image"
    }
}

private struct ConsumerVideoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 8
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "consumer",
        model: "video",
        dimensions: 8,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0, 0, 0, 0, 0]
    }

    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float] {
        _ = imageData
        _ = format
        return [0, 1, 0, 0, 0, 0, 0, 0]
    }
}

@Suite("MultimodalConsumerTests")
struct MultimodalConsumerTests {
    @Test
    func photoMemoryIngestSearchDeleteAndReopen() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "wax-photo-consumer-\(UUID().uuidString).wax")
        let imageURL = FileManager.default.temporaryDirectory
            .appending(path: "wax-photo-consumer-\(UUID().uuidString).png")
        defer {
            try? FileManager.default.removeItem(at: storeURL)
            try? FileManager.default.removeItem(at: imageURL)
        }
        try tinyPNGData.write(to: imageURL)

        let config = PhotoMemory.Config(
            enableOCR: false,
            enableRegionEmbeddings: false,
            includeThumbnailsInContext: true,
            includeRegionCropsInContext: false,
            lockWaitTimeout: .zero
        )
        let files = [
            PhotoMemory.File(id: "consumer-photo", url: imageURL)
        ]

        do {
            let photos = try await PhotoMemory.open(
                at: storeURL,
                embedding: ConsumerPhotoEmbedder(),
                captioner: ConsumerCaptionProvider(),
                config: config
            )
            try await photos.ingest(files: files)
            let hits = try await photos.search(PhotoMemory.Query(text: "receipt", resultLimit: 5))
            let hit = try #require(hits.items.first { $0.assetID == "consumer-photo" })
            let thumbnail = try #require(hit.thumbnail)
            #expect(thumbnail.starts(with: pngMagic))
            #expect(hit.regions.isEmpty)

            try await photos.delete(assetID: "consumer-photo")
            try await photos.close()
        }

        let reopened = try await PhotoMemory.open(
            at: storeURL,
            embedding: ConsumerPhotoEmbedder(),
            captioner: ConsumerCaptionProvider(),
            config: config
        )
        let afterReopen = try await reopened.search(PhotoMemory.Query(text: "receipt", resultLimit: 5))
        #expect(afterReopen.items.allSatisfy { $0.assetID != "consumer-photo" })

        try await reopened.ingest(files: files)
        let afterReingest = try await reopened.search(PhotoMemory.Query(text: "receipt", resultLimit: 5))
        #expect(afterReingest.items.contains { $0.assetID == "consumer-photo" })
        try await reopened.close()
    }

    @Test
    func videoMemoryOwnsStoreLockAndClosesDeterministically() async throws {
        let storeURL = FileManager.default.temporaryDirectory
            .appending(path: "wax-video-consumer-\(UUID().uuidString).wax")
        defer { try? FileManager.default.removeItem(at: storeURL) }

        let config = VideoMemory.Config(lockWaitTimeout: .zero)
        let first = try await VideoMemory.open(
            at: storeURL,
            embedding: ConsumerVideoEmbedder(),
            config: config
        )

        do {
            _ = try await VideoMemory.open(
                at: storeURL,
                embedding: ConsumerVideoEmbedder(),
                config: config
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
        try await first.close()

        let second = try await VideoMemory.open(
            at: storeURL,
            embedding: ConsumerVideoEmbedder(),
            config: config
        )
        try await second.close()
    }

    @Test
    func photoAndVideoResultPayloadsAreReadableFromWaxImport() {
        let region = PhotoMemory.Region(
            bbox: PhotoMemory.BoundingBox(x: 0.1, y: 0.2, width: 0.3, height: 0.4),
            crop: tinyPNGData
        )
        let photoItem = PhotoMemory.Item(
            assetID: "consumer-photo",
            score: 1,
            summaryText: "caption",
            thumbnail: tinyPNGData,
            regions: [region]
        )
        #expect(photoItem.thumbnail?.starts(with: pngMagic) == true)
        #expect(photoItem.regions.first?.bbox.width == 0.3)
        #expect(photoItem.regions.first?.crop?.starts(with: pngMagic) == true)

        let segment = VideoMemory.Segment(
            startMs: 0,
            endMs: 1_000,
            score: 0.5,
            transcriptSnippet: "hello",
            thumbnail: tinyPNGData
        )
        #expect(segment.thumbnail?.starts(with: pngMagic) == true)
    }
}
