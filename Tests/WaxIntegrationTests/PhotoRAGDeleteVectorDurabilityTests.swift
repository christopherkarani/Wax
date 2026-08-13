#if canImport(ImageIO)
import CoreGraphics
import Foundation
import Testing
@testable import Wax
import WaxVectorSearch
import WaxCore
import WaxTextSearch

// Byte-level proof that PhotoRAG delete and re-ingest (supersede) remove vectors from
// the committed vector index, mirroring MemoryDeleteVectorDurabilityTests. Before the
// fix, PhotoRAGOrchestrator only deleted frames and left ghost vectors searchable.

private let photoDeleteTinyPNGData = Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAQAAAC1HAwCAAAAC0lEQVR42mP8/x8AAwMCAO6Q5+YAAAAASUVORK5CYII=")!

private func photoDeleteCommittedVecFrameIds(from bytes: Data) throws -> [UInt64] {
    let decoded = try VectorSerializer.decodeVecSegment(from: bytes)
    guard case .metal(_, _, let frameIds) = decoded else {
        throw WaxError.io("unexpected vec payload (expected .metal/.flat decode)")
    }
    return frameIds
}

private func photoDeleteMakeOrchestrator(storeURL: URL) async throws -> PhotoRAGOrchestrator {
    var config = PhotoRAGConfig.default
    config.includeThumbnailsInContext = false
    config.includeRegionCropsInContext = false
    config.enableOCR = false
    config.enableRegionEmbeddings = false
    config.vectorEnginePreference = .cpuOnly
    return try await PhotoRAGOrchestrator(
        storeURL: storeURL,
        config: config,
        embedder: DeterministicMultimodalEmbedder(),
        walSizeBytes: Memory.Config.defaultWalSizeBytes
    )
}

private func photoDeleteRootId(wax: Wax, assetID: String, superseded: Bool) async throws -> UInt64 {
    try #require(await wax.frameMetas().first {
        $0.kind == PhotoFrameKind.root.rawValue
            && $0.metadata?.entries[PhotoMetadataKey.assetID.rawValue] == assetID
            && (($0.supersededBy != nil) == superseded)
    }?.id)
}

@Suite("PhotoRAGDeleteVectorDurabilityTests")
struct PhotoRAGDeleteVectorDurabilityTests {
@Test
func photoRAGDeleteRemovesRootVectorFromCommittedVecBytes() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-delete-photo-\(UUID().uuidString).png")
        try photoDeleteTinyPNGData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let orchestrator = try await photoDeleteMakeOrchestrator(storeURL: storeURL)
        try await orchestrator.ingest(files: [
            PhotoFile(id: "delete-me", url: imageURL, captureDate: Date(timeIntervalSince1970: 1_700_000_000))
        ])
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let rootId = try await photoDeleteRootId(wax: wax, assetID: "delete-me", superseded: false)

        let beforeBytes = try await wax.readCommittedVecIndexBytes()
        #expect(beforeBytes != nil, "setup: committed vec must exist after flush")
        #expect(try photoDeleteCommittedVecFrameIds(from: beforeBytes!).contains(rootId))

        try await orchestrator.delete(assetID: "delete-me")

        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil, "committed vec bytes must be non-nil after delete")
        #expect(
            !(try photoDeleteCommittedVecFrameIds(from: afterBytes!).contains(rootId)),
            "deleted photo root vector still present in committed vec after delete"
        )

        try await orchestrator.flush()
    }
}

@Test
func photoRAGReingestRemovesSupersededRootVectorFromCommittedVecBytes() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-supersede-photo-\(UUID().uuidString).png")
        try photoDeleteTinyPNGData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let orchestrator = try await photoDeleteMakeOrchestrator(storeURL: storeURL)
        let file = PhotoFile(id: "reingest-me", url: imageURL, captureDate: Date(timeIntervalSince1970: 1_700_000_000))

        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let oldRootId = try await photoDeleteRootId(wax: wax, assetID: "reingest-me", superseded: false)
        let beforeBytes = try await wax.readCommittedVecIndexBytes()
        #expect(beforeBytes != nil, "setup: committed vec must exist after first flush")
        #expect(try photoDeleteCommittedVecFrameIds(from: beforeBytes!).contains(oldRootId))

        // Re-ingesting the same asset supersedes the previous root.
        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()

        let newRootId = try await photoDeleteRootId(wax: wax, assetID: "reingest-me", superseded: false)
        #expect(newRootId != oldRootId)

        let afterBytes = try await wax.readCommittedVecIndexBytes()
        #expect(afterBytes != nil)
        let afterIds = try photoDeleteCommittedVecFrameIds(from: afterBytes!)
        #expect(
            !afterIds.contains(oldRootId),
            "superseded photo root vector still present in committed vec after re-ingest"
        )
        #expect(afterIds.contains(newRootId))

        try await orchestrator.flush()
    }
}

