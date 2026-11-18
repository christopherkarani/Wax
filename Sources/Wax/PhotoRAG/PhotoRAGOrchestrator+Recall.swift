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
    /// Recall RAG context for a photo query, returning ranked items with text surrogates and optional pixel payloads.
    package func recall(_ query: PhotoQuery) async throws -> PhotoRAGContext {
        let cleanedText = query.text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let queryText = (cleanedText?.isEmpty == false) ? cleanedText : nil

        let queryEmbedding = try await buildQueryEmbedding(text: queryText, image: query.image)

        let resolvedMode: SearchMode = {
            switch (queryText, queryEmbedding) {
            case (.none, .some):
                return .vectorOnly
            case (.some, .some):
                return .hybrid(alpha: config.hybridAlpha)
            case (.some, .none), (.none, .none):
                return .textOnly
            }
        }()
        let lane = try SearchLane.from(mode: resolvedMode, embedding: queryEmbedding)

        let timeRange = Self.toWaxTimeRange(query.timeRange)

        let locationAllowlist = query.location.flatMap { buildLocationAllowlist(location: $0) }
        let assetAllowlist = buildAssetAllowlist(assetIDs: query.filters.assetIDs)
        let filterFrameIds = Self.intersectAllowlists(locationAllowlist, assetAllowlist)
        let metadataFilter = Self.metadataFilter(from: query.filters)

        let isConstraintOnlyQuery = (queryText == nil && queryEmbedding == nil)
            && (query.timeRange != nil || query.location != nil || !query.filters.isEmpty)
        let frameFilter: FrameFilter? = if filterFrameIds != nil || metadataFilter != nil {
            FrameFilter(frameIds: filterFrameIds, metadataFilter: metadataFilter)
        } else {
            nil
        }

        let rootMetaById: [UInt64: FrameMeta]
        let picked: [RootCandidate]

        if isConstraintOnlyQuery {
            let direct = await constraintRootCandidates(
                query: query,
                timeRange: timeRange,
                filterFrameIds: filterFrameIds,
                metadataFilter: metadataFilter
            )
            rootMetaById = direct.rootMetaById
            picked = Array(direct.candidates.prefix(query.resultLimit))
        } else {
            let request = try SearchRequest(
                query: queryText,
                lane: lane,
                vectorEnginePreference: config.vectorEnginePreference,
                topK: max(query.resultLimit, config.searchTopK),
                timeRange: timeRange,
                frameFilter: frameFilter,
                previewMaxBytes: 1024,
                allowTimelineFallback: false,
                timelineFallbackLimit: max(query.resultLimit, config.searchTopK)
            )

            let response = try await session.search(request)
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

            rootMetaById = await wax.frameMetasIncludingPending(frameIds: Array(rootIds))

            var candidates: [UInt64: RootCandidate] = [:]
            candidates.reserveCapacity(rootIds.count)

            for result in response.results {
                guard let meta = metaById[result.frameId] else { continue }
                let rootId = meta.parentId ?? meta.id
                guard let rootMeta = rootMetaById[rootId] else { continue }
                guard FrameKind(rawKind: rootMeta.kind) == .photo(.root) else { continue }
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
                if entry.textSnippet == nil, (result.sources.contains(.text) || FrameKind(rawKind: meta.kind) == .photo(.ocrSummary)) {
                    entry.textSnippet = result.previewText
                }
                candidates[rootId] = entry
            }

            // Build summary text for the top candidates, then apply budgets.
            let sorted = candidates.values.sorted { a, b in
                if a.score != b.score { return a.score > b.score }
                return a.rootId < b.rootId
            }

            picked = Array(sorted.prefix(query.resultLimit))
        }

        guard !picked.isEmpty else {
            return PhotoRAGContext(query: query, items: [], diagnostics: .init())
        }
        let rootIdsPicked = picked.map(\.rootId)

        // Resolve photo IDs and derived frame refs.
        var photoIDByRoot: [UInt64: PhotoID] = [:]
        photoIDByRoot.reserveCapacity(rootIdsPicked.count)
        for rootId in rootIdsPicked {
            if let cached = index.photoIDByRoot[rootId] {
                photoIDByRoot[rootId] = cached
                continue
            }
            if let meta = rootMetaById[rootId],
               let entries = meta.metadata?.entries,
               let photoID = Self.photoID(from: entries) {
                photoIDByRoot[rootId] = photoID
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
            guard let photoID = photoIDByRoot[candidate.rootId] else { continue }
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
                    photoID: photoID,
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
        assert(processed.count == items.count, "countAndTruncateBatch must return exactly one result per input")
        guard processed.count == items.count else { return PhotoRAGContext(query: query, items: [], diagnostics: .init()) }
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

        let degradedCount = await degradedResultCount(photoIDs: itemsWithPixels.map(\.photoID))
        let diagnostics = PhotoRAGContext.Diagnostics(usedTextTokens: usedTokens, degradedResultCount: degradedCount)
        return PhotoRAGContext(query: query, items: itemsWithPixels, diagnostics: diagnostics)
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
                throw WaxError.invalidEmbedding(reason: "embedder produced \(vec.count) dims for query image, expected \(embedder.dimensions)")
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
            // Weighted sum in shared embedding space (configurable via textEmbeddingWeight).
            let wt: Float = config.textEmbeddingWeight
            let wi: Float = 1.0 - config.textEmbeddingWeight
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

    func indexStateRootId(for photoID: PhotoID) -> UInt64? {
        index.rootByPhotoID[photoID]
    }

    private func degradedResultCount(photoIDs: [PhotoID]) async -> Int {
        var rootIds: [UInt64] = []
        rootIds.reserveCapacity(photoIDs.count)
        var missingRootCount = 0
        for photoID in photoIDs {
            if let rootId = index.rootByPhotoID[photoID] {
                rootIds.append(rootId)
            } else {
                missingRootCount += 1
            }
        }
        guard !rootIds.isEmpty else { return missingRootCount }

        let metas = await wax.frameMetasIncludingPending(frameIds: rootIds)
        var degraded = missingRootCount
        for rootId in rootIds {
            guard let rawValue = metas[rootId]?.metadata?.entries[MetaKey.isLocal],
                  let isLocal = Bool(rawValue)
            else {
                degraded += 1
                continue
            }
            if !isLocal {
                degraded += 1
            }
        }
        return degraded
    }

    private func constraintRootCandidates(
        query: PhotoQuery,
        timeRange: SearchTimeRange?,
        filterFrameIds: Set<UInt64>?,
        metadataFilter: MetadataFilter?
    ) async -> (rootMetaById: [UInt64: FrameMeta], candidates: [RootCandidate]) {
        var roots: [FrameMeta] = []
        for meta in await wax.frameMetas() {
            guard FrameKind(rawKind: meta.kind) == .photo(.root) else { continue }
            if meta.status == .deleted { continue }
            if meta.supersededBy != nil { continue }
            if let timeRange, !timeRange.contains(meta.timestamp) { continue }
            if let filterFrameIds, !filterFrameIds.contains(meta.id) { continue }
            if let metadataFilter, !Self.matches(metadataFilter: metadataFilter, meta: meta) { continue }
            roots.append(meta)
        }

        roots.sort { lhs, rhs in
            if lhs.timestamp != rhs.timestamp { return lhs.timestamp > rhs.timestamp }
            return lhs.id < rhs.id
        }

        var rootMetaById: [UInt64: FrameMeta] = [:]
        rootMetaById.reserveCapacity(roots.count)
        var candidates: [RootCandidate] = []
        candidates.reserveCapacity(min(roots.count, query.resultLimit))

        for (rank, root) in roots.enumerated() {
            rootMetaById[root.id] = root
            candidates.append(
                RootCandidate(
                    rootId: root.id,
                    score: 1 / Float(rank + 1),
                    evidence: [.timeline],
                    matchedRegions: [],
                    textSnippet: nil
                )
            )
        }

        return (rootMetaById, candidates)
    }

    private func buildAssetAllowlist(assetIDs: Set<PhotoID>?) -> Set<UInt64>? {
        guard let assetIDs else { return nil }
        var frameIds: Set<UInt64> = []
        frameIds.reserveCapacity(assetIDs.count * 4)

        for photoID in assetIDs {
            guard let rootId = index.rootByPhotoID[photoID] else { continue }
            frameIds.insert(rootId)
            if let refs = index.derivedByRoot[rootId] {
                if let id = refs.ocrSummary { frameIds.insert(id) }
                if let id = refs.caption { frameIds.insert(id) }
                if let id = refs.tags { frameIds.insert(id) }
                frameIds.formUnion(refs.regions)
            }
        }

        return frameIds
    }

    private static func intersectAllowlists(_ lhs: Set<UInt64>?, _ rhs: Set<UInt64>?) -> Set<UInt64>? {
        switch (lhs, rhs) {
        case (nil, nil):
            return nil
        case (let ids?, nil), (nil, let ids?):
            return ids
        case (let lhs?, let rhs?):
            return lhs.intersection(rhs)
        }
    }

    private static func metadataFilter(from filters: PhotoFilters) -> MetadataFilter? {
        var requiredEntries: [String: String] = [:]
        if let source = filters.source {
            requiredEntries[MetaKey.source] = source.rawValue
        }
        if let isLocal = filters.isLocal {
            requiredEntries[MetaKey.isLocal] = isLocal ? "true" : "false"
        }
        guard !requiredEntries.isEmpty else { return nil }
        return MetadataFilter(requiredEntries: requiredEntries)
    }

    private static func matches(metadataFilter: MetadataFilter, meta: FrameMeta) -> Bool {
        if !metadataFilter.requiredEntries.isEmpty {
            let entries = meta.metadata?.entries ?? [:]
            for (key, value) in metadataFilter.requiredEntries where entries[key] != value {
                return false
            }
        }
        if !metadataFilter.requiredTags.isEmpty {
            for tag in metadataFilter.requiredTags where !meta.tags.contains(tag) {
                return false
            }
        }
        if !metadataFilter.requiredLabels.isEmpty {
            for label in metadataFilter.requiredLabels where !meta.labels.contains(label) {
                return false
            }
        }
        return true
    }

    // MARK: - Helpers

    private static func evidence(from result: SearchResponse.Result, meta: FrameMeta) -> PhotoRAGItem.Evidence? {
        if result.sources.contains(.timeline) {
            return .timeline
        }
        if FrameKind(rawKind: meta.kind) == .photo(.region) {
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

    private static func toWaxTimeRange(_ range: ClosedRange<Date>?) -> SearchTimeRange? {
        guard let range else { return nil }
        let after = Int64(range.lowerBound.timeIntervalSince1970 * 1000)
        let beforeInclusive = Int64(range.upperBound.timeIntervalSince1970 * 1000)
        
        // Handle unbounded ranges (e.g., Date...Date.distantFuture)
        // Check for very large dates that represent "no upper bound"
        let beforeExclusive: Int64
        if beforeInclusive > Int64.max - 1 {
            beforeExclusive = Int64.max
        } else {
            beforeExclusive = beforeInclusive + 1
        }
        return SearchTimeRange(after: after, before: beforeExclusive)
    }
}

#endif // canImport(ImageIO)
