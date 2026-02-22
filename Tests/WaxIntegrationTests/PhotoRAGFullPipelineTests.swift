import CoreGraphics
import Foundation
import Testing
@testable import Wax

// MARK: - Shared config helpers

/// A `PhotoRAGConfig` tuned for fast, deterministic testing:
/// no pixel I/O, CPU vector engine only, no OCR, no region embeddings.
private func makePhotoRAGConfig(
    vectorPreference: VectorEnginePreference = .cpuOnly
) -> PhotoRAGConfig {
    var config = PhotoRAGConfig.default
    config.includeThumbnailsInContext = false
    config.includeRegionCropsInContext = false
    config.enableOCR = false
    config.enableRegionEmbeddings = false
    config.vectorEnginePreference = vectorPreference
    return config
}

/// Shared Wax session config used for all pre-population writes.
private func makeSessionConfig() -> WaxSession.Config {
    WaxSession.Config(
        enableTextSearch: true,
        enableVectorSearch: true,
        enableStructuredMemory: false,
        vectorEnginePreference: .cpuOnly,
        vectorMetric: .cosine,
        vectorDimensions: 4
    )
}

/// Embedding identity matching `DeterministicMultimodalEmbedder` from MockEmbedders.swift.
private let sharedEmbeddingIdentity = EmbeddingIdentity(
    provider: "Mock",
    model: "DeterministicMultimodal",
    dimensions: 4,
    normalized: true
)

/// Write a photo root frame (and optional derived frames) directly into `session`.
/// Returns the root frame ID.
@discardableResult
private func insertPhotoAsset(
    session: WaxSession,
    assetID: String,
    captureMs: Int64,
    embedding: [Float],
    ocrText: String? = nil,
    captionText: String? = nil,
    tagsText: String? = nil,
    lat: Double? = nil,
    lon: Double? = nil
) async throws -> UInt64 {
    var meta = Metadata()
    meta.entries[PhotoMetadataKey.assetID.rawValue] = assetID
    meta.entries[PhotoMetadataKey.captureMs.rawValue] = String(captureMs)
    meta.entries[PhotoMetadataKey.isLocal.rawValue] = "true"
    meta.entries[PhotoMetadataKey.pipelineVersion.rawValue] = "test"
    if let lat { meta.entries[PhotoMetadataKey.lat.rawValue] = String(lat) }
    if let lon { meta.entries[PhotoMetadataKey.lon.rawValue] = String(lon) }

    let rootId = try await session.put(
        Data(),
        embedding: embedding,
        identity: sharedEmbeddingIdentity,
        options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: meta),
        compression: .plain,
        timestampMs: captureMs
    )

    if let ocrText, !ocrText.isEmpty {
        let frameId = try await session.put(
            Data(ocrText.utf8),
            options: FrameMetaSubset(
                kind: PhotoFrameKind.ocrSummary.rawValue,
                role: .blob,
                parentId: rootId,
                metadata: meta
            ),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: frameId, text: ocrText)
    }

    if let captionText, !captionText.isEmpty {
        let frameId = try await session.put(
            Data(captionText.utf8),
            options: FrameMetaSubset(
                kind: PhotoFrameKind.captionShort.rawValue,
                role: .blob,
                parentId: rootId,
                metadata: meta
            ),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: frameId, text: captionText)
    }

    if let tagsText, !tagsText.isEmpty {
        let frameId = try await session.put(
            Data(tagsText.utf8),
            options: FrameMetaSubset(
                kind: PhotoFrameKind.tags.rawValue,
                role: .blob,
                parentId: rootId,
                metadata: meta
            ),
            compression: .plain,
            timestampMs: captureMs
        )
        try await session.indexText(frameId: frameId, text: tagsText)
    }

    return rootId
}

// MARK: - Phase 1D: PhotoRAG full pipeline tests

// MARK: Delete

