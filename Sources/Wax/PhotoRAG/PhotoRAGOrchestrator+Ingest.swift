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

extension PhotoRAGOrchestrator {
    // MARK: - Public API

    /// Sync the Photos library into the local Wax store.
    ///
    /// The implementation fetches asset identifiers on the MainActor, then ingests by identifier only.
    package func syncLibrary(scope: PhotoScope) async throws {
        #if canImport(Photos)
        let ids: [PhotoID] = switch scope {
        case .assetIDs(let ids):
            ids
        case .fullLibrary:
            await MainActor.run {
                let opts = PHFetchOptions()
                opts.sortDescriptors = [NSSortDescriptor(key: "creationDate", ascending: true)]
                let result = PHAsset.fetchAssets(with: .image, options: opts)
                if result.count == 0 { return [] }
                var ids: [PhotoID] = []
                ids.reserveCapacity(result.count)
                for index in 0..<result.count {
                    ids.append(PhotoID(source: .photos, id: result.object(at: index).localIdentifier))
                }
                return ids
            }
        }
        try await ingest(assetIDs: ids)
        try await writeSyncState(scope: scope, assetCount: ids.count)
        #else
        throw WaxError.io("Photos framework unavailable on this platform")
        #endif
    }

    #if canImport(Photos)
    /// Convenience wrapper: accepts PHAssets but only passes stable IDs into the actor.
    package nonisolated func ingest(assets: [PHAsset]) async throws {
        let ids = await MainActor.run { assets.map { PhotoID(source: .photos, id: $0.localIdentifier) } }
        try await self.ingest(assetIDs: ids)
    }
    #endif

