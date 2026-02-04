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
public actor PhotoRAGOrchestrator {
    private enum FrameKind {
        static let root = "photo.root"
        static let ocrBlock = "photo.ocr.block"
        static let ocrSummary = "photo.ocr.summary"
        static let captionShort = "photo.caption.short"
        static let tags = "photo.tags"
        static let region = "photo.region"
        static let syncState = "system.photos.sync_state"
    }

    private enum MetaKey {
        static let assetID = "photos.asset_id"
        static let captureMs = "photo.capture_ms"
        static let isLocal = "photo.availability.local"
        static let pipelineVersion = "photo.pipeline.version"

        static let lat = "photo.location.lat"
        static let lon = "photo.location.lon"
        static let gpsAccuracyM = "photo.location.accuracy_m"

        static let cameraMake = "photo.camera.make"
        static let cameraModel = "photo.camera.model"
        static let lensModel = "photo.lens"

        static let width = "photo.width"
        static let height = "photo.height"
        static let orientation = "photo.orientation"

        static let bboxX = "photo.bbox.x"
        static let bboxY = "photo.bbox.y"
        static let bboxW = "photo.bbox.w"
        static let bboxH = "photo.bbox.h"
        static let regionType = "photo.region.type"
    }

    private struct LocationBin: Hashable, Sendable {
        var latBin: Int
        var lonBin: Int
    }

    private struct DerivedRefs: Sendable {
        var ocrSummary: UInt64?
        var caption: UInt64?
        var tags: UInt64?
        var regions: [UInt64] = []
    }

    private struct RootCandidate: Sendable {
        var rootId: UInt64
        var score: Float
        var evidence: [PhotoRAGItem.Evidence]
        var matchedRegions: [PhotoNormalizedRect]
        var textSnippet: String?
    }

    private struct IndexState: Sendable {
        var rootByAssetID: [String: UInt64] = [:]
        var assetIDByRoot: [UInt64: String] = [:]
        var derivedByRoot: [UInt64: DerivedRefs] = [:]
        var locationBins: [LocationBin: Set<UInt64>] = [:]
    }

    public let wax: Wax
    public let session: WaxSession
    public let config: PhotoRAGConfig

    private let embedder: any MultimodalEmbeddingProvider
    private let ocr: (any OCRProvider)?
    private let captioner: (any CaptionProvider)?
    private let queryEmbeddingCache: EmbeddingMemoizer?

    private var index = IndexState()

    public init(
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

        if FileManager.default.fileExists(atPath: storeURL.path) {
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

        if config.queryEmbeddingCacheCapacity > 0 {
            self.queryEmbeddingCache = EmbeddingMemoizer(capacity: config.queryEmbeddingCacheCapacity)
        } else {
            self.queryEmbeddingCache = nil
        }

        try await rebuildIndex()
    }

    // MARK: - Public API

    /// Sync the Photos library into the local Wax store.
    ///
    /// The implementation fetches asset identifiers on the MainActor, then ingests by identifier only.
    public func syncLibrary(scope: PhotoScope) async throws {
        #if canImport(Photos)
        let ids: [String] = switch scope {
        case .assetIDs(let ids):
            ids
        case .fullLibrary:
            await MainActor.run {
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                let result = PHAsset.fetchAssets(with: opts)
                if result.count == 0 { return [] }
                var ids: [String] = []
                ids.reserveCapacity(result.count)
                for index in 0..<result.count {
                    ids.append(result.object(at: index).localIdentifier)
                }
                return ids
            }
        }
        try await ingest(assetIDs: ids)
        #else
        throw WaxError.io("Photos framework unavailable on this platform")
        #endif
    }

    /// Convenience wrapper: accepts PHAssets but only passes stable IDs into the actor.
    @MainActor
    public func ingest(assets: [PHAsset]) async throws {
        let ids = assets.map(\.localIdentifier)
        try await self.ingest(assetIDs: ids)
    }

    /// Ingest photos by `PHAsset.localIdentifier`.
    ///
    /// This method enforces offline-only ingestion. If an asset’s bytes are not locally available
    /// (iCloud-only), it is indexed as metadata-only and marked degraded.
    public func ingest(assetIDs: [String]) async throws {
        let uniqueAssetIDs = Self.dedupeAssetIDs(assetIDs)
        guard !uniqueAssetIDs.isEmpty else { return }

        // Note: Actor isolation serializes ingestion for correctness. `ingestConcurrency` is reserved for a future
        // optimization that parallelizes decode/embedding outside the actor without leaking non-Sendable types.
        for assetID in uniqueAssetIDs {
            try await ingestOne(assetID: assetID)
        }

        try await session.commit()
        try await rebuildIndex()
    }

    public func recall(_ query: PhotoQuery) async throws -> PhotoRAGContext {
        let cleanedText = query.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = (cleanedText?.isEmpty == false) ? cleanedText : nil

        let queryEmbedding = try await buildQueryEmbedding(text: queryText, image: query.image)

        let mode: SearchMode = {
            if queryText == nil {
                return .vectorOnly
            }
            if queryEmbedding == nil {
                return .textOnly
            }
            return .hybrid(alpha: config.hybridAlpha)
        }()

        let timeRange = Self.toWaxTimeRange(query.timeRange)

        let locationAllowlist = query.location.flatMap { buildLocationAllowlist(location: $0) }

        let isConstraintOnlyQuery = (queryText == nil && queryEmbedding == nil)
            && (query.timeRange != nil || query.location != nil)
        let fallbackLimit = max(query.resultLimit, config.searchTopK)

        let request = SearchRequest(
            query: queryText,
            embedding: queryEmbedding,
            vectorEnginePreference: config.vectorEnginePreference,
            mode: mode,
            topK: max(query.resultLimit, config.searchTopK),
            timeRange: timeRange,
            frameFilter: locationAllowlist.map { FrameFilter(frameIds: $0) },
            previewMaxBytes: 1024,
            allowTimelineFallback: isConstraintOnlyQuery,
            timelineFallbackLimit: fallbackLimit
        )

        let response = try await wax.search(request)
        guard !response.results.isEmpty else {
            return PhotoRAGContext(query: query, items: [], diagnostics: .init())
        }

        let frameIds = response.results.map(\.frameId)
        let metaById = await wax.frameMetasIncludingPending(frameIds: frameIds)

        var rootIds: Set<UInt64> = []
        rootIds.reserveCapacity(response.results.count)
        for result in response.results {
            if let meta = metaById[result.frameId] {
                rootIds.insert(meta.parentId ?? meta.id)
            }
        }

        let rootMetaById = await wax.frameMetasIncludingPending(frameIds: Array(rootIds))

        var candidates: [UInt64: RootCandidate] = [:]
        candidates.reserveCapacity(rootIds.count)

        for result in response.results {
            guard let meta = metaById[result.frameId] else { continue }
            let rootId = meta.parentId ?? meta.id
            guard let rootMeta = rootMetaById[rootId] else { continue }
            guard rootMeta.kind == FrameKind.root else { continue }
            if rootMeta.status == .deleted { continue }
            if rootMeta.supersededBy != nil { continue }

            let ev = Self.evidence(from: result, meta: meta)

            var entry = candidates[rootId] ?? RootCandidate(
                rootId: rootId,
                score: result.score,
                evidence: [],
                matchedRegions: [],
                textSnippet: nil
            )
            entry.score = max(entry.score, result.score)
            if let ev, !entry.evidence.contains(ev) {
                entry.evidence.append(ev)
            }
            if let rect = Self.regionRect(from: meta) {
                entry.matchedRegions.append(rect)
            }
            if entry.textSnippet == nil, (result.sources.contains(.text) || meta.kind == FrameKind.ocrSummary) {
                entry.textSnippet = result.previewText
            }
            candidates[rootId] = entry
        }

        // Build summary text for the top candidates, then apply budgets.
        let sorted = candidates.values.sorted { a, b in
            if a.score != b.score { return a.score > b.score }
            return a.rootId < b.rootId
        }

        let limit = query.resultLimit
        let picked = Array(sorted.prefix(limit))
        let rootIdsPicked = picked.map(\.rootId)

        // Resolve asset IDs and derived frame refs.
        var assetIdByRoot: [UInt64: String] = [:]
        assetIdByRoot.reserveCapacity(rootIdsPicked.count)
        for rootId in rootIdsPicked {
            if let cached = index.assetIDByRoot[rootId] {
                assetIdByRoot[rootId] = cached
                continue
            }
            if let meta = rootMetaById[rootId],
               let entries = meta.metadata?.entries,
               let assetID = entries[MetaKey.assetID] {
                assetIdByRoot[rootId] = assetID
            }
        }

        // Load derived texts in a single batch.
        var derivedFrameIds: [UInt64] = []
        derivedFrameIds.reserveCapacity(rootIdsPicked.count * 3)
        for rootId in rootIdsPicked {
            if let refs = index.derivedByRoot[rootId] {
                if let id = refs.caption { derivedFrameIds.append(id) }
                if let id = refs.ocrSummary { derivedFrameIds.append(id) }
                if let id = refs.tags { derivedFrameIds.append(id) }
            }
        }
        let derivedContents = try await wax.frameContents(frameIds: derivedFrameIds)

        func text(from frameId: UInt64?) -> String? {
            guard let frameId, let data = derivedContents[frameId] else { return nil }
            return String(data: data, encoding: .utf8)
        }

        let tokenCounter = try await TokenCounter.shared()
        var items: [PhotoRAGItem] = []
        items.reserveCapacity(picked.count)

        for candidate in picked {
            guard let assetID = assetIdByRoot[candidate.rootId] else { continue }
            let refs = index.derivedByRoot[candidate.rootId] ?? DerivedRefs()

            let caption = text(from: refs.caption)
            let ocrSummary = text(from: refs.ocrSummary)
            let tags = text(from: refs.tags)

            let rootMeta = rootMetaById[candidate.rootId]
            let summary = Self.buildSummaryText(
                root: rootMeta,
                caption: caption,
                ocrSummary: ocrSummary,
                tags: tags,
                query: query,
                maxOCRLines: query.contextBudget.maxOCRLinesPerItem
            )

            items.append(
                PhotoRAGItem(
                    assetID: assetID,
                    score: candidate.score,
                    evidence: candidate.evidence,
                    summaryText: summary,
                    thumbnail: nil,
                    regions: []
                )
            )
        }

        // Apply text budget.
        let perItemCap = max(1, query.contextBudget.maxTextTokens / max(1, items.count))
        let processed = await tokenCounter.countAndTruncateBatch(items.map(\.summaryText), maxTokens: perItemCap)
        var usedTokens = 0
        var budgetedItems: [PhotoRAGItem] = []
        budgetedItems.reserveCapacity(items.count)
        for (index, item) in items.enumerated() {
            let (tokens, capped) = processed[index]
            guard usedTokens + tokens <= query.contextBudget.maxTextTokens else { break }
            usedTokens += tokens
            var updated = item
            updated.summaryText = capped
            budgetedItems.append(updated)
        }

        // Optionally attach thumbnails and region crops (offline-only, Photos-backed).
        let itemsWithPixels = try await attachPixels(
            items: budgetedItems,
            rootCandidates: picked,
            maxImages: query.contextBudget.maxImages,
            maxRegions: query.contextBudget.maxRegions
        )

        let degradedCount = itemsWithPixels.filter { isDegraded(assetID: $0.assetID) }.count
        let diagnostics = PhotoRAGContext.Diagnostics(usedTextTokens: usedTokens, degradedResultCount: degradedCount)
        return PhotoRAGContext(query: query, items: itemsWithPixels, diagnostics: diagnostics)
    }

    /// Delete all frames associated with a given `PHAsset.localIdentifier` (including older, superseded versions).
    public func delete(assetID: String) async throws {
        // Robust: scan once; deletion is a rare operation and should be correct.
        let metas = await wax.frameMetas()
        var toDelete: [UInt64] = []
        toDelete.reserveCapacity(32)
        for meta in metas {
            guard meta.status != .deleted else { continue }
            guard let entries = meta.metadata?.entries,
                  entries[MetaKey.assetID] == assetID
            else { continue }
            toDelete.append(meta.id)
        }
        for frameId in toDelete {
            try await wax.delete(frameId: frameId)
        }
        try await session.commit()
        try await rebuildIndex()
    }

    /// Flush pending writes to disk.
    public func flush() async throws {
        try await session.commit()
    }

    // MARK: - Ingest internals

    private func ingestOne(assetID: String) async throws {
        #if canImport(Photos)
        let metadata = try await PhotosAssetMetadata.load(assetID: assetID)

        let captureMs = metadata.captureMs
        let frameTimestampMs = captureMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let isLocal = metadata.isLocal
        let baseMeta = Self.baseMetadata(
            assetID: assetID,
            captureMs: captureMs,
            pipelineVersion: config.pipelineVersion,
            isLocal: isLocal,
            location: metadata.location,
            pixelWidth: metadata.pixelWidth,
            pixelHeight: metadata.pixelHeight,
            exif: metadata.exif
        )

        // If we have a previous root, we supersede it after writing the new root.
        // Note: We intentionally keep old frames for audit/debug; superseded roots (and their children)
        // are filtered out by default in indexing and retrieval.
        let previousRoot = index.rootByAssetID[assetID]

        if !isLocal {
            // Metadata-only ingest
            let options = FrameMetaSubset(
                kind: FrameKind.root,
                metadata: baseMeta
            )
            let rootId = try await session.put(Data(), options: options, compression: .plain, timestampMs: frameTimestampMs)
            if let previousRoot {
                try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
            }
            return
        }

        guard let imageData = metadata.imageData else {
            // Treat as non-local if data couldn't be loaded without network.
            var degradedMeta = baseMeta
            degradedMeta.entries[MetaKey.isLocal] = "false"
            let options = FrameMetaSubset(
                kind: FrameKind.root,
                metadata: degradedMeta
            )
            let rootId = try await session.put(
                Data(),
                options: options,
                compression: .plain,
                timestampMs: frameTimestampMs
            )
            if let previousRoot {
                try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
            }
            return
        }

        // Decode derivative images (orientation-correct) from the same source bytes.
        let embedImage = try Self.decodeThumbnail(from: imageData, maxPixelSize: config.embedMaxPixelSize)
        let ocrImage = try Self.decodeThumbnail(from: imageData, maxPixelSize: config.ocrMaxPixelSize)

        // Global embedding
        var globalEmbedding = try await embedder.embed(image: embedImage)
        if embedder.normalize, !globalEmbedding.isEmpty {
            globalEmbedding = VectorMath.normalizeL2(globalEmbedding)
        }
        guard globalEmbedding.count == embedder.dimensions else {
            throw WaxError.io("embedder produced \(globalEmbedding.count) dims for image, expected \(embedder.dimensions)")
        }

        // Root frame
        let rootOptions = FrameMetaSubset(
            kind: FrameKind.root,
            metadata: baseMeta
        )

        let rootId = try await session.put(
            Data(),
            embedding: globalEmbedding,
            identity: embedder.identity,
            options: rootOptions,
            compression: .plain,
            timestampMs: frameTimestampMs
        )

        // OCR
        var ocrBlocks: [RecognizedTextBlock] = []
        if config.enableOCR, let ocr = ocr ?? Self.defaultOCRProvider() {
            ocrBlocks = try await ocr.recognizeText(in: ocrImage)
        }

        // Caption
        let captionText: String? = if let captioner {
            try? await captioner.caption(for: ocrImage)
        } else {
            Self.weakCaption(metadata: metadata, ocrBlocks: ocrBlocks)
        }

        // Derived frames to write (non-embedded)
        var derivedContents: [Data] = []
        var derivedOptions: [FrameMetaSubset] = []
        var derivedTextsForIndex: [(frameIndex: Int, text: String)] = []

        func addDerived(kind: String, text: String, searchable: Bool) {
            let idx = derivedContents.count
            derivedContents.append(Data(text.utf8))
            var subset = FrameMetaSubset(kind: kind, parentId: rootId, metadata: baseMeta)
            subset.role = .blob
            derivedOptions.append(subset)
            if searchable {
                derivedTextsForIndex.append((frameIndex: idx, text: text))
            }
        }

        if let captionText, !captionText.isEmpty {
            addDerived(kind: FrameKind.captionShort, text: captionText, searchable: true)
        }

        // OCR block frames (not indexed) + one summary frame (indexed)
        if !ocrBlocks.isEmpty {
            // Summary
            let summary = Self.buildOCRSummary(ocrBlocks, maxLines: 32)
            if !summary.isEmpty {
                addDerived(kind: FrameKind.ocrSummary, text: summary, searchable: true)
            }

            // Blocks
            for block in ocrBlocks.prefix(64) {
                var meta = baseMeta
                Self.writeBBox(into: &meta, rect: block.bbox)
                meta.entries["photo.ocr.confidence"] = String(block.confidence)
                if let lang = block.language {
                    meta.entries["photo.ocr.language"] = lang
                }
                let text = block.text
                let idx = derivedContents.count
                derivedContents.append(Data(text.utf8))
                var subset = FrameMetaSubset(kind: FrameKind.ocrBlock, parentId: rootId, metadata: meta)
                subset.role = .blob
                derivedOptions.append(subset)
                _ = idx
            }
        }

        let derivedIds = try await session.putBatch(
            contents: derivedContents,
            options: derivedOptions,
            compression: .plain,
            timestampsMs: Array(repeating: frameTimestampMs, count: derivedContents.count)
        )

        // Index searchable derived frames.
        if !derivedTextsForIndex.isEmpty {
            var frameIds: [UInt64] = []
            var texts: [String] = []
            frameIds.reserveCapacity(derivedTextsForIndex.count)
            texts.reserveCapacity(derivedTextsForIndex.count)
            for entry in derivedTextsForIndex {
                frameIds.append(derivedIds[entry.frameIndex])
                texts.append(entry.text)
            }
            try await session.indexTextBatch(frameIds: frameIds, texts: texts)
        }

        // Regions (OCR-driven and/or grid)
        if config.enableRegionEmbeddings, config.maxRegionsPerPhoto > 0 {
            let regions = Self.proposeRegions(from: ocrBlocks, maxRegions: config.maxRegionsPerPhoto)
            if !regions.isEmpty {
                var regionEmbeddings: [[Float]] = []
                var regionContents: [Data] = []
                var regionOptions: [FrameMetaSubset] = []
                regionEmbeddings.reserveCapacity(regions.count)
                regionContents.reserveCapacity(regions.count)
                regionOptions.reserveCapacity(regions.count)

                for region in regions {
                    guard let crop = Self.crop(embedImage, rect: region.bbox) else { continue }
                    var vec = try await embedder.embed(image: crop)
                    if embedder.normalize, !vec.isEmpty { vec = VectorMath.normalizeL2(vec) }
                    guard vec.count == embedder.dimensions else {
                        throw WaxError.io("embedder produced \(vec.count) dims for region image, expected \(embedder.dimensions)")
                    }
                    regionEmbeddings.append(vec)
                    regionContents.append(Data())

                    var meta = baseMeta
                    Self.writeBBox(into: &meta, rect: region.bbox)
                    meta.entries[MetaKey.regionType] = region.type
                    let subset = FrameMetaSubset(kind: FrameKind.region, role: .blob, parentId: rootId, metadata: meta)
                    regionOptions.append(subset)
                }

                _ = try await session.putBatch(
                    contents: regionContents,
                    embeddings: regionEmbeddings,
                    identity: embedder.identity,
                    options: regionOptions,
                    compression: .plain,
                    timestampsMs: Array(repeating: frameTimestampMs, count: regionContents.count)
                )
            }
        }

        if let previousRoot {
            try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
        }
        #else
        throw WaxError.io("Photos framework unavailable on this platform")
        #endif
    }

    // MARK: - Indexing

    private func rebuildIndex() async throws {
        let metas = await wax.frameMetas()

        var supersededRoots: Set<UInt64> = []
        supersededRoots.reserveCapacity(64)
        for meta in metas where meta.kind == FrameKind.root {
            if meta.supersededBy != nil {
                supersededRoots.insert(meta.id)
            }
        }

        var next = IndexState()

        for meta in metas {
            guard meta.status != .deleted else { continue }
            guard let kind = meta.kind else { continue }
            if !kind.hasPrefix("photo.") && kind != FrameKind.syncState { continue }
            guard let entries = meta.metadata?.entries,
                  let assetID = entries[MetaKey.assetID]
            else { continue }

            if kind == FrameKind.root {
                guard meta.supersededBy == nil else { continue }
                next.rootByAssetID[assetID] = meta.id
                next.assetIDByRoot[meta.id] = assetID
            }

            if let parentId = meta.parentId {
                guard !supersededRoots.contains(parentId) else { continue }
                var refs = next.derivedByRoot[parentId] ?? DerivedRefs()
                switch kind {
                case FrameKind.ocrSummary:
                    refs.ocrSummary = meta.id
                case FrameKind.captionShort:
                    refs.caption = meta.id
                case FrameKind.tags:
                    refs.tags = meta.id
                case FrameKind.region:
                    refs.regions.append(meta.id)
                default:
                    break
                }
                next.derivedByRoot[parentId] = refs
            }

            if Self.isSearchablePhotoKind(kind),
               let bin = Self.locationBin(from: entries) {
                next.locationBins[bin, default: []].insert(meta.id)
            }
        }

        index = next
    }

    private static func isSearchablePhotoKind(_ kind: String) -> Bool {
        switch kind {
        case FrameKind.root, FrameKind.ocrSummary, FrameKind.captionShort, FrameKind.tags, FrameKind.region:
            return true
        default:
            return false
        }
    }

    // MARK: - Location allowlist

    private func buildLocationAllowlist(location: PhotoLocationQuery) -> Set<UInt64>? {
        let center = location.center
        let radius = location.radiusMeters

        guard radius > 0 else { return nil }

        let lat = center.latitude
        let lon = center.longitude

        let latDelta = radius / 111_000.0
        let lonDelta = radius / max(1e-6, 111_000.0 * cos(lat * .pi / 180))

        let minLat = lat - latDelta
        let maxLat = lat + latDelta
        let minLon = lon - lonDelta
        let maxLon = lon + lonDelta

        let minLatBin = Int(floor(minLat * 100.0))
        let maxLatBin = Int(floor(maxLat * 100.0))
        let minLonBin = Int(floor(minLon * 100.0))
        let maxLonBin = Int(floor(maxLon * 100.0))

        var allowlist: Set<UInt64> = []
        for latBin in minLatBin...maxLatBin {
            for lonBin in minLonBin...maxLonBin {
                let bin = LocationBin(latBin: latBin, lonBin: lonBin)
                if let ids = index.locationBins[bin] {
                    allowlist.formUnion(ids)
                }
            }
        }
        return allowlist
    }

    static func dedupeAssetIDs(_ assetIDs: [String]) -> [String] {
        guard assetIDs.count > 1 else { return assetIDs }
        var seen: Set<String> = []
        seen.reserveCapacity(assetIDs.count)
        var unique: [String] = []
        unique.reserveCapacity(assetIDs.count)
        for assetID in assetIDs where seen.insert(assetID).inserted {
            unique.append(assetID)
        }
        return unique
    }

    private static func locationBin(from meta: [String: String]) -> LocationBin? {
        guard let latStr = meta[MetaKey.lat],
              let lonStr = meta[MetaKey.lon],
              let lat = Double(latStr),
              let lon = Double(lonStr)
        else { return nil }
        return LocationBin(latBin: Int(floor(lat * 100.0)), lonBin: Int(floor(lon * 100.0)))
    }

    // MARK: - Query embedding

    private func buildQueryEmbedding(text: String?, image: PhotoQueryImage?) async throws -> [Float]? {
        let textEmbedding: [Float]?
        if let text, !text.isEmpty {
            textEmbedding = try await embedQueryText(text)
        } else {
            textEmbedding = nil
        }

        let imageEmbedding: [Float]?
        if let image {
            let cg = try Self.decodeThumbnail(from: image.data, maxPixelSize: config.embedMaxPixelSize)
            var vec = try await embedder.embed(image: cg)
            if embedder.normalize, !vec.isEmpty { vec = VectorMath.normalizeL2(vec) }
            guard vec.count == embedder.dimensions else {
                throw WaxError.io("embedder produced \(vec.count) dims for query image, expected \(embedder.dimensions)")
            }
            imageEmbedding = vec
        } else {
            imageEmbedding = nil
        }

        switch (textEmbedding, imageEmbedding) {
        case (nil, nil):
            return nil
        case (let t?, nil):
            return t
        case (nil, let i?):
            return i
        case (let t?, let i?):
            // Weighted sum in shared embedding space.
            let wt: Float = 0.6
            let wi: Float = 0.4
            guard t.count == i.count else {
                throw WaxError.io("query embedding dimension mismatch (text=\(t.count), image=\(i.count))")
            }
            var out = [Float](repeating: 0, count: t.count)
            for idx in 0..<t.count {
                out[idx] = wt * t[idx] + wi * i[idx]
            }
            if embedder.normalize, !out.isEmpty { out = VectorMath.normalizeL2(out) }
            return out
        }
    }

    private func embedQueryText(_ text: String) async throws -> [Float] {
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
            throw WaxError.io("embedder produced \(vec.count) dims for query text, expected \(embedder.dimensions)")
        }
        await queryEmbeddingCache?.set(key, value: vec)
        return vec
    }

    // MARK: - Pixels (thumbnails + crops)

    private func attachPixels(
        items: [PhotoRAGItem],
        rootCandidates: [RootCandidate],
        maxImages: Int,
        maxRegions: Int
    ) async throws -> [PhotoRAGItem] {
        guard (!items.isEmpty) else { return items }
        guard config.includeThumbnailsInContext || config.includeRegionCropsInContext else { return items }
        guard maxImages > 0 || maxRegions > 0 else { return items }

        var updated = items

        // Thumbnails for the first N items.
        let thumbCount = min(maxImages, updated.count)
        if config.includeThumbnailsInContext, thumbCount > 0 {
            for index in 0..<thumbCount {
                let assetID = updated[index].assetID
                if let pixel = try await loadThumbnail(assetID: assetID) {
                    updated[index].thumbnail = pixel
                }
            }
        }

        // Region crops: take the highest-scoring matched regions first.
        if config.includeRegionCropsInContext, maxRegions > 0 {
            var remaining = maxRegions
            for index in 0..<updated.count where remaining > 0 {
                let assetID = updated[index].assetID
                guard let rootId = indexStateRootId(for: assetID) else { continue }
                let matched = rootCandidates.first(where: { $0.rootId == rootId })?.matchedRegions ?? []
                guard !matched.isEmpty else { continue }

                let source = try await loadRegionSourceImage(assetID: assetID)
                guard let source else { continue }

                var regions: [PhotoRAGItem.RegionContext] = []
                for rect in matched where remaining > 0 {
                    guard let crop = Self.crop(source, rect: rect) else { continue }
                    if let encoded = try? Self.encodePNG(crop) {
                        let pixel = PhotoPixel(data: encoded, format: .png, width: crop.width, height: crop.height)
                        regions.append(.init(bbox: rect, crop: pixel))
                    } else {
                        regions.append(.init(bbox: rect, crop: nil))
                    }
                    remaining -= 1
                }

                if !regions.isEmpty {
                    updated[index].regions = regions
                }
            }
        }

        return updated
    }

    private func indexStateRootId(for assetID: String) -> UInt64? {
        index.rootByAssetID[assetID]
    }

    private func isDegraded(assetID: String) -> Bool {
        guard let rootId = index.rootByAssetID[assetID] else { return true }
        // If the root has no derived refs and no embedding, treat as degraded. (MVP heuristic)
        let refs = index.derivedByRoot[rootId]
        return refs?.ocrSummary == nil && refs?.caption == nil
    }

    private func loadThumbnail(assetID: String) async throws -> PhotoPixel? {
        #if canImport(Photos)
        let data = try await PhotosAssetMetadata.loadImageData(assetID: assetID)
        guard let data else { return nil }
        let thumb = try Self.decodeThumbnail(from: data, maxPixelSize: config.thumbnailMaxPixelSize)
        let encoded = try Self.encodePNG(thumb)
        return PhotoPixel(data: encoded, format: .png, width: thumb.width, height: thumb.height)
        #else
        return nil
        #endif
    }

    private func loadRegionSourceImage(assetID: String) async throws -> CGImage? {
        #if canImport(Photos)
        let data = try await PhotosAssetMetadata.loadImageData(assetID: assetID)
        guard let data else { return nil }
        return try Self.decodeThumbnail(from: data, maxPixelSize: config.regionCropMaxPixelSize)
        #else
        return nil
        #endif
    }

    // MARK: - Helpers

    private static func evidence(from result: SearchResponse.Result, meta: FrameMeta) -> PhotoRAGItem.Evidence? {
        if result.sources.contains(.timeline) {
            return .timeline
        }
        if meta.kind == FrameKind.region {
            if let rect = regionRect(from: meta) {
                return .region(bbox: rect)
            }
        }
        if result.sources.contains(.vector) {
            return .vector
        }
        if result.sources.contains(.text) {
            return .text(snippet: result.previewText)
        }
        return nil
    }

    private static func regionRect(from meta: FrameMeta) -> PhotoNormalizedRect? {
        guard let entries = meta.metadata?.entries else { return nil }
        guard let x = Double(entries[MetaKey.bboxX] ?? ""),
              let y = Double(entries[MetaKey.bboxY] ?? ""),
              let w = Double(entries[MetaKey.bboxW] ?? ""),
              let h = Double(entries[MetaKey.bboxH] ?? "")
        else { return nil }
        return PhotoNormalizedRect(x: x, y: y, width: w, height: h)
    }

    private static func toWaxTimeRange(_ range: ClosedRange<Date>?) -> TimeRange? {
        guard let range else { return nil }
        let after = Int64(range.lowerBound.timeIntervalSince1970 * 1000)
        let beforeInclusive = Int64(range.upperBound.timeIntervalSince1970 * 1000)
        let beforeExclusive = beforeInclusive == Int64.max ? beforeInclusive : beforeInclusive + 1
        return TimeRange(after: after, before: beforeExclusive)
    }

    private static func buildSummaryText(
        root: FrameMeta?,
        caption: String?,
        ocrSummary: String?,
        tags: String?,
        query: PhotoQuery,
        maxOCRLines: Int
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(6)

        if let caption, !caption.isEmpty {
            parts.append("Caption: \(caption)")
        }

        if let ocrSummary, !ocrSummary.isEmpty {
            let lines = ocrSummary
                .split(separator: "\n", omittingEmptySubsequences: true)
                .prefix(max(0, maxOCRLines))
                .map(String.init)
            if !lines.isEmpty {
                parts.append("OCR:\n" + lines.joined(separator: "\n"))
            }
        }

        if let tags, !tags.isEmpty {
            parts.append("Tags:\n" + tags)
        }

        if let root, let entries = root.metadata?.entries {
            if let ms = Int64(entries[MetaKey.captureMs] ?? "") {
                let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                let iso = ISO8601DateFormatter().string(from: date)
                parts.append("Captured: \(iso)")
            }
            if let lat = entries[MetaKey.lat], let lon = entries[MetaKey.lon] {
                parts.append("Location: \(lat),\(lon)")
            }
            if let model = entries[MetaKey.cameraModel] {
                parts.append("Camera: \(model)")
            }
        }

        if parts.isEmpty {
            // Deterministic fallback
            if let q = query.text, !q.isEmpty {
                return "Photo context (no extracted text). Query: \(q)"
            }
            return "Photo context (no extracted text)."
        }

        return parts.joined(separator: "\n\n")
    }

    private static func buildOCRSummary(_ blocks: [RecognizedTextBlock], maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(min(maxLines, blocks.count))

        let sorted = blocks.sorted { a, b in
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            return a.text.count > b.text.count
        }

        for block in sorted {
            let t = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            guard seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count >= maxLines { break }
        }
        return out.joined(separator: "\n")
    }

    private static func weakCaption(metadata: PhotosAssetMetadata.Record, ocrBlocks: [RecognizedTextBlock]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(4)

        if let ms = metadata.captureMs {
            let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            parts.append("Captured \(ISO8601DateFormatter().string(from: date))")
        }
        if let loc = metadata.location {
            parts.append(String(format: "Near %.5f, %.5f", loc.latitude, loc.longitude))
        }
        if let model = metadata.exif.cameraModel {
            parts.append("Camera \(model)")
        }
        if let top = ocrBlocks.first?.text, !top.isEmpty {
            parts.append("Text: \(top)")
        }
        return parts.joined(separator: " • ")
    }

    private static func baseMetadata(
        assetID: String,
        captureMs: Int64?,
        pipelineVersion: String,
        isLocal: Bool,
        location: PhotosAssetMetadata.Location?,
        pixelWidth: Int,
        pixelHeight: Int,
        exif: PhotosAssetMetadata.EXIF
    ) -> Metadata {
        var meta = Metadata()
        meta.entries[MetaKey.assetID] = assetID
        if let captureMs {
            meta.entries[MetaKey.captureMs] = String(captureMs)
        }
        meta.entries[MetaKey.pipelineVersion] = pipelineVersion
        meta.entries[MetaKey.width] = String(pixelWidth)
        meta.entries[MetaKey.height] = String(pixelHeight)
        meta.entries[MetaKey.isLocal] = isLocal ? "true" : "false"

        if let location {
            meta.entries[MetaKey.lat] = String(location.latitude)
            meta.entries[MetaKey.lon] = String(location.longitude)
            if let accuracy = location.horizontalAccuracyMeters {
                meta.entries[MetaKey.gpsAccuracyM] = String(accuracy)
            }
        }

        if let make = exif.cameraMake { meta.entries[MetaKey.cameraMake] = make }
        if let model = exif.cameraModel { meta.entries[MetaKey.cameraModel] = model }
        if let lens = exif.lensModel { meta.entries[MetaKey.lensModel] = lens }
        if let orientation = exif.orientation { meta.entries[MetaKey.orientation] = String(orientation) }

        return meta
    }

    private struct ProposedRegion {
        var bbox: PhotoNormalizedRect
        var type: String
    }

    private static func proposeRegions(from ocr: [RecognizedTextBlock], maxRegions: Int) -> [ProposedRegion] {
        guard maxRegions > 0 else { return [] }
        if !ocr.isEmpty {
            let sorted = ocr.sorted { $0.confidence > $1.confidence }
            return sorted.prefix(maxRegions).map { ProposedRegion(bbox: $0.bbox, type: "ocr") }
        }

        // Fallback 2x2 grid.
        let grid: [ProposedRegion] = [
            .init(bbox: .init(x: 0.0, y: 0.0, width: 0.5, height: 0.5), type: "grid"),
            .init(bbox: .init(x: 0.5, y: 0.0, width: 0.5, height: 0.5), type: "grid"),
            .init(bbox: .init(x: 0.0, y: 0.5, width: 0.5, height: 0.5), type: "grid"),
            .init(bbox: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5), type: "grid"),
        ]
        return Array(grid.prefix(maxRegions))
    }

    private static func writeBBox(into meta: inout Metadata, rect: PhotoNormalizedRect) {
        meta.entries[MetaKey.bboxX] = String(rect.x)
        meta.entries[MetaKey.bboxY] = String(rect.y)
        meta.entries[MetaKey.bboxW] = String(rect.width)
        meta.entries[MetaKey.bboxH] = String(rect.height)
    }

    private static func crop(_ image: CGImage, rect: PhotoNormalizedRect) -> CGImage? {
        let w = Double(image.width)
        let h = Double(image.height)
        let x = max(0, min(w, rect.x * w))
        let y = max(0, min(h, rect.y * h))
        let cw = max(1, min(w - x, rect.width * w))
        let ch = max(1, min(h - y, rect.height * h))
        let cropRect = CGRect(x: x.rounded(.down), y: y.rounded(.down), width: cw.rounded(.down), height: ch.rounded(.down))
        return image.cropping(to: cropRect)
    }

    private static func decodeThumbnail(from data: Data, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WaxError.io("failed to create image source")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WaxError.io("failed to decode thumbnail")
        }
        return image
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw WaxError.io("failed to create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WaxError.io("failed to encode png")
        }
        return data as Data
    }

    private static func defaultOCRProvider() -> (any OCRProvider)? {
        #if canImport(Vision)
        return VisionOCRProvider()
        #else
        return nil
        #endif
    }
}