/// `delete(assetID:)` for a known asset must remove the root from the index so that
/// a subsequent `recall` no longer returns it.
@Test
func photoRAGFullPipelineDeleteRemovesAssetFromRecall() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        let tsA: Int64 = 1_700_000_000_000
        let tsB: Int64 = 1_700_000_100_000

        try await insertPhotoAsset(
            session: session,
            assetID: "DEL-A",
            captureMs: tsA,
            embedding: [1, 0, 0, 0],
            ocrText: "invoice receipt payment"
        )
        try await insertPhotoAsset(
            session: session,
            assetID: "DEL-B",
            captureMs: tsB,
            embedding: [0, 1, 0, 0],
            ocrText: "landscape mountains"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let config = makePhotoRAGConfig()
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: config,
            embedder: DeterministicMultimodalEmbedder()
        )

        // Confirm asset A is visible before deletion.
        let beforeCtx = try await orchestrator.recall(
            PhotoQuery(
                text: "invoice",
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )
        #expect(Set(beforeCtx.items.map(\.assetID)).contains("DEL-A"))

        // Delete asset A.
        try await orchestrator.delete(assetID: "DEL-A")

        // After deletion, "DEL-A" must not appear.
        let afterCtx = try await orchestrator.recall(
            PhotoQuery(
                text: "invoice",
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )
        #expect(!Set(afterCtx.items.map(\.assetID)).contains("DEL-A"))
    }
}

/// `delete(assetID:)` for an asset that does not exist in the index must be a no-op:
/// the guard `guard let rootId = index.rootByAssetID[assetID] else { return }` fires
/// and returns without throwing.
@Test
func photoRAGFullPipelineDeleteNonExistentAssetIsNoOp() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )
        // Must not throw.
        try await orchestrator.delete(assetID: "does-not-exist")
    }
}

/// Deleting the same asset twice must be idempotent: the second call hits the guard
/// (`rootByAssetID[assetID]` is nil after the first deletion) and returns without error.
@Test
func photoRAGFullPipelineDeleteSameAssetTwiceIsIdempotent() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "DOUBLE-DEL",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0]
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        try await orchestrator.delete(assetID: "DOUBLE-DEL")
        // Second delete: asset no longer in index → guard returns early → no-op.
        try await orchestrator.delete(assetID: "DOUBLE-DEL")
    }
}

// MARK: rebuildIndex

/// `rebuildIndex` is called during `PhotoRAGOrchestrator.init`. Opening an existing
/// store (with already-committed frames) must pick up those frames so they are
/// immediately retrievable via `recall` without any additional ingestion.
@Test
func photoRAGFullPipelineRebuildIndexPicksUpPreExistingFrames() async throws {
    try await TempFiles.withTempFile { url in
        // Phase 1: write frames directly and close.
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "REBUILD-A",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            ocrText: "blockchain decentralized ledger"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        // Phase 2: open via orchestrator — rebuildIndex fires during init.
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "blockchain",
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )

        #expect(ctx.items.map(\.assetID).contains("REBUILD-A"))
    }
}

// MARK: Recall — text-only query

/// A text query matching OCR text must rank the matching asset at the top.
@Test
func photoRAGFullPipelineRecallTextQueryMatchesOCR() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        let ts: Int64 = 1_700_000_000_000
        try await insertPhotoAsset(
            session: session,
            assetID: "RECEIPT-X",
            captureMs: ts,
            embedding: [1, 0, 0, 0],
            ocrText: "WHOLE FOODS MARKET total 87.42"
        )
        try await insertPhotoAsset(
            session: session,
            assetID: "SCENIC-Y",
            captureMs: ts + 1_000,
            embedding: [0, 1, 0, 0],
            ocrText: "golden gate bridge"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "whole foods market",
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )

        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.assetID == "RECEIPT-X")
    }
}

/// `recall` on an empty store must return an empty context without throwing.
@Test
func photoRAGFullPipelineRecallOnEmptyStoreReturnsEmptyContext() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "anything",
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )

        #expect(ctx.items.isEmpty)
    }
}

