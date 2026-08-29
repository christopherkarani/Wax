import Foundation
import WaxCore

/// Compact assembly: budgeted packing of Layered recall hits into short/medium/long buckets.
/// Fetch, project filter, and the working-lane empty fallback stay in Layered recall.
package enum CompactAssembly {
    package struct Request: Sendable {
        package var query: String
        package var sessionID: UUID?
        package var mode: Memory.RetrievalMode
        package var tokenBudget: Int
        package var maxItems: Int
        package var scope: LayeredRecall.Scope
        package var explicitProject: String?
        package var explicitRepo: String?
        package var clientCWD: String?
        package var frameFilter: FrameFilter?
        package var timeRange: SearchTimeRange?

        package init(
            query: String,
            sessionID: UUID?,
            mode: Memory.RetrievalMode,
            tokenBudget: Int,
            maxItems: Int,
            scope: LayeredRecall.Scope = .project,
            explicitProject: String? = nil,
            explicitRepo: String? = nil,
            clientCWD: String? = nil,
            frameFilter: FrameFilter? = nil,
            timeRange: SearchTimeRange? = nil
        ) {
            self.query = query
            self.sessionID = sessionID
            self.mode = mode
            self.tokenBudget = tokenBudget
            self.maxItems = maxItems
            self.scope = scope
            self.explicitProject = explicitProject
            self.explicitRepo = explicitRepo
            self.clientCWD = clientCWD
            self.frameFilter = frameFilter
            self.timeRange = timeRange
        }
    }

    package struct Result: Sendable {
        package var short: [LayeredRecall.Hit]
        package var medium: [LayeredRecall.Hit]
        package var long: [LayeredRecall.Hit]
        package var compactedText: String
        package var summary: String
        package var usedTokens: Int
    }

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

    package static func fetchSearchTopK(maxItems: Int) -> Int {
        max(1, min(4, maxItems))
    }

    package static func assemble(
        request: Request,
        stores: LayeredRecall.Stores,
        tokenizer: Tokenizer
    ) async throws -> Result {
        let recallRequest = LayeredRecall.RecallRequest(
            query: request.query,
            scope: request.scope,
            limit: request.maxItems,
            searchTopK: fetchSearchTopK(maxItems: request.maxItems),
            mode: request.mode,
            sessionID: request.sessionID,
            explicitProject: request.explicitProject,
            explicitRepo: request.explicitRepo,
            clientCWD: request.clientCWD,
            frameFilter: request.frameFilter,
            timeRange: request.timeRange
        )
        let lanes = try await LayeredRecall.fetchLanes(
            request: recallRequest,
            stores: stores,
            horizons: .all,
            canonicalizeFrameIDs: true,
            episodicTopK: 2
        )

        let identity = lanes.identity

        let working = scoped(lanes.working, scope: request.scope, identity: identity).map(annotate)
        let episodic = scoped(lanes.episodic, scope: request.scope, identity: identity).map(annotate)
        let durable = scoped(lanes.durable, scope: request.scope, identity: identity).map(annotate)

        return await pack(
            query: request.query,
            working: working,
            episodic: episodic,
            durable: durable,
            tokenBudget: request.tokenBudget,
            maxItems: request.maxItems,
            tokenizer: tokenizer
        )
    }

    package static func pack(
        query: String,
        working: [LayeredRecall.Hit],
        episodic: [LayeredRecall.Hit],
        durable: [LayeredRecall.Hit],
        tokenBudget: Int,
        maxItems: Int,
        tokenizer: Tokenizer
    ) async -> Result {
        let short = deduplicate(working)
        let medium = deduplicate(episodic).sorted {
            if $0.score != $1.score { return $0.score > $1.score }
            if $0.timestampMs != $1.timestampMs { return $0.timestampMs > $1.timestampMs }
            return $0.reference < $1.reference
        }
        let long = deduplicate(durable)

        let ordered = Array(
            (short.prefix(maxItems) + medium.prefix(maxItems) + long.prefix(maxItems))
                .prefix(maxItems * 3)
        )
        var selectedShort: [LayeredRecall.Hit] = []
        var selectedMedium: [LayeredRecall.Hit] = []
        var selectedLong: [LayeredRecall.Hit] = []
        var usedTokens = await tokenizer.count(
            render(query: query, short: selectedShort, medium: selectedMedium, long: selectedLong)
        )

        for hit in ordered {
            var candidateShort = selectedShort
            var candidateMedium = selectedMedium
            var candidateLong = selectedLong
            switch hit.horizon {
            case .working:
                candidateShort.append(hit)
            case .episodic:
                candidateMedium.append(hit)
            case .durable:
                candidateLong.append(hit)
            }
            let candidateText = render(
                query: query,
                short: candidateShort,
                medium: candidateMedium,
                long: candidateLong
            )
            let candidateTokens = await tokenizer.count(candidateText)
            guard candidateTokens <= tokenBudget else { continue }
            selectedShort = candidateShort
            selectedMedium = candidateMedium
            selectedLong = candidateLong
            usedTokens = candidateTokens
        }

        var compactedText = render(
            query: query,
            short: selectedShort,
            medium: selectedMedium,
            long: selectedLong
        )
        let renderedTokens = await tokenizer.count(compactedText)
        if renderedTokens > tokenBudget {
            compactedText = await tokenizer.truncate(compactedText, tokenBudget)
            usedTokens = await tokenizer.count(compactedText)
        } else {
            usedTokens = renderedTokens
        }

        let summary = [
            selectedShort.first?.preview,
            selectedMedium.first?.preview,
            selectedLong.first?.preview,
        ]
        .compactMap { $0 }
        .prefix(3)
        .joined(separator: " | ")

        return Result(
            short: selectedShort,
            medium: selectedMedium,
            long: selectedLong,
            compactedText: compactedText,
            summary: summary.isEmpty ? "No compacted context available." : summary,
            usedTokens: usedTokens
        )
    }

    package static func render(
        query: String,
        short: [LayeredRecall.Hit],
        medium: [LayeredRecall.Hit],
        long: [LayeredRecall.Hit]
    ) -> String {
        var lines = ["Query: \(query)"]
        func appendSection(_ title: String, _ hits: [LayeredRecall.Hit]) {
            guard !hits.isEmpty else { return }
            lines.append("")
            lines.append(title)
            for hit in hits {
                let reason = hit.explanations.prefix(2).joined(separator: ", ")
                lines.append("- \(hit.preview)")
                if !reason.isEmpty {
                    lines.append("  why: \(reason)")
                }
            }
        }
        appendSection("Short-Term Context", short)
        appendSection("Medium-Term Context", medium)
        appendSection("Long-Term Context", long)
        return lines.joined(separator: "\n")
    }

    package static func deduplicate(_ hits: [LayeredRecall.Hit]) -> [LayeredRecall.Hit] {
        var seen = Set<String>()
        var deduped: [LayeredRecall.Hit] = []
        deduped.reserveCapacity(hits.count)
        for hit in hits where seen.insert(hit.reference).inserted {
            deduped.append(hit)
        }
        return deduped
    }

    private static func scoped(
        _ hits: [LayeredRecall.Hit],
        scope: LayeredRecall.Scope,
        identity: LayeredRecall.Identity
    ) -> [LayeredRecall.Hit] {
        LayeredRecall.selectHits(merged: hits, scope: scope, identity: identity).hits
    }

    private static func annotate(_ hit: LayeredRecall.Hit) -> LayeredRecall.Hit {
        let prefix: String
        switch hit.horizon {
        case .working:
            prefix = "current session"
        case .episodic:
            prefix = "recent session episode"
        case .durable:
            prefix = "durable memory"
        }
        guard !hit.explanations.contains(prefix) else { return hit }
        var copy = hit
        copy.explanations = [prefix] + hit.explanations
        return copy
    }
}
