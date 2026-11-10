import Foundation
import CoreGraphics
import Testing
import Wax
import WaxTestSupport
import WaxCore

/// Text → `[1, 0, 0, 0]`, image → `[0, 1, 0, 0]`.
private let stubMultimodalEmbedder = DeterministicMultimodalEmbedder(
    identity: EmbeddingIdentity(provider: "stub", model: "stub", dimensions: 4, normalized: true)
)

private struct NetworkOCRProvider: OCRProvider {
    var executionMode: ProviderExecutionMode { .mayUseNetwork }

    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock] {
        _ = image
        return []
    }
}

@Test
func photoRAGRecallReturnsAssetIDsFromOCR() async throws {
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

        let rootA = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaA),
            compression: .plain,
            timestampMs: captureMs
        )

        let ocrTextA = "COSTCO WHOLESALE\nTOTAL 42.00"
        let ocrA = try await session.put(
            Data(ocrTextA.utf8),
            options: FrameMetaSubset(kind: "photo.ocr.summary", role: .blob, parentId: rootA, metadata: metaA),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: ocrA, text: ocrTextA)

        var metaB = Metadata()
        metaB.entries["photos.asset_id"] = "B"
        metaB.entries["photo.capture_ms"] = String(captureMs)

        let rootB = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: metaB),
            compression: .plain,
            timestampMs: captureMs
        )

        let ocrTextB = "Hello World"
        let ocrB = try await session.put(
            Data(ocrTextB.utf8),
            options: FrameMetaSubset(kind: "photo.ocr.summary", role: .blob, parentId: rootB, metadata: metaB),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: ocrB, text: ocrTextB)

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
            embedder: stubMultimodalEmbedder
        )

        let query = PhotoQuery(
            text: "Costco",
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: PhotoContextBudget(maxTextTokens: 400, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 4)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.photoID.id == "A")
        #expect(ctx.items.first?.summaryText.contains("COSTCO") == true)
        try await orchestrator.flush()
    }
}

#if canImport(Photos)
@Test
func photoRAGSyncLibraryWritesSyncStateCheckpoint() async throws {
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
            embedder: stubMultimodalEmbedder
        )

        try await orchestrator.syncLibrary(scope: .assetIDs([]))
        await orchestrator.session.close()
        try await orchestrator.wax.close()

        let reopened = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: stubMultimodalEmbedder
        )

        let syncState = await reopened.wax.frameMetas().filter {
            $0.kind == PhotoFrameKind.syncState.rawValue
        }
        #expect(syncState.count == 1)
        #expect(syncState.first?.metadata?.entries["photos.sync.scope"] == "asset_ids")
        #expect(syncState.first?.metadata?.entries["photos.sync.asset_count"] == "0")
        #expect(syncState.first?.metadata?.entries["photo.pipeline.version"] == config.pipelineVersion)
        let completedAt = syncState.first?.metadata?.entries["photos.sync.completed_at_ms"]
        #expect(completedAt.flatMap(Int64.init) != nil)

        try await reopened.flush()
        await reopened.session.close()
        try await reopened.wax.close()
    }
}
#endif

