import Foundation
import Wax

// wax-bench perf --data <dir> --n <docs> --store <path.wax> --out <result.json> [options]
//
// Speed benchmark of the public `Memory` API on precomputed embeddings, so Wax and the
// competitor stores (Benchmarks/scripts/perf_competitors.py) index identical vectors.
// `--data` is the directory written by Benchmarks/scripts/perf_prepare_data.py.
//
// Phases (`--phase`):
//   ingest  create a fresh store, save the first N passages one by one (calling flush()
//           every --flush-every saves), flush, close. --save-batch N > 1 saves them
//           through `save(contentsOf:)`, N passages per call.
//   query   open the existing store (cold open + first search), then run the warm query
//           loop for each mode and score recall@10 against exact brute force.
//   all     ingest, then query (the query phase reopens the store in the same process).
// Run ingest and query as separate processes to keep ingest state out of the query numbers.
//
// --flush-every exists because `Memory` never commits on its own while embeddings are
// pending: its 8 MiB WAL cannot auto-commit before the vector index is staged, so a long
// run of saves without flush() fails with "WAL capacity exceeded" after a few thousand
// passages (Sources/WaxCore/Wax.swift `canAutoCommitForWalPressureLocked`). 0 never flushes.

struct PerfOptions {
    var dataDir = ""
    var count = 0
    var storePath = ""
    var outputPath = ""
    var phase = "all"
    var queryCount = 1_000
    var warmupCount = 50
    var topK = 10
    var modes: [String] = ["vector", "hybrid"]
    var flushEvery = 1_000
    var saveBatch = 1

    static func parse(_ args: ArraySlice<String>) throws -> PerfOptions {
        var options = PerfOptions()
        var iterator = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw BenchError.usage("missing value for \(flag)") }
            return next
        }
        func integer(_ flag: String) throws -> Int {
            let raw = try value(flag)
            guard let parsed = Int(raw), parsed >= 0 else { throw BenchError.usage("\(flag) needs a non-negative integer, got \(raw)") }
            return parsed
        }
        while let flag = iterator.next() {
            switch flag {
            case "--data": options.dataDir = try value(flag)
            case "--n": options.count = try integer(flag)
            case "--store": options.storePath = try value(flag)
            case "--out": options.outputPath = try value(flag)
            case "--phase": options.phase = try value(flag)
            case "--queries": options.queryCount = try integer(flag)
            case "--warmup": options.warmupCount = try integer(flag)
            case "--top-k": options.topK = max(1, try integer(flag))
            case "--modes": options.modes = try value(flag).split(separator: ",").map(String.init)
            case "--flush-every": options.flushEvery = try integer(flag)
            case "--save-batch": options.saveBatch = max(1, try integer(flag))
            default: throw BenchError.usage("unknown flag \(flag)")
            }
        }
        guard !options.dataDir.isEmpty, options.count > 0, !options.storePath.isEmpty, !options.outputPath.isEmpty else {
            throw BenchError.usage("perf needs --data, --n, --store and --out")
        }
        guard ["ingest", "query", "all"].contains(options.phase) else {
            throw BenchError.usage("--phase must be ingest, query or all")
        }
        for mode in options.modes where !["vector", "hybrid", "text"].contains(mode) {
            throw BenchError.usage("unknown mode \(mode); use vector, hybrid or text")
        }
        return options
    }
}

// MARK: - Dataset

/// Row-major float32 matrix loaded from a NumPy `.npy` file (little-endian, C order).
struct NpyMatrix {
    let rows: Int
    let columns: Int
    let values: [Float]

    /// Loads at most `maxRows` leading rows.
    static func load(_ path: String, maxRows: Int = .max) throws -> NpyMatrix {
        let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
        let header = try NpyHeader(data: data, path: path)
        guard header.descr == "<f4", header.shape.count == 2 else {
            throw BenchError.failed("\(path): expected a 2-D <f4 array, got \(header.descr) \(header.shape)")
        }
        let rows = min(header.shape[0], maxRows)
        let columns = header.shape[1]
        var values = [Float](repeating: 0, count: rows * columns)
        _ = values.withUnsafeMutableBytes { target in
            data.copyBytes(to: target, from: header.dataOffset..<(header.dataOffset + target.count))
        }
        return NpyMatrix(rows: rows, columns: columns, values: values)
    }
}

