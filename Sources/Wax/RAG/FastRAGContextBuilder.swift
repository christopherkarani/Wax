import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

public struct FastRAGContextBuilder: Sendable {
    public init() {}

    /// Build a deterministic RAG context: at most one expansion + ranked snippets.
    /// - Parameters:
    ///   - query: user query string
    ///   - embedding: optional caller-supplied embedding (no query-time embedding inside Wax)
    ///   - wax: Wax handle
    ///   - config: Fast RAG configuration
    public func build(
        query: String,
        embedding: [Float]? = nil,
        vectorEnginePreference: VectorEnginePreference = .auto,
        wax: Wax,
        config: FastRAGConfig = .init()
    ) async throws -> RAGContext {
        let clamped = clamp(config)
        let counter = try await TokenCounter.shared()

        // 1) Run unified search
        let request = SearchRequest(
            query: query,
            embedding: embedding,
            vectorEnginePreference: vectorEnginePreference,
            mode: clamped.searchMode,
            topK: clamped.searchTopK,
            rrfK: clamped.rrfK,
            previewMaxBytes: clamped.previewMaxBytes
        )
        let response = try await wax.search(request)

        var items: [RAGContext.Item] = []
        var usedTokens = 0
        var expandedFrameId: UInt64?
        var surrogateSourceFrameIds: Set<UInt64> = []

        // 2) Expansion: first result with valid UTF-8 frame content
        if clamped.expansionMaxTokens > 0, clamped.expansionMaxBytes > 0 {
            for result in response.results {
                if let expanded = try await expansionText(
                    frameId: result.frameId,
                    wax: wax,
                    counter: counter,
                    maxTokens: clamped.expansionMaxTokens,
                    maxBytes: clamped.expansionMaxBytes
                ) {
                    usedTokens += await counter.count(expanded)
                    expandedFrameId = result.frameId
                    items.append(
                        .init(
                            kind: .expanded,
                            frameId: result.frameId,
                            score: result.score,
                            sources: result.sources,
                            text: expanded
                        )
                    )
                    break
                }
            }
        }

        // 3) Surrogates (denseCached mode) - Optimized with batch token operations
        if clamped.mode == .denseCached,
           clamped.maxContextTokens > usedTokens,
           clamped.maxSurrogates > 0,
           clamped.surrogateMaxTokens > 0 {
            var remainingTokens = clamped.maxContextTokens - usedTokens

            let maxToLoad = min(clamped.maxSurrogates, min(clamped.searchTopK, 32))

            // Batch resolve surrogate ids in a single actor hop to avoid TaskGroup churn.
            let sourceFrameIds = response.results
                .filter { result in
                    guard let expandedFrameId else { return true }
                    return result.frameId != expandedFrameId
                }
                .map(\.frameId)
            let surrogateMap = await wax.surrogateFrameIds(for: sourceFrameIds)

            // Keep only the top candidates, preserving response order.
            var orderedSurrogateIds: [UInt64] = []
            orderedSurrogateIds.reserveCapacity(maxToLoad)
            for result in response.results {
                guard let surrogateId = surrogateMap[result.frameId] else { continue }
                orderedSurrogateIds.append(surrogateId)
                if orderedSurrogateIds.count >= maxToLoad { break }
            }

            // Batch load surrogate contents to avoid per-frame actor hops.
            // If any surrogate is corrupted, fall back to per-frame loads and skip failures.
            let surrogateContents: [UInt64: Data]
            do {
                surrogateContents = try await wax.frameContents(frameIds: orderedSurrogateIds)
            } catch {
                var recovered: [UInt64: Data] = [:]
                recovered.reserveCapacity(orderedSurrogateIds.count)
                for surrogateId in orderedSurrogateIds {
                    if let data = try? await wax.frameContent(frameId: surrogateId) {
                        recovered[surrogateId] = data
                    }
                }
                surrogateContents = recovered
            }

            var surrogateCandidates: [(result: SearchResponse.Result, surrogateFrameId: UInt64, text: String)] = []
            surrogateCandidates.reserveCapacity(orderedSurrogateIds.count)
            for result in response.results {
                guard let surrogateId = surrogateMap[result.frameId],
                      let data = surrogateContents[surrogateId],
                      let text = String(data: data, encoding: .utf8),
                      !text.isEmpty else { continue }
                surrogateCandidates.append((result, surrogateId, text))
                if surrogateCandidates.count >= maxToLoad { break }
            }

            if !surrogateCandidates.isEmpty {
                // Use optimized combined count and truncate operation
                let texts = surrogateCandidates.map { $0.text }
                let maxTokensPerText = min(clamped.surrogateMaxTokens, remainingTokens)
                let processedResults = await counter.countAndTruncateBatch(texts, maxTokens: maxTokensPerText)

                for (index, (result, surrogateFrameId, _)) in surrogateCandidates.enumerated() {
                    let (tokens, capped) = processedResults[index]

                    guard !capped.isEmpty && tokens <= remainingTokens else { continue }

                    items.append(
                        .init(
                            kind: .surrogate,
                            frameId: surrogateFrameId,
                            score: result.score,
                            sources: result.sources,
                            text: capped
                        )
                    )
                    surrogateSourceFrameIds.insert(result.frameId)
                    remainingTokens -= tokens
                    if remainingTokens == 0 { break }
                }
            }

            usedTokens = clamped.maxContextTokens - remainingTokens
        }

        // 4) Snippets - Optimized with batch token operations
        if clamped.maxContextTokens > usedTokens {
            var remainingTokens = clamped.maxContextTokens - usedTokens
            var snippetCount = 0

            // Collect all snippet candidates
            var snippetCandidates: [(result: SearchResponse.Result, preview: String)] = []
            snippetCandidates.reserveCapacity(min(clamped.maxSnippets, 32))
            
            for result in response.results {
                if let expandedFrameId, result.frameId == expandedFrameId { continue }
                if surrogateSourceFrameIds.contains(result.frameId) { continue }
                guard snippetCount < clamped.maxSnippets else { break }
                guard let preview = result.previewText, !preview.isEmpty else { continue }

                snippetCandidates.append((result, preview))
                snippetCount += 1
            }

            // Always use batch processing for consistency and better performance
            if !snippetCandidates.isEmpty {
                let previews = snippetCandidates.map { $0.preview }
                let maxTokensPerSnippet = min(clamped.snippetMaxTokens, remainingTokens)
                
                // Use optimized combined count and truncate operation
                let processedResults = await counter.countAndTruncateBatch(previews, maxTokens: maxTokensPerSnippet)

                for (index, (result, _)) in snippetCandidates.enumerated() {
                    let (tokens, capped) = processedResults[index]

                    guard !capped.isEmpty && tokens <= remainingTokens else { continue }

                    items.append(
                        .init(
                            kind: .snippet,
                            frameId: result.frameId,
                            score: result.score,
                            sources: result.sources,
                            text: capped
                        )
                    )
                    remainingTokens -= tokens
                    if remainingTokens == 0 { break }
                }
            }
            usedTokens = clamped.maxContextTokens - remainingTokens
        }

        return RAGContext(query: query, items: items, totalTokens: usedTokens)
    }