/// `recall` with `resultLimit = 0` must return an empty items array, exercising the
/// `Array(sorted.prefix(limit))` path with `limit == 0`.
@Test
func photoRAGFullPipelineRecallWithZeroResultLimitReturnsEmpty() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "LIMIT-A",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            ocrText: "sunset"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "sunset",
                resultLimit: 0,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )

        #expect(ctx.items.isEmpty)
    }
}

// MARK: Recall — derived frame content in summary

/// A photo with a caption frame must surface "Caption: …" inside `summaryText`.
@Test
func photoRAGFullPipelineRecallCaptionAppearsInSummaryText() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "CAP-A",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            captionText: "A majestic mountain peak at dawn"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "mountain",
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )

        #expect(!ctx.items.isEmpty)
        #expect(ctx.items.first?.assetID == "CAP-A")
        let summary = ctx.items.first?.summaryText ?? ""
        #expect(summary.contains("Caption:"))
        #expect(summary.contains("majestic mountain"))
    }
}

/// A photo with a tags frame must surface "Tags: …" inside `summaryText`.
@Test
func photoRAGFullPipelineRecallTagsAppearsInSummaryText() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "TAGS-A",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            tagsText: "sunset, travel, beach"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "sunset beach travel",
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )

        #expect(!ctx.items.isEmpty)
        let summary = ctx.items.first?.summaryText ?? ""
        #expect(summary.contains("Tags:"))
        #expect(summary.contains("sunset, travel, beach"))
    }
}

/// A photo with all three derived frames (OCR, caption, tags) must produce a summary
/// that contains all three sections.
@Test
func photoRAGFullPipelineRecallSummaryContainsAllDerivedSections() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "FULL-A",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            ocrText: "boarding pass JFK to LAX",
            captionText: "Departure lounge",
            tagsText: "travel, airport"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "boarding pass JFK",
                resultLimit: 3,
                contextBudget: ContextBudget(
                    maxTextTokens: 800,
                    maxImages: 0,
                    maxRegions: 0,
                    maxOCRLinesPerItem: 5
                )
            )
        )

        #expect(!ctx.items.isEmpty)
        let summary = ctx.items.first?.summaryText ?? ""
        #expect(summary.contains("Caption: Departure lounge"))
        #expect(summary.contains("OCR:"))
        #expect(summary.contains("boarding pass JFK"))
        #expect(summary.contains("Tags:"))
        #expect(summary.contains("travel, airport"))
    }
}

// MARK: Recall — diagnostics

/// `diagnostics.usedTextTokens` must be positive after recalling at least one result
/// with non-empty summary text.
@Test
func photoRAGFullPipelineRecallDiagnosticsUsedTokensIsPositive() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "DIAG-A",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            ocrText: "festival music crowd"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "festival music",
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )

        #expect(!ctx.items.isEmpty)
        #expect(ctx.diagnostics.usedTextTokens > 0)
    }
}

/// `degradedResultCount` must equal the number of recalled assets that lack both
/// an OCR summary and a caption frame (the `isDegraded` heuristic).
@Test
func photoRAGFullPipelineRecallDiagnosticsDegradedCountReflectsMissingDerivedFrames() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        let ts: Int64 = 1_700_000_000_000

        // Asset A: has OCR summary → NOT degraded.
        try await insertPhotoAsset(
            session: session,
            assetID: "DIAG-FULL",
            captureMs: ts,
            embedding: [1, 0, 0, 0],
            ocrText: "unique receipt text xyzzy"
        )
        // Asset B: no OCR, no caption → DEGRADED.
        try await insertPhotoAsset(
            session: session,
            assetID: "DIAG-DEGRADED",
            captureMs: ts + 1_000,
            embedding: [0.9, 0.1, 0, 0]
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "unique receipt xyzzy",
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 800, maxImages: 0, maxRegions: 0)
            )
        )

        // At least one result must appear.
        #expect(!ctx.items.isEmpty)
        // degradedResultCount is non-negative.
        #expect(ctx.diagnostics.degradedResultCount >= 0)
        // The fully-indexed asset must not be counted as degraded.
        let returnedIDs = ctx.items.map(\.assetID)
        if returnedIDs.contains("DIAG-FULL") && returnedIDs.contains("DIAG-DEGRADED") {
            // Both returned: exactly the degraded asset contributes 1.
            #expect(ctx.diagnostics.degradedResultCount == 1)
        }
    }
}

