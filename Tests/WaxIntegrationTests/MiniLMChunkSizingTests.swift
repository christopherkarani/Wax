import Foundation
import Testing
@testable import Wax
import WaxCore
import WaxVectorSearch

#if MiniLMEmbeddings && canImport(WaxVectorSearchMiniLM) && canImport(CoreML)
import WaxVectorSearchMiniLM

/// Claims an identity without running a model: chunk sizing only reads the identity.
private struct IdentityEmbedder: EmbeddingProvider, Sendable {
    let dimensions = 4
    let normalize = true
    let identity: EmbeddingIdentity?

    init(model: String) {
        identity = EmbeddingIdentity(provider: "Wax", model: model, dimensions: 4, normalized: true)
    }

    func embed(_ text: String) async throws -> [Float] {
        [1, 0, 0, 0]
    }
}

private enum ChunkCorpus {
    static func repeated(_ unit: String, words: Int = 3_000) -> String {
        let unitWords = max(1, unit.split(whereSeparator: \.isWhitespace).count)
        return Array(repeating: unit, count: words / unitWords + 1).joined(separator: "\n")
    }

    /// Prose, Swift, JSON, file paths, and markup-dense text (the worst WordPiece/cl100k ratio).
    static let texts: [String] = [
        repeated("""
            Wax keeps every agent memory in one local file. Chat sessions end, but the decisions, \
            preferences and lessons an agent learned stay searchable on disk without an account.
            """),
        repeated("""
            func recall(_ query: String, limit: Int = 8) async throws -> [Hit] {
                let plan = try await planner.plan(query: query.trimmingCharacters(in: .whitespaces))
                return try await engine.search(plan, topK: max(1, limit)).map(Hit.init(result:))
            }
            """),
        repeated(#"{"identity": "MiniLMAll-mean", "dimensions": 384, "pins": [{"id": 17, "revision": "537133031bc2b2731048d00748c69700e1b48185"}]}"#),
        repeated("Sources/Wax/Orchestrator/MemoryOrchestrator+Remember.swift:135 Tests/WaxIntegrationTests/Fixtures/long_memory_fixture.json"),
        repeated(#"<a href="https://img.shields.io/badge/platform-macOS%20%7C%20iOS%20%7C%20Linux-lightgrey?style=flat-square"><img src="https://img.shields.io/npm/v/waxmcp?style=flat-square&logo=npm" alt="npm" /></a>"#),
    ]

    static func words(_ text: String) -> [Substring] {
        text.split(whereSeparator: \.isWhitespace)
    }
}

private func miniLMInputTokens(_ text: String, tokenizer: BertTokenizer) -> Int {
    tokenizer.tokenize(text: text).count + 2
}

@Test func miniLMDefaultChunksFitTheModelInputWindow() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let memory = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: IdentityEmbedder(model: "MiniLMAll-mean")
        )
        let tokenizer = try BertTokenizer()
        for text in ChunkCorpus.texts {
            let chunks = await memory.ingestChunks(for: text)
            #expect(chunks.count > 1)
            for chunk in chunks {
                let tokens = miniLMInputTokens(chunk, tokenizer: tokenizer)
                #expect(tokens <= MiniLMChunkSizing.inputTokenLimit, "chunk of \(tokens) tokens: \(chunk.prefix(80))")
            }
            // Fitting re-splits; it never drops text.
            let joined = chunks.joined()
            for word in Set(ChunkCorpus.words(text)) {
                #expect(joined.contains(word), "lost \(word)")
            }
        }
        try await memory.close()
    }
}

@Test func otherEmbeddersKeepTheGeneralChunkTarget() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let memory = try await MemoryOrchestrator(
            at: url,
            config: config,
            embedder: IdentityEmbedder(model: "ArcticEmbedS")
        )
        #expect(await memory.config.chunking == OrchestratorConfig.defaultChunking)
        #expect(!(await memory.config.fitsChunksToMiniLMInput))
        let text = ChunkCorpus.texts[0]
        let general = await TextChunker.chunk(text: text, strategy: OrchestratorConfig.defaultChunking)
        #expect(await memory.ingestChunks(for: text) == general)
        try await memory.close()
    }
}