    // MARK: - Helpers

    private func clamp(_ config: FastRAGConfig) -> FastRAGConfig {
        var c = config
        c.maxContextTokens = max(0, c.maxContextTokens)
        c.expansionMaxTokens = min(max(0, c.expansionMaxTokens), c.maxContextTokens)
        c.expansionMaxBytes = max(0, c.expansionMaxBytes)
        c.snippetMaxTokens = max(0, c.snippetMaxTokens)
        c.maxSnippets = max(0, c.maxSnippets)
        c.maxSurrogates = max(0, c.maxSurrogates)
        c.surrogateMaxTokens = max(0, c.surrogateMaxTokens)
        c.searchTopK = max(0, c.searchTopK)
        c.rrfK = max(0, c.rrfK)
        c.previewMaxBytes = max(0, c.previewMaxBytes)
        return c
    }

    private func expansionText(
        frameId: UInt64,
        wax: Wax,
        counter: TokenCounter,
        maxTokens: Int,
        maxBytes: Int
    ) async throws -> String? {
        guard maxTokens > 0, maxBytes > 0 else { return nil }

        let meta = try await wax.frameMetaIncludingPending(frameId: frameId)
        let canonicalBytes: UInt64
        if meta.canonicalEncoding == .plain {
            canonicalBytes = meta.payloadLength
        } else if let length = meta.canonicalLength {
            canonicalBytes = length
        } else {
            throw WaxError.invalidToc(reason: "missing canonical_length for frame \(frameId)")
        }
        guard canonicalBytes > 0 else { return nil }
        guard canonicalBytes <= UInt64(maxBytes) else { return nil }

        let data = try await wax.frameContentIncludingPending(frameId: frameId)
        try Self.validateExpansionPayloadSize(
            expectedBytes: canonicalBytes,
            actualBytes: data.count,
            maxBytes: maxBytes
        )
        guard let text = String(data: data, encoding: .utf8),
              !text.isEmpty else { return nil }
        let truncated = await counter.truncate(text, maxTokens: maxTokens)
        return truncated.isEmpty ? nil : truncated
    }

    static func validateExpansionPayloadSize(
        expectedBytes: UInt64,
        actualBytes: Int,
        maxBytes: Int
    ) throws {
        guard maxBytes > 0 else { return }
        if actualBytes > maxBytes {
            throw WaxError.io("expansion payload exceeds cap: \(actualBytes) > \(maxBytes)")
        }
        if actualBytes != Int(expectedBytes) {
            throw WaxError.io("expansion payload length mismatch: expected \(expectedBytes), got \(actualBytes)")
        }
    }
}