    /// Ingest photos by ``PhotoID``.
    ///
    /// This method enforces offline-only ingestion. If an asset’s bytes are not locally available
    /// (iCloud-only), it is indexed as metadata-only and marked degraded.
    package func ingest(assetIDs: [PhotoID]) async throws {
        let uniqueAssetIDs = Self.photosLibraryIDs(assetIDs)
        guard !uniqueAssetIDs.isEmpty else { return }

        // Throttled concurrency: the actor's executor serializes state mutations, while
        // suspension points (metadata load, embedding, OCR) interleave across assets.
        let concurrency = max(1, config.ingestConcurrency)
        var iterator = uniqueAssetIDs.makeIterator()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<concurrency {
                    guard let photoID = iterator.next() else { break }
                    group.addTask {
                        try Task.checkCancellation()
                        try await self.ingestOne(photoID: photoID)
                    }
                }
                for try await _ in group {
                    if let photoID = iterator.next() {
                        group.addTask {
                            try Task.checkCancellation()
                            try await self.ingestOne(photoID: photoID)
                        }
                    }
                }
            }
        } catch {
            await reconcileAfterFailedIngest()
            throw error
        }

        try await session.commit()
        try await rebuildIndex()
    }

    /// Ingest local image files into the Photo RAG index.
    package func ingest(files: [PhotoFile]) async throws {
        let uniqueFiles = Self.dedupePhotoFiles(files)
        guard !uniqueFiles.isEmpty else { return }

        let concurrency = max(1, config.ingestConcurrency)
        var iterator = uniqueFiles.makeIterator()

        do {
            try await withThrowingTaskGroup(of: Void.self) { group in
                for _ in 0..<concurrency {
                    guard let file = iterator.next() else { break }
                    group.addTask {
                        try Task.checkCancellation()
                        try await self.ingestOne(file: file)
                    }
                }
                for try await _ in group {
                    if let file = iterator.next() {
                        group.addTask {
                            try Task.checkCancellation()
                            try await self.ingestOne(file: file)
                        }
                    }
                }
            }
        } catch {
            await reconcileAfterFailedIngest()
            throw error
        }

        try await session.commit()
        try await rebuildIndex()
    }

    // MARK: - Ingest internals

    private func writeSyncState(scope: PhotoScope, assetCount: Int) async throws {
        let completedAtMs = Int64(Date().timeIntervalSince1970 * 1000)
        var metadata = Metadata()
        metadata.entries[MetaKey.syncScope] = Self.syncScopeValue(scope)
        metadata.entries[MetaKey.syncAssetCount] = String(assetCount)
        metadata.entries[MetaKey.syncCompletedAtMs] = String(completedAtMs)
        metadata.entries[MetaKey.pipelineVersion] = config.pipelineVersion

        _ = try await session.put(
            Data(),
            options: FrameMetaSubset(kind: PhotoFrameKind.syncState.rawValue, metadata: metadata),
            compression: .plain,
            timestampMs: completedAtMs
        )
        try await session.commit()
    }

    private static func syncScopeValue(_ scope: PhotoScope) -> String {
        switch scope {
        case .fullLibrary:
            return "full_library"
        case .assetIDs:
            return "asset_ids"
        }
    }

    private func ingestOne(photoID: PhotoID) async throws {
        let libraryID = PhotoID(source: .photos, id: photoID.id)
        guard inFlightPhotoIDs.insert(libraryID).inserted else { return }
        defer { inFlightPhotoIDs.remove(libraryID) }

        var newRootId: UInt64?
        do {
            try await ingestTree(libraryID: libraryID, newRootId: &newRootId)
        } catch {
            if let newRootId { await discardPartialTree(rootId: newRootId) }
            throw error
        }
    }

    /// Writes a new tree for `libraryID`. `newRootId` holds the new root from the moment it is
    /// written until it supersedes the previous version, so a failure in between can discard it.
    private func ingestTree(libraryID: PhotoID, newRootId: inout UInt64?) async throws {
        #if canImport(Photos)
        let metadata = try await PhotosAssetMetadata.load(photoID: libraryID)
        let resolvedID = metadata.photoID

        let captureMs = metadata.captureMs
        let frameTimestampMs = captureMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let isLocal = metadata.isLocal
        let baseMeta = Self.baseMetadata(
            photoID: resolvedID,
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
        let previousRoot = index.rootByPhotoID[resolvedID]

        if !isLocal {
            // Metadata-only ingest
            let options = FrameMetaSubset(
                kind: PhotoFrameKind.root.rawValue,
                metadata: baseMeta
            )
            let rootId = try await session.put(Data(), options: options, compression: .plain, timestampMs: frameTimestampMs)
            newRootId = rootId
            if let previousRoot {
                try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
                newRootId = nil
                try await removeVectorsForRetiredTree(previousRoot)
            }
            return
        }

        guard let imageData = metadata.imageData else {
            // Treat as non-local if data couldn't be loaded without network.
            var degradedMeta = baseMeta
            degradedMeta.entries[MetaKey.isLocal] = "false"
            let options = FrameMetaSubset(
                kind: PhotoFrameKind.root.rawValue,
                metadata: degradedMeta
            )
            let rootId = try await session.put(
                Data(),
                options: options,
                compression: .plain,
                timestampMs: frameTimestampMs
            )
            newRootId = rootId
            if let previousRoot {
                try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
                newRootId = nil
                try await removeVectorsForRetiredTree(previousRoot)
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
            throw WaxError.invalidEmbedding(reason: "embedder produced \(globalEmbedding.count) dims for image, expected \(embedder.dimensions)")
        }

        // Root frame
        let rootOptions = FrameMetaSubset(
            kind: PhotoFrameKind.root.rawValue,
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
        newRootId = rootId

        // OCR
        var ocrBlocks: [RecognizedTextBlock] = []
        if config.enableOCR, let ocr = ocr ?? Self.defaultOCRProvider() {
            ocrBlocks = try await ocr.recognizeText(in: ocrImage)
        }

        // Caption
        let captionText: String?
        if let captioner {
            do {
                captionText = try await captioner.caption(for: ocrImage)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "photo caption generation",
                    fallback: "skip caption for asset"
                )
                captionText = nil
            }
        } else {
            captionText = Self.weakCaption(metadata: metadata, ocrBlocks: ocrBlocks)
        }

        let derivedTagsText = Self.buildPhotoTags(from: metadata, captionText: captionText)

        // Derived frames to write (non-embedded)
        var derivedContents: [Data] = []
        var derivedOptions: [FrameMetaSubset] = []
        var derivedTextsForIndex: [(frameIndex: Int, text: String)] = []

        func addDerived(kind: String, text: String, searchable: Bool) {
            let idx = derivedContents.count
            derivedContents.append(Data(text.utf8))
            var subset = FrameMetaSubset(kind: kind, parentId: rootId, metadata: baseMeta)
            subset.role = FrameRole.blob
            derivedOptions.append(subset)
            if searchable {
                derivedTextsForIndex.append((frameIndex: idx, text: text))
            }
        }

        if let captionText, !captionText.isEmpty {
            addDerived(kind: PhotoFrameKind.captionShort.rawValue, text: captionText, searchable: true)
        }

        if let derivedTagsText {
            addDerived(kind: PhotoFrameKind.tags.rawValue, text: derivedTagsText, searchable: true)
        }

        // OCR summary + per-block frames; both are text-indexed.
        if !ocrBlocks.isEmpty {
            // Summary
            let summary = Self.buildOCRSummary(ocrBlocks, maxLines: config.maxOCRSummaryLines)
            if !summary.isEmpty {
                addDerived(kind: PhotoFrameKind.ocrSummary.rawValue, text: summary, searchable: true)
            }

            // Blocks — also text-indexed so serials and short OCR tokens stay findable
            // even when they are not selected into the summary.
            for block in ocrBlocks.prefix(max(1, config.maxOCRBlocksPerPhoto)) {
                var meta = baseMeta
                Self.writeBBox(into: &meta, rect: block.bbox)
                meta.entries["photo.ocr.confidence"] = String(block.confidence)
                if let lang = block.language {
                    meta.entries["photo.ocr.language"] = lang
                }
                let text = block.text
                let idx = derivedContents.count
                derivedContents.append(Data(text.utf8))
                var subset = FrameMetaSubset(kind: PhotoFrameKind.ocrBlock.rawValue, parentId: rootId, metadata: meta)
                subset.role = FrameRole.blob
                derivedOptions.append(subset)
                if !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    derivedTextsForIndex.append((frameIndex: idx, text: text))
                }
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
                // Collect all crops first
                var crops: [(index: Int, crop: CGImage, region: ProposedRegion)] = []
                crops.reserveCapacity(regions.count)
                for region in regions {
                    guard let crop = Self.crop(embedImage, rect: region.bbox) else { continue }
                    crops.append((crops.count, crop, region))
                }

                if !crops.isEmpty {
                    // Embed in parallel with bounded concurrency (4 concurrent tasks)
                    var regionEmbeddings: [[Float]] = []
                    var regionContents: [Data] = []
                    var regionOptions: [FrameMetaSubset] = []
                    regionEmbeddings.reserveCapacity(crops.count)
                    regionContents.reserveCapacity(crops.count)
                    regionOptions.reserveCapacity(crops.count)

                    try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
                        var activeCount = 0
                        let maxConcurrency = max(1, self.config.regionEmbeddingConcurrency)
                        var cropIterator = crops.makeIterator()

                        // Start initial batch
                        while activeCount < maxConcurrency, let item = cropIterator.next() {
                            let (index, crop, _) = item
                            group.addTask {
                                var vec = try await self.embedder.embed(image: crop)
                                if self.embedder.normalize, !vec.isEmpty {
                                    vec = VectorMath.normalizeL2(vec)
                                }
                                guard vec.count == self.embedder.dimensions else {
                                    throw WaxError.invalidEmbedding(reason: "embedder produced \(vec.count) dims for region image, expected \(self.embedder.dimensions)")
                                }
                                return (index, vec)
                            }
                            activeCount += 1
                        }

                        // Collect results and spawn new tasks
                        var results: [(Int, [Float])] = []
                        results.reserveCapacity(crops.count)
                        for try await result in group {
                            results.append(result)
                            if let item = cropIterator.next() {
                                let (index, crop, _) = item
                                group.addTask {
                                    var vec = try await self.embedder.embed(image: crop)
                                    if self.embedder.normalize, !vec.isEmpty {
                                        vec = VectorMath.normalizeL2(vec)
                                    }
                                    guard vec.count == self.embedder.dimensions else {
                                        throw WaxError.invalidEmbedding(reason: "embedder produced \(vec.count) dims for region image, expected \(self.embedder.dimensions)")
                                    }
                                    return (index, vec)
                                }
                            }
                        }

                        // Sort results by index to maintain deterministic ordering
                        results.sort { $0.0 < $1.0 }

                        // Build final arrays in correct order
                        for (index, vec) in results {
                            let (_, _, region) = crops[index]
                            regionEmbeddings.append(vec)
                            regionContents.append(Data())

                            var meta = baseMeta
                            Self.writeBBox(into: &meta, rect: region.bbox)
                            meta.entries[MetaKey.regionType] = region.type
                            let subset = FrameMetaSubset(kind: PhotoFrameKind.region.rawValue, role: .blob, parentId: rootId, metadata: meta)
                            regionOptions.append(subset)
                        }
                    }

                    _ = try await session.putBatch(
                        contents: regionContents,
                        embeddings: regionEmbeddings,
                        identity: embedder.identity,
                        options: regionOptions,
                        timestampsMs: Array(repeating: frameTimestampMs, count: regionContents.count),
                        compression: .plain
                    )
                }
            }
        }

        if let previousRoot {
            try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
            newRootId = nil
            try await removeVectorsForRetiredTree(previousRoot)
        }
        #else
        throw WaxError.io("Photos framework unavailable on this platform")
        #endif
    }

    private func ingestOne(file: PhotoFile) async throws {
        let photoID = file.id
        guard inFlightPhotoIDs.insert(photoID).inserted else { return }
        defer { inFlightPhotoIDs.remove(photoID) }

        var newRootId: UInt64?
        do {
            try await ingestTree(file: file, newRootId: &newRootId)
        } catch {
            if let newRootId { await discardPartialTree(rootId: newRootId) }
            throw error
        }
    }

    /// Writes a new tree for `file`; `newRootId` follows the same contract as in
    /// ``ingestTree(libraryID:newRootId:)``.
    private func ingestTree(file: PhotoFile, newRootId: inout UInt64?) async throws {
        let photoID = file.id
        guard FileManager.default.fileExists(atPath: file.url.path(percentEncoded: false)) else {
            throw PhotoIngestError.fileMissing(id: photoID, url: file.url)
        }

        let imageData: Data
        do {
            imageData = try Data(contentsOf: file.url)
        } catch {
            throw PhotoIngestError.invalidImage(reason: "failed to read local image: \(file.url.path)")
        }
        let exif = PhotosAssetMetadata.extractEXIF(from: imageData)
        let embedImage: CGImage
        let ocrImage: CGImage
        do {
            embedImage = try Self.decodeThumbnail(from: imageData, maxPixelSize: config.embedMaxPixelSize)
            ocrImage = try Self.decodeThumbnail(from: imageData, maxPixelSize: config.ocrMaxPixelSize)
        } catch {
            throw PhotoIngestError.invalidImage(reason: "failed to decode local image: \(file.url.path)")
        }
        let originalDimensions = Self.imagePixelDimensions(from: imageData) ?? (width: embedImage.width, height: embedImage.height)
        let captureMs = exif.dateTimeOriginalMs ?? file.captureDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        let frameTimestampMs = captureMs ?? Int64(Date().timeIntervalSince1970 * 1000)
        let location: PhotosAssetMetadata.Location? = if let lat = exif.gpsLatitude, let lon = exif.gpsLongitude {
            PhotosAssetMetadata.Location(latitude: lat, longitude: lon, horizontalAccuracyMeters: nil)
        } else {
            nil
        }
        let metadata = PhotosAssetMetadata.Record(
            photoID: photoID,
            creationDateMs: nil,
            captureMs: captureMs,
            location: location,
            isFavorite: false,
            pixelWidth: originalDimensions.width,
            pixelHeight: originalDimensions.height,
            isLocal: true,
            imageData: imageData,
            exif: exif
        )
        let baseMeta = Self.baseMetadata(
            photoID: photoID,
            captureMs: captureMs,
            pipelineVersion: config.pipelineVersion,
            isLocal: true,
            location: location,
            pixelWidth: originalDimensions.width,
            pixelHeight: originalDimensions.height,
            exif: exif,
            fileURL: file.url
        )
        let previousRoot = index.rootByPhotoID[photoID]

        var globalEmbedding = try await embedder.embed(image: embedImage)
        if embedder.normalize, !globalEmbedding.isEmpty {
            globalEmbedding = VectorMath.normalizeL2(globalEmbedding)
        }
        guard globalEmbedding.count == embedder.dimensions else {
            throw PhotoIngestError.embedderDimensionMismatch(expected: embedder.dimensions, got: globalEmbedding.count)
        }

        let rootId = try await session.put(
            Data(),
            embedding: globalEmbedding,
            identity: embedder.identity,
            options: FrameMetaSubset(kind: PhotoFrameKind.root.rawValue, metadata: baseMeta),
            compression: .plain,
            timestampMs: frameTimestampMs
        )
        newRootId = rootId

        var ocrBlocks: [RecognizedTextBlock] = []
        if config.enableOCR, let ocr = ocr ?? Self.defaultOCRProvider() {
            ocrBlocks = try await ocr.recognizeText(in: ocrImage)
        }

        let captionText: String?
        if let captioner {
            do {
                captionText = try await captioner.caption(for: ocrImage)
            } catch {
                WaxDiagnostics.logSwallowed(
                    error,
                    context: "local photo caption generation",
                    fallback: "skip caption for file"
                )
                captionText = nil
            }
        } else {
            captionText = Self.weakCaption(metadata: metadata, ocrBlocks: ocrBlocks)
        }

        let derivedTagsText = Self.buildPhotoTags(from: metadata, captionText: captionText)
        var derivedContents: [Data] = []
        var derivedOptions: [FrameMetaSubset] = []
        var derivedTextsForIndex: [(frameIndex: Int, text: String)] = []

        func addDerived(kind: String, text: String, searchable: Bool) {
            let idx = derivedContents.count
            derivedContents.append(Data(text.utf8))
            var subset = FrameMetaSubset(kind: kind, parentId: rootId, metadata: baseMeta)
            subset.role = FrameRole.blob
            derivedOptions.append(subset)
            if searchable {
                derivedTextsForIndex.append((frameIndex: idx, text: text))
            }
        }

        if let captionText, !captionText.isEmpty {
            addDerived(kind: PhotoFrameKind.captionShort.rawValue, text: captionText, searchable: true)
        }
        if let derivedTagsText {
            addDerived(kind: PhotoFrameKind.tags.rawValue, text: derivedTagsText, searchable: true)
        }
        if !ocrBlocks.isEmpty {
            let summary = Self.buildOCRSummary(ocrBlocks, maxLines: config.maxOCRSummaryLines)
            if !summary.isEmpty {
                addDerived(kind: PhotoFrameKind.ocrSummary.rawValue, text: summary, searchable: true)
            }
            for block in ocrBlocks.prefix(max(1, config.maxOCRBlocksPerPhoto)) {
                var meta = baseMeta
                Self.writeBBox(into: &meta, rect: block.bbox)
                meta.entries["photo.ocr.confidence"] = String(block.confidence)
                if let lang = block.language {
                    meta.entries["photo.ocr.language"] = lang
                }
                let idx = derivedContents.count
                derivedContents.append(Data(block.text.utf8))
                var subset = FrameMetaSubset(kind: PhotoFrameKind.ocrBlock.rawValue, parentId: rootId, metadata: meta)
                subset.role = FrameRole.blob
                derivedOptions.append(subset)
                if !block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    derivedTextsForIndex.append((frameIndex: idx, text: block.text))
                }
            }
        }

        let derivedIds = try await session.putBatch(
            contents: derivedContents,
            options: derivedOptions,
            compression: .plain,
            timestampsMs: Array(repeating: frameTimestampMs, count: derivedContents.count)
        )
        if !derivedTextsForIndex.isEmpty {
            var frameIds: [UInt64] = []
            var texts: [String] = []
            for entry in derivedTextsForIndex {
                frameIds.append(derivedIds[entry.frameIndex])
                texts.append(entry.text)
            }
            try await session.indexTextBatch(frameIds: frameIds, texts: texts)
        }

        try await writeRegionEmbeddingsIfNeeded(
            rootId: rootId,
            baseMeta: baseMeta,
            sourceImage: embedImage,
            ocrBlocks: ocrBlocks,
            timestampMs: frameTimestampMs
        )

        if let previousRoot {
            try await wax.supersede(supersededId: previousRoot, supersedingId: rootId)
            newRootId = nil
            try await removeVectorsForRetiredTree(previousRoot)
        }
    }

    private func writeRegionEmbeddingsIfNeeded(
        rootId: UInt64,
        baseMeta: Metadata,
        sourceImage: CGImage,
        ocrBlocks: [RecognizedTextBlock],
        timestampMs: Int64
    ) async throws {
        guard config.enableRegionEmbeddings, config.maxRegionsPerPhoto > 0 else { return }
        let regions = Self.proposeRegions(from: ocrBlocks, maxRegions: config.maxRegionsPerPhoto)
        guard !regions.isEmpty else { return }

        var crops: [(index: Int, crop: CGImage, region: ProposedRegion)] = []
        crops.reserveCapacity(regions.count)
        for region in regions {
            guard let crop = Self.crop(sourceImage, rect: region.bbox) else { continue }
            crops.append((crops.count, crop, region))
        }
        guard !crops.isEmpty else { return }

        var regionEmbeddings: [[Float]] = []
        var regionContents: [Data] = []
        var regionOptions: [FrameMetaSubset] = []
        regionEmbeddings.reserveCapacity(crops.count)
        regionContents.reserveCapacity(crops.count)
        regionOptions.reserveCapacity(crops.count)

        try await withThrowingTaskGroup(of: (Int, [Float]).self) { group in
            var activeCount = 0
            let maxConcurrency = max(1, config.regionEmbeddingConcurrency)
            var cropIterator = crops.makeIterator()

            while activeCount < maxConcurrency, let item = cropIterator.next() {
                let (index, crop, _) = item
                group.addTask {
                    var vec = try await self.embedder.embed(image: crop)
                    if self.embedder.normalize, !vec.isEmpty {
                        vec = VectorMath.normalizeL2(vec)
                    }
                    guard vec.count == self.embedder.dimensions else {
                        throw PhotoIngestError.embedderDimensionMismatch(
                            expected: self.embedder.dimensions,
                            got: vec.count
                        )
                    }
                    return (index, vec)
                }
                activeCount += 1
            }

            var results: [(Int, [Float])] = []
            results.reserveCapacity(crops.count)
            for try await result in group {
                results.append(result)
                if let item = cropIterator.next() {
                    let (index, crop, _) = item
                    group.addTask {
                        var vec = try await self.embedder.embed(image: crop)
                        if self.embedder.normalize, !vec.isEmpty {
                            vec = VectorMath.normalizeL2(vec)
                        }
                        guard vec.count == self.embedder.dimensions else {
                            throw PhotoIngestError.embedderDimensionMismatch(
                                expected: self.embedder.dimensions,
                                got: vec.count
                            )
                        }
                        return (index, vec)
                    }
                }
            }

            results.sort { $0.0 < $1.0 }
            for (index, vec) in results {
                let (_, _, region) = crops[index]
                regionEmbeddings.append(vec)
                regionContents.append(Data())

                var meta = baseMeta
                Self.writeBBox(into: &meta, rect: region.bbox)
                meta.entries[MetaKey.regionType] = region.type
                regionOptions.append(FrameMetaSubset(kind: PhotoFrameKind.region.rawValue, role: .blob, parentId: rootId, metadata: meta))
            }
        }

        _ = try await session.putBatch(
            contents: regionContents,
            embeddings: regionEmbeddings,
            identity: embedder.identity,
            options: regionOptions,
            timestampsMs: Array(repeating: timestampMs, count: regionContents.count),
            compression: .plain
        )
    }

    private static func defaultOCRProvider() -> (any OCRProvider)? {
        #if canImport(Vision)
        return VisionOCRProvider()
        #else
        return nil
        #endif
    }
}

#endif // canImport(ImageIO)
