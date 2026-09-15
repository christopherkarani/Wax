import Foundation
import Testing
@testable import Wax

@Suite("BrokerRecallSearchTests")
struct BrokerRecallSearchTests {
    @Test(arguments: [false, true])
    func mergedSearchDoesNotHideEitherStoresFallback(workingDegraded: Bool) {
        let active = MemoryOrchestrator.SearchExecution(
            hits: [], requestedMode: .hybrid(), effectiveMode: .hybrid(), queryEmbeddingState: .available
        )
        let degraded = MemoryOrchestrator.SearchExecution(
            hits: [], requestedMode: .hybrid(), effectiveMode: .textOnly, queryEmbeddingState: .timeout
        )
        let result = BrokerRecall.mergeSearchExecutions(
            working: workingDegraded ? degraded : active,
            durable: workingDegraded ? active : degraded,
            topK: 3
        )
        #expect(result.effectiveMode == .textOnly)
        #expect(result.queryEmbeddingState == .timeout)
    }

    @Test
    func mergeSearchExecutionsPrefersWorkingOnScoreTiesAndDoesNotDedupeFrameIDs() {
        let working = MemoryOrchestrator.SearchExecution(
            hits: [
                MemoryOrchestrator.MemorySearchHit(
                    frameId: 7, score: 0.5, previewText: "session", sources: [.text]
                )
            ],
            requestedMode: .hybrid(),
            effectiveMode: .hybrid(),
            queryEmbeddingState: .available
        )
        let durable = MemoryOrchestrator.SearchExecution(
            hits: [
                MemoryOrchestrator.MemorySearchHit(
                    frameId: 7, score: 0.5, previewText: "durable", sources: [.text]
                ),
                MemoryOrchestrator.MemorySearchHit(
                    frameId: 9, score: 0.4, previewText: "other", sources: [.text]
                )
            ],
            requestedMode: .hybrid(),
            effectiveMode: .hybrid(),
            queryEmbeddingState: .available
        )
        let result = BrokerRecall.mergeSearchExecutions(working: working, durable: durable, topK: 3)
        #expect(result.hits.count == 3)
        #expect(result.hits[0].previewText == "session")
        #expect(result.hits.contains { $0.previewText == "durable" })
        #expect(result.hits.contains { $0.previewText == "other" })
    }

    @Test
    func searchPackerKeepsDiagnosticKeysWithoutMemoryID() {
        let execution = MemoryOrchestrator.SearchExecution(
            hits: [
                MemoryOrchestrator.MemorySearchHit(
                    frameId: 42, score: 0.9, previewText: "hit", sources: [.text], metadata: ["k": "v"]
                )
            ],
            requestedMode: .hybrid(),
            effectiveMode: .hybrid(),
            queryEmbeddingState: .available
        )
        let payload = BrokerRecall.packSearchPayload(
            query: "q",
            topK: 10,
            filtersSummary: .object(["ok": .bool(true)]),
            timeRangePresent: false,
            execution: execution,
            preview: { $0 ?? "" }
        )
        guard case .object(let object) = payload else {
            Issue.record("expected object payload")
            return
        }
        #expect(object["query"] == .string("q"))
        #expect(object["topK"] == .from(10))
        #expect(object.keys.contains("requested_mode"))
        #expect(object.keys.contains("effective_mode"))
        #expect(object.keys.contains("query_embedding_state"))
        #expect(object.keys.contains("applied_filters"))
        #expect(object.keys.contains("time_range_requested"))
        #expect(object.keys.contains("time_range_applied"))
        #expect(object.keys.contains("results"))
        #expect(object.keys.contains("display_text"))
        guard case .array(let rows) = object["results"], case .object(let row) = rows.first else {
            Issue.record("expected result row")
            return
        }
        #expect(row["rank"] == .from(1))
        #expect(row["frameId"] == .from(42))
        #expect(row["memory_id"] == nil)
    }
}
