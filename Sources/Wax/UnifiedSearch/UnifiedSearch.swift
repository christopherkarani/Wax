import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

struct UnifiedSearchEngineOverrides {
    var textEngine: FTS5SearchEngine?
    var vectorEngine: (any VectorSearchEngine)?
    var structuredEngine: FTS5SearchEngine?
}

public extension Wax {
    func search(_ request: SearchRequest) async throws -> SearchResponse {
        try await search(request, engineOverrides: nil)
    }
}

extension Wax {
    func search(
        _ request: SearchRequest,
        engineOverrides: UnifiedSearchEngineOverrides?
    ) async throws -> SearchResponse {
        let requestedTopK = max(0, request.topK)
        if requestedTopK == 0 {
            return SearchResponse(results: [])
        }

        let trimmedQuery = request.query?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let queryType: QueryType
        if let trimmedQuery, !trimmedQuery.isEmpty {
            queryType = RuleBasedQueryClassifier.classify(trimmedQuery)
        } else {
            queryType = .exploratory
        }

        let weights = AdaptiveFusionConfig.default.weights(for: queryType)
        let filter = request.frameFilter ?? FrameFilter()

        let includeText: Bool
        let includeVector: Bool
        switch request.mode {
        case .textOnly:
            includeText = true
            includeVector = false
        case .vectorOnly:
            let hasEmbedding = !(request.embedding?.isEmpty ?? true)
            guard hasEmbedding else {
                throw WaxError.io("vectorOnly search requires a non-empty query embedding")
            }
            includeText = false
            includeVector = true
        case .hybrid:
            includeText = true
            includeVector = true
        }

        let candidateLimit = Self.candidateLimit(for: requestedTopK)
        let cache = UnifiedSearchEngineCache.shared
        let textEngine: FTS5SearchEngine? = if includeText {
            if let override = engineOverrides?.textEngine {
                override
            } else {
                try await cache.textEngine(for: self)
            }
        } else {
            nil
        }

        let vectorEngine: (any VectorSearchEngine)? = if includeVector, let embedding = request.embedding, !embedding.isEmpty {
            if let override = engineOverrides?.vectorEngine {
                override
            } else {
                try await cache.vectorEngine(
                    for: self,
                    queryEmbeddingDimensions: embedding.count,
                    preference: request.vectorEnginePreference
                )
            }
        } else {
            nil
        }

        let structuredEngine: FTS5SearchEngine?
        if let trimmedQuery, !trimmedQuery.isEmpty {
            if let override = engineOverrides?.structuredEngine {
                structuredEngine = override
            } else if let textEngine {
                structuredEngine = textEngine
            } else {
                structuredEngine = try await cache.textEngine(for: self)
            }
        } else {
            structuredEngine = nil
        }


        async let textResultsAsync: [TextSearchResult] = {
            guard includeText, let textEngine, let trimmedQuery, !trimmedQuery.isEmpty else { return [] }
            let base = try await textEngine.search(query: trimmedQuery, topK: candidateLimit)
            guard base.isEmpty, let fallback = Self.orExpandedQuery(from: trimmedQuery) else {
                return base
            }
            return try await textEngine.search(query: fallback, topK: candidateLimit)
        }()

        async let vectorResultsAsync: [(frameId: UInt64, score: Float)] = {
            guard includeVector, let vectorEngine, let embedding = request.embedding, !embedding.isEmpty else { return [] }
            var queryEmbedding = embedding
            if vectorEngine is MetalVectorEngine, !VectorMath.isNormalizedL2(queryEmbedding) {
                queryEmbedding = VectorMath.normalizeL2(queryEmbedding)
            }
            return try await vectorEngine.search(vector: queryEmbedding, topK: candidateLimit)
        }()

        async let structuredFrameIdsAsync: [UInt64] = {
            guard let trimmedQuery, !trimmedQuery.isEmpty else { return [] }
            let options = request.structuredMemory
            guard options.weight > 0,
                  options.maxEntityCandidates > 0,
                  options.maxFacts > 0,
                  options.maxEvidenceFrames > 0,
                  let structuredEngine
            else { return [] }

            let candidates = try await Self.structuredEntityCandidates(
                query: trimmedQuery,
                engine: structuredEngine,
                maxCandidates: options.maxEntityCandidates
            )
            guard !candidates.isEmpty else { return [] }

            let asOfMs = request.timeRange?.before ?? request.asOfMs
            let asOf = StructuredMemoryAsOf(asOfMs: asOfMs)
            return try await structuredEngine.evidenceFrameIds(
                subjectKeys: candidates,
                asOf: asOf,
                maxFacts: options.maxFacts,
                maxFrames: options.maxEvidenceFrames,
                requireEvidenceSpan: options.requireEvidenceSpan
            )
        }()

        let textResults = try await textResultsAsync
        let vectorResults = try await vectorResultsAsync
        let structuredFrameIds = try await structuredFrameIdsAsync

        var timelineFrameIds: [UInt64] = []
        if queryType == .temporal, weights.temporal > 0 {
            let timelineQuery = TimelineQuery(
                limit: max(candidateLimit, request.timelineFallbackLimit),
                order: .reverseChronological,
                after: request.timeRange?.after,
                before: request.timeRange?.before,
                includeDeleted: filter.includeDeleted,
                includeSuperseded: filter.includeSuperseded
            )
            timelineFrameIds = await timeline(timelineQuery)
                .filter { filter.includeSurrogates || $0.kind != "surrogate" }
                .map(\.id)
        }

        let snippetByFrameId: [UInt64: String] = textResults.reduce(into: [:]) { acc, result in
            guard let snippet = result.snippet, !snippet.isEmpty else { return }
            acc[result.frameId] = snippet
        }

        let structuredIds = structuredFrameIds
        let structuredWeight = max(0, request.structuredMemory.weight)

        let baseResults: [(frameId: UInt64, score: Float, sources: [SearchResponse.Source])]
        switch request.mode {
        case .textOnly:
            if structuredIds.isEmpty || structuredWeight <= 0 {
                baseResults = textResults.map { (frameId: $0.frameId, score: Float($0.score), sources: [.text]) }
            } else {
                let (textIds, textSet) = Self.frameIDsAndSet(from: textResults.lazy.map(\.frameId))
                let fused = HybridSearch.rrfFusion(
                    lists: [
                        (weight: weights.bm25, frameIds: textIds),
                        (weight: structuredWeight, frameIds: structuredIds),
                    ],
                    k: request.rrfK
                )

                let structuredSet = Set(structuredIds)

                baseResults = fused.map { (frameId, score) in
                    var sources: [SearchResponse.Source] = []
                    if textSet.contains(frameId) { sources.append(.text) }
                    if structuredSet.contains(frameId) { sources.append(.structuredMemory) }
                    return (frameId: frameId, score: score, sources: sources)
                }
            }
        case .vectorOnly:
            if structuredIds.isEmpty || structuredWeight <= 0 {
                baseResults = vectorResults.map { (frameId: $0.frameId, score: $0.score, sources: [.vector]) }
            } else {
                let (vectorIds, vectorSet) = Self.frameIDsAndSet(from: vectorResults.lazy.map(\.frameId))
                let fused = HybridSearch.rrfFusion(
                    lists: [
                        (weight: weights.vector, frameIds: vectorIds),
                        (weight: structuredWeight, frameIds: structuredIds),
                    ],
                    k: request.rrfK
                )

                let structuredSet = Set(structuredIds)

                baseResults = fused.map { (frameId, score) in
                    var sources: [SearchResponse.Source] = []
                    if vectorSet.contains(frameId) { sources.append(.vector) }
                    if structuredSet.contains(frameId) { sources.append(.structuredMemory) }
                    return (frameId: frameId, score: score, sources: sources)
                }
            }
        case .hybrid(let alpha):
            let clampedAlpha = min(1, max(0, alpha))
            let textWeight = weights.bm25 * clampedAlpha
            let vectorWeight = weights.vector * (1 - clampedAlpha)

            let (textIds, textSet) = Self.frameIDsAndSet(from: textResults.lazy.map(\.frameId))
            let (vectorIds, vectorSet) = Self.frameIDsAndSet(from: vectorResults.lazy.map(\.frameId))
            let timelineIds = timelineFrameIds

            var lists: [(weight: Float, frameIds: [UInt64])] = []
            if textWeight > 0, !textIds.isEmpty { lists.append((weight: textWeight, frameIds: textIds)) }
            if vectorWeight > 0, !vectorIds.isEmpty { lists.append((weight: vectorWeight, frameIds: vectorIds)) }
            if weights.temporal > 0, !timelineIds.isEmpty { lists.append((weight: weights.temporal, frameIds: timelineIds)) }
            if structuredWeight > 0, !structuredIds.isEmpty { lists.append((weight: structuredWeight, frameIds: structuredIds)) }

            let fused = HybridSearch.rrfFusion(lists: lists, k: request.rrfK)

            let timelineSet = Set(timelineIds)
            let structuredSet = Set(structuredIds)

            baseResults = fused.map { (frameId, score) in
                var sources: [SearchResponse.Source] = []
                if textSet.contains(frameId) { sources.append(.text) }
                if vectorSet.contains(frameId) { sources.append(.vector) }
                if timelineSet.contains(frameId) { sources.append(.timeline) }
                if structuredSet.contains(frameId) { sources.append(.structuredMemory) }
                return (frameId: frameId, score: score, sources: sources)
            }
        }


        struct PendingResult {
            let frameId: UInt64
            let score: Float
            let sources: [SearchResponse.Source]
            let snippet: String?
        }

        func passesFilters(
            meta: FrameMeta,
            frameId: UInt64,
            score: Float
        ) -> Bool {
            if let minScore = request.minScore, score < minScore { return false }
            if let timeRange = request.timeRange, !timeRange.contains(meta.timestamp) { return false }
            if let allowlist = filter.frameIds, !allowlist.contains(frameId) { return false }
            if !filter.includeDeleted, meta.status == .deleted { return false }
            if !filter.includeSuperseded, meta.supersededBy != nil { return false }
            if !filter.includeSurrogates, meta.kind == "surrogate" { return false }
            if let metadataFilter = filter.metadataFilter, !Self.matches(metadataFilter: metadataFilter, meta: meta) {
                return false
            }
            return true
        }

        var pendingResults: [PendingResult] = []
        pendingResults.reserveCapacity(min(requestedTopK, baseResults.count))

        if !baseResults.isEmpty {
            // Optimization: Use lazy metadata loading for small result sets
            // Dictionary-building overhead dominates for small scales (<50 items)
            // Prefetch is only beneficial for larger result sets
            let lazyMetadataThreshold = max(1, request.metadataLoadingThreshold)
            
            if baseResults.count >= lazyMetadataThreshold {
                // Batch prefetch for large result sets
                let metaById = await frameMetasIncludingPending(frameIds: baseResults.map(\.frameId))
                
                for item in baseResults {
                    if let minScore = request.minScore, item.score < minScore { continue }
                    guard let meta = metaById[item.frameId] else { continue }
                    guard passesFilters(meta: meta, frameId: item.frameId, score: item.score) else { continue }

                    pendingResults.append(
                        PendingResult(
                            frameId: item.frameId,
                            score: item.score,
                            sources: item.sources,
                            snippet: snippetByFrameId[item.frameId]
                        )
                    )

                    if pendingResults.count >= requestedTopK {
                        break
                    }
                }
            } else {
                // Lazy loading for small result sets - avoids dictionary overhead
                for item in baseResults {
                    if let minScore = request.minScore, item.score < minScore { continue }
                    let meta: FrameMeta
                    do {
                        meta = try await frameMetaIncludingPending(frameId: item.frameId)
                    } catch {
                        WaxDiagnostics.logSwallowed(
                            error,
                            context: "unified search frame metadata lookup",
                            fallback: "skip result without metadata"
                        )
                        continue
                    }
                    guard passesFilters(meta: meta, frameId: item.frameId, score: item.score) else { continue }

                    pendingResults.append(
                        PendingResult(
                            frameId: item.frameId,
                            score: item.score,
                            sources: item.sources,
                            snippet: snippetByFrameId[item.frameId]
                        )
                    )

                    if pendingResults.count >= requestedTopK {
                        break
                    }
                }
            }
        }

        let previewIds = pendingResults
            .filter { $0.snippet == nil }
            .map(\.frameId)
        let previewById = try await framePreviews(
            frameIds: previewIds,
            maxBytes: request.previewMaxBytes
        )

        var filtered: [SearchResponse.Result] = pendingResults.map { item in
            let previewText: String?
            if let snippet = item.snippet {
                previewText = snippet
            } else {
                previewText = previewById[item.frameId]
                    .flatMap { String(data: $0, encoding: .utf8) }
            }
            return SearchResponse.Result(
                frameId: item.frameId,
                score: item.score,
                previewText: previewText,
                sources: item.sources
            )
        }

        if filtered.isEmpty, request.allowTimelineFallback {
            filtered = await timelineFallbackResults(request: request, filter: filter)
        }

        return SearchResponse(results: filtered)
    }