@Test
func photoRAGRejectsNetworkOCRProviderByDefault() async throws {
    try await TempFiles.withTempFile { url in
        do {
            _ = try await PhotoRAGOrchestrator(
                storeURL: url,
                config: .default,
                embedder: stubMultimodalEmbedder,
                ocr: NetworkOCRProvider(),
                captioner: nil
            )
            Issue.record("Expected WaxError for network OCR provider")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("Expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("on-device OCR provider"))
        }
    }
}

@Test
func photoRAGRecallIncludesSearchableTagsFromIndexedFrames() async throws {
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
        var rootMeta = Metadata()
        rootMeta.entries["photos.asset_id"] = "A"
        rootMeta.entries["photo.capture_ms"] = String(captureMs)

        let rootId = try await session.put(
            Data(),
            embedding: [1, 0, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: "photo.root", metadata: rootMeta),
            compression: .plain,
            timestampMs: captureMs
        )

        let tagsText = "beach, sunset, travel"
        let tagsId = try await session.put(
            Data(tagsText.utf8),
            options: FrameMetaSubset(kind: "photo.tags", parentId: rootId, metadata: rootMeta),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexTextBatch(frameIds: [tagsId], texts: [tagsText])

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
            embedder: stubMultimodalEmbedder
        )

        let query = PhotoQuery(
            text: "sunset",
            image: nil,
            timeRange: nil,
            location: nil,
            filters: .none,
            resultLimit: 5,
            contextBudget: PhotoContextBudget(maxTextTokens: 120, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 4)
        )

        let ctx = try await orchestrator.recall(query)
        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.photoID.id == "A")
        #expect(ctx.items.first?.summaryText.contains("Tags:") == true)
        #expect(ctx.items.first?.summaryText.contains("beach, sunset") == true)

        try await orchestrator.flush()
    }
}

private let ocrBlockOnlyToken = "zephyrtoken"

private func hasTextEvidence(_ item: PhotoRAGItem?, containing token: String) -> Bool {
    guard let item else { return false }
    return item.evidence.contains { evidence in
        if case .text(let snippet) = evidence {
            return snippet?.contains(token) == true
        }
        return false
    }
}

@Test
func photoRAGAssetFilteredRecallMatchesTextOnlyInOCRBlock() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-ocr-block-\(UUID().uuidString).png")
        let tinyPNG = try #require(Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII="))
        try tinyPNG.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = true
        config.enableRegionEmbeddings = false
        config.maxOCRSummaryLines = 1
        config.vectorEnginePreference = .cpuOnly

        let ocr = StubOCRProvider(blocks: [
            RecognizedTextBlock(text: "summary line", bbox: PhotoNormalizedRect(x: 0, y: 0, width: 1, height: 0.5), confidence: 0.9),
            RecognizedTextBlock(text: ocrBlockOnlyToken, bbox: PhotoNormalizedRect(x: 0, y: 0.5, width: 1, height: 0.5), confidence: 0.5),
        ])
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: stubMultimodalEmbedder,
            ocr: ocr,
            captioner: StubCaptionProvider(captionText: "a photo")
        )
        let photoID = PhotoID(source: .file, id: "ocr-block-photo")
        try await orchestrator.ingest(files: [PhotoFile(id: photoID, url: imageURL)])

        let budget = PhotoContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        let unfiltered = try await orchestrator.recall(
            PhotoQuery(text: ocrBlockOnlyToken, resultLimit: 5, contextBudget: budget)
        )
        #expect(hasTextEvidence(unfiltered.items.first, containing: ocrBlockOnlyToken))

        let filtered = try await orchestrator.recall(
            PhotoQuery(
                text: ocrBlockOnlyToken,
                filters: PhotoFilters(assetIDs: [photoID]),
                resultLimit: 5,
                contextBudget: budget
            )
        )
        #expect(filtered.items.map(\.photoID) == [photoID])
        #expect(hasTextEvidence(filtered.items.first, containing: ocrBlockOnlyToken))

        try await orchestrator.close()
    }
}

