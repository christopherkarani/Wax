import Foundation
import WaxCore

/// Cross-encoder reranking of broker recall, run once after the hits of every store merge.
///
/// The merge's order (freshness, lock and stale penalties, the session boost, dedupe and
/// clustering) is the retrieval order the reranker fuses with, the same way `Memory` fuses
/// a store's retrieval order: with the default reciprocal-rank fusion, policy and relevance
/// each get one vote. The merge's hard rules stay rules: a hit demoted for an unlanded claim
/// is never promoted, and the working or durable slot the merge reserved stays filled.
extension LayeredRecall {
    /// Most characters of a frame the reranker scores. It reads at most 16 windows of 288
    /// tokens (about 20 KB of English), so longer text only costs tokenization.
    package static let rerankTextMaxCharacters = 65_536

    /// The stage that reranks this recall, or `nil`: no stage, or a mode it skips (the
    /// automatic stage reranks hybrid recall only).
    static func rerankStage(for lanes: HorizonLanes, stores: Stores) -> RerankStage? {
        guard let stage = stores.reranking else { return nil }
        let modes = [lanes.durableExecution, lanes.workingExecution].compactMap { $0?.effectiveMode }
        return modes.contains(where: stage.applies(to:)) ? stage : nil
    }

    /// Reranks the merged `window` (the merge's order, at least `limit` long when there are
    /// that many hits) and returns the top `limit`. `policyTop` is the merge at `limit`: a
    /// horizon it reserved a slot for keeps one.
    package static func rerankMerged(
        window: [Hit],
        policyTop: [Hit],
        limit: Int,
        query: String,
        stage: RerankStage,
        text: (Hit) async -> String
    ) async throws -> [Hit] {
        // Demoted hits sort after every other hit, so they are the window's tail.
        let promotable = Array(window.prefix { !$0.flags.contains(.unlandedDemoted) })
        let reranked = try await stage.rerank(query: query, items: promotable, text: text) { hit, explanation in
            hit.explanations.append(explanation)
        } + window.dropFirst(promotable.count)
        return reservingHorizons(of: policyTop, in: reranked, limit: limit)
    }

    /// The first `limit` of `ranked`, with a slot for each horizon `policyTop` holds, taken
    /// by that horizon's best-ranked hit in place of the lowest hit of another horizon.
    private static func reservingHorizons(of policyTop: [Hit], in ranked: [Hit], limit: Int) -> [Hit] {
        var kept = Array(ranked.prefix(limit))
        for horizon in [Horizon.working, .durable] where policyTop.contains(where: { $0.horizon == horizon }) {
            guard !kept.contains(where: { $0.horizon == horizon }),
                  let reserved = ranked.first(where: { $0.horizon == horizon })
                      ?? policyTop.first(where: { $0.horizon == horizon })
            else { continue }
            if kept.count >= limit {
                guard let evict = kept.lastIndex(where: { $0.horizon != horizon }) else { continue }
                kept.remove(at: evict)
            }
            kept.append(reserved)
        }
        return kept
    }

    /// The text the reranker scores for `hit`: its full frame from the store it came from,
    /// or the hit's own text when the frame cannot be read.
    static func rerankText(for hit: Hit, stores: Stores) async -> String {
        let memory: MemoryOrchestrator? = switch hit.horizon {
        case .durable: stores.longTermMemory
        case .working: hit.sessionID.flatMap { stores.workingLane($0)?.memory }
        case .episodic: nil
        }
        if let memory {
            do {
                let data = try await memory.wax.frameContent(frameId: hit.frameID)
                if let frame = String(data: data, encoding: .utf8), !frame.isEmpty {
                    return String(frame.prefix(rerankTextMaxCharacters))
                }
            } catch {
                WaxDiagnostics.logSwallowed(error, context: "broker rerank frame text", fallback: "score the hit text")
            }
        }
        return String(hit.text.prefix(rerankTextMaxCharacters))
    }
}