/// Row-major int32 matrix from `.npy` (the ground-truth neighbour rows).
struct NpyIntMatrix {
    let rows: Int
    let columns: Int
    let values: [Int32]

    static func load(_ path: String) throws -> NpyIntMatrix {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        let header = try NpyHeader(data: data, path: path)
        guard header.descr == "<i4", header.shape.count == 2 else {
            throw BenchError.failed("\(path): expected a 2-D <i4 array, got \(header.descr) \(header.shape)")
        }
        var values = [Int32](repeating: 0, count: header.shape[0] * header.shape[1])
        _ = values.withUnsafeMutableBytes { target in
            data.copyBytes(to: target, from: header.dataOffset..<(header.dataOffset + target.count))
        }
        return NpyIntMatrix(rows: header.shape[0], columns: header.shape[1], values: values)
    }

    func row(_ index: Int) -> ArraySlice<Int32> {
        values[(index * columns)..<((index + 1) * columns)]
    }
}

struct NpyHeader {
    let descr: String
    let shape: [Int]
    let dataOffset: Int

    init(data: Data, path: String) throws {
        let magic: [UInt8] = [0x93, 0x4E, 0x55, 0x4D, 0x50, 0x59]
        guard data.count > 10, Array(data.prefix(6)) == magic else {
            throw BenchError.failed("\(path) is not a .npy file")
        }
        let major = data[data.startIndex + 6]
        let lengthBytes = major == 1 ? 2 : 4
        var headerLength = 0
        for byte in data[(data.startIndex + 8)..<(data.startIndex + 8 + lengthBytes)].reversed() {
            headerLength = headerLength << 8 | Int(byte)
        }
        dataOffset = 8 + lengthBytes + headerLength
        let text = String(decoding: data[(data.startIndex + 8 + lengthBytes)..<(data.startIndex + dataOffset)], as: UTF8.self)
        guard !text.contains("'fortran_order': True") else {
            throw BenchError.failed("\(path): Fortran-order arrays are not supported")
        }
        descr = try Self.field("descr", in: text, path: path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "'"))
        let shapeText = try Self.field("shape", in: text, path: path)
            .trimmingCharacters(in: CharacterSet(charactersIn: "()"))
        shape = shapeText.split(separator: ",").compactMap { Int($0.trimmingCharacters(in: .whitespaces)) }
    }

    private static func field(_ name: String, in header: String, path: String) throws -> String {
        guard let keyRange = header.range(of: "'\(name)': ") else {
            throw BenchError.failed("\(path): .npy header has no \(name)")
        }
        let rest = header[keyRange.upperBound...]
        let end = rest.hasPrefix("(") ? rest.firstIndex(of: ")").map { rest.index(after: $0) } : rest.firstIndex(of: ",")
        guard let end else { throw BenchError.failed("\(path): malformed .npy header") }
        return String(rest[..<end])
    }
}

func readLines(_ path: String, limit: Int) throws -> [String] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path), options: .alwaysMapped)
    var lines: [String] = []
    lines.reserveCapacity(min(limit, 1 << 21))
    for line in data.split(separator: UInt8(ascii: "\n"), omittingEmptySubsequences: false) {
        guard lines.count < limit else { break }
        lines.append(String(decoding: line, as: UTF8.self))
    }
    guard lines.count == limit else {
        throw BenchError.failed("\(path) has \(lines.count) lines, need \(limit)")
    }
    return lines
}

struct PerfDataset {
    let corpusTexts: [String]
    let corpus: NpyMatrix
    let queryTexts: [String]
    let queries: NpyMatrix