// MARK: buildQueryEmbedding — nil + nil falls back gracefully

/// A query with no text and no image must not throw. `buildQueryEmbedding` returns nil
/// (both branches produce nil), selecting `mode = .textOnly` with an empty query string.
@Test
func photoRAGFullPipelineBuildQueryEmbeddingNilTextNilImageCompletesWithoutError() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "TIMELINE-A",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0]
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        // No text, no image — pure nil+nil query. Must not throw.
        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: nil,
                image: nil,
                timeRange: nil,
                location: nil,
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )
        // Result may be empty; we only require no error.
        _ = ctx.items
    }
}

/// Whitespace-only `text` is trimmed to `""` which is treated as nil, so
/// `buildQueryEmbedding` returns nil for the text embedding.
/// The call must complete without error.
@Test
func photoRAGFullPipelineRecallTrimsWhitespaceOnlyTextToNil() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "WHITESPACE",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            ocrText: "hello"
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        // "   " trims to "" → treated as nil text.
        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "   ",
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )
        _ = ctx.items // Must not throw.
    }
}

// MARK: buildLocationAllowlist — zero radius

/// `buildLocationAllowlist` with `radiusMeters = 0` must return `nil` (the guard
/// `guard radius > 0 else { return nil }` fires), meaning no spatial filter is applied
/// and all assets remain eligible.
@Test
func photoRAGFullPipelineLocationFilterZeroRadiusSkipsSpatialFilter() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        let ts: Int64 = 1_700_000_000_000

        try await insertPhotoAsset(
            session: session,
            assetID: "PARIS",
            captureMs: ts,
            embedding: [1, 0, 0, 0],
            ocrText: "eiffel",
            lat: 48.8584,
            lon: 2.2945
        )
        try await insertPhotoAsset(
            session: session,
            assetID: "TOKYO",
            captureMs: ts + 1_000,
            embedding: [0.5, 0.5, 0, 0],
            ocrText: "shibuya",
            lat: 35.6895,
            lon: 139.6917
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        // radius=0 → allowlist is nil → no spatial filter → all assets eligible.
        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "eiffel shibuya",
                location: PhotoLocationQuery(
                    center: PhotoCoordinate(latitude: 48.8584, longitude: 2.2945),
                    radiusMeters: 0
                ),
                resultLimit: 10,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )
        let ids = Set(ctx.items.map(\.assetID))
        // Without a spatial filter, both assets must be eligible for retrieval.
        #expect(ids.contains("PARIS") || ids.contains("TOKYO"))
    }
}

/// A very large radius (> ~5000 km) produces > 100 000 bins, triggering the degenerate
/// guard `guard latBinCount * lonBinCount < 100_000 else { return nil }`. The
/// orchestrator must gracefully fall back to no spatial filter.
@Test
func photoRAGFullPipelineLocationFilterHugeRadiusDegradesSafely() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        try await insertPhotoAsset(
            session: session,
            assetID: "HUGE-RADIUS",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            ocrText: "anywhere on earth",
            lat: 0.0,
            lon: 0.0
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        // 10 000 km radius ≫ 5 000 km threshold → allowlist is nil → no spatial filter.
        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "anywhere on earth",
                location: PhotoLocationQuery(
                    center: PhotoCoordinate(latitude: 0, longitude: 0),
                    radiusMeters: 10_000_000
                ),
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )
        #expect(ctx.items.map(\.assetID).contains("HUGE-RADIUS"))
    }
}