    private func timelineFallbackResults(request: SearchRequest, filter: FrameFilter) async -> [SearchResponse.Result] {
        if request.timelineFallbackLimit <= 0 { return [] }
        let query = TimelineQuery(
            limit: request.timelineFallbackLimit,
            order: .reverseChronological,
            after: request.timeRange?.after,
            before: request.timeRange?.before,
            includeDeleted: filter.includeDeleted,
            includeSuperseded: filter.includeSuperseded
        )

        var results: [SearchResponse.Result] = []
        results.reserveCapacity(max(0, request.timelineFallbackLimit))

        let frames = await timeline(query)
        let previewById: [UInt64: Data]
        do {
            previewById = try await framePreviews(
                frameIds: frames.map(\.id),
                maxBytes: request.previewMaxBytes
            )
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "unified search timeline fallback previews",
                fallback: "empty preview map"
            )
            previewById = [:]
        }

        for (rank, meta) in frames.enumerated() {
            let frameId = meta.id

            if let allowlist = filter.frameIds, !allowlist.contains(frameId) { continue }
            if !filter.includeDeleted, meta.status == .deleted { continue }
            if !filter.includeSuperseded, meta.supersededBy != nil { continue }
            if !filter.includeSurrogates, meta.kind == "surrogate" { continue }

            let score = 1 / Float(max(0, request.rrfK) + rank + 1)
            let previewText = previewById[frameId]
                .flatMap { String(data: $0, encoding: .utf8) }

            results.append(
                SearchResponse.Result(
                    frameId: frameId,
                    score: score,
                    previewText: previewText,
                    sources: [.timeline]
                )
            )

            if results.count >= request.timelineFallbackLimit {
                break
            }
        }