    static func load(_ options: PerfOptions) throws -> PerfDataset {
        let dir = URL(fileURLWithPath: options.dataDir)
        let corpus = try NpyMatrix.load(dir.appendingPathComponent("corpus.npy").path, maxRows: options.count)
        guard corpus.rows == options.count else {
            throw BenchError.failed("corpus.npy has \(corpus.rows) rows, need \(options.count)")
        }
        let queries = try NpyMatrix.load(dir.appendingPathComponent("queries.npy").path, maxRows: options.queryCount)
        guard queries.rows == options.queryCount, queries.columns == corpus.columns else {
            throw BenchError.failed("queries.npy shape does not match --queries / corpus dimensions")
        }
        return PerfDataset(
            corpusTexts: try readLines(dir.appendingPathComponent("corpus.txt").path, limit: options.count),
            corpus: corpus,
            queryTexts: try readLines(dir.appendingPathComponent("queries.txt").path, limit: options.queryCount),
            queries: queries
        )
    }
}

// MARK: - Embedder

/// Returns the precomputed vector for each known text (corpus passages and queries), so Wax
/// indexes exactly the vectors the competitor stores index. An unknown text is an error:
/// it would mean Wax embedded something other than the saved passage (for example a chunk).
struct PrecomputedEmbeddings: BatchEmbeddingProvider {
    let dimensions: Int
    let normalize = true
    var identity: EmbeddingIdentity? {
        EmbeddingIdentity(provider: "wax-bench", model: "precomputed-all-MiniLM-L6-v2", dimensions: dimensions, normalized: true)
    }

    private let rowByText: [String: Int]
    private let vectors: [Float]

    init(dataset: PerfDataset) {
        dimensions = dataset.corpus.columns
        var rowByText: [String: Int] = [:]
        rowByText.reserveCapacity(dataset.corpusTexts.count + dataset.queryTexts.count)
        for (row, text) in dataset.corpusTexts.enumerated() {
            rowByText[text] = row
        }
        let queryBase = dataset.corpus.rows
        for (row, text) in dataset.queryTexts.enumerated() where rowByText[text] == nil {
            rowByText[text] = queryBase + row
        }
        self.rowByText = rowByText
        vectors = dataset.corpus.values + dataset.queries.values
    }

    func embed(_ text: String) async throws -> [Float] {
        guard let row = rowByText[text] else {
            throw BenchError.failed("no precomputed vector for text: \(text.prefix(80))")
        }
        return Array(vectors[(row * dimensions)..<((row + 1) * dimensions)])
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        var result: [[Float]] = []
        result.reserveCapacity(texts.count)
        for text in texts {
            result.append(try await embed(text))
        }
        return result
    }
}

// MARK: - Results

struct LatencySummary: Encodable {
    let count: Int
    let meanMs: Double
    let p50Ms: Double
    let p95Ms: Double
    let p99Ms: Double
    let maxMs: Double

    init(_ samples: [Double]) {
        let sorted = samples.sorted()
        func percentile(_ fraction: Double) -> Double {
            guard !sorted.isEmpty else { return 0 }
            let rank = Int((fraction * Double(sorted.count)).rounded(.up)) - 1
            return sorted[min(max(rank, 0), sorted.count - 1)]
        }
        count = sorted.count
        meanMs = sorted.isEmpty ? 0 : sorted.reduce(0, +) / Double(sorted.count)
        p50Ms = percentile(0.50)
        p95Ms = percentile(0.95)
        p99Ms = percentile(0.99)
        maxMs = sorted.last ?? 0
    }

    enum CodingKeys: String, CodingKey {
        case count
        case meanMs = "mean_ms", p50Ms = "p50_ms", p95Ms = "p95_ms", p99Ms = "p99_ms", maxMs = "max_ms"
    }
}

struct IngestResult: Encodable {
    let docs: Int
    let flushEvery: Int
    /// Passages per save call: 1 calls `save(_:metadata:)`, more call `save(contentsOf:)`.
    let saveBatch: Int
    /// Wall time of the save loop, including the periodic flushes.
    let saveSeconds: Double
    /// Part of `saveSeconds` spent in the periodic flush() calls.
    let periodicFlushSeconds: Double
    /// The final flush() after the last save.
    let flushSeconds: Double
    let closeSeconds: Double
    let docsPerSecond: Double
    /// One sample per save call, so per batch when `saveBatch` > 1.
    let perSave: LatencySummary
    /// Mean save-call latency per tenth of the ingest, to show whether a save gets slower as the store grows.
    let perSaveMeanMsByDecile: [Double]
    let storeBytes: Int64
    let frameCount: UInt64
    let framesWithoutVectors: UInt64
    let embeddingStatus: String

