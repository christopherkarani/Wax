#if canImport(ImageIO)
import CoreGraphics
import Foundation
import os
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

/// Opposite unit vectors whose 0.5/0.5 mix is the zero query vector.
private struct OppositeUnitEmbedder: CGImageEmbeddingProvider {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "test",
        model: "opposite-unit",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [-1, 0, 0, 0]
    }
}

/// First image embed (global) is valid; later region-crop embeds are NaN.
private final class RegionNaNEmbedder: MultimodalEmbeddingProvider, @unchecked Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "test",
        model: "region-nan",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly
    private let imageEmbedCount = OSAllocatedUnfairLock(initialState: 0)

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float] {
        _ = imageData
        _ = format
        let count = imageEmbedCount.withLock { value -> Int in
            value += 1
            return value
        }
        if count > 1 {
            return [.nan, 0, 0, 0]
        }
        return [0, 1, 0, 0]
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
    func fusedTextAndImageQueryRejectsZeroMixAsInvalidEmbedding() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-public-photo-fused-\(UUID().uuidString).png")
            try tinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            var config = PhotoRAGConfig.default
            config.enableOCR = false
            config.enableRegionEmbeddings = false
            config.includeThumbnailsInContext = false
            config.includeRegionCropsInContext = false
            config.requireOnDeviceProviders = true
            config.vectorEnginePreference = .cpuOnly
            config.textEmbeddingWeight = 0.5

            let orchestrator = try await PhotoRAGOrchestrator(
                storeURL: storeURL,
                config: config,
                embedder: OppositeUnitEmbedder()
            )
            try await orchestrator.ingest(files: [
                PhotoFile(id: "fused-fixture", url: imageURL)
            ])

            do {
                _ = try await orchestrator.recall(
                    PhotoQuery(
                        text: "receipt",
                        image: PhotoQueryImage(data: tinyPNGData, format: .png),
                        resultLimit: 5
                    )
                )
                Issue.record("fused zero mix must throw")
            } catch let error as WaxError {
                guard case .invalidEmbedding = error else {
                    Issue.record("expected WaxError.invalidEmbedding, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxError.invalidEmbedding, got \(error)")
            }

            try await orchestrator.close()
        }
    }

    @Test
    func invalidRegionEmbeddingThrowsInvalidEmbedding() async throws {
        try await TempFiles.withTempFile { storeURL in
            let imageURL = storeURL.deletingLastPathComponent()
                .appendingPathComponent("wax-public-photo-region-\(UUID().uuidString).png")
            try tinyPNGData.write(to: imageURL)
            defer { try? FileManager.default.removeItem(at: imageURL) }

            let config = PhotoMemory.Config(
                enableOCR: true,
                enableRegionEmbeddings: true,
                includeThumbnailsInContext: false,
                includeRegionCropsInContext: false,
                requireOnDeviceProviders: true,
                maxRegionsPerPhoto: 1,
                lockWaitTimeout: .zero
            )
            let photos = try await PhotoMemory.open(
                at: storeURL,
                embedding: RegionNaNEmbedder(),
                ocr: ReceiptOCRProvider(),
                captioner: ReceiptCaptionProvider(),
                config: config
            )
            do {
                try await photos.ingest(files: [
                    PhotoMemory.File(id: "region-nan", url: imageURL)
                ])
                Issue.record("NaN region embedding must throw")
            } catch let error as WaxError {
                guard case .invalidEmbedding = error else {
                    Issue.record("expected WaxError.invalidEmbedding, got \(error)")
                    return
                }
            } catch {
                Issue.record("expected WaxError.invalidEmbedding, got \(error)")
            }

            let duringOpen = try await photos.search(
                PhotoMemory.Query(text: "receipt", resultLimit: 5)
            )
            #expect(duringOpen.items.isEmpty)
            #expect(duringOpen.items.allSatisfy { $0.assetID != "region-nan" })

            try await photos.close()

            var reopenConfig = PhotoRAGConfig.default
            reopenConfig.enableOCR = true
            reopenConfig.enableRegionEmbeddings = true
            reopenConfig.includeThumbnailsInContext = false
            reopenConfig.includeRegionCropsInContext = false
            reopenConfig.maxRegionsPerPhoto = 1
            reopenConfig.vectorEnginePreference = .cpuOnly
            let orchestrator = try await PhotoRAGOrchestrator(
                storeURL: storeURL,
                config: reopenConfig,
                embedder: DeterministicMultimodalEmbedder()
            )
            let metas = await orchestrator.wax.frameMetasIncludingPending()
            #expect(metas.filter { $0.kind == PhotoFrameKind.root.rawValue }.isEmpty)
            #expect(metas.filter { $0.kind == PhotoFrameKind.region.rawValue }.isEmpty)
            try await orchestrator.close()
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
