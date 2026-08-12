#if canImport(ImageIO)
import Foundation
import Testing
import Wax
import XCTest

private let tinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII=")!
private let pngMagic = Data([0x89, 0x50, 0x4E, 0x47, 0x0D, 0x0A, 0x1A, 0x0A])

private struct PublicPhotoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "test",
        model: "photo-public",
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

private struct NetworkPhotoEmbedder: MultimodalEmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = nil
    let executionMode: ProviderExecutionMode = .mayUseNetwork

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float] {
        _ = imageData
        _ = format
        return [0, 1, 0, 0]
    }
}

private struct ReceiptCaptionProvider: PhotoCaptionProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func caption(for imageData: Data, format: WaxImageFormat) async throws -> String {
        _ = imageData
        _ = format
        return "local receipt image"
    }
}

private struct ReceiptOCRProvider: PhotoOCRProvider {
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func recognizeText(in imageData: Data, format: WaxImageFormat) async throws -> [PhotoMemory.RecognizedText] {
        _ = imageData
        _ = format
        return [
            PhotoMemory.RecognizedText(
                text: "receipt",
                confidence: 0.95,
                language: "en",
                bbox: PhotoMemory.BoundingBox(x: 0, y: 0, width: 1, height: 1)
            )
        ]
    }
}

@Suite("PublicPhotoMemoryTests")
struct PublicPhotoMemoryTests {
    private static var testConfig: PhotoMemory.Config {
        PhotoMemory.Config(
            enableOCR: false,
            enableRegionEmbeddings: false,
            includeThumbnailsInContext: false,
            includeRegionCropsInContext: false,
            requireOnDeviceProviders: true,
            lockWaitTimeout: .zero
        )
    }

    @Test
    func ingestSearchDeleteReopenReingestHasNoGhost() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-public-photo-\(UUID().uuidString).png")
            try tinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let files = [
                PhotoMemory.File(
                    id: "local-fixture",
                    url: imageURL,
                    captureDate: Date(timeIntervalSince1970: 1_700_000_000)
                )
            ]

            do {
                let photos = try await PhotoMemory.open(
                    at: storeURL,
                    embedding: PublicPhotoEmbedder(),
                    captioner: ReceiptCaptionProvider(),
                    config: Self.testConfig
                )
                try await photos.ingest(files: files)

                let textHits = try await photos.search(
                    PhotoMemory.Query(text: "receipt", resultLimit: 5)
                )
                #expect(textHits.items.contains { $0.assetID == "local-fixture" })
                #expect(textHits.items.first?.summaryText.contains("local receipt image") == true)

                try await photos.delete(assetID: "local-fixture")
                let afterDelete = try await photos.search(
                    PhotoMemory.Query(text: "receipt", resultLimit: 5)
                )
                #expect(afterDelete.items.allSatisfy { $0.assetID != "local-fixture" })

                try await photos.close()
            }

            do {
                let reopened = try await PhotoMemory.open(
                    at: storeURL,
                    embedding: PublicPhotoEmbedder(),
                    captioner: ReceiptCaptionProvider(),
                    config: Self.testConfig
                )
                let afterReopen = try await reopened.search(
                    PhotoMemory.Query(text: "receipt", resultLimit: 5)
                )
                #expect(
                    afterReopen.items.allSatisfy { $0.assetID != "local-fixture" },
                    "deleted photo must not return as a ghost after reopen"
                )

                try await reopened.ingest(files: files)
                let afterReingest = try await reopened.search(
                    PhotoMemory.Query(text: "receipt", resultLimit: 5)
                )
                #expect(afterReingest.items.contains { $0.assetID == "local-fixture" })
                #expect(afterReingest.items.filter { $0.assetID == "local-fixture" }.count == 1)