    enum CodingKeys: String, CodingKey {
        case docs
        case flushEvery = "flush_every", saveBatch = "save_batch", periodicFlushSeconds = "periodic_flush_seconds"
        case saveSeconds = "save_seconds", flushSeconds = "flush_seconds", closeSeconds = "close_seconds"
        case docsPerSecond = "docs_per_second", perSave = "per_save"
        case perSaveMeanMsByDecile = "per_save_mean_ms_by_decile"
        case storeBytes = "store_bytes", frameCount = "frame_count"
        case framesWithoutVectors = "frames_without_vectors", embeddingStatus = "embedding_status"
    }
}

struct ModeResult: Encodable {
    let mode: String
    let effectiveModes: [String: Int]
    let latency: LatencySummary
    /// Mean |returned ∩ exact top-k| / k, against the exact inner-product top-k of the
    /// query vector. For hybrid this measures overlap with pure vector search, not quality.
    let recallAtK: Double
    let meanReturned: Double

    enum CodingKeys: String, CodingKey {
        case mode, latency
        case effectiveModes = "effective_modes", recallAtK = "recall_at_k", meanReturned = "mean_returned"
    }
}

struct QueryResult: Encodable {
    let openMs: Double
    let firstSearchMs: Double
    let firstSearchMode: String
    let warmupQueries: Int
    let modes: [ModeResult]
    let storeBytes: Int64

    enum CodingKeys: String, CodingKey {
        case modes
        case openMs = "open_ms", firstSearchMs = "first_search_ms", firstSearchMode = "first_search_mode"
        case warmupQueries = "warmup_queries", storeBytes = "store_bytes"
    }
}

struct PerfResult: Encodable {
    let system = "wax"
    let waxVectorEngine: String
    let n: Int
    let dimensions: Int
    let topK: Int
    let queries: Int
    let queryLoop = "single caller, one query at a time"
    let ingest: IngestResult?
    let query: QueryResult?

    enum CodingKeys: String, CodingKey {
        case system, n, dimensions, queries, ingest, query
        case waxVectorEngine = "wax_vector_engine", topK = "top_k", queryLoop = "query_loop"
    }
}

/// Engine `Memory` selects under the default `.auto` preference
/// (Sources/WaxVectorSearch/LoadedVectorSearchEngine.swift `resolveKind`): MetalANNS once the
/// store holds `MetalANNSVectorEngine.autoThreshold` (10,000) vectors and Metal is available,
/// otherwise the Accelerate exact scan. From `MetalANNSVectorEngine.defaultQuantizedScanMinVectorCount`
/// (50,000) the flat scan shortlists rows by sign code and rescores them exactly. Those choices are
/// package-internal, so they are restated here.
func expectedWaxVectorEngine(vectorCount: Int) -> String {
    if vectorCount >= 50_000 { return "metalANNS (searchMode .exact, sign-code shortlist + exact rescore)" }
    return vectorCount >= 10_000 ? "metalANNS (searchMode .exact)" : "accelerate (exact)"
}

// MARK: - Phases

func perfConfig(embedder: PrecomputedEmbeddings) -> Memory.Config {
    var config = Memory.Config.default
    config.embedding = .custom(embedder)
    return config
}

/// The store file plus any sidecar files Wax writes next to it (`<name>*`).
func storeSize(_ path: String) throws -> Int64 {
    let url = URL(fileURLWithPath: path)
    let directory = url.deletingLastPathComponent()
    let name = url.lastPathComponent
    var total: Int64 = 0
    for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) where entry.hasPrefix(name) {
        let attributes = try FileManager.default.attributesOfItem(atPath: directory.appendingPathComponent(entry).path)
        total += (attributes[.size] as? NSNumber)?.int64Value ?? 0
    }
    return total
}

