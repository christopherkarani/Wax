#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WaxCore
import WaxVectorSearch

#if canImport(Photos)
@preconcurrency import Photos
#endif

#if canImport(CoreLocation)
import CoreLocation
#endif

/// On-device (no cloud) retrieval-augmented generation (RAG) over a user’s Photos library.
///
/// `PhotoRAGOrchestrator` ingests `PHAsset`s (offline-only), extracts metadata/OCR, computes
/// multimodal embeddings, indexes everything in Wax, and serves hybrid retrieval to assemble
/// RAG-ready context with text surrogates and optional pixel payloads (thumbnails/crops).
package actor PhotoRAGOrchestrator {
    enum MetaKey {
        static let assetID = PhotoMetadataKey.assetID.rawValue
        static let source = PhotoMetadataKey.source.rawValue
        static let fileURL = PhotoMetadataKey.fileURL.rawValue
        static let captureMs = PhotoMetadataKey.captureMs.rawValue
        static let isLocal = PhotoMetadataKey.isLocal.rawValue
        static let pipelineVersion = PhotoMetadataKey.pipelineVersion.rawValue

        static let lat = PhotoMetadataKey.lat.rawValue
        static let lon = PhotoMetadataKey.lon.rawValue
        static let gpsAccuracyM = PhotoMetadataKey.gpsAccuracyM.rawValue

        static let cameraMake = PhotoMetadataKey.cameraMake.rawValue
        static let cameraModel = PhotoMetadataKey.cameraModel.rawValue
        static let lensModel = PhotoMetadataKey.lensModel.rawValue

        static let width = PhotoMetadataKey.width.rawValue
        static let height = PhotoMetadataKey.height.rawValue
        static let orientation = PhotoMetadataKey.orientation.rawValue

        static let bboxX = PhotoMetadataKey.bboxX.rawValue
        static let bboxY = PhotoMetadataKey.bboxY.rawValue
        static let bboxW = PhotoMetadataKey.bboxW.rawValue
        static let bboxH = PhotoMetadataKey.bboxH.rawValue
        static let regionType = PhotoMetadataKey.regionType.rawValue

        static let syncScope = PhotoMetadataKey.syncScope.rawValue
        static let syncAssetCount = PhotoMetadataKey.syncAssetCount.rawValue
        static let syncCompletedAtMs = PhotoMetadataKey.syncCompletedAtMs.rawValue
    }

    struct LocationBin: Hashable, Sendable {
        var latBin: Int
        var lonBin: Int
    }

    struct DerivedRefs: Sendable {
        var ocrSummary: UInt64?
        var caption: UInt64?
        var tags: UInt64?
        var regions: [UInt64] = []
        var ocrBlocks: [UInt64] = []
    }

    struct RootCandidate: Sendable {
        var rootId: UInt64
        var score: Float
        var evidence: [PhotoRAGItem.Evidence]
        var matchedRegions: [PhotoNormalizedRect]
        var textSnippet: String?
    }

    struct IndexState: Sendable {
        var rootByPhotoID: [PhotoID: UInt64] = [:]
        var photoIDByRoot: [UInt64: PhotoID] = [:]
        var derivedByRoot: [UInt64: DerivedRefs] = [:]
        var locationBins: [LocationBin: Set<UInt64>] = [:]
        var locationByFrame: [UInt64: PhotoCoordinate] = [:]
    }

    /// The underlying Wax store for frame storage and indexing.
    package let wax: Wax
    /// The active Wax session for reads and writes.
    package let session: WaxSession
    /// Configuration controlling pixel sizes, OCR, regions, search parameters, and budgets.
    package let config: PhotoRAGConfig

    let embedder: any MultimodalEmbeddingProvider
    let ocr: (any OCRProvider)?
    let captioner: (any CaptionProvider)?
    private let queryEmbeddingCache: EmbeddingMemoizer?

    var index = IndexState()
    var inFlightPhotoIDs: Set<PhotoID> = []
    /// Serializes calls that write trees or commit, from the first write through the index rebuild.
    package let ingestMutex = AsyncMutex()

    package init(
        storeURL: URL,
        config: PhotoRAGConfig = .default,
        embedder: any MultimodalEmbeddingProvider,
        ocr: (any OCRProvider)? = nil,
        captioner: (any CaptionProvider)? = nil
    ) async throws {
        self.config = config
        self.embedder = embedder
        self.captioner = captioner
        self.ocr = ocr

        if config.requireOnDeviceProviders {
            var checks: [ProviderValidation.ProviderCheck] = [
                .init(name: "embedding provider", executionMode: embedder.executionMode)
            ]
            if let ocr {
                checks.append(.init(name: "OCR provider", executionMode: ocr.executionMode))
            }
            if let captioner {
                checks.append(.init(name: "caption provider", executionMode: captioner.executionMode))
            }
            try ProviderValidation.validateOnDevice(checks, orchestratorName: "PhotoRAG")
        }

        if FileManager.default.fileExists(atPath: storeURL.path(percentEncoded: false)) {
            self.wax = try await Wax.open(at: storeURL)
        } else {
            self.wax = try await Wax.create(at: storeURL)
        }

        if config.vectorEnginePreference != .cpuOnly, embedder.normalize == false {
            throw WaxError.io("Metal vector search requires normalized embeddings (set embedder.normalize=true or use cpuOnly)")
        }

        let sessionConfig = WaxSession.Config(
            enableTextSearch: true,
            enableVectorSearch: true,
            enableStructuredMemory: false,
            vectorEnginePreference: config.vectorEnginePreference,
            vectorMetric: .cosine,
            vectorDimensions: embedder.dimensions
        )
        self.session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

        self.queryEmbeddingCache = EmbeddingMemoizer.fromConfig(capacity: config.queryEmbeddingCacheCapacity)

        try await rebuildIndex()
    }

    /// Delete all frames associated with a given ``PhotoID``.
    package func delete(photoID: PhotoID) async throws {
        try await ingestMutex.withLock {
            try await self.deleteUnderLock(photoID: photoID)
        }
    }

    private func deleteUnderLock(photoID: PhotoID) async throws {
        guard let rootId = index.rootByPhotoID[photoID] else { return }

        var toDelete: [UInt64] = [rootId]
        if let refs = index.derivedByRoot[rootId] {
            if let id = refs.ocrSummary { toDelete.append(id) }
            if let id = refs.caption { toDelete.append(id) }
            if let id = refs.tags { toDelete.append(id) }
            toDelete.append(contentsOf: refs.regions)
            toDelete.append(contentsOf: refs.ocrBlocks)
        }

        for frameId in toDelete {
            try await wax.delete(frameId: frameId)
        }
        try await removeSearchIndexes(frameIds: toDelete)
        try await session.commit()
        try await rebuildIndex()
    }

    /// Removes vector-index entries for a superseded root and its derived frames.
    /// Superseded frames are retained for audit/debug but must not stay searchable as
    /// ghost hits. Must run before `rebuildIndex()` while the retired tree is still
    /// present in `index`.
    func removeVectorsForRetiredTree(_ rootId: UInt64) async throws {
        var ids: [UInt64] = [rootId]
        if let refs = index.derivedByRoot[rootId] {
            if let id = refs.ocrSummary { ids.append(id) }
            if let id = refs.caption { ids.append(id) }
            if let id = refs.tags { ids.append(id) }
            ids.append(contentsOf: refs.regions)
            ids.append(contentsOf: refs.ocrBlocks)
        }
        try await removeSearchIndexes(frameIds: ids)
    }

    /// Deletes a tree whose ingest failed before it superseded the previous version, so the
    /// asset keeps its previous version (or nothing) rather than a partial second live tree.
    /// Best-effort: the ingest error is what the caller reports.
    func discardPartialTree(rootId: UInt64) async {
        let children = await wax.frameMetasIncludingPending().filter { $0.parentId == rootId }
        let frameIds = [rootId] + children.map(\.id)
        do {
            for frameId in frameIds {
                try await wax.delete(frameId: frameId)
            }
            try await removeSearchIndexes(frameIds: frameIds)
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "PhotoRAG partial-tree discard",
                fallback: "partial tree may stay live until the asset is re-ingested"
            )
        }
    }

    /// Ends an ingest call that failed partway: commits the trees that completed and rebuilds
    /// the index so it matches the store. Best-effort: the ingest error is what the caller reports.
    func reconcileAfterFailedIngest() async {
        do {
            try await session.commit()
            try await rebuildIndex()
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "PhotoRAG failed-ingest reconcile",
                fallback: "completed trees stay pending until the next flush"
            )
        }
    }

    /// Drops vector and text postings for frames that must no longer be searchable.
    /// Text cleanup is required: otherwise BM25 keeps ranking deleted/superseded
    /// OCR frames and live re-ingests of the same asset disappear from recall.
    private func removeSearchIndexes(frameIds: [UInt64]) async throws {
        for frameId in frameIds {
            try await session.removeVector(frameId: frameId)
            try await session.removeText(frameId: frameId)
        }
    }

    /// Flush pending writes to disk.
    package func flush() async throws {
        try await ingestMutex.withLock {
            try await self.session.commit()
        }
    }

    /// Flush pending writes, then close the session and the underlying store.
    ///
    /// The orchestrator must not be used after `close()` returns.
    package func close() async throws {
        // A failed flush must not keep the store open: only `wax.close()` releases the file lock.
        var flushError: (any Error)?
        do {
            try await flush()
        } catch {
            flushError = error
        }
        await session.close()
        do {
            try await wax.close()
        } catch {
            throw flushError ?? error
        }
        if let flushError { throw flushError }
    }

    static func dedupePhotoIDs(_ photoIDs: [PhotoID]) -> [PhotoID] {
        guard photoIDs.count > 1 else { return photoIDs }
        var seen: Set<PhotoID> = []
        seen.reserveCapacity(photoIDs.count)
        var unique: [PhotoID] = []
        unique.reserveCapacity(photoIDs.count)
        for photoID in photoIDs where seen.insert(photoID).inserted {
            unique.append(photoID)
        }
        return unique
    }

    /// Rewrites source to `.photos`, then order-preserving-dedupes.
    static func photosLibraryIDs(_ photoIDs: [PhotoID]) -> [PhotoID] {
        dedupePhotoIDs(photoIDs.map { PhotoID(source: .photos, id: $0.id) })
    }

    static func dedupePhotoFiles(_ files: [PhotoFile]) -> [PhotoFile] {
        guard files.count > 1 else { return files }
        var seen: Set<PhotoID> = []
        seen.reserveCapacity(files.count)
        var unique: [PhotoFile] = []
        unique.reserveCapacity(files.count)
        for file in files where seen.insert(file.id).inserted {
            unique.append(file)
        }
        return unique
    }

    func embedQueryText(_ text: String) async throws -> [Float] {
        let key = EmbeddingKey.make(
            text: text,
            identity: embedder.identity,
            dimensions: embedder.dimensions,
            normalized: embedder.normalize
        )
        if let cached = await queryEmbeddingCache?.get(key) {
            return cached
        }

        var vec = try await embedder.embed(text: text)
        if embedder.normalize, !vec.isEmpty { vec = VectorMath.normalizeL2(vec) }
        guard vec.count == embedder.dimensions else {
            throw WaxError.invalidEmbedding(reason: "embedder produced \(vec.count) dims for query text, expected \(embedder.dimensions)")
        }
        await queryEmbeddingCache?.set(key, value: vec)
        return vec
    }
}

#endif // canImport(ImageIO)