                try await reopened.close()
            }
        }
    }

    @Test
    func secondWriterReceivesLockUnavailableUntilOwnerCloses() async throws {
        try await TempFiles.withTempFile { storeURL in
            let first = try await PhotoMemory.open(
                at: storeURL,
                embedding: PublicPhotoEmbedder(),
                config: Self.testConfig
            )

            do {
                _ = try await PhotoMemory.open(
                    at: storeURL,
                    embedding: PublicPhotoEmbedder(),
                    config: Self.testConfig
                )
                Issue.record("second PhotoMemory.open must fail while the owner holds the store lock")
            } catch let error as WaxError {
                guard case .lockUnavailable = error else {
                    Issue.record("expected WaxError.lockUnavailable, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxError.lockUnavailable, got \(error)")
            }

            try await first.close()

            let second = try await PhotoMemory.open(
                at: storeURL,
                embedding: PublicPhotoEmbedder(),
                config: Self.testConfig
            )
            try await second.close()
        }
    }

    @Test
    func invalidWALSizeThrowsInvalidConfiguration() async throws {
        try await TempFiles.withTempFile { storeURL in
            let config = PhotoMemory.Config(walSizeBytes: 8)
            do {
                _ = try await PhotoMemory.open(
                    at: storeURL,
                    embedding: PublicPhotoEmbedder(),
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
    func networkEmbedderThrowsInvalidConfigurationWhenOnDeviceRequired() async throws {
        try await TempFiles.withTempFile { storeURL in
            do {
                _ = try await PhotoMemory.open(
                    at: storeURL,
                    embedding: NetworkPhotoEmbedder(),
                    config: Self.testConfig
                )
                Issue.record("network embedder must throw invalidConfiguration")
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
            let photos = try await PhotoMemory.open(
                at: storeURL,
                embedding: PublicPhotoEmbedder(),
                config: Self.testConfig
            )
            try await photos.close()
            try await photos.close()
        }
    }

    @Test
    func searchReturnsThumbnailAndRegionPayloadsWhenEnabled() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-public-photo-payload-\(UUID().uuidString).png")
            try tinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let config = PhotoMemory.Config(
                enableOCR: true,
                enableRegionEmbeddings: true,
                includeThumbnailsInContext: true,
                includeRegionCropsInContext: true,
                requireOnDeviceProviders: true,
                maxRegionsPerPhoto: 1,
                lockWaitTimeout: .zero
            )
            let photos = try await PhotoMemory.open(
                at: storeURL,
                embedding: PublicPhotoEmbedder(),
                ocr: ReceiptOCRProvider(),
                captioner: ReceiptCaptionProvider(),
                config: config
            )
            try await photos.ingest(files: [
                PhotoMemory.File(id: "payload-fixture", url: imageURL)
            ])

            let hits = try await photos.search(PhotoMemory.Query(text: "receipt", resultLimit: 5))
            let item = try #require(hits.items.first { $0.assetID == "payload-fixture" })
            let thumbnail = try #require(item.thumbnail)
            #expect(thumbnail.starts(with: pngMagic), "thumbnail must be PNG bytes")
            #expect(!item.regions.isEmpty)
            let region = try #require(item.regions.first)
            #expect(region.bbox.x == 0)
            #expect(region.bbox.y == 0)
            #expect(region.bbox.width == 1)
            #expect(region.bbox.height == 1)
            let crop = try #require(region.crop)
            #expect(crop.starts(with: pngMagic), "region crop must be PNG bytes")

            try await photos.close()
        }
    }

    @Test
    func publicDTOsExposeMemberwiseInitializers() {
        let fileURL = URL(fileURLWithPath: "/tmp/photo.png")
        let file = PhotoMemory.File(
            id: "asset-1",
            url: fileURL,
            captureDate: Date(timeIntervalSince1970: 1)
        )
        let emptyID = PhotoMemory.File(id: "  ", url: fileURL)
        let query = PhotoMemory.Query(text: "receipt", resultLimit: 3)
        let region = PhotoMemory.Region(
            bbox: PhotoMemory.BoundingBox(x: 0, y: 0, width: 1, height: 1),
            crop: tinyPNGData
        )
        let item = PhotoMemory.Item(
            assetID: "asset-1",
            score: 0.9,
            summaryText: "Caption: local receipt image",
            thumbnail: tinyPNGData,
            regions: [region]
        )
        let results = PhotoMemory.Results(items: [item], usedTextTokens: 4, degradedResultCount: 0)
        let config = PhotoMemory.Config()

        #expect(file.id == "asset-1")
        #expect(emptyID.id == fileURL.standardizedFileURL.absoluteString)
        #expect(query.resultLimit == 3)
        #expect(results.items.count == 1)
        #expect(item.thumbnail?.starts(with: pngMagic) == true)
        #expect(item.regions.count == 1)
        #expect(config.enableOCR == true)
        #expect(config.includeThumbnailsInContext == true)
        #expect(config.includeRegionCropsInContext == true)
        #expect(WaxImageFormat.png == .png)
        #expect(WaxImageFormat.jpeg == .jpeg)
        #expect(WaxImageFormat.heic == .heic)
        #expect(WaxImageFormat.other(uti: "public.tiff") == .other(uti: "public.tiff"))
    }
}
#endif
