import Foundation
import Testing
import Wax
import WaxCore

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
    let text = try await wax.openSession(.readWrite(), config: WaxSession.Config(enableVectorSearch: false))
    let docs = [
        "Swift actors isolate mutable state for data-race safety.",
        "Task groups enable structured concurrent workloads.",
        "Vector search and BM25 hybrid retrieval can improve recall.",
        "Deterministic ranking prevents flaky context assembly.",
        "Temporal metadata helps answer timeline questions."
    ]

    for doc in docs {
        let frameId = try await wax.put(Data(doc.utf8), options: FrameMetaSubset(searchText: doc))
        try await text.indexText(frameId: frameId, text: doc)
    }
    try await text.commit()
    return wax
}
