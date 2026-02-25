#if canImport(XCTest)
import Foundation
import XCTest
@testable import Wax

struct BenchmarkScale {
    var name: String
    var documentCount: Int
    var sentencesPerDocument: Int
    var vectorDimensions: Int
    var searchTopK: Int
    var iterations: Int
    var timeout: TimeInterval

    static var smoke: BenchmarkScale {
        BenchmarkScale(
            name: "smoke",
            documentCount: 200,
            sentencesPerDocument: 6,
            vectorDimensions: 64,
            searchTopK: 12,
            iterations: 3,
            timeout: 20
        )
    }

    static var standard: BenchmarkScale {
        BenchmarkScale(
            name: "standard",
            documentCount: 1_000,
            sentencesPerDocument: 10,
            vectorDimensions: 128,
            searchTopK: 24,
            iterations: 5,
            timeout: 40
        )
    }

    static var stress: BenchmarkScale {
        BenchmarkScale(
            name: "stress",
            documentCount: 5_000,
            sentencesPerDocument: 14,
            vectorDimensions: 256,
            searchTopK: 32,
            iterations: 3,
            timeout: 90
        )
    }

    static func current() -> BenchmarkScale {
        let env = ProcessInfo.processInfo.environment
        let raw = env["WAX_BENCHMARK_SCALE"]?.lowercased()
        var scale: BenchmarkScale
        switch raw {
        case "smoke", "quick":
            scale = .smoke
        case "stress", "large":
            scale = .stress
        default:
            scale = .standard
        }

        if let docs = env["WAX_BENCHMARK_DOCS"].flatMap(Int.init), docs > 0 {
            scale.documentCount = docs
        }
        if let sentences = env["WAX_BENCHMARK_SENTENCES"].flatMap(Int.init), sentences > 0 {
            scale.sentencesPerDocument = sentences
        }
        if let dims = env["WAX_BENCHMARK_DIMS"].flatMap(Int.init), dims > 0 {
            scale.vectorDimensions = dims
        }
        if let topK = env["WAX_BENCHMARK_TOPK"].flatMap(Int.init), topK > 0 {
            scale.searchTopK = topK
        }
        if let iterations = env["WAX_BENCHMARK_ITERS"].flatMap(Int.init), iterations > 0 {
            scale.iterations = iterations
        }

        return scale
    }
}

struct BenchmarkTextFactory {
    let sentencesPerDocument: Int
    let baseSentences: [String] = [
        "Swift concurrency uses actors and tasks for safe parallelism.",
        "Vector search compares embeddings to find semantic neighbors.",
        "Hybrid search fuses lexical and vector signals for recall.",
        "Wax stores memory in a single Wax file with WAL safety.",
        "RAG pipelines rank, expand, and truncate context deterministically.",
        "Token budgets keep prompts stable across runs."
    ]

    var queryText: String {
        "Swift concurrency vector search"
    }

    func makeDocument(index: Int) -> String {
        var parts: [String] = []
        parts.reserveCapacity(sentencesPerDocument + 2)
        parts.append("Document \(index) about Wax RAG performance.")
        for offset in 0..<sentencesPerDocument {
            let sentence = baseSentences[(index + offset) % baseSentences.count]
            parts.append(sentence)
        }
        if index % 7 == 0 {
            parts.append("Swift performance and retrieval for doc \(index).")
        }
        return parts.joined(separator: " ")
    }
}

actor DeterministicEmbedder: EmbeddingProvider {
    let dimensions: Int
    let normalize: Bool
    let identity: EmbeddingIdentity?

    init(dimensions: Int, normalize: Bool = true) {
        self.dimensions = dimensions
        self.normalize = normalize
        self.identity = EmbeddingIdentity(
            provider: "bench",
            model: "fnv1a-lcg",
            dimensions: dimensions,
            normalized: normalize
        )
    }

    func embed(_ text: String) async throws -> [Float] {
        let seed = Self.fnv1a64(bytes: Array(text.utf8))
        var state = seed
        var vector = [Float](repeating: 0, count: dimensions)
        for index in vector.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let signed = Int64(bitPattern: state)
            vector[index] = Float(signed) / Float(Int64.max)
        }
        if normalize {
            return Self.normalized(vector)
        }
        return vector
    }

    private static func fnv1a64(bytes: [UInt8]) -> UInt64 {
        var hash: UInt64 = 14695981039346656037
        for byte in bytes {
            hash ^= UInt64(byte)
            hash &*= 1099511628211
        }
        return hash
    }

    private static func normalized(_ vector: [Float]) -> [Float] {
        VectorMath.normalizeL2(vector)
    }
}

struct BenchmarkFixture {
    let url: URL
    let wax: Wax
    let text: WaxTextSearchSession
    let vector: WaxVectorSearchSession?
    let embedder: DeterministicEmbedder?
    let queryText: String
    let queryEmbedding: [Float]?
    let scale: BenchmarkScale

