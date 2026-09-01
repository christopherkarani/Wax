import Foundation

/// Budgeted packing of ranked hits + already-loaded texts into `RAGContext`.
/// Retrieval, access I/O, and frame loads stay in `FastRAGContextBuilder`.
package enum RecallAssembly {
    package struct Tokenizer: Sendable {
        package var count: @Sendable (String) async -> Int
        package var truncate: @Sendable (String, Int) async -> String

        package init(
            count: @escaping @Sendable (String) async -> Int,
            truncate: @escaping @Sendable (String, Int) async -> String
        ) {
            self.count = count
            self.truncate = truncate
        }

        /// Test adapter: one token per Character.
        package static let character = Tokenizer(
            count: { $0.count },
            truncate: { text, maxTokens in
                String(text.prefix(max(0, maxTokens)))
            }
        )
    }

    package struct Payload: Sendable {
        package var hit: SearchResponse.Result
        package var expansionText: String?
        package var surrogateText: String?
        package var snippetText: String
        package var surrogateFrameId: UInt64?
        package var accessStats: FrameAccessStats?

        package init(
            hit: SearchResponse.Result,
            expansionText: String? = nil,
            surrogateText: String? = nil,
            snippetText: String = "",
            surrogateFrameId: UInt64? = nil,
            accessStats: FrameAccessStats? = nil
        ) {
            self.hit = hit
            self.expansionText = expansionText
            self.surrogateText = surrogateText
            self.snippetText = snippetText
            self.surrogateFrameId = surrogateFrameId
            self.accessStats = accessStats
        }
    }

    /// Pack already-loaded payloads. Does not rewrite Ranking's published score.
    package static func pack(
        query: String,
        payloads: [Payload],
        config: FastRAGConfig,
        tokenizer: Tokenizer,
        nowMs: Int64?
    ) async -> RAGContext {
        let clamped = clamp(config)
        var items: [RAGContext.Item] = []
        var usedTokens = 0
        var expandedFrameId: UInt64?
        var surrogateSourceFrameIds: Set<UInt64> = []

        if clamped.expansionMaxTokens > 0 {
            for payload in payloads {
                guard let text = payload.expansionText else { continue }
                let remaining = clamped.maxContextTokens - usedTokens
                guard let budgeted = await budgetedText(
                    text,
                    maxTokens: clamped.expansionMaxTokens,
                    remaining: remaining,
                    tokenizer: tokenizer
                ) else { continue }
                items.append(
                    item(
                        kind: .expanded,
                        frameId: payload.hit.frameId,
                        payload: payload,
                        text: budgeted.text,
                        nowMs: nowMs
                    )
                )
                usedTokens += budgeted.tokens
                expandedFrameId = payload.hit.frameId
                break
            }
        }

        if clamped.mode == .denseCached,
           clamped.maxContextTokens > usedTokens,
           clamped.maxSurrogates > 0,
           clamped.surrogateMaxTokens > 0 {
            var remaining = clamped.maxContextTokens - usedTokens
            var surrogateCount = 0
            for payload in payloads {
                if let expandedFrameId, payload.hit.frameId == expandedFrameId { continue }
                guard let text = payload.surrogateText,
                      let surrogateFrameId = payload.surrogateFrameId else { continue }
                guard surrogateCount < clamped.maxSurrogates else { break }
                guard let budgeted = await budgetedText(
                    text,
                    maxTokens: clamped.surrogateMaxTokens,
                    remaining: remaining,
                    tokenizer: tokenizer
                ) else { continue }
                items.append(
                    item(
                        kind: .surrogate,
                        frameId: surrogateFrameId,
                        payload: payload,
                        text: budgeted.text,
                        nowMs: nowMs
                    )
                )
                surrogateSourceFrameIds.insert(payload.hit.frameId)
                remaining -= budgeted.tokens
                surrogateCount += 1
                if remaining == 0 { break }
            }
            usedTokens = clamped.maxContextTokens - remaining
        }

        if clamped.maxContextTokens > usedTokens, clamped.snippetMaxTokens > 0, clamped.maxSnippets > 0 {
            var remaining = clamped.maxContextTokens - usedTokens
            var snippetCount = 0
            for payload in payloads {
                if let expandedFrameId, payload.hit.frameId == expandedFrameId { continue }
                if surrogateSourceFrameIds.contains(payload.hit.frameId) { continue }
                guard snippetCount < clamped.maxSnippets else { break }
                guard let budgeted = await budgetedText(
                    payload.snippetText,
                    maxTokens: clamped.snippetMaxTokens,
                    remaining: remaining,
                    tokenizer: tokenizer
                ) else { continue }
                items.append(
                    item(
                        kind: .snippet,
                        frameId: payload.hit.frameId,
                        payload: payload,
                        text: budgeted.text,
                        nowMs: nowMs
                    )
                )
                remaining -= budgeted.tokens
                snippetCount += 1
                if remaining == 0 { break }
            }
            usedTokens = clamped.maxContextTokens - remaining
        }

        return RAGContext(query: query, items: items, totalTokens: usedTokens)
    }

    private static func clamp(_ config: FastRAGConfig) -> FastRAGConfig {
        var c = config
        c.maxContextTokens = max(0, c.maxContextTokens)
        c.expansionMaxTokens = max(0, c.expansionMaxTokens)
        c.snippetMaxTokens = max(0, c.snippetMaxTokens)
        c.maxSnippets = max(0, c.maxSnippets)
        c.maxSurrogates = max(0, c.maxSurrogates)
        c.surrogateMaxTokens = max(0, c.surrogateMaxTokens)
        return c
    }

    /// Truncate to the per-item cap only. Skip (do not shrink to remaining) when
    /// the capped item still exceeds the leftover budget.
    private static func budgetedText(
        _ text: String,
        maxTokens: Int,
        remaining: Int,
        tokenizer: Tokenizer
    ) async -> (text: String, tokens: Int)? {
        guard maxTokens > 0, remaining > 0, !text.isEmpty else { return nil }
        let capped = await tokenizer.truncate(text, maxTokens)
        let tokens = await tokenizer.count(capped)
        guard !capped.isEmpty, tokens <= remaining else { return nil }
        return (capped, tokens)
    }

    private static func item(
        kind: RAGContext.ItemKind,
        frameId: UInt64,
        payload: Payload,
        text: String,
        nowMs: Int64?
    ) -> RAGContext.Item {
        RAGContext.Item(
            kind: kind,
            frameId: frameId,
            score: payload.hit.score,
            sources: payload.hit.sources.isEmpty ? [.unknown] : payload.hit.sources,
            text: text,
            metadata: payload.hit.metadata,
            explanations: enrichedExplanations(
                payload.hit.explanations,
                stats: payload.accessStats,
                metadata: payload.hit.metadata,
                nowMs: nowMs
            )
        )
    }

    private static func enrichedExplanations(
        _ existing: [String],
        stats: FrameAccessStats?,
        metadata: [String: String],
        nowMs: Int64?
    ) -> [String] {
        let accessReasons = nowMs.map {
            MemorySemantics.accessReasons(
                stats: stats,
                metadata: metadata,
                nowMs: $0
            ).reasons
        } ?? []
        var seen = Set<String>()
        var combined: [String] = []
        for reason in existing + accessReasons {
            let normalized = reason.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty, seen.insert(normalized).inserted else { continue }
            combined.append(normalized)
        }
        return combined
    }
}
