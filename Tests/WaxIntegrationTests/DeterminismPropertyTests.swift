import Foundation
import Testing
import Wax

@Test
func rrfFusionIsIdempotentForSameInputs() {
    let lists: [(weight: Float, frameIds: [UInt64])] = [
        (weight: 1.0, frameIds: [1, 2, 3, 4, 5]),
        (weight: 0.5, frameIds: [3, 4, 5, 6, 7]),
        (weight: 0.2, frameIds: [5, 2, 8]),
    ]

    let resultA = HybridSearch.rrfFusion(lists: lists, k: 60)
    let resultB = HybridSearch.rrfFusion(lists: lists, k: 60)

    let idsA = resultA.map { $0.0 }
    let idsB = resultB.map { $0.0 }
    #expect(idsA == idsB)

    let scoresA = resultA.map { $0.1 }
    let scoresB = resultB.map { $0.1 }
    #expect(scoresA.count == scoresB.count)
    for (lhs, rhs) in zip(scoresA, scoresB) {
        #expect(abs(lhs - rhs) < 1e-9)
    }
}

@Test
func rrfFusionIsOrderIndependentForListPermutation() {
    let listA: (weight: Float, frameIds: [UInt64]) = (weight: 1.0, frameIds: [1, 2, 3, 4])
    let listB: (weight: Float, frameIds: [UInt64]) = (weight: 0.5, frameIds: [3, 4, 5])
    let listC: (weight: Float, frameIds: [UInt64]) = (weight: 0.25, frameIds: [2, 6])

    let abc = HybridSearch.rrfFusion(lists: [listA, listB, listC], k: 60)
    let cba = HybridSearch.rrfFusion(lists: [listC, listB, listA], k: 60)

    #expect(Set(abc.map(\.0)) == Set(cba.map(\.0)))
}

@Test
func tokenCountIsSubadditiveWithinSmallConstant() async throws {
    let counter = try await TokenCounter.shared()
    let first = "Hello world from Swift."
    let second = "Concurrency with actors and tasks."
    let joined = first + " " + second

    let firstCount = await counter.count(first)
    let secondCount = await counter.count(second)
    let joinedCount = await counter.count(joined)

    let mergeConstant = 4
    #expect(joinedCount <= firstCount + secondCount + mergeConstant)
}

@Test
func fastRAGDeterministicAcrossRepeatedBuildsWithMixedCorpus() async throws {
    try await TempFiles.withTempFile { url in
        let wax = try await makeDeterminismWax(at: url)
        let builder = FastRAGContextBuilder()
        let config = FastRAGConfig(
            maxContextTokens: 140,
            expansionMaxTokens: 56,
            snippetMaxTokens: 24,
            maxSnippets: 10,
            searchTopK: 24,
            searchMode: .textOnly
        )

        let contextA = try await builder.build(query: "Swift concurrency", wax: wax, config: config)
        let contextB = try await builder.build(query: "Swift concurrency", wax: wax, config: config)

        #expect(contextA == contextB)
        #expect(contextA.totalTokens == contextB.totalTokens)

        try await wax.close()
    }
}

private func makeDeterminismWax(at url: URL) async throws -> Wax {
    let wax = try await Wax.create(at: url)
    let text = try await wax.enableTextSearch()
    let docs = [
        "Swift actors isolate mutable state for data-race safety.",
        "Task groups enable structured concurrent workloads.",
        "Vector search and BM25 hybrid retrieval can improve recall.",
        "Deterministic ranking prevents flaky context assembly.",
        "Temporal metadata helps answer timeline questions."
    ]

    for doc in docs {
        let frameId = try await wax.put(Data(doc.utf8), options: FrameMetaSubset(searchText: doc))
        try await text.index(frameId: frameId, text: doc)
    }
    try await text.commit()
    return wax
}
