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
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task {
                do {
                    try await block()
                } catch {
                    XCTFail("Benchmark failed: \(error)")
                }
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + timeout)
            if result == .timedOut {
                task.cancel()
                XCTFail("Benchmark timed out after \(timeout)s")
            }
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
            let semaphore = DispatchSemaphore(value: 0)
            let task = Task {
                do {
                    try await block()
                } catch {
                    XCTFail("Benchmark failed: \(error)")
                }
                semaphore.signal()
            }
            let result = semaphore.wait(timeout: .now() + timeout)
            if result == .timedOut {
                task.cancel()
                XCTFail("Benchmark timed out after \(timeout)s")
            }
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

struct BenchmarkRegressionGuard {
    static func assertMeanBudget(
        label: String,
        stats: BenchmarkStats,
        meanBudget: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            stats.mean,
            meanBudget,
            "mean budget exceeded for \(label): current=\(stats.mean.formatSeconds)s budget=\(meanBudget.formatSeconds)s",
            file: file,
            line: line
        )
    }

    static func assertTailBudget(
        label: String,
        stats: BenchmarkStats,
        p95Budget: Double,
        p99Budget: Double,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        XCTAssertLessThanOrEqual(
            stats.p95,
            p95Budget,
            "p95 budget exceeded for \(label): current=\(stats.p95.formatSeconds)s budget=\(p95Budget.formatSeconds)s",
            file: file,
            line: line
        )
        XCTAssertLessThanOrEqual(
            stats.p99,
            p99Budget,
            "p99 budget exceeded for \(label): current=\(stats.p99.formatSeconds)s budget=\(p99Budget.formatSeconds)s",
            file: file,
            line: line
        )
    }

    static func assertP95NoRegression(
        label: String,
        stats: BenchmarkStats,
        maxRegressionFraction: Double = 0.20,
        file: StaticString = #filePath,
        line: UInt = #line
    ) {
        guard let baseline = baselineP95(for: label) else {
            print("🧪 \(label): no baseline configured (set \(baselineEnvKey(for: label)))")
            return
        }
        let allowed = baseline * (1 + maxRegressionFraction)
        XCTAssertLessThanOrEqual(
            stats.p95,
            allowed,
            "p95 regression for \(label): current=\(stats.p95.formatSeconds)s baseline=\(baseline.formatSeconds)s allowed=\(allowed.formatSeconds)s",
            file: file,
            line: line
        )
    }

    private static func baselineP95(for label: String) -> Double? {
        let key = baselineEnvKey(for: label)
        guard let raw = ProcessInfo.processInfo.environment[key] else { return nil }
        return Double(raw)
    }

    private static func baselineEnvKey(for label: String) -> String {
        let normalized = label.uppercased().map { char -> Character in
            if char.isLetter || char.isNumber {
                return char
            }
            return "_"
        }
        return "WAX_BENCH_BASELINE_\(String(normalized))_P95"
    }
}

enum BenchmarkDedupHarness {
    static func makeCorpus(total: Int, uniqueModulo: Int) -> [String] {
        guard total > 0 else { return [] }
        let cardinality = max(1, uniqueModulo)
        var corpus: [String] = []
        corpus.reserveCapacity(total)
        for index in 0..<total {
            let bucket = index % cardinality
            corpus.append("dedup-doc-\(bucket)-swift-concurrency-vector-search")
        }
        return corpus
    }

    static func deduplicate(corpus: [String]) -> Int {
        var seenHashes = Set<Data>()
        seenHashes.reserveCapacity(corpus.count)
        for text in corpus {
            let digest = SHA256Checksum.digest(Data(text.utf8))
            _ = seenHashes.insert(digest)
        }
        return seenHashes.count
    }
}

enum BenchmarkTemporalHarness {
    static func makeQueries(count: Int) -> [String] {
        let templates = [
            "what did we discuss today",
            "show notes from yesterday",
            "plans from last week",
            "tasks due next week",
            "updates from 2 days ago",
            "schedule in 3 days",
            "review from q3 2025",
            "meeting notes last friday",
        ]
        guard count > 0 else { return templates }
        return (0..<count).map { templates[$0 % templates.count] }
    }

    static func parseAll(_ queries: [String]) -> Int {
        var resolved = 0
        for query in queries {
            if parse(query) != nil {
                resolved &+= 1
            }
        }
        return resolved
    }

    private static func parse(_ query: String) -> (afterDays: Int, beforeDays: Int)? {
        let lowered = query.lowercased()
        if lowered.contains("today") { return (0, 1) }
        if lowered.contains("yesterday") { return (-1, 0) }
        if lowered.contains("last week") { return (-7, 0) }
        if lowered.contains("next week") { return (0, 7) }
        if lowered.contains("last friday") { return (-7, 0) }
        if lowered.contains("q3 2025") { return (-365, -270) }

        let parts = lowered.split(separator: " ")
        if parts.count >= 3,
           let value = Int(parts[parts.count - 3]),
           parts.suffix(2) == ["days", "ago"] {
            return (-value, 0)
        }
        for i in 0..<(parts.count - 2) {
            if parts[i] == "in",
               let value = Int(parts[i + 1]),
               parts[i + 2] == "days" {
                return (value, value + 1)
            }
        }
        return nil
    }
}

enum BenchmarkEnrichmentHarness {
    static func makeTasks(count: Int) -> [String] {
        guard count > 0 else { return [] }
        var tasks: [String] = []
        tasks.reserveCapacity(count)
        for index in 0..<count {
            tasks.append("task-\(index) swift concurrency actors memory pipeline enrichment deterministic benchmark")
        }
        return tasks
    }

    static func drain(_ tasks: [String], topK: Int = 6) -> Int {
        guard topK > 0 else { return 0 }
        var processed = 0
        for text in tasks {
            _ = keywords(text, topK: topK)
            processed &+= 1
        }
        return processed
    }

    private static func keywords(_ text: String, topK: Int) -> [String] {
        let stopwords: Set<String> = ["the", "and", "for", "with", "from", "into", "about", "task"]
        var counts: [String: Int] = [:]
        for token in text.lowercased().split(whereSeparator: { !$0.isLetter }) {
            let word = String(token)
            guard word.count >= 3, !stopwords.contains(word) else { continue }
            counts[word, default: 0] += 1
        }
        return counts
            .sorted { lhs, rhs in
                if lhs.value == rhs.value { return lhs.key < rhs.key }
                return lhs.value > rhs.value
            }
            .prefix(topK)
            .map(\.key)
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