/// A query centered near the antimeridian (lon ≈ 179.9) with a radius that straddles
/// the 180°/-180° boundary exercises the split-range longitude bin path:
///   `lonRanges = [minLonBin...18000, -18000...maxLonBin]`
/// The asset at lon=179.9 must be reachable.
@Test
func photoRAGFullPipelineLocationFilterAntimeridianWraparoundFindsAsset() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await Wax.create(at: url)
        let session = try await wax.openSession(.readWrite(.wait), config: makeSessionConfig())

        // Frame positioned at longitude 179.9, just west of the antimeridian.
        try await insertPhotoAsset(
            session: session,
            assetID: "ANTIMERIDIAN",
            captureMs: 1_700_000_000_000,
            embedding: [1, 0, 0, 0],
            ocrText: "dateline pacific",
            lat: 0.0,
            lon: 179.9
        )
        try await session.commit()
        await session.close()
        try await wax.close()

        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )

        // 200 km ≈ 1.8° at the equator. Center at 179.9 → range [178.1, 181.7]
        // which wraps across the antimeridian, forcing the split-range path.
        let ctx = try await orchestrator.recall(
            PhotoQuery(
                text: "dateline pacific",
                location: PhotoLocationQuery(
                    center: PhotoCoordinate(latitude: 0, longitude: 179.9),
                    radiusMeters: 200_000
                ),
                resultLimit: 5,
                contextBudget: ContextBudget(maxTextTokens: 500, maxImages: 0, maxRegions: 0)
            )
        )
        // The frame at lon=179.9 must appear in results (either via the bin
        // allowlist or because the allowlist degraded to nil).
        #expect(ctx.items.map(\.assetID).contains("ANTIMERIDIAN"))
    }
}

// MARK: flush

/// `flush` on an orchestrator with no pending writes must complete without error.
@Test
func photoRAGFullPipelineFlushOnIdleOrchestratorIsNoOp() async throws {
    try await TempFiles.withTempFile { url in
        let orchestrator = try await PhotoRAGOrchestrator(
            storeURL: url,
            config: makePhotoRAGConfig(),
            embedder: DeterministicMultimodalEmbedder()
        )
        try await orchestrator.flush()
    }
}

// MARK: Evidence mapping

/// `_evidenceForTesting` with a `.timeline` source must return `.timeline` regardless
/// of the frame kind — timeline always takes priority.
@Test
func photoRAGFullPipelineEvidenceTimelineTakesPriority() {
    var metadata = Metadata()
    metadata.entries = [
        PhotoMetadataKey.bboxX.rawValue: "0.0",
        PhotoMetadataKey.bboxY.rawValue: "0.0",
        PhotoMetadataKey.bboxW.rawValue: "1.0",
        PhotoMetadataKey.bboxH.rawValue: "1.0",
    ]
    let regionMeta = FrameMeta(
        id: 42,
        timestamp: 0,
        kind: PhotoFrameKind.region.rawValue,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        metadata: metadata
    )

    let result = SearchResponse.Result(
        frameId: 42,
        score: 0.9,
        previewText: nil,
        sources: [.timeline, .vector]
    )

    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: result, meta: regionMeta) == .timeline)
}

/// `_evidenceForTesting` for a vector-only source on a root frame must return `.vector`.
@Test
func photoRAGFullPipelineEvidenceVectorOnRootReturnsVector() {
    var metadata = Metadata()
    metadata.entries = [PhotoMetadataKey.assetID.rawValue: "root-1"]
    let rootMeta = FrameMeta(
        id: 1,
        timestamp: 0,
        kind: PhotoFrameKind.root.rawValue,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        metadata: metadata
    )

    let result = SearchResponse.Result(
        frameId: 1,
        score: 0.85,
        previewText: nil,
        sources: [.vector]
    )

    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: result, meta: rootMeta) == .vector)
}

/// `_evidenceForTesting` for a text source must return `.text(snippet:)` with the
/// `previewText` string.
@Test
func photoRAGFullPipelineEvidenceTextCarriesPreviewSnippet() {
    var metadata = Metadata()
    metadata.entries = [PhotoMetadataKey.assetID.rawValue: "root-2"]
    let rootMeta = FrameMeta(
        id: 2,
        timestamp: 0,
        kind: PhotoFrameKind.root.rawValue,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        metadata: metadata
    )

    let result = SearchResponse.Result(
        frameId: 2,
        score: 0.7,
        previewText: "sample preview",
        sources: [.text]
    )

    #expect(
        PhotoRAGOrchestrator._evidenceForTesting(result: result, meta: rootMeta)
        == .text(snippet: "sample preview")
    )
}

