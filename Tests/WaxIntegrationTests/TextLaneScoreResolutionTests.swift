import Foundation
import Testing
import Wax
import WaxTestSupport
@testable import WaxTextSearch

/// A conversation-sized corpus: many short turns that mention a speaker, so the
/// speaker's name has low IDF and the topic words have high IDF, as in real chat logs.
private func chatTurns(count: Int) -> [String] {
    let topics = [
        "the weather was lovely this morning", "the kids loved the new board game",
        "work has been hectic all week", "the garden is finally blooming",
        "the dog chewed my favourite shoes", "dinner with the neighbours was fun",
    ]
    return (0..<count).map { index in
        let topic = topics[index % topics.count]
        return index.isMultiple(of: 2)
            ? "Melanie: Hey! \(topic), how about you?"
            : "Caroline: Thanks Melanie, \(topic) too."
    }
}

@Test
func textLaneScoresKeepBM25SpacingOnConversationSizedCorpora() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    let filler = chatTurns(count: 40)
    try await engine.indexBatch(frameIds: (0..<UInt64(filler.count)).map { $0 }, texts: filler)
    try await engine.index(frameId: 100, text: "Melanie: I ran a charity race for mental health last Saturday.")

    let results = try await engine.search(matchQuery: "\"melanie\" OR \"charity\" OR \"race\"", topK: 10)

    #expect(results.first?.frameId == 100)
    let top = try #require(results.first)
    let second = try #require(results.dropFirst().first)
    // The topic match outscores a name-only match several times over in BM25.
    // Published scores must keep that gap, not saturate both to the same Float.
    #expect(Float(top.score) > Float(second.score))
    #expect(second.score < top.score * 0.5)
}

@Test
func textOnlySearchKeepsTopicMatchAboveNameOnlyTurns() async throws {
    try await TempFiles.withTempFile { url in
        let memory = try await Memory(
            at: url,
            config: .init(enableTextSearch: true, enableVectorSearch: false, requireOnDeviceProviders: false)
        )
        for (index, text) in chatTurns(count: 40).enumerated() {
            try await memory.save(text, metadata: ["id": "filler-\(index)"])
        }
        // The only turn about the charity race. It is long enough that its FTS
        // snippet (built around "charity race") leaves out the speaker's name, so
        // rerank signals that read the snippet see no name match here and a name
        // match in every short filler turn.
        try await memory.save(
            "Melanie: Hey Caroline, since we last chatted, I've had a lot of things happening to me. "
                + "I ran a charity race for mental health last weekend, it was so rewarding.",
            metadata: ["id": "evidence"]
        )
        try await memory.flush()

        let results = try await memory.search(
            "When did Melanie run a charity race?",
            options: .init(topK: 10, mode: .textOnly, inferTimeRange: false)
        )

        let ids = results.items.compactMap { $0.metadata["id"] }
        #expect(ids.first == "evidence", "ranked: \(ids.prefix(5))")
        try await memory.close()
    }
}