func perfLog(_ message: String) {
    FileHandle.standardError.write(Data("perf: \(message)\n".utf8))
}

func runIngest(_ options: PerfOptions, dataset: PerfDataset, embedder: PrecomputedEmbeddings) async throws -> IngestResult {
    let url = URL(fileURLWithPath: options.storePath)
    let directory = url.deletingLastPathComponent()
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    for entry in try FileManager.default.contentsOfDirectory(atPath: directory.path) where entry.hasPrefix(url.lastPathComponent) {
        try FileManager.default.removeItem(at: directory.appendingPathComponent(entry))
    }

    let memory = try await Memory(at: url, config: perfConfig(embedder: embedder))
    var saveMs: [Double] = []
    saveMs.reserveCapacity(options.count)
    let progressStep = max(1, options.count / 10)
    var periodicFlushMs = 0.0
    let start = ContinuousClock.now
    let texts = dataset.corpusTexts
    for lower in stride(from: 0, to: texts.count, by: options.saveBatch) {
        let upper = min(lower + options.saveBatch, texts.count)
        let saveStart = ContinuousClock.now
        if options.saveBatch == 1 {
            try await memory.save(texts[lower], metadata: ["doc_id": String(lower)])
        } else {
            try await memory.save(contentsOf: (lower..<upper).map { (texts[$0], ["doc_id": String($0)]) })
        }
        saveMs.append(elapsedMs(since: saveStart))
        if options.flushEvery > 0, upper / options.flushEvery > lower / options.flushEvery, upper < options.count {
            let flushStart = ContinuousClock.now
            try await memory.flush()
            periodicFlushMs += elapsedMs(since: flushStart)
        }
        if upper / progressStep > lower / progressStep {
            let seconds = elapsedMs(since: start) / 1_000
            perfLog("ingest \(upper)/\(options.count) (\(Int(Double(upper) / seconds)) docs/s)")
        }
    }
    let saveSeconds = elapsedMs(since: start) / 1_000
    let flushStart = ContinuousClock.now
    try await memory.flush()
    let flushSeconds = elapsedMs(since: flushStart) / 1_000
    let stats = await memory.stats()
    let closeStart = ContinuousClock.now
    try await memory.close()
    let closeSeconds = elapsedMs(since: closeStart) / 1_000

    let decile = max(1, saveMs.count / 10)
    let deciles = stride(from: 0, to: saveMs.count, by: decile).map { lower in
        let slice = saveMs[lower..<min(lower + decile, saveMs.count)]
        return slice.reduce(0, +) / Double(slice.count)
    }
    return IngestResult(
        docs: options.count,
        flushEvery: options.flushEvery,
        saveBatch: options.saveBatch,
        saveSeconds: saveSeconds,
        periodicFlushSeconds: periodicFlushMs / 1_000,
        flushSeconds: flushSeconds,
        closeSeconds: closeSeconds,
        docsPerSecond: Double(options.count) / (saveSeconds + flushSeconds),
        perSave: LatencySummary(saveMs),
        perSaveMeanMsByDecile: deciles,
        storeBytes: try storeSize(options.storePath),
        frameCount: stats.frameCount,
        framesWithoutVectors: stats.framesWithoutVectors,
        embeddingStatus: "\(stats.embeddingStatus)"
    )
}

func searchOptions(mode: String, topK: Int) -> Memory.SearchOptions {
    let retrievalMode: Memory.RetrievalMode = switch mode {
    case "vector": .vectorOnly
    case "text": .textOnly
    default: .hybrid()
    }
    return Memory.SearchOptions(
        topK: topK,
        mode: retrievalMode,
        // Large budget so the context builder never trims results below topK.
        maxContextTokens: Memory.SearchOptions.maxContextTokensRange.upperBound,
        inferTimeRange: false
    )
}

func rankedRows(_ results: Memory.Results, topK: Int) -> [Int] {
    var rows: [Int] = []
    var seen: Set<Int> = []
    for item in results.items {
        guard let raw = item.metadata["doc_id"], let row = Int(raw), seen.insert(row).inserted else { continue }
        rows.append(row)
        if rows.count == topK { break }
    }
    return rows
}