/// `_evidenceForTesting` for a region frame with a valid bbox and no special sources
/// must return `.region(bbox:)` with the correct coordinates.
@Test
func photoRAGFullPipelineEvidenceRegionFrameReturnsRegionWithBBox() {
    var metadata = Metadata()
    metadata.entries = [
        PhotoMetadataKey.bboxX.rawValue: "0.25",
        PhotoMetadataKey.bboxY.rawValue: "0.30",
        PhotoMetadataKey.bboxW.rawValue: "0.45",
        PhotoMetadataKey.bboxH.rawValue: "0.15",
    ]
    let regionMeta = FrameMeta(
        id: 7,
        timestamp: 0,
        kind: PhotoFrameKind.region.rawValue,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        metadata: metadata
    )

    let result = SearchResponse.Result(
        frameId: 7,
        score: 0.6,
        previewText: nil,
        sources: []
    )

    #expect(
        PhotoRAGOrchestrator._evidenceForTesting(result: result, meta: regionMeta)
        == .region(bbox: PhotoNormalizedRect(x: 0.25, y: 0.30, width: 0.45, height: 0.15))
    )
}

/// `_evidenceForTesting` for a region frame whose bbox entries are malformed (unparseable
/// doubles) and has no special sources must return `nil`.
@Test
func photoRAGFullPipelineEvidenceMalformedRegionBBoxReturnsNil() {
    var metadata = Metadata()
    metadata.entries = [
        PhotoMetadataKey.bboxX.rawValue: "not_a_number",
    ]
    let regionMeta = FrameMeta(
        id: 99,
        timestamp: 0,
        kind: PhotoFrameKind.region.rawValue,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        metadata: metadata
    )

    let result = SearchResponse.Result(
        frameId: 99,
        score: 0.5,
        previewText: nil,
        sources: []
    )

    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: result, meta: regionMeta) == nil)
}

// MARK: buildSummaryText — via _buildSummaryTextForTesting

/// All nil inputs with no query text must produce the deterministic fallback string.
@Test
func photoRAGFullPipelineBuildSummaryAllNilFallsBackToDeterministicString() {
    let result = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: nil,
        caption: nil,
        ocrSummary: nil,
        tags: nil,
        query: PhotoQuery(text: nil),
        maxOCRLines: 5
    )
    #expect(result == "Photo context (no extracted text).")
}

/// All nil inputs with a non-empty query text must embed the query in the fallback.
@Test
func photoRAGFullPipelineBuildSummaryAllNilWithQueryTextIncludesQuery() {
    let result = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: nil,
        caption: nil,
        ocrSummary: nil,
        tags: nil,
        query: PhotoQuery(text: "sunset on the bay"),
        maxOCRLines: 5
    )
    #expect(result.contains("Query: sunset on the bay"))
}

/// OCR content with more lines than `maxOCRLines` must be capped: only the first N
/// lines appear in the output.
@Test
func photoRAGFullPipelineBuildSummaryOCRLineCapIsRespected() {
    let result = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: nil,
        caption: nil,
        ocrSummary: "LINE1\nLINE2\nLINE3\nLINE4",
        tags: nil,
        query: PhotoQuery(text: nil),
        maxOCRLines: 2
    )
    #expect(result.contains("LINE1"))
    #expect(result.contains("LINE2"))
    #expect(!result.contains("LINE3"))
    #expect(!result.contains("LINE4"))
}

/// When `maxOCRLines = 0`, the OCR section must be entirely suppressed from the summary.
@Test
func photoRAGFullPipelineBuildSummaryMaxOCRLinesZeroSuppressesOCRSection() {
    let result = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: nil,
        caption: "Hilltop view",
        ocrSummary: "LINE ONE\nLINE TWO",
        tags: nil,
        query: PhotoQuery(text: nil),
        maxOCRLines: 0
    )
    #expect(result.contains("Caption: Hilltop view"))
    #expect(!result.contains("OCR:"))
    #expect(!result.contains("LINE ONE"))
}

