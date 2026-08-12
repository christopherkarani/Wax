import Foundation
import Testing
import Wax

@Suite("PublicRAGAndEnrichmentTests")
struct PublicRAGAndEnrichmentTests {
    private static var textOnly: Memory.Config {
        Memory.Config(enableVectorSearch: false)
    }

    @Test
    func ragConfigDefaultsMatchPublishedValues() {
        let rag = Memory.RAGConfig.default
        #expect(rag.maxContextTokens == 1_500)
        #expect(rag.searchTopK == 24)
        #expect(rag.answerRerankWindow == 12)
        #expect(rag.answerDistractorPenalty == 0.30)
        #expect(Memory.Config().rag == Memory.RAGConfig.default)
        #expect(Memory.Config().enrichment == .disabled)
    }

    @Test
    func publicTypesExposeMemberwiseInitializers() {
        let rag = Memory.RAGConfig(
            maxContextTokens: 64,
            searchTopK: 4,
            answerRerankWindow: 3,
            answerDistractorPenalty: 0.15
        )
        #expect(rag.maxContextTokens == 64)
        #expect(rag.searchTopK == 4)
        #expect(rag.answerRerankWindow == 3)
        #expect(rag.answerDistractorPenalty == 0.15)

        let stats = Memory.EnrichmentStats(
            processedCount: 2,
            pendingCount: 1,
            isRunning: true
        )
        #expect(stats.processedCount == 2)
        #expect(stats.pendingCount == 1)
        #expect(stats.isRunning)

        let snapshot = Memory.Stats(
            frameCount: 0,
            pendingFrames: 0,
            vectorSearchEnabled: false,
            queryEmbedderConfigured: false,
            queryEmbeddingCircuitOpen: false,
            embedderIdentity: nil,
            enrichment: stats
        )
        #expect(snapshot.enrichment == stats)
        #expect(Memory.EnrichmentPolicy.disabled != .builtIn)
    }

    @Test
    func maxContextTokensBoundsAssembledSearchContext() async throws {
        try await TempFiles.withTempFile { url in
            var config = Self.textOnly
            config.rag.maxContextTokens = 32
            let memory = try await Memory(at: url, config: config)
            let long = String(repeating: "Swift concurrency uses actors and tasks. ", count: 80)
            try await memory.save(long)
            try await memory.save("Rust ownership and borrowing prevent data races.")
            try await memory.flush()

            let results = try await memory.search(
                "Swift",
                options: .init(topK: 50, mode: .textOnly)
            )
            #expect(results.totalTokens <= 32)
            #expect(!results.items.isEmpty)

            try await memory.close()
        }

        try await TempFiles.withTempFile { url in
            var config = Self.textOnly
            config.rag.maxContextTokens = 1_500
            let memory = try await Memory(at: url, config: config)
            let long = String(repeating: "Swift concurrency uses actors and tasks. ", count: 80)
            try await memory.save(long)
            try await memory.save("Rust ownership and borrowing prevent data races.")
            try await memory.flush()

            let results = try await memory.search(
                "Swift",
                options: .init(topK: 50, mode: .textOnly)
            )
            #expect(results.totalTokens > 32)
            #expect(results.totalTokens <= 1_500)

            try await memory.close()
        }
    }

    @Test
    func searchTopKControlsCandidateDepth() async throws {
        try await TempFiles.withTempFile { url in
            var shallow = Self.textOnly
            shallow.rag.searchTopK = 1
            let memory = try await Memory(at: url, config: shallow)
            try await seedDistinctSwiftFacts(into: memory)
            let shallowResults = try await memory.search(
                "Swift",
                options: .init(topK: 50, mode: .textOnly)
            )
            try await memory.close()

            var deep = Self.textOnly
            deep.rag.searchTopK = 8
            let deeper = try await Memory(at: url, config: deep)
            let deepResults = try await deeper.search(
                "Swift",
                options: .init(topK: 50, mode: .textOnly)
            )
            try await deeper.close()

            #expect(shallowResults.items.count == 1)
            #expect(deepResults.items.count > shallowResults.items.count)
        }
    }

    @Test
    func answerRerankWindowChangesResultOrder() async throws {
        let query = "Which city did Person01 move to?"
        let allergy = "Which city Person01 Person01 Person01 is allergic to peanuts and avoids foods with peanuts."
        let seattle = "Person01 moved to Seattle in 2021 and works on the platform team."

        let withoutRerank = try await searchOrder(
            query: query,
            facts: [allergy, seattle],
            rag: Memory.RAGConfig(answerRerankWindow: 0)
        )
        let withRerank = try await searchOrder(
            query: query,
            facts: [allergy, seattle],
            rag: Memory.RAGConfig(answerRerankWindow: 12)
        )

        #expect(withoutRerank != withRerank)
        #expect(withRerank.first?.contains("Seattle") == true)
    }