@Test
func photoRAGLocationFilteredRecallMatchesTextOnlyInOCRBlock() async throws {
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
        var meta = Metadata()
        meta.entries[PhotoMetadataKey.assetID.rawValue] = "located"
        meta.entries[PhotoMetadataKey.captureMs.rawValue] = String(captureMs)
        meta.entries[PhotoMetadataKey.lat.rawValue] = "37.3318"
        meta.entries[PhotoMetadataKey.lon.rawValue] = "-122.0312"

        let root = try await session.put(
            Data(),
            embedding: [0, 1, 0, 0],
            identity: nil,
            options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: meta),
            compression: .plain,
            timestampMs: captureMs
        )
        let block = try await session.put(
            Data(ocrBlockOnlyToken.utf8),
            options: FrameMetaSubset(kind: PhotoFrameKind.ocrBlock.rawValue, role: .blob, parentId: root, metadata: meta),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: block, text: ocrBlockOnlyToken)
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
            embedder: stubMultimodalEmbedder
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: ocrBlockOnlyToken,
                location: PhotoLocationQuery(
                    center: PhotoCoordinate(latitude: 37.3318, longitude: -122.0312),
                    radiusMeters: 1_000
                ),
                resultLimit: 5,
                contextBudget: PhotoContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
            )
        )
        #expect(ctx.items.map(\.photoID.id) == ["located"])
        #expect(hasTextEvidence(ctx.items.first, containing: ocrBlockOnlyToken))

        try await orchestrator.close()
    }
}

private let tinyPhotoPNGBase64 = "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII="

private func writeTinyPhoto(near storeURL: URL, name: String) throws -> URL {
    let imageURL = storeURL.deletingLastPathComponent()
        .appendingPathComponent("wax-\(name)-\(UUID().uuidString).png")
    try #require(Data(base64Encoded: tinyPhotoPNGBase64)).write(to: imageURL)
    return imageURL
}

private func livePhotoRootIDs(_ orchestrator: PhotoRAGOrchestrator, photoID: PhotoID) async -> [UInt64] {
    await orchestrator.wax.frameMetas()
        .filter { meta in
            meta.kind == PhotoFrameKind.root.rawValue
                && meta.status != .deleted
                && meta.supersededBy == nil
                && meta.metadata?.entries[PhotoMetadataKey.assetID.rawValue] == photoID.id
        }
        .map(\.id)
}

@Test
func photoRAGFailedIngestKeepsPreviousVersionAndReindexesSurvivors() async throws {
    try await TempFiles.withTempFile { storeURL in
        let urlA = try writeTinyPhoto(near: storeURL, name: "failed-ingest-a")
        let urlB = try writeTinyPhoto(near: storeURL, name: "failed-ingest-b")
        defer {
            try? FileManager.default.removeItem(at: urlA)
            try? FileManager.default.removeItem(at: urlB)
        }

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = true
        config.enableRegionEmbeddings = false
        config.ingestConcurrency = 1
        config.vectorEnginePreference = .cpuOnly

        // OCR runs after the root frame is written. Call 1 is A's first ingest, call 2 is B,
        // call 3 is A's re-ingest, which therefore fails with its new root already written.
        let ocr = FailingOnCallOCRProvider(
            blocks: [RecognizedTextBlock(text: "receipt", bbox: PhotoNormalizedRect(x: 0, y: 0, width: 1, height: 1), confidence: 0.9)],
            failOnCall: 3
        )
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: stubMultimodalEmbedder,
            ocr: ocr,
            captioner: StubCaptionProvider(captionText: "a photo")
        )
        let idA = PhotoID(source: .file, id: "photo-a")
        let idB = PhotoID(source: .file, id: "photo-b")

        try await orchestrator.ingest(files: [PhotoFile(id: idA, url: urlA)])
        let firstRootsA = await livePhotoRootIDs(orchestrator, photoID: idA)
        try #require(firstRootsA.count == 1)

        await #expect(throws: MockEmbedderError.self) {
            try await orchestrator.ingest(files: [PhotoFile(id: idB, url: urlB), PhotoFile(id: idA, url: urlA)])
        }
        try await orchestrator.flush()

        let liveRootsA: [UInt64] = await livePhotoRootIDs(orchestrator, photoID: idA)
        let liveRootsB: [UInt64] = await livePhotoRootIDs(orchestrator, photoID: idB)
        #expect(liveRootsA == firstRootsA)
        #expect(liveRootsB.count == 1)

        let budget = PhotoContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        let onlyB = try await orchestrator.recall(PhotoQuery(filters: PhotoFilters(assetIDs: [idB]), resultLimit: 5, contextBudget: budget))
        #expect(onlyB.items.map(\.photoID) == [idB])
        let onlyA = try await orchestrator.recall(PhotoQuery(text: "receipt", filters: PhotoFilters(assetIDs: [idA]), resultLimit: 5, contextBudget: budget))
        #expect(onlyA.items.map(\.photoID) == [idA])

        try await orchestrator.delete(photoID: idB)
        try await orchestrator.delete(photoID: idA)
        #expect(await livePhotoRootIDs(orchestrator, photoID: idA).isEmpty)
        #expect(await livePhotoRootIDs(orchestrator, photoID: idB).isEmpty)
        try await orchestrator.close()
    }
}