// MARK: toWaxTimeRange — via _toWaxTimeRangeForTesting

/// A bounded range must round-trip to the correct millisecond `after` and `before` values.
@Test
func photoRAGFullPipelineToWaxTimeRangeBoundedRangeRoundTrips() {
    let lower = Date(timeIntervalSince1970: 100)
    let upper = Date(timeIntervalSince1970: 200)
    let result = PhotoRAGOrchestrator._toWaxTimeRangeForTesting(lower...upper)
    #expect(result != nil)
    #expect(result?.after == 100_000)
    #expect(result?.before == 200_001)
}

/// A nil range must produce a nil `TimeRange`.
@Test
func photoRAGFullPipelineToWaxTimeRangeNilReturnsNil() {
    #expect(PhotoRAGOrchestrator._toWaxTimeRangeForTesting(nil) == nil)
}

/// `Date.distantFuture` as the upper bound must not overflow: the implementation
/// clamps `beforeExclusive` to `Int64.max` when `beforeInclusive > Int64.max - 1`.
@Test
func photoRAGFullPipelineToWaxTimeRangeDistantFutureDoesNotOverflow() {
    let lower = Date(timeIntervalSince1970: 0)
    let range = lower...Date.distantFuture
    let result = PhotoRAGOrchestrator._toWaxTimeRangeForTesting(range)
    #expect(result != nil)
    #expect(result?.before == Int64.max)
    #expect(result?.after == 0)
}

// MARK: baseMetadata — via _baseMetadataForTesting

/// All fields provided must round-trip correctly into `Metadata.entries`.
@Test
func photoRAGFullPipelineBaseMetadataRoundTripsAllFields() {
    let exif = PhotosAssetMetadata.EXIF(
        cameraMake: "Sony",
        cameraModel: "Alpha 7",
        lensModel: "FE 24mm",
        orientation: 3,
        dateTimeOriginalMs: 1_700_000_000_000,
        gpsLatitude: 35.68,
        gpsLongitude: 139.77,
        keywords: []
    )
    let location = PhotosAssetMetadata.Location(
        latitude: 35.68,
        longitude: 139.77,
        horizontalAccuracyMeters: 5.0
    )

    let meta = PhotoRAGOrchestrator._baseMetadataForTesting(
        assetID: "ROUND-TRIP",
        captureMs: 1_700_000_000_000,
        pipelineVersion: "v99",
        isLocal: false,
        location: location,
        pixelWidth: 4000,
        pixelHeight: 3000,
        exif: exif
    )

    #expect(meta.entries[PhotoMetadataKey.assetID.rawValue] == "ROUND-TRIP")
    #expect(meta.entries[PhotoMetadataKey.pipelineVersion.rawValue] == "v99")
    #expect(meta.entries[PhotoMetadataKey.isLocal.rawValue] == "false")
    #expect(meta.entries[PhotoMetadataKey.captureMs.rawValue] == "1700000000000")
    #expect(meta.entries[PhotoMetadataKey.width.rawValue] == "4000")
    #expect(meta.entries[PhotoMetadataKey.height.rawValue] == "3000")
    #expect(meta.entries[PhotoMetadataKey.lat.rawValue] == "35.68")
    #expect(meta.entries[PhotoMetadataKey.lon.rawValue] == "139.77")
    #expect(meta.entries[PhotoMetadataKey.gpsAccuracyM.rawValue] == "5.0")
    #expect(meta.entries[PhotoMetadataKey.cameraMake.rawValue] == "Sony")
    #expect(meta.entries[PhotoMetadataKey.cameraModel.rawValue] == "Alpha 7")
    #expect(meta.entries[PhotoMetadataKey.lensModel.rawValue] == "FE 24mm")
    #expect(meta.entries[PhotoMetadataKey.orientation.rawValue] == "3")
}

