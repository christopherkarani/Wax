import Foundation
import Testing
import Wax

@Suite struct BrokerClientResultsDecodeTests {
    private func recallRowPayload(
        rank: AgentBrokerValue = .from(1),
        kind: AgentBrokerValue? = .string("snippet"),
        frameId: AgentBrokerValue = .from(UInt64(42)),
        score: AgentBrokerValue = .double(0.5),
        text: AgentBrokerValue = .string("hello world")
    ) -> [String: AgentBrokerValue] {
        var payload: [String: AgentBrokerValue] = [
            "rank": rank,
            "frameId": frameId,
            "score": score,
            "text": text,
        ]
        if let kind {
            payload["kind"] = kind
        }
        return payload
    }

    @Test func recallRowDecodesAllFields() throws {
        let row = try BrokerRecallRow(recallRowPayload())
        #expect(row.rank == 1)
        #expect(row.kind == "snippet")
        #expect(row.frameId == 42)
        #expect(row.score == 0.5)
        #expect(row.text == "hello world")
    }

    @Test func recallRowMissingKeyThrowsNamedError() throws {
        var payload = recallRowPayload()
        payload["text"] = nil

        #expect(throws: BrokerPayloadDecodeError(reason: .missingKey("text"))) {
            try BrokerRecallRow(payload)
        }
    }

    @Test func recallRowMissingKindDecodesAsNilKind() throws {
        let row = try BrokerRecallRow(recallRowPayload(kind: nil))
        #expect(row.kind == nil)
    }

    @Test func recallRowWrongTypedScoreThrowsNamedError() throws {
        let payload = recallRowPayload(score: .string("fast"))

        #expect(throws: BrokerPayloadDecodeError(reason: .invalidValue(key: "score", expected: "a number"))) {
            try BrokerRecallRow(payload)
        }
    }

    @Test func recallResultDecodesEnvelopeAndRows() throws {
        let payload: [String: AgentBrokerValue] = [
            "query": .string("rollback steps"),
            "total_tokens": .from(6),
            "results": .array([
                .object(recallRowPayload()),
                .object(recallRowPayload(rank: .from(2), frameId: .from(UInt64(7)), text: .string("second"))),
            ]),
        ]

        let result = try BrokerRecallResult(payload)
        #expect(result.query == "rollback steps")
        #expect(result.totalTokens == 6)
        #expect(result.items.count == 2)
        #expect(result.items[1].rank == 2)
        #expect(result.items[1].text == "second")
    }

    @Test func searchRowDecodesSourcesAndPreview() throws {
        let payload: [String: AgentBrokerValue] = [
            "rank": .from(3),
            "frameId": .from(UInt64(9)),
            "score": .double(1.25),
            "sources": .array([.string("text"), .string("vector")]),
            "preview": .string("preview text"),
        ]

        let row = try BrokerSearchRow(payload)
        #expect(row.rank == 3)
        #expect(row.frameId == 9)
        #expect(row.score == 1.25)
        #expect(row.sources == ["text", "vector"])
        #expect(row.preview == "preview text")
    }

    @Test func searchRowMissingSourcesThrowsNamedError() throws {
        let payload: [String: AgentBrokerValue] = [
            "rank": .from(1),
            "frameId": .from(UInt64(9)),
            "score": .double(1.0),
            "preview": .string("preview"),
        ]

        #expect(throws: BrokerPayloadDecodeError(reason: .missingKey("sources"))) {
            try BrokerSearchRow(payload)
        }
    }

    @Test func searchResultDecodesResultsArray() throws {
        let payload: [String: AgentBrokerValue] = [
            "results": .array([
                .object([
                    "rank": .from(1),
                    "frameId": .from(UInt64(4)),
                    "score": .double(0.75),
                    "sources": .array([.string("timeline")]),
                    "preview": .string("p"),
                ]),
            ]),
        ]

        let result = try BrokerSearchResult(payload)
        #expect(result.items.map(\.preview) == ["p"])
    }

    @Test func rememberResultDecodesCounts() throws {
        let payload: [String: AgentBrokerValue] = [
            "status": .string("ok"),
            "framesAdded": .from(2),
            "frameCount": .from(11),
            "pendingFrames": .from(0),
        ]

        let result = try BrokerRememberResult(payload)
        #expect(result.framesAdded == 2)
        #expect(result.frameCount == 11)
        #expect(result.pendingFrames == 0)
    }

    @Test func statsSummaryDecodesFieldsAndToleratesAbsentOptionals() throws {
        let payload: [String: AgentBrokerValue] = [
            "storePath": .string("/tmp/memory.wax"),
            "frameCount": .from(3),
            "pendingFrames": .from(1),
            "generation": .from(5),
            "diskBytes": .from(Int64(268_852_990)),
            "vectorSearchEnabled": .bool(false),
        ]

        let summary = try BrokerStatsSummary(payload)
        #expect(summary.storePath == "/tmp/memory.wax")
        #expect(summary.frameCount == 3)
        #expect(summary.pendingFrames == 1)
        #expect(summary.generation == 5)
        #expect(summary.diskBytes == 268_852_990)
        #expect(summary.vectorSearchEnabled == false)
        #expect(summary.embeddingStatus == nil)
    }

    @Test func statsSummaryMissingFrameCountThrowsNamedError() throws {
        let payload: [String: AgentBrokerValue] = [
            "storePath": .string("/tmp/memory.wax"),
            "pendingFrames": .from(1),
            "generation": .from(5),
            "diskBytes": .from(Int64(10)),
            "vectorSearchEnabled": .bool(false),
        ]

        #expect(throws: BrokerPayloadDecodeError(reason: .missingKey("frameCount"))) {
            try BrokerStatsSummary(payload)
        }
    }
}