        return results
    }

    private static func orExpandedQuery(from query: String, maxTokens: Int = 16) -> String? {
        let tokens = query.split(whereSeparator: { $0.isWhitespace })
        if tokens.isEmpty { return nil }
        let capped = tokens.prefix(max(0, maxTokens))

        let quoted = capped.map { raw -> String in
            let token = String(raw)
            let escaped = token.replacingOccurrences(of: "\"", with: "\"\"")
            return "\"\(escaped)\""
        }
        return quoted.joined(separator: " OR ")
    }

    private static let asciiPunctuationScalars: Set<UnicodeScalar> = {
        let scalars = "!\\\"#$%&'()*+,-./:;<=>?@[\\\\]^_`{|}~".unicodeScalars
        return Set(scalars)
    }()

    private static func structuredEntityCandidates(
        query: String,
        engine: FTS5SearchEngine,
        maxCandidates: Int
    ) async throws -> [EntityKey] {
        let capped = max(0, min(maxCandidates, 10_000))
        guard capped > 0 else { return [] }

        var candidates: [String: (rank: Int, aliasLength: Int)] = [:]

        let fullAlias = StructuredMemoryCanonicalizer.normalizedAlias(query)
        if !fullAlias.isEmpty {
            let matches = try await engine.resolveEntities(matchingAlias: fullAlias, limit: capped)
            for match in matches {
                let key = match.key.rawValue
                let aliasLength = fullAlias.count
                if let existing = candidates[key] {
                    if 0 < existing.rank || (existing.rank == 0 && aliasLength > existing.aliasLength) {
                        candidates[key] = (rank: 0, aliasLength: aliasLength)
                    }
                } else {
                    candidates[key] = (rank: 0, aliasLength: aliasLength)
                }
            }
        }

        let tokens = structuredAliasTokens(from: query)
        var seenTokens: Set<String> = []
        for token in tokens {
            let normalized = StructuredMemoryCanonicalizer.normalizedAlias(token)
            if normalized.count < 2 { continue }
            if !seenTokens.insert(normalized).inserted { continue }

            let matches = try await engine.resolveEntities(matchingAlias: normalized, limit: capped)
            for match in matches {
                let key = match.key.rawValue
                let aliasLength = normalized.count
                if let existing = candidates[key] {
                    if 1 < existing.rank || (existing.rank == 1 && aliasLength > existing.aliasLength) {
                        candidates[key] = (rank: 1, aliasLength: aliasLength)
                    }
                } else {
                    candidates[key] = (rank: 1, aliasLength: aliasLength)
                }
            }
        }

        let sorted = candidates.map { (key, value) in
            (key: key, rank: value.rank, aliasLength: value.aliasLength)
        }.sorted { lhs, rhs in
            if lhs.rank != rhs.rank { return lhs.rank < rhs.rank }
            if lhs.aliasLength != rhs.aliasLength { return lhs.aliasLength > rhs.aliasLength }
            return lhs.key < rhs.key
        }

        return sorted.prefix(capped).map { EntityKey($0.key) }
    }

    private static func structuredAliasTokens(from query: String) -> [String] {
        var tokens: [String] = []
        var buffer = String.UnicodeScalarView()

        func flush() {
            if !buffer.isEmpty {
                tokens.append(String(buffer))
                buffer.removeAll(keepingCapacity: true)
            }
        }

        for scalar in query.unicodeScalars {
            if scalar.properties.isWhitespace || (scalar.isASCII && asciiPunctuationScalars.contains(scalar)) {
                flush()
            } else {
                buffer.append(scalar)
            }
        }
        flush()

        return tokens
    }

    private static func candidateLimit(for topK: Int) -> Int {
        guard topK > 0 else { return 0 }
        let expanded = topK > Int.max / 3 ? Int.max : topK * 3
        let capped = min(expanded, 1000)
        return max(topK, capped)
    }

    private static func frameIDsAndSet<S: Sequence>(from frameIDs: S) -> ([UInt64], Set<UInt64>)
    where S.Element == UInt64 {
        var ids: [UInt64] = []
        var set: Set<UInt64> = []
        ids.reserveCapacity(frameIDs.underestimatedCount)
        set.reserveCapacity(frameIDs.underestimatedCount)
        for frameId in frameIDs {
            ids.append(frameId)
            set.insert(frameId)
        }
        return (ids, set)
    }

    private static func matches(metadataFilter: MetadataFilter, meta: FrameMeta) -> Bool {
        if !metadataFilter.requiredEntries.isEmpty {
            guard let entries = meta.metadata?.entries else { return false }
            for (key, value) in metadataFilter.requiredEntries {
                guard entries[key] == value else { return false }
            }
        }

        if !metadataFilter.requiredTags.isEmpty {
            for required in metadataFilter.requiredTags {
                let hasTag = meta.tags.contains { tag in
                    tag.key == required.key && tag.value == required.value
                }
                if !hasTag { return false }
            }
        }

        if !metadataFilter.requiredLabels.isEmpty {
            for label in metadataFilter.requiredLabels where !meta.labels.contains(label) {
                return false
            }
        }

        return true
    }
}