    @Test
    func answerDistractorPenaltyChangesResultOrder() async throws {
        let query = "Which city did Person01 move to?"
        let distractor = "Person01 city move weekly report checklist signoff distractor notes."
        let seattle = "Person01 moved to Seattle in 2021 and works on the platform team."

        let unpenalized = try await searchOrder(
            query: query,
            facts: [distractor, seattle],
            rag: Memory.RAGConfig(answerDistractorPenalty: 0)
        )
        let penalized = try await searchOrder(
            query: query,
            facts: [distractor, seattle],
            rag: Memory.RAGConfig(answerDistractorPenalty: 0.90)
        )

        #expect(unpenalized != penalized)
        #expect(penalized.first?.contains("Seattle") == true)
    }

    @Test
    func invalidRAGValuesClampAtMappingRatherThanThrowing() async throws {
        // Brief: "Clamp values exactly once while mapping into package FastRAGConfig."
        try await TempFiles.withTempFile { url in
            let config = Memory.Config(
                enableVectorSearch: false,
                rag: Memory.RAGConfig(
                    maxContextTokens: -10,
                    searchTopK: -3,
                    answerRerankWindow: -1,
                    answerDistractorPenalty: -4
                )
            )
            let memory = try await Memory(at: url, config: config)
            try await memory.save("Swift actors isolate state.")
            try await memory.flush()
            let results = try await memory.search(
                "Swift",
                options: .init(topK: 50, mode: .textOnly)
            )
            #expect(results.items.isEmpty)
            #expect(results.totalTokens == 0)
            try await memory.close()
        }
    }

    @Test
    func enrichmentDisabledReportsNilStats() async throws {
        try await TempFiles.withTempFile { url in
            let memory = try await Memory(at: url, config: Self.textOnly)
            try await memory.save("Swift concurrency uses actors and structured tasks.")
            try await memory.flush()
            let stats = await memory.stats()
            #expect(stats.enrichment == nil)
            try await memory.close()
        }
    }

    @Test
    func enrichmentBuiltInIsObservableAfterSaveAndFlush() async throws {
        try await TempFiles.withTempFile { url in
            var config = Self.textOnly
            config.enrichment = .builtIn
            let memory = try await Memory(at: url, config: config)

            let before = await memory.stats()
            #expect(before.enrichment != nil)
            #expect(before.enrichment?.processedCount == 0)
            #expect(before.enrichment?.pendingCount == 0)
            #expect(before.enrichment?.isRunning == true)

            try await memory.save("Swift concurrency uses actors and structured tasks assigned to Ada Lovelace.")
            try await memory.flush()

            let after = await memory.stats()
            let enrichment = try #require(after.enrichment)
            #expect(enrichment.processedCount > 0)
            #expect(enrichment.pendingCount == 0)
            #expect(enrichment.isRunning)
            #expect(enrichment.processedCount != before.enrichment?.processedCount)

            try await memory.close()
        }
    }
}

private func seedDistinctSwiftFacts(into memory: Memory) async throws {
    let facts = [
        "Swift actors isolate state across concurrent tasks.",
        "Swift protocols enable composition without inheritance.",
        "Swift value types copy independently of reference types.",
        "Swift generics preserve type information at compile time.",
        "Swift optionals model absence without sentinel values.",
        "Swift enums can carry associated values for each case.",
        "Swift structured concurrency coordinates child tasks.",
        "Swift property wrappers encapsulate reusable storage logic.",
    ]
    for fact in facts {
        try await memory.save(fact)
    }
    try await memory.flush()
}

private func searchOrder(
    query: String,
    facts: [String],
    rag: Memory.RAGConfig
) async throws -> [String] {
    try await TempFiles.withTempFile { url in
        var config = Memory.Config(enableVectorSearch: false)
        config.rag = rag
        config.rag.searchTopK = max(facts.count, 4)
        let memory = try await Memory(at: url, config: config)
        for fact in facts {
            try await memory.save(fact)
        }
        try await memory.flush()
        let results = try await memory.search(
            query,
            options: .init(topK: 50, mode: .textOnly)
        )
        try await memory.close()
        return results.items.map(\.text)
    }
}