@Test
func photoRAGRebuildSweepsLegacyGhostVectorForSupersededTree() async throws {
    try await TempFiles.withTempFile { storeURL in
        let imageURL = storeURL.deletingLastPathComponent()
            .appendingPathComponent("wax-ghost-sweep-photo-\(UUID().uuidString).png")
        try photoDeleteTinyPNGData.write(to: imageURL)
        defer { try? FileManager.default.removeItem(at: imageURL) }

        let orchestrator = try await photoDeleteMakeOrchestrator(storeURL: storeURL)
        let file = PhotoFile(id: "legacy-ghost", url: imageURL, captureDate: Date(timeIntervalSince1970: 1_700_000_000))

        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        let oldRootId = try await photoDeleteRootId(wax: wax, assetID: "legacy-ghost", superseded: false)

        // Re-ingest supersedes the tree; current cleanup removes its vectors.
        try await orchestrator.ingest(files: [file])
        try await orchestrator.flush()
        let newRootId = try await photoDeleteRootId(wax: wax, assetID: "legacy-ghost", superseded: false)

        // Simulate a store written before vector cleanup existed: the superseded
        // root's vector is still present in the committed index.
        try await wax.putEmbedding(frameId: oldRootId, vector: [1, 0, 0, 0])
        try await orchestrator.flush()
        let legacyBytes = try await wax.readCommittedVecIndexBytes()
        #expect(
            try photoDeleteCommittedVecFrameIds(from: legacyBytes!).contains(oldRootId),
            "setup: injected legacy ghost must be committed"
        )

        // The next index rebuild sweeps retired-tree vectors out of the committed index.
        // Do not flush after rebuild — durability must come from rebuildIndex itself.
        try await orchestrator.ingest(files: [
            PhotoFile(id: "sweep-trigger", url: imageURL, captureDate: Date(timeIntervalSince1970: 1_700_000_100))
        ])

        let sweptBytes = try await wax.readCommittedVecIndexBytes()
        #expect(sweptBytes != nil)
        let sweptIds = try photoDeleteCommittedVecFrameIds(from: sweptBytes!)
        #expect(!sweptIds.contains(oldRootId), "legacy ghost vector survived the retired-tree sweep")
        #expect(sweptIds.contains(newRootId), "current root vector must survive the sweep")
    }
}

@Test
func concurrentPhotoIngestOnFourMiBStoreSucceeds() async throws {
    try await TempFiles.withTempFile { storeURL in
        var config = PhotoRAGConfig.default
        config.includeThumbnailsInContext = false
        config.includeRegionCropsInContext = false
        config.enableOCR = false
        config.enableRegionEmbeddings = false
        config.ingestConcurrency = 2
        config.vectorEnginePreference = .cpuOnly
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: storeURL,
            config: config,
            embedder: DeterministicMultimodalEmbedder(),
            walSizeBytes: Memory.Config.defaultWalSizeBytes
        )

        let dir = storeURL.deletingLastPathComponent()
        var files: [PhotoFile] = []
        files.reserveCapacity(8)
        for index in 0..<8 {
            let imageURL = dir.appendingPathComponent("wax-concurrent-photo-\(index)-\(UUID().uuidString).png")
            try photoDeleteTinyPNGData.write(to: imageURL)
            files.append(
                PhotoFile(
                    id: "concurrent-\(index)",
                    url: imageURL,
                    captureDate: Date(timeIntervalSince1970: 1_700_000_000 + Double(index))
                )
            )
        }
        defer {
            for file in files {
                try? FileManager.default.removeItem(at: file.url)
            }
        }

        try await orchestrator.ingest(files: files)
        try await orchestrator.flush()

        let wax = await orchestrator.wax
        #expect((await wax.walStats()).walSize == Memory.Config.defaultWalSizeBytes)
        let liveRoots = (await wax.frameMetas()).filter {
            $0.kind == PhotoFrameKind.root.rawValue
                && $0.status != .deleted
                && $0.supersededBy == nil
        }
        #expect(liveRoots.count == 8, "concurrent 4 MiB ingest lost roots: \(liveRoots.count)")

        await orchestrator.session.close()
        try await orchestrator.wax.close()
    }
}
}
#endif