private enum PhotoOverlapOutcome: Sendable, Equatable {
    case secondIngestFinished
    case secondIngestQueued
}

@Test
func photoRAGOverlappingIngestsOfOneAssetLeaveOneLiveVersion() async throws {
    try await TempFiles.withTempFile { storeURL in
        let urlX = try writeTinyPhoto(near: storeURL, name: "overlap-x")
        let urlY = try writeTinyPhoto(near: storeURL, name: "overlap-y")
        defer {
            try? FileManager.default.removeItem(at: urlX)
            try? FileManager.default.removeItem(at: urlY)
        }

        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.ingestConcurrency = 1
        config.vectorEnginePreference = .cpuOnly

        // One image embed per photo. After arm(), call 1 is X and call 2 is Y in ingest A, so A
        // parks on Y after X's new tree is written but before A rebuilds the index.
        let gate = ImageEmbedGate(blockedCall: 2)
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: GatedImageEmbedder(gate: gate)
        )
        let idX = PhotoID(source: .file, id: "photo-x")
        let idY = PhotoID(source: .file, id: "photo-y")
        let fileX = PhotoFile(id: idX, url: urlX)
        let fileY = PhotoFile(id: idY, url: urlY)

        try await orchestrator.ingest(files: [fileX])
        try #require(await livePhotoRootIDs(orchestrator, photoID: idX).count == 1)

        await gate.arm()
        let first = Task { try await orchestrator.ingest(files: [fileX, fileY]) }
        await gate.waitUntilParked()

        // B re-ingests X while A has not yet rebuilt the index. It must queue behind A rather
        // than supersede the root A already retired.
        let second = Task { try await orchestrator.ingest(files: [fileX]) }
        let outcome: PhotoOverlapOutcome = await withTaskGroup(of: PhotoOverlapOutcome.self) { group in
            group.addTask {
                _ = await second.result
                return .secondIngestFinished
            }
            group.addTask {
                await orchestrator.ingestMutex.waitUntilWaiting(atLeast: 1)
                return .secondIngestQueued
            }
            let winner: PhotoOverlapOutcome = await group.next() ?? .secondIngestFinished
            group.cancelAll()
            // The loser may be waiting on B, which cannot finish until A is released.
            await gate.release()
            return winner
        }
        #expect(outcome == .secondIngestQueued)

        try await first.value
        try await second.value

        let liveRootsX: [UInt64] = await livePhotoRootIDs(orchestrator, photoID: idX)
        let liveRootsY: [UInt64] = await livePhotoRootIDs(orchestrator, photoID: idY)
        #expect(liveRootsX.count == 1)
        #expect(liveRootsY.count == 1)

        let budget = PhotoContextBudget(maxTextTokens: 200, maxImages: 0, maxRegions: 0, maxOCRLinesPerItem: 2)
        let onlyX = try await orchestrator.recall(PhotoQuery(filters: PhotoFilters(assetIDs: [idX]), resultLimit: 5, contextBudget: budget))
        #expect(onlyX.items.map(\.photoID) == [idX])

        try await orchestrator.delete(photoID: idX)
        #expect(await livePhotoRootIDs(orchestrator, photoID: idX).isEmpty)
        try await orchestrator.close()
    }
}
