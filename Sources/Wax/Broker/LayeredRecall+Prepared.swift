import Foundation

extension LayeredRecall {
    /// A recall whose stores have been read: what is left reads none of them. A recall that
    /// reranks is left with its cross-encoder scoring, which takes 100–450 ms; a broker runs
    /// that after it releases its command lock, so other agents' commands do not wait for it.
    package struct PreparedRecall: Sendable {
        enum State: Sendable {
            case finished(RecallResult)
            case scoring(Scoring)
        }

        /// What the result needs besides the ranked hits.
        struct Outline: Sendable {
            var request: RecallRequest
            var identity: Identity
            var diagnostics: LaneDiagnostics
            var retrievalTopK: Int
            /// The person lane's owner card, which leads the hits.
            var ownerCard: Hit?
        }

        /// A merged window and the frame text of each hit the reranker scores.
        struct Scoring: Sendable {
            var outline: Outline
            var window: [Hit]
            var policyTop: [Hit]
            var stage: RerankStage
            var texts: [MemoryID: String]
        }

        let state: State

        /// Whether `finish()` scores with a cross-encoder.
        package var needsScoring: Bool {
            if case .scoring = state { return true }
            return false
        }

        /// Ranks and selects the hits. Reads no store. `@concurrent`, so the scoring never
        /// runs on the caller's actor.
        @concurrent
        package func finish() async throws -> RecallResult {
            switch state {
            case .finished(let result):
                return result
            case .scoring(let scoring):
                let ranked = try await LayeredRecall.rerankMerged(
                    window: scoring.window,
                    policyTop: scoring.policyTop,
                    limit: scoring.outline.request.limit,
                    query: scoring.outline.request.query,
                    stage: scoring.stage,
                    text: { scoring.texts[$0.id] ?? String($0.text.prefix(LayeredRecall.rerankTextMaxCharacters)) }
                )
                // A scored window keeps at least one hit, so the lane is never found empty.
                return await scoring.outline.result(merged: ranked) { false }
            }
        }
    }
}

extension LayeredRecall.PreparedRecall.Outline {
    typealias Hit = LayeredRecall.Hit

    /// The result for the merged (or reranked) hits: the owner card first, then the scope's
    /// selection. `laneOccupied` is asked only when a project-scoped recall finds nothing.
    func result(
        merged searched: [Hit],
        laneOccupied: () async -> Bool
    ) async -> LayeredRecall.RecallResult {
        let merged: [Hit]
        if let card = ownerCard {
            // Card leads; leftover prefs still fill the window.
            let rest = searched.filter { hit in
                !hit.flags.contains(.ownerCard)
                    && !OwnerCard.matchesCompiledSlot(text: hit.text, metadata: hit.metadata)
            }
            merged = Array(([card] + rest).prefix(request.limit))
        } else {
            merged = searched
        }

        let selected = LayeredRecall.selectHits(merged: merged, scope: request.scope, identity: identity)
        var projectMiss = selected.projectMiss
        var scopeMissMessage = selected.scopeMissMessage
        if request.scope == .project,
           selected.hits.isEmpty,
           projectMiss,
           identity.project != nil || identity.repo != nil,
           await laneOccupied() {
            // Query miss in an occupied project is not an empty lane.
            projectMiss = false
            scopeMissMessage = nil
        }
        let keptHits = Array(selected.hits.prefix(request.limit))
        return LayeredRecall.RecallResult(
            hits: keptHits,
            scope: request.scope,
            identity: identity,
            projectMiss: projectMiss,
            scopeMissMessage: scopeMissMessage,
            scopeDropped: selected.scopeDropped,
            diagnostics: diagnostics,
            searchTopK: request.searchTopK,
            retrievalTopK: retrievalTopK,
            limit: request.limit,
            collapsed: LayeredRecall.collapsedTotal(in: keptHits)
        )
    }
}
