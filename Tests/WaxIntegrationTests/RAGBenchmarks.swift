#if canImport(XCTest)
import XCTest
import Foundation
@testable import Wax

final class RAGPerformanceBenchmarks: XCTestCase {
    private let scale = BenchmarkScale.current()
    private var runXCTestBenchmarks: Bool {
        ProcessInfo.processInfo.environment["WAX_RUN_XCTEST_BENCHMARKS"] == "1"
    }
    private var collectMetrics: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_METRICS"] == "1"
    }
    private var run10K: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_10K"] == "1"
    }
    private var runSampledLatency: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_SAMPLES"] == "1"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard runXCTestBenchmarks else {
            throw XCTSkip("Set WAX_RUN_XCTEST_BENCHMARKS=1 to run XCTest benchmark suite.")
        }
    }

    func testIngestTextOnlyPerformance() async throws {
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
            let url = Self.makeTempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let wax = try await Wax.create(at: url)
            let text = try await wax.enableTextSearch()

            for index in 0..<scale.documentCount {
                let content = factory.makeDocument(index: index)
                let data = Data(content.utf8)
                let frameId = try await wax.put(data, options: FrameMetaSubset(searchText: content))
                try await text.index(frameId: frameId, text: content)
            }

            try await text.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }

    func testIngestHybridPerformance() async throws {
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let embedder = DeterministicEmbedder(dimensions: scale.vectorDimensions)

        measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
            let url = Self.makeTempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let wax = try await Wax.create(at: url)
            let text = try await wax.enableTextSearch()
            let vector = try await wax.enableVectorSearch(dimensions: scale.vectorDimensions)

            for index in 0..<scale.documentCount {
                let content = factory.makeDocument(index: index)
                let data = Data(content.utf8)
                let embedding = try await embedder.embed(content)
                let frameId = try await vector.putWithEmbedding(
                    data,
                    embedding: embedding,
                    options: FrameMetaSubset(searchText: content),
                    identity: embedder.identity
                )
                try await text.index(frameId: frameId, text: content)
            }

            try await text.stageForCommit()
            try await vector.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }

    func testIngestHybridBatchedPerformance() async throws {
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let embedder = DeterministicEmbedder(dimensions: scale.vectorDimensions)
        let batchSize = 32

        measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
            let url = Self.makeTempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let wax = try await Wax.create(at: url)
            let text = try await wax.enableTextSearch()
            let vector = try await wax.enableVectorSearch(dimensions: scale.vectorDimensions)

            // Process in batches
            for batchStart in stride(from: 0, to: scale.documentCount, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, scale.documentCount)
                let batchIndices = batchStart..<batchEnd

                // Prepare batch data
                var contents: [Data] = []
                var embeddings: [[Float]] = []
                var options: [FrameMetaSubset] = []
                var texts: [String] = []

                for index in batchIndices {
                    let content = factory.makeDocument(index: index)
                    contents.append(Data(content.utf8))
                    embeddings.append(try await embedder.embed(content))
                    options.append(FrameMetaSubset(searchText: content))
                    texts.append(content)
                }

                // Batch put
                let frameIds = try await vector.putWithEmbeddingBatch(
                    contents: contents,
                    embeddings: embeddings,
                    options: options,
                    identity: embedder.identity
                )

                // Batch text index
                try await text.indexBatch(frameIds: frameIds, texts: texts)
            }

            try await text.stageForCommit()
            try await vector.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }

    func testIngestTextOnlyPerformance10KDocs() async throws {
        guard run10K else { throw XCTSkip("Set WAX_BENCHMARK_10K=1 to run 10k doc benchmark.") }
        var scale = BenchmarkScale.standard
        scale.documentCount = 10_000
        scale.sentencesPerDocument = max(scale.sentencesPerDocument, 8)
        scale.iterations = max(1, min(2, scale.iterations))
        scale.timeout = max(scale.timeout, 180)

        let documentCount = scale.documentCount
        let sentencesPerDocument = scale.sentencesPerDocument
        let iterations = scale.iterations
        let timeout = scale.timeout

        let factory = BenchmarkTextFactory(sentencesPerDocument: sentencesPerDocument)
        measureAsync(timeout: timeout, iterations: iterations) {
            let url = Self.makeTempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let wax = try await Wax.create(at: url)
            let text = try await wax.enableTextSearch()

            for index in 0..<documentCount {
                let content = factory.makeDocument(index: index)
                let data = Data(content.utf8)
                let frameId = try await wax.put(data, options: FrameMetaSubset(searchText: content))
                try await text.index(frameId: frameId, text: content)
            }

            try await text.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }

    func testIngestHybridPerformance10KDocs() async throws {
        guard run10K else { throw XCTSkip("Set WAX_BENCHMARK_10K=1 to run 10k doc benchmark.") }
        var scale = BenchmarkScale.standard
        scale.documentCount = 10_000
        scale.sentencesPerDocument = max(scale.sentencesPerDocument, 8)
        scale.vectorDimensions = max(scale.vectorDimensions, 128)
        scale.iterations = max(1, min(2, scale.iterations))
        scale.timeout = max(scale.timeout, 240)

        let documentCount = scale.documentCount
        let sentencesPerDocument = scale.sentencesPerDocument
        let vectorDimensions = scale.vectorDimensions
        let iterations = scale.iterations
        let timeout = scale.timeout

        let factory = BenchmarkTextFactory(sentencesPerDocument: sentencesPerDocument)
        let embedder = DeterministicEmbedder(dimensions: vectorDimensions)

        measureAsync(timeout: timeout, iterations: iterations) {
            let url = Self.makeTempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let wax = try await Wax.create(at: url)
            let text = try await wax.enableTextSearch()
            let vector = try await wax.enableVectorSearch(dimensions: vectorDimensions)

            for index in 0..<documentCount {
                let content = factory.makeDocument(index: index)
                let data = Data(content.utf8)
                let embedding = try await embedder.embed(content)
                let frameId = try await vector.putWithEmbedding(
                    data,
                    embedding: embedding,
                    options: FrameMetaSubset(searchText: content),
                    identity: embedder.identity
                )
                try await text.index(frameId: frameId, text: content)
            }

            try await text.stageForCommit()
            try await vector.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }

    func testIngestHybridBatchedPerformance10KDocs() async throws {
        guard run10K else { throw XCTSkip("Set WAX_BENCHMARK_10K=1 to run 10k doc benchmark.") }
        var scale = BenchmarkScale.standard
        scale.documentCount = 10_000
        scale.sentencesPerDocument = max(scale.sentencesPerDocument, 8)
        scale.vectorDimensions = max(scale.vectorDimensions, 128)
        scale.iterations = max(1, min(2, scale.iterations))
        scale.timeout = max(scale.timeout, 240)

        let documentCount = scale.documentCount
        let sentencesPerDocument = scale.sentencesPerDocument
        let vectorDimensions = scale.vectorDimensions
        let iterations = scale.iterations
        let timeout = scale.timeout

        let factory = BenchmarkTextFactory(sentencesPerDocument: sentencesPerDocument)
        let embedder = DeterministicEmbedder(dimensions: vectorDimensions)
        let batchSize = 64

        measureAsync(timeout: timeout, iterations: iterations) {
            let url = Self.makeTempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            let wax = try await Wax.create(at: url)
            let text = try await wax.enableTextSearch()
            let vector = try await wax.enableVectorSearch(dimensions: vectorDimensions)

            for batchStart in stride(from: 0, to: documentCount, by: batchSize) {
                let batchEnd = min(batchStart + batchSize, documentCount)
                let batchIndices = batchStart..<batchEnd

                var contents: [Data] = []
                var embeddings: [[Float]] = []
                var options: [FrameMetaSubset] = []
                var texts: [String] = []

                for index in batchIndices {
                    let content = factory.makeDocument(index: index)
                    contents.append(Data(content.utf8))
                    embeddings.append(try await embedder.embed(content))
                    options.append(FrameMetaSubset(searchText: content))
                    texts.append(content)
                }

                let frameIds = try await vector.putWithEmbeddingBatch(
                    contents: contents,
                    embeddings: embeddings,
                    options: options,
                    identity: embedder.identity
                )
                try await text.indexBatch(frameIds: frameIds, texts: texts)
            }

            try await text.stageForCommit()
            try await vector.stageForCommit()
            try await wax.commit()
            try await wax.close()
        }
    }

    func testTextSearchPerformance() async throws {
        let scale = self.scale
        try await withFixture(includeVectors: false) { fixture in
            let query = fixture.queryText
            _ = try await fixture.text.search(query: query, topK: scale.searchTopK)

            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await fixture.text.search(query: query, topK: scale.searchTopK)
            }
        }
    }

    func testVectorSearchPerformance() async throws {
        let scale = self.scale
        try await withFixture(includeVectors: true) { fixture in
            guard let vector = fixture.vector, let embedding = fixture.queryEmbedding else {
                XCTFail("Vector search fixture missing embeddings")
                return
            }
            _ = try await vector.search(vector: embedding, topK: scale.searchTopK)

            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await vector.search(vector: embedding, topK: scale.searchTopK)
            }
        }
    }

    func testUnifiedSearchHybridPerformance() async throws {
        let scale = self.scale
        try await withFixture(includeVectors: true) { fixture in
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Hybrid search fixture missing embeddings")
                return
            }
            let request = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK
            )
            _ = try await fixture.wax.search(request)

            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await fixture.wax.search(request)
            }
        }
    }

    func testUnifiedSearchHybridPerformanceWithMetrics() async throws {
        guard collectMetrics else { throw XCTSkip("Set WAX_BENCHMARK_METRICS=1 to collect CPU/memory metrics.") }
        let scale = self.scale
        try await withFixture(includeVectors: true) { fixture in
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Hybrid search fixture missing embeddings")
                return
            }
            let request = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK
            )
            _ = try await fixture.wax.search(request)

            let metrics: [XCTMetric] = [
                XCTClockMetric(),
                XCTCPUMetric(),
                XCTMemoryMetric()
            ]
            let iterations = max(1, min(3, scale.iterations))
            measureAsync(metrics: metrics, timeout: scale.timeout, iterations: iterations) {
                _ = try await fixture.wax.search(request)
            }
        }
    }

    func testFastRAGBuildPerformanceFastMode() async throws {
        let scale = self.scale
        try await withFixture(includeVectors: true) { fixture in
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Fast RAG fixture missing embeddings")
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

            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await builder.build(
                    query: fixture.queryText,
                    embedding: embedding,
                    wax: fixture.wax,
                    config: config
                )
            }
        }
    }

    func testFastRAGBuildPerformanceDenseCached() async throws {
        let scale = self.scale
        try await withFixture(includeVectors: true) { fixture in
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Dense cached fixture missing embeddings")
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

            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await builder.build(
                    query: fixture.queryText,
                    embedding: embedding,
                    wax: fixture.wax,
                    config: config
                )
            }
        }
    }

    func testMemoryOrchestratorIngestPerformance() async throws {
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let embedder = DeterministicEmbedder(dimensions: scale.vectorDimensions)

        measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
            let url = Self.makeTempURL()
            defer { try? FileManager.default.removeItem(at: url) }

            var config = OrchestratorConfig.default
            config.rag.searchTopK = scale.searchTopK
            config.rag.searchMode = .hybrid(alpha: 0.7)
            config.chunking = .tokenCount(targetTokens: 220, overlapTokens: 24)

            let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)

            for index in 0..<scale.documentCount {
                let content = factory.makeDocument(index: index)
                try await orchestrator.remember(content)
            }
            try await orchestrator.flush()
            try await orchestrator.close()
        }
    }

    func testMemoryOrchestratorRecallPerformance() async throws {
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let embedder = DeterministicEmbedder(dimensions: scale.vectorDimensions)

        try await TempFiles.withTempFile { url in
            var config = OrchestratorConfig.default
            config.rag.searchTopK = scale.searchTopK
            config.rag.searchMode = .hybrid(alpha: 0.7)
            config.chunking = .tokenCount(targetTokens: 220, overlapTokens: 24)

            print("🧪 Recall benchmark: creating orchestrator")
            let orchestrator = try await MemoryOrchestrator(at: url, config: config, embedder: embedder)

            print("🧪 Recall benchmark: ingesting \(scale.documentCount) docs")
            for index in 0..<scale.documentCount {
                let content = factory.makeDocument(index: index)
                try await orchestrator.remember(content)
            }
            print("🧪 Recall benchmark: flushing")
            try await orchestrator.flush()

            let query = factory.queryText
            print("🧪 Recall benchmark: warm recall")
            _ = try await orchestrator.recall(query: query)

            print("🧪 Recall benchmark: measured recall start")
            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await orchestrator.recall(query: query)
            }
            print("🧪 Recall benchmark: measured recall done")

            print("🧪 Recall benchmark: closing orchestrator")
            try await orchestrator.close()
        }
    }

    func testColdOpenHybridSearchPerformance() async throws {
        guard ProcessInfo.processInfo.environment["WAX_BENCHMARK_COLD_OPEN"] == "1" else {
            throw XCTSkip("Set WAX_BENCHMARK_COLD_OPEN=1 to run cold-open hybrid search benchmark.")
        }
        let scale = self.scale
        let iterations = max(1, min(3, scale.iterations))
        try await TempFiles.withTempFile { url in
            let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Cold open fixture missing embeddings")
                return
            }
            let request = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK
            )
            await fixture.close()

            _ = try await timedSamples(label: "cold_open_hybrid", iterations: iterations, warmup: 0) {
                let wax = try await Wax.open(at: url)
                _ = try await wax.search(request)
                try await wax.close()
            }
        }
    }

    func testTokenCountingPerformance() async throws {
        let scale = self.scale
        let counter = try await TokenCounter.shared()
        let longText = String(repeating: "Swift concurrency is fast. ", count: 2_000)

        _ = await counter.count(longText)

        measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
            _ = await counter.count(longText)
        }
    }

    func testTokenCountingColdStartPerformance() async throws {
        let scale = self.scale
        let iterations = max(1, min(3, scale.iterations))
        let longText = String(repeating: "Swift concurrency is fast. ", count: 2_000)

        _ = try await timedSamples(label: "tokenizer_cold_start", iterations: iterations, warmup: 0) {
            let counter = try await TokenCounter()
            _ = await counter.count(longText)
        }
    }

    func testUnifiedSearchHybridWarmLatencySamples() async throws {
        guard runSampledLatency else { throw XCTSkip("Set WAX_BENCHMARK_SAMPLES=1 to run sampled latency benchmarks.") }
        let scale = self.scale

        try await withFixture(includeVectors: true) { fixture in
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Hybrid search fixture missing embeddings")
                return
            }

            let requestWithPreviews = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK,
                previewMaxBytes: 512
            )
            let requestNoPreviews = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK,
                previewMaxBytes: 0
            )

            // Warm up caches / any lazy engine state.
            _ = try await fixture.wax.search(requestWithPreviews)
            _ = try await fixture.wax.search(requestNoPreviews)

            _ = try await timedSamples(label: "unified_search_hybrid_warm_previews", iterations: 30, warmup: 5) {
                _ = try await fixture.wax.search(requestWithPreviews)
            }
            _ = try await timedSamples(label: "unified_search_hybrid_warm_no_previews", iterations: 30, warmup: 5) {
                _ = try await fixture.wax.search(requestNoPreviews)
            }
        }
    }

    func testUnifiedSearchHybridWarmLatencySamplesCPUOnly() async throws {
        guard runSampledLatency else { throw XCTSkip("Set WAX_BENCHMARK_SAMPLES=1 to run sampled latency benchmarks.") }
        let scale = self.scale

        try await withFixture(includeVectors: true) { fixture in
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Hybrid search fixture missing embeddings")
                return
            }

            let requestNoPreviews = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK,
                previewMaxBytes: 0
            )

            // Warm up caches / any lazy engine state.
            _ = try await fixture.wax.search(requestNoPreviews)

            _ = try await timedSamples(label: "unified_search_hybrid_warm_cpu_only", iterations: 30, warmup: 5) {
                _ = try await fixture.wax.search(requestNoPreviews)
            }
        }
    }

    func testFramePreviewsWarmLatencySamples() async throws {
        guard runSampledLatency else { throw XCTSkip("Set WAX_BENCHMARK_SAMPLES=1 to run sampled latency benchmarks.") }
        let scale = self.scale

        try await withFixture(includeVectors: true) { fixture in
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Hybrid search fixture missing embeddings")
                return
            }

            let request = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK,
                previewMaxBytes: 0
            )

            let response = try await fixture.wax.search(request)
            let frameIds = response.results.map(\.frameId)

            // Warm the file cache and any payload decode paths.
            _ = try await fixture.wax.framePreviews(frameIds: frameIds, maxBytes: 512)

            _ = try await timedSamples(label: "frame_previews_topk_512b", iterations: 30, warmup: 5) {
                _ = try await fixture.wax.framePreviews(frameIds: frameIds, maxBytes: 512)
            }
        }
    }

    func testWaxOpenCloseColdLatencySamples() async throws {
        guard runSampledLatency else { throw XCTSkip("Set WAX_BENCHMARK_SAMPLES=1 to run sampled latency benchmarks.") }
        let scale = self.scale
        let iterations = max(3, min(15, scale.iterations * 3))

        try await TempFiles.withTempFile { url in
            _ = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)

            // Measure open/close only: footer scan + WAL scan + engine cache hydration.
            _ = try await timedSamples(label: "wax_open_close_cold", iterations: iterations, warmup: 0) {
                let wax = try await Wax.open(at: url)
                try await wax.close()
            }
        }
    }

    func testIncrementalStageAndCommitLatencySamples() async throws {
        guard runSampledLatency else { throw XCTSkip("Set WAX_BENCHMARK_SAMPLES=1 to run sampled latency benchmarks.") }
        let scale = self.scale
        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let embedder = DeterministicEmbedder(dimensions: scale.vectorDimensions)

        let clock = ContinuousClock()
        let batchSize = 64
        let iterations = max(3, min(15, scale.iterations * 3))

        func seconds(_ duration: Duration) -> Double {
            let comp = duration.components
            return Double(comp.seconds) + Double(comp.attoseconds) / 1_000_000_000_000_000_000
        }

        func measureSeconds(_ block: @escaping @Sendable () async throws -> Void) async throws -> Double {
            let start = clock.now
            try await block()
            let duration = clock.now - start
            return seconds(duration)
        }

        try await TempFiles.withTempFile { url in
            let wax = try await Wax.create(at: url)
            let sessionConfig = WaxSession.Config(
                enableTextSearch: true,
                enableVectorSearch: true,
                enableStructuredMemory: false,
                vectorEnginePreference: .cpuOnly,
                vectorMetric: .cosine,
                vectorDimensions: embedder.dimensions
            )
            let session = try await wax.openSession(.readWrite(.wait), config: sessionConfig)

            let texts = (0..<batchSize).map { factory.makeDocument(index: $0) }
            let contents = texts.map { Data($0.utf8) }
            var embeddings: [[Float]] = []
            embeddings.reserveCapacity(batchSize)
            for text in texts {
                embeddings.append(try await embedder.embed(text))
            }

            var options: [FrameMetaSubset] = []
            options.reserveCapacity(batchSize)
            for _ in 0..<batchSize {
                var meta = FrameMetaSubset()
                meta.role = .chunk
                options.append(meta)
            }

            // Warm: compile any lazy paths in staging and commit before sampling.
            do {
                let frameIds = try await session.putBatch(
                    contents: contents,
                    embeddings: embeddings,
                    identity: embedder.identity,
                    options: options
                )
                try await session.indexTextBatch(frameIds: frameIds, texts: texts)
                try await session.stage()
                try await wax.commit()
            }

            var stageSamples: [Double] = []
            stageSamples.reserveCapacity(iterations)
            var commitSamples: [Double] = []
            commitSamples.reserveCapacity(iterations)

            for sampleIndex in 0..<iterations {
                let offset = (sampleIndex + 1) * batchSize
                let batchTexts = (0..<batchSize).map { factory.makeDocument(index: offset + $0) }
                let batchContents = batchTexts.map { Data($0.utf8) }
                var batchEmbeddings: [[Float]] = []
                batchEmbeddings.reserveCapacity(batchSize)
                for text in batchTexts {
                    batchEmbeddings.append(try await embedder.embed(text))
                }

                let frameIds = try await session.putBatch(
                    contents: batchContents,
                    embeddings: batchEmbeddings,
                    identity: embedder.identity,
                    options: options
                )
                try await session.indexTextBatch(frameIds: frameIds, texts: batchTexts)

                let stageSeconds = try await measureSeconds {
                    try await session.stage()
                }
                stageSamples.append(stageSeconds)

                let commitSeconds = try await measureSeconds {
                    try await wax.commit()
                }
                commitSamples.append(commitSeconds)
            }

            BenchmarkStats(samples: stageSamples).report(label: "stage_for_commit_incremental_batch64")
            BenchmarkStats(samples: commitSamples).report(label: "wax_commit_incremental_batch64")

            await session.close()
            try await wax.close()
        }
    }

    func testUnifiedSearchHybridPerformance10KDocs() async throws {
        guard run10K else { throw XCTSkip("Set WAX_BENCHMARK_10K=1 to run 10k doc benchmark.") }
        var scale = BenchmarkScale.standard
        scale.documentCount = 10_000
        scale.sentencesPerDocument = max(scale.sentencesPerDocument, 8)
        scale.vectorDimensions = max(scale.vectorDimensions, 128)
        scale.searchTopK = max(scale.searchTopK, 24)
        scale.iterations = max(1, min(3, scale.iterations))
        scale.timeout = max(scale.timeout, 180)

        try await TempFiles.withTempFile { url in
            let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Hybrid search fixture missing embeddings")
                return
            }
            let request = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK
            )
            _ = try await fixture.wax.search(request)

            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await fixture.wax.search(request)
            }

            await fixture.close()
        }
    }

    func testUnifiedSearchHybridPerformance10KDocsCPU() async throws {
        guard run10K else { throw XCTSkip("Set WAX_BENCHMARK_10K=1 to run 10k doc benchmark.") }
        var scale = BenchmarkScale.standard
        scale.documentCount = 10_000
        scale.sentencesPerDocument = max(scale.sentencesPerDocument, 8)
        scale.vectorDimensions = max(scale.vectorDimensions, 128)
        scale.searchTopK = max(scale.searchTopK, 24)
        scale.iterations = max(1, min(3, scale.iterations))
        scale.timeout = max(scale.timeout, 180)

        try await TempFiles.withTempFile { url in
            let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: true)
            guard let embedding = fixture.queryEmbedding else {
                XCTFail("Hybrid search fixture missing embeddings")
                return
            }
            let request = SearchRequest(
                query: fixture.queryText,
                embedding: embedding,
                vectorEnginePreference: .cpuOnly,
                mode: .hybrid(alpha: 0.7),
                topK: scale.searchTopK
            )
            _ = try await fixture.wax.search(request)

            measureAsync(timeout: scale.timeout, iterations: scale.iterations) {
                _ = try await fixture.wax.search(request)
            }

            await fixture.close()
        }
    }

    private func withFixture(
        includeVectors: Bool,
        _ body: (BenchmarkFixture) async throws -> Void
    ) async throws {
        let scale = self.scale
        try await TempFiles.withTempFile { url in
            let fixture = try await BenchmarkFixture.build(at: url, scale: scale, includeVectors: includeVectors)
            try await body(fixture)
            await fixture.close()
        }
    }

    private static func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
    }
}
#endif
