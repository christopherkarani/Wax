import Testing
@testable import Wax
import WaxCore

struct SearchLaneTests {
    @Test(arguments: [[Float](), nil])
    func fromRejectsVectorOnlyWithoutNonEmptyEmbedding(embedding: [Float]?) {
        do {
            _ = try SearchLane.from(mode: .vectorOnly, embedding: embedding)
            Issue.record("expected WaxError for vectorOnly without a non-empty embedding")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("requires a non-empty query embedding"))
        } catch {
            Issue.record("wrong error thrown: \(error)")
        }
    }

    @Test
    func searchRequestFactoryRejectsEmptyVectorOnlyEmbedding() {
        do {
            _ = try SearchRequest(query: "q", lane: .vectorOnly(embedding: []))
            Issue.record("expected WaxError for empty vectorOnly embedding")
        } catch let error as WaxError {
            guard case .io(let message) = error else {
                Issue.record("expected WaxError.io, got \(error)")
                return
            }
            #expect(message.contains("requires a non-empty query embedding"))
        } catch {
            Issue.record("wrong error thrown: \(error)")
        }
    }

    @Test
    func hybridNilEmbeddingIsLegalAndOmitsVectorLane() throws {
        let lane = try SearchLane.from(mode: .hybrid(alpha: 0.5), embedding: nil)
        #expect(lane == .hybrid(alpha: 0.5, embedding: nil))

        let request = try SearchRequest(query: "hello world", lane: lane, nowMs: 0)
        #expect(request.mode == .hybrid(alpha: 0.5))
        #expect(request.embedding == nil)
        #expect(request.lane == lane)

        let plan = SearchPlan.make(request)
        #expect(plan.includeText)
        #expect(plan.includeVector == false)
    }

    @Test
    func hybridEmptyEmbeddingTreatsVectorAsAbsent() throws {
        let lane = try SearchLane.from(mode: .hybrid(alpha: 0.25), embedding: [])
        #expect(lane == .hybrid(alpha: 0.25, embedding: nil))

        let plan = SearchPlan.make(try SearchRequest(query: "hello world", lane: lane, nowMs: 0))
        #expect(plan.includeText)
        #expect(plan.includeVector == false)
    }

    @Test
    func hybridWithEmbeddingIncludesVectorLane() throws {
        let embedding: [Float] = [1, 0, 0, 0]
        let lane = try SearchLane.from(mode: .hybrid(alpha: 0.5), embedding: embedding)
        #expect(lane == .hybrid(alpha: 0.5, embedding: embedding))

        let plan = SearchPlan.make(
            try SearchRequest(query: "hello world", lane: lane, nowMs: 0)
        )
        #expect(plan.includeText)
        #expect(plan.includeVector)
    }

    @Test
    func vectorOnlyWithEmbeddingIncludesVectorLaneOnly() throws {
        let embedding: [Float] = [0.2, 0.8]
        let request = try SearchRequest(
            query: "7f3a91",
            lane: .vectorOnly(embedding: embedding),
            nowMs: 0
        )
        #expect(request.mode == .vectorOnly)
        #expect(request.embedding == embedding)

        let plan = SearchPlan.make(request)
        #expect(plan.includeText == false)
        #expect(plan.includeVector)
        #expect(plan.exactIntentWindow == nil)
    }

    @Test
    func textOnlyOmitsVectorLane() throws {
        let request = try SearchRequest(query: "hello", lane: .textOnly, nowMs: 0)
        #expect(request.mode == .textOnly)
        #expect(request.embedding == nil)

        let plan = SearchPlan.make(request)
        #expect(plan.includeText)
        #expect(plan.includeVector == false)
    }
}
