import Foundation
import Wax

// wax-bench retrieve --input jobs.jsonl --output ranked.jsonl [options]
//
// Each input line is one retrieval job: a private haystack plus one query,
//   {"qid": "...", "query": "...", "docs": [{"id": "...", "text": "..."}]}
// or a haystack plus several queries that share it,
//   {"queries": [{"qid": "...", "query": "..."}], "docs": [...]}
// For each job, wax-bench creates a fresh store, saves every doc through the public
// `Memory` API, runs the searches, and writes one line per query with the ranked doc ids:
//   {"qid": "...", "ranked": ["doc-id", ...], "hits": [...], "ingest_ms": 0, "search_ms": 0, ...}

struct Job: Decodable {
    struct Doc: Decodable {
        let id: String
        let text: String
    }

    struct Query: Decodable {
        let qid: String
        let query: String
    }

    let qid: String?
    let query: String?
    let queries: [Query]?
    let docs: [Doc]

    func resolvedQueries() throws -> [Query] {
        if let queries { return queries }
        guard let qid, let query else { throw BenchError.failed("job needs qid+query or queries") }
        return [Query(qid: qid, query: query)]
    }
}

struct Hit: Encodable {
    let id: String
    let score: Float
    let sources: [String]
}

struct JobResult: Encodable {
    let qid: String
    let ranked: [String]
    let hits: [Hit]
    let unmappedHits: Int
    let ingestMs: Double
    let searchMs: Double
    let effectiveMode: String
    let queryEmbedding: String
    let docCount: Int

    enum CodingKeys: String, CodingKey {
        case qid, ranked, hits
        case unmappedHits = "unmapped_hits"
        case ingestMs = "ingest_ms"
        case searchMs = "search_ms"
        case effectiveMode = "effective_mode"
        case queryEmbedding = "query_embedding"
        case docCount = "doc_count"
    }
}

struct Options {
    var input = ""
    var output = ""
    var mode: Memory.RetrievalMode = .hybrid()
    var topK = 50
    var embedder: BuiltInEmbeddingProvider = .miniLM
    /// Set by `--embedder http://...`: embed through scripts/embed_server.py instead.
    var embedderURL: URL?
    /// Set by `--embedder-similarity cosine|dot`; applies to the HTTP embedder only.
    var embedderSimilarity: VectorSimilarity = .cosine
    var concurrency = 4
    var storeDir = FileManager.default.temporaryDirectory.appendingPathComponent("wax-bench").path

    static func parse(_ args: ArraySlice<String>) throws -> Options {
        var options = Options()
        var iterator = args.makeIterator()
        func value(_ flag: String) throws -> String {
            guard let next = iterator.next() else { throw BenchError.usage("missing value for \(flag)") }
            return next
        }
        while let flag = iterator.next() {
            switch flag {
            case "--input": options.input = try value(flag)
            case "--output": options.output = try value(flag)
            case "--top-k": options.topK = Int(try value(flag)) ?? options.topK
            case "--concurrency": options.concurrency = max(1, Int(try value(flag)) ?? options.concurrency)
            case "--store-dir": options.storeDir = try value(flag)
            case "--embedder":
                let raw = try value(flag)
                if raw.hasPrefix("http://") {
                    guard let url = URL(string: raw) else { throw BenchError.usage("bad embedder URL \(raw)") }
                    options.embedderURL = url
                    continue
                }
                guard let provider = BuiltInEmbeddingProvider(rawValue: raw) else {
                    throw BenchError.usage("unknown embedder \(raw)")
                }
                options.embedder = provider
            case "--embedder-similarity":
                switch try value(flag) {
                case "cosine": options.embedderSimilarity = .cosine
                case "dot": options.embedderSimilarity = .dotProduct
                case let other: throw BenchError.usage("embedder similarity must be cosine or dot, got \(other)")
                }
            case "--mode":
                switch try value(flag) {
                case "text": options.mode = .textOnly
                case "vector": options.mode = .vectorOnly
                case "hybrid": options.mode = .hybrid()
                case let other:
                    guard other.hasPrefix("hybrid:"), let alpha = Float(other.dropFirst("hybrid:".count)) else {
                        throw BenchError.usage("mode must be text, vector, hybrid or hybrid:<alpha>")
                    }
                    options.mode = .hybrid(alpha: alpha)
                }
            default:
                throw BenchError.usage("unknown flag \(flag)")
            }
        }
        guard !options.input.isEmpty, !options.output.isEmpty else {
            throw BenchError.usage("--input and --output are required")
        }
        guard options.embedderSimilarity == .cosine || options.embedderURL != nil else {
            throw BenchError.usage("--embedder-similarity dot needs --embedder http://...; built-in embedders are cosine")
        }
        return options
    }
}

enum BenchError: Error, CustomStringConvertible {
    case usage(String)
    case failed(String)

    var description: String {
        switch self {
        case .usage(let message): "usage error: \(message)"
        case .failed(let message): message
        }
    }
}

func elapsedMs(since start: ContinuousClock.Instant) -> Double {
    let duration = ContinuousClock.now - start
    let components = duration.components
    return Double(components.seconds) * 1_000 + Double(components.attoseconds) / 1e15
}