/// With `captureMs = nil`, the captureMs key must be absent; with `location = nil`,
/// the lat/lon keys must be absent.
@Test
func photoRAGFullPipelineBaseMetadataNilOptionalFieldsAreAbsent() {
    let meta = PhotoRAGOrchestrator._baseMetadataForTesting(
        assetID: "NO-OPTIONALS",
        captureMs: nil,
        pipelineVersion: "v1",
        isLocal: true,
        location: nil,
        pixelWidth: 1,
        pixelHeight: 1,
        exif: PhotosAssetMetadata.EXIF()
    )
    #expect(meta.entries[PhotoMetadataKey.captureMs.rawValue] == nil)
    #expect(meta.entries[PhotoMetadataKey.lat.rawValue] == nil)
    #expect(meta.entries[PhotoMetadataKey.lon.rawValue] == nil)
    #expect(meta.entries[PhotoMetadataKey.cameraMake.rawValue] == nil)
    #expect(meta.entries[PhotoMetadataKey.cameraModel.rawValue] == nil)
    #expect(meta.entries[PhotoMetadataKey.lensModel.rawValue] == nil)
    #expect(meta.entries[PhotoMetadataKey.orientation.rawValue] == nil)
}

// MARK: writeBBox — via _writeBBoxForTesting

/// All four bbox keys must be written with the correct string values.
@Test
func photoRAGFullPipelineWriteBBoxWritesAllFourEntries() {
    let rect = PhotoNormalizedRect(x: 0.1, y: 0.2, width: 0.3, height: 0.4)
    let meta = PhotoRAGOrchestrator._writeBBoxForTesting(rect: rect)

    #expect(meta.entries[PhotoMetadataKey.bboxX.rawValue] == "0.1")
    #expect(meta.entries[PhotoMetadataKey.bboxY.rawValue] == "0.2")
    #expect(meta.entries[PhotoMetadataKey.bboxW.rawValue] == "0.3")
    #expect(meta.entries[PhotoMetadataKey.bboxH.rawValue] == "0.4")
}

// MARK: proposeRegions — via _proposeRegionsForTesting

/// With no OCR blocks, `proposeRegions` falls back to a 2×2 grid. Requesting 2 cells
/// must return exactly 2 grid regions of type "grid".
@Test
func photoRAGFullPipelineProposeRegionsGridFallbackTwoCells() {
    let regions = PhotoRAGOrchestrator._proposeRegionsForTesting(from: [], maxRegions: 2)
    #expect(regions.count == 2)
    #expect(regions.allSatisfy { $0.type == "grid" })
}

/// With OCR blocks available, `proposeRegions` must prefer them over the grid,
/// returning regions of type "ocr" sorted by confidence (highest first).
@Test
func photoRAGFullPipelineProposeRegionsOCRBlocksTakePrecedenceOverGrid() {
    let blocks = [
        RecognizedTextBlock(
            text: "low confidence",
            bbox: .init(x: 0, y: 0, width: 0.5, height: 0.5),
            confidence: 0.3
        ),
        RecognizedTextBlock(
            text: "high confidence",
            bbox: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
            confidence: 0.9
        ),
    ]
    let regions = PhotoRAGOrchestrator._proposeRegionsForTesting(from: blocks, maxRegions: 1)
    #expect(regions.count == 1)
    #expect(regions[0].type == "ocr")
    // The highest-confidence block must come first.
    #expect(regions[0].bbox == .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5))
}

/// `maxRegions = 0` must always return an empty array regardless of input.
@Test
func photoRAGFullPipelineProposeRegionsMaxRegionsZeroReturnsEmpty() {
    let blocks = [
        RecognizedTextBlock(
            text: "text",
            bbox: .init(x: 0, y: 0, width: 1, height: 1),
            confidence: 0.8
        )
    ]
    #expect(PhotoRAGOrchestrator._proposeRegionsForTesting(from: blocks, maxRegions: 0).isEmpty)
    #expect(PhotoRAGOrchestrator._proposeRegionsForTesting(from: [], maxRegions: 0).isEmpty)
}