@available(macOS 15.0, iOS 18.0, *)
@Test func miniLMChunkSizingMatchesTheModelSequenceLength() {
    #expect(MiniLMChunkSizing.inputTokenLimit == MiniLMEmbeddings.maxSequenceLength)
}

/// The fact sits ~280 cl100k tokens into the document: inside the first 400-token chunk but
/// past MiniLM's 256 WordPiece window, and before the second chunk's 360-token start.
@available(macOS 15.0, iOS 18.0, *)
@Test(.disabled(
    if: ProcessInfo.processInfo.environment["WAX_TEST_MINILM"] != "1",
    "Set WAX_TEST_MINILM=1 to run MiniLM inference quality tests"
))
func miniLMVectorSearchFindsAFactPastTheOldChunkWindow() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.enableTextSearch = false
        config.enableAccessStatsScoring = false
        let memory = try await MemoryOrchestrator.openMiniLM(at: url, config: config)
        let counter = try await TokenCounter.shared()
        let filler = "The committee reviewed the quarterly budget spreadsheet and approved the travel line items."
        var head: [String] = []
        while await counter.encode(head.joined(separator: " ")).count < 280 {
            head.append(filler)
        }
        let fact = "The lighthouse keeper's orange cat is named Biscuit and sleeps on the warm lamp housing."
        let document = (head + [fact] + Array(repeating: filler, count: 60)).joined(separator: " ")
        try await memory.remember(document)
        try await memory.flush()

        let hits = try await memory.searchExecution(
            query: "What is the lighthouse cat called?",
            mode: .vectorOnly,
            topK: 50
        ).hits
        var factScore: Float = -1
        var fillerScore: Float = -1
        for hit in hits {
            let content = String(decoding: try await memory.wax.frameContent(frameId: hit.frameId), as: UTF8.self)
            if content.contains("Biscuit") {
                factScore = max(factScore, hit.score)
            } else {
                fillerScore = max(fillerScore, hit.score)
            }
        }
        print("MiniLM chunk-tail retrieval: fact=\(factScore) filler=\(fillerScore) margin=\(factScore - fillerScore)")
        #expect(fillerScore > -1)
        #expect(factScore - fillerScore > 0.05, "fact \(factScore) vs filler \(fillerScore)")
        try await memory.close()
    }
}

@Test func explicitChunkTargetIsKeptButStillFittedForMiniLM() async throws {
    var config = OrchestratorConfig.default
    config.chunking = .tokenCount(targetTokens: 64, overlapTokens: 0)
    let sized = config.sizingChunks(forEmbedderModel: "MiniLMAll-mean")
    #expect(sized.chunking == .tokenCount(targetTokens: 64, overlapTokens: 0))
    #expect(sized.fitsChunksToMiniLMInput)
}

@Test func builtInMiniLMRequestSizesChunksBeforeTheProviderLoads() async throws {
    try await TempFiles.withTempFile { url in
        var config = OrchestratorConfig.default
        config.requireOnDeviceProviders = false
        let memory = try await EmbeddingReadinessBinding.openOrchestrator(
            at: url,
            config: config,
            request: .automatic(.miniLM, .default),
            readiness: EmbeddingReadiness()
        ) {
            try await Task.sleep(for: .seconds(3_600))
            return IdentityEmbedder(model: "MiniLMAll-mean")
        }
        #expect(await memory.runtimeStats().embeddingStatus == .loading)
        #expect(await memory.config.chunking == MiniLMChunkSizing.chunking)
        #expect(await memory.config.fitsChunksToMiniLMInput)
        try await memory.close()
    }
}
#endif