func runJob(_ job: Job, options: Options, embedder: any EmbeddingProvider) async throws -> [JobResult] {
    let storeURL = URL(fileURLWithPath: options.storeDir)
        .appendingPathComponent("\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: storeURL) }

    var config = Memory.Config.default
    config.embedding = .custom(embedder)
    config.enableVectorSearch = options.mode != .textOnly
    let memory = try await Memory(at: storeURL, config: config)

    let ingestStart = ContinuousClock.now
    for doc in job.docs {
        try await memory.save(doc.text, metadata: ["doc_id": doc.id])
    }
    try await memory.flush()
    let ingestMs = elapsedMs(since: ingestStart)

    let searchOptions = Memory.SearchOptions(
        topK: options.topK,
        mode: options.mode,
        maxContextTokens: Memory.SearchOptions.maxContextTokensRange.upperBound,
        // Saved-at time is "now" for every doc, so relative phrases in the question
        // ("last week") would filter on wall-clock time, not the conversation's dates.
        inferTimeRange: false
    )
    var jobResults: [JobResult] = []
    for query in try job.resolvedQueries() {
        let searchStart = ContinuousClock.now
        let results = try await memory.search(query.query, options: searchOptions)
        let searchMs = elapsedMs(since: searchStart)
        jobResults.append(rankedResult(
            qid: query.qid,
            results: results,
            ingestMs: ingestMs,
            searchMs: searchMs,
            docCount: job.docs.count
        ))
    }
    try await memory.close()
    return jobResults
}

func rankedResult(qid: String, results: Memory.Results, ingestMs: Double, searchMs: Double, docCount: Int) -> JobResult {
    var ranked: [String] = []
    var seen: Set<String> = []
    var hits: [Hit] = []
    var unmapped = 0
    for item in results.items {
        guard let id = item.metadata["doc_id"] else {
            unmapped += 1
            continue
        }
        hits.append(Hit(id: id, score: item.score, sources: item.sources.map { "\($0)" }))
        if seen.insert(id).inserted {
            ranked.append(id)
        }
    }
    let diagnostics = results.diagnostics
    return JobResult(
        qid: qid,
        ranked: ranked,
        hits: hits,
        unmappedHits: unmapped,
        ingestMs: ingestMs,
        searchMs: searchMs,
        effectiveMode: diagnostics.map { "\($0.effectiveMode)" } ?? "unknown",
        queryEmbedding: diagnostics.map { $0.queryEmbeddingState.rawValue } ?? "unknown",
        docCount: docCount
    )
}

func readJobs(_ path: String) throws -> [Job] {
    let data = try Data(contentsOf: URL(fileURLWithPath: path))
    let decoder = JSONDecoder()
    return try data.split(separator: UInt8(ascii: "\n")).map { line in
        try decoder.decode(Job.self, from: Data(line))
    }
}

func retrieve(_ options: Options) async throws {
    let jobs = try readJobs(options.input)
    try FileManager.default.createDirectory(atPath: options.storeDir, withIntermediateDirectories: true)
    let embedder: any EmbeddingProvider = if let url = options.embedderURL {
        try await HTTPEmbeddings.connect(to: url, similarity: options.embedderSimilarity)
    } else {
        try await BuiltInEmbeddings.make(options.embedder)
    }
    FileManager.default.createFile(atPath: options.output, contents: nil)
    guard let out = FileHandle(forWritingAtPath: options.output) else {
        throw BenchError.failed("cannot open \(options.output)")
    }
    defer { try? out.close() }
    let encoder = JSONEncoder()
    encoder.outputFormatting = [.sortedKeys, .withoutEscapingSlashes]

    var done = 0
    try await withThrowingTaskGroup(of: [JobResult].self) { group in
        var pending = jobs.makeIterator()
        for _ in 0..<options.concurrency {
            guard let job = pending.next() else { break }
            group.addTask { try await runJob(job, options: options, embedder: embedder) }
        }
        while let results = try await group.next() {
            for result in results {
                var line = try encoder.encode(result)
                line.append(UInt8(ascii: "\n"))
                try out.write(contentsOf: line)
            }
            done += 1
            if done % 25 == 0 || done == jobs.count {
                FileHandle.standardError.write(Data("retrieve: \(done)/\(jobs.count)\n".utf8))
            }
            if let job = pending.next() {
                group.addTask { try await runJob(job, options: options, embedder: embedder) }
            }
        }
    }
}

let arguments = CommandLine.arguments
do {
    guard arguments.count >= 2 else { throw BenchError.usage("wax-bench retrieve --input <jsonl> --output <jsonl>") }
    switch arguments[1] {
    case "retrieve":
        try await retrieve(try Options.parse(arguments.dropFirst(2)))
    case "perf":
        try await perf(try PerfOptions.parse(arguments.dropFirst(2)))
    default:
        throw BenchError.usage("unknown command \(arguments[1])")
    }
} catch {
    FileHandle.standardError.write(Data("wax-bench: \(error)\n".utf8))
    exit(1)
}
