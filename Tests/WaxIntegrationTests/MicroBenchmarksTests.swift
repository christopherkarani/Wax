import Testing
@testable import Wax

private func timedSamples(
    label: String,
    iterations: Int,
    warmup: Int = 1,
    _ block: @escaping @Sendable () async throws -> Void
) async throws -> BenchmarkStats {
    let clock = ContinuousClock()
    for _ in 0..<max(0, warmup) {
        try await block()
    }

    var samples: [Double] = []
    samples.reserveCapacity(iterations)
    for _ in 0..<max(1, iterations) {
        let start = clock.now
        try await block()
        let duration = clock.now - start
        let seconds = Double(duration.components.seconds) +
            Double(duration.components.attoseconds) / 1_000_000_000_000_000_000
        samples.append(seconds)
    }

    let stats = BenchmarkStats(samples: samples)
    stats.report(label: label)
    return stats
}

private func microEnabled() -> Bool {
    ProcessInfo.processInfo.environment["WAX_BENCHMARK_MICRO"] == "1"
}

@Test func microTextSearchLatency() async throws {
    guard microEnabled() else { return }
    let scale = BenchmarkScale.smoke
    try await TempFiles.withTempFile { url in
        let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: false)
        let query = fixture.queryText
        _ = try await fixture.text.search(query: query, topK: scale.searchTopK)

        _ = try await timedSamples(label: "micro_text_search", iterations: 25, warmup: 2) {
            _ = try await fixture.text.search(query: query, topK: scale.searchTopK)
        }

        await fixture.close()
    }
}

@Test func microVectorSearchLatency() async throws {
    guard microEnabled() else { return }
    let scale = BenchmarkScale.smoke
    try await TempFiles.withTempFile { url in
        let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)
        guard let embedding = fixture.queryEmbedding else {
            #expect(Bool(false))
            return
        }

        let cpuSession = try await fixture.wax.enableVectorSearchFromManifest(preference: .cpuOnly)
        _ = try await cpuSession.search(vector: embedding, topK: scale.searchTopK)
        _ = try await timedSamples(label: "micro_vector_search_cpu", iterations: 25, warmup: 2) {
            _ = try await cpuSession.search(vector: embedding, topK: scale.searchTopK)
        }

        if MetalVectorEngine.isAvailable {
            let metalSession = try await fixture.wax.enableVectorSearchFromManifest(preference: .metalPreferred)
            _ = try await metalSession.search(vector: embedding, topK: scale.searchTopK)
            _ = try await timedSamples(label: "micro_vector_search_metal", iterations: 25, warmup: 2) {
                _ = try await metalSession.search(vector: embedding, topK: scale.searchTopK)
            }
        }

        await fixture.close()
    }
}

@Test func microUnifiedSearchHybridLatency() async throws {
    guard microEnabled() else { return }
    let scale = BenchmarkScale.smoke
    try await TempFiles.withTempFile { url in
        let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)
        guard let embedding = fixture.queryEmbedding else {
            #expect(Bool(false))
            return
        }

        let request = SearchRequest(
            query: fixture.queryText,
            embedding: embedding,
            mode: .hybrid(alpha: 0.7),
            topK: scale.searchTopK
        )
        _ = try await fixture.wax.search(request)

        _ = try await timedSamples(label: "micro_unified_hybrid", iterations: 25, warmup: 2) {
            _ = try await fixture.wax.search(request)
        }

        await fixture.close()
    }
}

@Test func microFastRAGBuildFastMode() async throws {
    guard microEnabled() else { return }
    let scale = BenchmarkScale.smoke
    try await TempFiles.withTempFile { url in
        let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)
        guard let embedding = fixture.queryEmbedding else {
            #expect(Bool(false))
            return
        }
        let builder = FastRAGContextBuilder()
        let config = FastRAGConfig(
            mode: .fast,
            maxContextTokens: 1_200,
            expansionMaxTokens: 500,
            snippetMaxTokens: 160,
            maxSnippets: 20,
            searchTopK: scale.searchTopK,
            searchMode: .hybrid(alpha: 0.7)
        )

        _ = try await builder.build(
            query: fixture.queryText,
            embedding: embedding,
            wax: fixture.wax,
            config: config
        )

        _ = try await timedSamples(label: "micro_rag_fast", iterations: 20, warmup: 1) {
            _ = try await builder.build(
                query: fixture.queryText,
                embedding: embedding,
                wax: fixture.wax,
                config: config
            )
        }

        await fixture.close()
    }
}

@Test func microFastRAGBuildDenseCached() async throws {
    guard microEnabled() else { return }
    let scale = BenchmarkScale.smoke
    try await TempFiles.withTempFile { url in
        let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)
        guard let embedding = fixture.queryEmbedding else {
            #expect(Bool(false))
            return
        }
        let builder = FastRAGContextBuilder()
        let config = FastRAGConfig(
            mode: .denseCached,
            maxContextTokens: 1_200,
            expansionMaxTokens: 500,
            snippetMaxTokens: 160,
            maxSnippets: 16,
            maxSurrogates: 8,
            surrogateMaxTokens: 80,
            searchTopK: scale.searchTopK,
            searchMode: .hybrid(alpha: 0.7)
        )

        _ = try await builder.build(
            query: fixture.queryText,
            embedding: embedding,
            wax: fixture.wax,
            config: config
        )

        _ = try await timedSamples(label: "micro_rag_dense_cached", iterations: 20, warmup: 1) {
            _ = try await builder.build(
                query: fixture.queryText,
                embedding: embedding,
                wax: fixture.wax,
                config: config
            )
        }

        await fixture.close()
    }
}