    static func build(
        at url: URL,
        scale: BenchmarkScale,
        includeVectors: Bool
    ) async throws -> BenchmarkFixture {
        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()
        var vector: WaxVectorSearchSession?
        var embedder: DeterministicEmbedder?
        if includeVectors {
            let localEmbedder = DeterministicEmbedder(dimensions: scale.vectorDimensions)
            embedder = localEmbedder
            vector = try await wax.enableVectorSearch(dimensions: localEmbedder.dimensions)
        }

        let factory = BenchmarkTextFactory(sentencesPerDocument: scale.sentencesPerDocument)
        let queryText = factory.queryText

        for index in 0..<scale.documentCount {
            let content = factory.makeDocument(index: index)
            let data = Data(content.utf8)
            let options = FrameMetaSubset(searchText: content)

            if let vector, let embedder {
                let embedding = try await embedder.embed(content)
                let finalEmbedding = embedder.normalize ? VectorMath.normalizeL2(embedding) : embedding
                let frameId = try await vector.putWithEmbedding(
                    data,
                    embedding: finalEmbedding,
                    options: options,
                    identity: embedder.identity
                )
                try await text.index(frameId: frameId, text: content)
            } else {
                let frameId = try await wax.put(data, options: options)
                try await text.index(frameId: frameId, text: content)
            }
        }

        try await text.stageForCommit()
        if let vector {
            try await vector.stageForCommit()
        }
        try await wax.commit()

        let queryEmbedding: [Float]?
        if let embedder {
            let embedding = try await embedder.embed(queryText)
            queryEmbedding = embedder.normalize ? VectorMath.normalizeL2(embedding) : embedding
        } else {
            queryEmbedding = nil
        }

        return BenchmarkFixture(
            url: url,
            wax: wax,
            text: text,
            vector: vector,
            embedder: embedder,
            queryText: queryText,
            queryEmbedding: queryEmbedding,
            scale: scale
        )
    }

    func close() async {
        try? await wax.close()
    }
}

extension XCTestCase {
    func measureAsync(
        timeout: TimeInterval,
        iterations: Int,
        _ block: @escaping @Sendable () async throws -> Void
    ) {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations

        measure(options: options) {
            let exp = expectation(description: "benchmark")
            Task {
                do {
                    try await block()
                } catch {
                    XCTFail("Benchmark failed: \(error)")
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: timeout)
        }
    }

    func measureAsync(
        metrics: [XCTMetric],
        timeout: TimeInterval,
        iterations: Int,
        _ block: @escaping @Sendable () async throws -> Void
    ) {
        let options = XCTMeasureOptions()
        options.iterationCount = iterations

        measure(metrics: metrics, options: options) {
            let exp = expectation(description: "benchmark")
            Task {
                do {
                    try await block()
                } catch {
                    XCTFail("Benchmark failed: \(error)")
                }
                exp.fulfill()
            }
            wait(for: [exp], timeout: timeout)
        }
    }

    func timedSamples(
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
            samples.append(duration.seconds)
        }

        let stats = BenchmarkStats(samples: samples)
        stats.report(label: label)
        return stats
    }
}

struct BenchmarkStats {
    let samples: [Double]
    let mean: Double
    let min: Double
    let max: Double
    let p50: Double
    let p95: Double
    let p99: Double
    let stdev: Double

    init(samples: [Double]) {
        self.samples = samples
        let sorted = samples.sorted()
        let count = Double(Swift.max(1, sorted.count))
        let sum = samples.reduce(0, +)
        let localMean = sum / count
        self.mean = localMean
        self.min = sorted.first ?? 0
        self.max = sorted.last ?? 0
        self.p50 = Self.percentile(sorted: sorted, p: 0.50)
        self.p95 = Self.percentile(sorted: sorted, p: 0.95)
        self.p99 = Self.percentile(sorted: sorted, p: 0.99)

        let variance = samples.reduce(0) { partial, value in
            let delta = value - localMean
            return partial + delta * delta
        } / count
        self.stdev = sqrt(variance)
    }

    func report(label: String) {
        print("🧪 \(label): mean \(mean.formatSeconds) s, p50 \(p50.formatSeconds) s, p95 \(p95.formatSeconds) s, p99 \(p99.formatSeconds) s, min \(min.formatSeconds) s, max \(max.formatSeconds) s, stdev \(stdev.formatSeconds) s")
    }

    private static func percentile(sorted: [Double], p: Double) -> Double {
        guard !sorted.isEmpty else { return 0 }
        if sorted.count == 1 { return sorted[0] }
        let clamped = Swift.min(1, Swift.max(0, p))
        let rank = clamped * Double(sorted.count - 1)
        let lower = Int(rank.rounded(FloatingPointRoundingRule.down))
        let upper = Int(rank.rounded(FloatingPointRoundingRule.up))
        if lower == upper { return sorted[lower] }
        let weight = rank - Double(lower)
        return sorted[lower] + (sorted[upper] - sorted[lower]) * weight
    }
}

private extension Duration {
    var seconds: Double {
        let comp = components
        return Double(comp.seconds) + Double(comp.attoseconds) / 1_000_000_000_000_000_000
    }
}

private extension Double {
    var formatSeconds: String {
        String(format: "%.4f", self)
    }
}
#endif