func runQueries(_ options: PerfOptions, dataset: PerfDataset, embedder: PrecomputedEmbeddings) async throws -> QueryResult {
    let groundTruthPath = URL(fileURLWithPath: options.dataDir)
        .appendingPathComponent("groundtruth-\(options.count).npy").path
    let groundTruth = try NpyIntMatrix.load(groundTruthPath)
    guard groundTruth.rows >= options.queryCount, groundTruth.columns >= options.topK else {
        throw BenchError.failed("\(groundTruthPath) does not cover \(options.queryCount) queries at top-\(options.topK)")
    }

    let openStart = ContinuousClock.now
    let memory = try await Memory(at: URL(fileURLWithPath: options.storePath), config: perfConfig(embedder: embedder))
    let openMs = elapsedMs(since: openStart)
    // The first search loads the vector index into the engine, so it is reported as part
    // of the cold start.
    let firstMode = options.modes.first ?? "vector"
    let firstStart = ContinuousClock.now
    _ = try await memory.search(dataset.queryTexts[0], options: searchOptions(mode: firstMode, topK: options.topK))
    let firstSearchMs = elapsedMs(since: firstStart)
    perfLog("open \(Int(openMs)) ms, first \(firstMode) search \(Int(firstSearchMs)) ms")

    var modeResults: [ModeResult] = []
    for mode in options.modes {
        let searchOptions = searchOptions(mode: mode, topK: options.topK)
        for index in 0..<min(options.warmupCount, options.queryCount) {
            _ = try await memory.search(dataset.queryTexts[index], options: searchOptions)
        }
        var latencies: [Double] = []
        latencies.reserveCapacity(options.queryCount)
        var effective: [String: Int] = [:]
        var recallSum = 0.0
        var returnedSum = 0
        for (index, query) in dataset.queryTexts.enumerated() {
            let start = ContinuousClock.now
            let results = try await memory.search(query, options: searchOptions)
            latencies.append(elapsedMs(since: start))
            let label = results.diagnostics.map { "\($0.effectiveMode)" } ?? "unknown"
            effective[label, default: 0] += 1
            let rows = rankedRows(results, topK: options.topK)
            let exact = Set(groundTruth.row(index).prefix(options.topK).map(Int.init))
            recallSum += Double(rows.filter(exact.contains).count) / Double(options.topK)
            returnedSum += rows.count
        }
        let result = ModeResult(
            mode: mode,
            effectiveModes: effective,
            latency: LatencySummary(latencies),
            recallAtK: recallSum / Double(options.queryCount),
            meanReturned: Double(returnedSum) / Double(options.queryCount)
        )
        perfLog("\(mode): p50 \(String(format: "%.3f", result.latency.p50Ms)) ms, recall@\(options.topK) \(String(format: "%.4f", result.recallAtK))")
        modeResults.append(result)
    }
    try await memory.close()
    return QueryResult(
        openMs: openMs,
        firstSearchMs: firstSearchMs,
        firstSearchMode: firstMode,
        warmupQueries: min(options.warmupCount, options.queryCount),
        modes: modeResults,
        storeBytes: try storeSize(options.storePath)
    )
}

func perf(_ options: PerfOptions) async throws {
    let loadStart = ContinuousClock.now
    let dataset = try PerfDataset.load(options)
    let embedder = PrecomputedEmbeddings(dataset: dataset)
    perfLog("loaded \(options.count) docs and \(options.queryCount) queries in \(Int(elapsedMs(since: loadStart))) ms")

    let ingest = options.phase == "query" ? nil : try await runIngest(options, dataset: dataset, embedder: embedder)
    let query = options.phase == "ingest" ? nil : try await runQueries(options, dataset: dataset, embedder: embedder)
    let result = PerfResult(
        waxVectorEngine: expectedWaxVectorEngine(vectorCount: options.count),
        n: options.count,
        dimensions: dataset.corpus.columns,
        topK: options.topK,
        queries: options.queryCount,
        ingest: ingest,
        query: query
    )
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
    try encoder.encode(result).write(to: URL(fileURLWithPath: options.outputPath))
}
