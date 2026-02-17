import Foundation
import XCTest
@testable import Wax

private enum LongMemoryBenchmarkError: Error {
    case missingFixture(String)
}

private struct LongMemoryFixture: Decodable, Sendable {
    let name: String
    let documents: [Document]
    let queries: [Query]

    struct Document: Decodable, Sendable {
        let id: String
        let text: String
        let metadata: [String: String]?
        let tags: [Tag]?
        let labels: [String]?
    }

    struct Tag: Decodable, Sendable {
        let key: String
        let value: String
    }

    struct Query: Decodable, Sendable {
        let id: String
        let text: String
        let expectedDocumentIds: [String]
        let expectedAnswer: String?
        let requiredDocumentHits: Int?
    }
}

private enum LongMemoryFixtureLoader {
    static func load(pathOverride: String?) throws -> LongMemoryFixture {
        let url: URL
        if let pathOverride, !pathOverride.isEmpty {
            url = URL(fileURLWithPath: pathOverride)
        } else if let bundled = Bundle.module.url(forResource: "long_memory_fixture", withExtension: "json") {
            url = bundled
        } else {
            throw LongMemoryBenchmarkError.missingFixture("long_memory_fixture.json")
        }

        let data = try Data(contentsOf: url)
        let decoder = JSONDecoder()
        decoder.keyDecodingStrategy = .convertFromSnakeCase
        return try decoder.decode(LongMemoryFixture.self, from: data)
    }
}

private protocol LongMemoryAnswerJudge {
    func score(predicted: String, expected: String) -> Double
}

private struct TokenF1AnswerJudge: LongMemoryAnswerJudge {
    func score(predicted: String, expected: String) -> Double {
        let predictedTokens = Self.tokens(from: predicted)
        let expectedTokens = Self.tokens(from: expected)
        guard !predictedTokens.isEmpty, !expectedTokens.isEmpty else { return 0 }

        var predictedCounts: [String: Int] = [:]
        var expectedCounts: [String: Int] = [:]
        for token in predictedTokens {
            predictedCounts[token, default: 0] += 1
        }
        for token in expectedTokens {
            expectedCounts[token, default: 0] += 1
        }

        var overlap = 0
        for (token, predictedCount) in predictedCounts {
            if let expectedCount = expectedCounts[token] {
                overlap += min(predictedCount, expectedCount)
            }
        }

        if overlap == 0 { return 0 }
        let precision = Double(overlap) / Double(predictedTokens.count)
        let recall = Double(overlap) / Double(expectedTokens.count)
        let denom = precision + recall
        guard denom > 0 else { return 0 }
        return 2 * precision * recall / denom
    }

    private static func tokens(from text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }
}

private struct LongMemoryRunConfig: Sendable {
    let topK: Int
    let includeVectors: Bool
    let vectorDimensions: Int
    let searchAlpha: Float
    let minRecallAtK: Double
    let minMRR: Double
    let minJudgeScore: Double
    let enableDiagnostics: Bool

    static func current() -> LongMemoryRunConfig {
        let env = ProcessInfo.processInfo.environment
        return LongMemoryRunConfig(
            topK: max(1, env["WAX_LONG_MEMORY_TOPK"].flatMap(Int.init) ?? 8),
            includeVectors: env["WAX_LONG_MEMORY_VECTORS"] == "1",
            vectorDimensions: max(8, env["WAX_LONG_MEMORY_DIMS"].flatMap(Int.init) ?? 64),
            searchAlpha: min(1, max(0, env["WAX_LONG_MEMORY_ALPHA"].flatMap(Float.init) ?? 1.0)),
            minRecallAtK: min(1, max(0, env["WAX_LONG_MEMORY_MIN_RECALL"].flatMap(Double.init) ?? 0.95)),
            minMRR: min(1, max(0, env["WAX_LONG_MEMORY_MIN_MRR"].flatMap(Double.init) ?? 0.80)),
            minJudgeScore: min(1, max(0, env["WAX_LONG_MEMORY_MIN_JUDGE"].flatMap(Double.init) ?? 0.25)),
            enableDiagnostics: env["WAX_LONG_MEMORY_DIAGNOSTICS"] == "1"
        )
    }
}

private struct LongMemoryAnswerOverlap: Codable, Sendable {
    let f1: Double
    let precision: Double
    let recall: Double
    let overlapTokens: Int
    let predictedTokens: Int
    let expectedTokens: Int
}

private struct LongMemoryQueryDiagnostics: Codable, Sendable {
    let queryID: String
    let queryText: String
    let expectedDocumentIDs: [String]
    let topDocumentIDs: [String]
    let selectedKind: String?
    let selectedDocumentID: String?
    let selectedText: String?
    let expectedAnswer: String?
    let predictedAnswer: String?
    let overlap: LongMemoryAnswerOverlap?
    let bucket: String
}

private struct LongMemoryQueryOutcome: Codable, Sendable {
    let queryID: String
    let hitAtK: Bool
    let reciprocalRank: Double
    let topDocumentIDs: [String]
    let answerScore: Double?
}

private struct LongMemoryMetrics: Codable, Sendable {
    let queryCount: Int
    let hitAtKCount: Int
    let recallAtK: Double
    let meanReciprocalRank: Double
    let judgedQueries: Int
    let meanJudgeScore: Double
}

private struct LongMemoryLatencySummary: Codable, Sendable {
    let samples: Int
    let meanSeconds: Double
    let p95Seconds: Double
}

private struct LongMemoryReport: Codable, Sendable {
    let fixtureName: String
    let topK: Int
    let includeVectors: Bool
    let documentCount: Int
    let queryCount: Int
    let metrics: LongMemoryMetrics
    let latency: LongMemoryLatencySummary
    let failureBuckets: [String: Int]
}

private actor QueryCycler {
    private var index = 0

    func next(max: Int) -> Int {
        guard max > 0 else { return 0 }
        let current = index % max
        index += 1
        return current
    }
}

private enum LongMemoryAnswerBucket: String {
    case retrievalMiss = "retrieval_miss"
    case missingContext = "missing_context_item"
    case wrongContext = "selected_wrong_doc"
    case multiHopPartial = "multi_hop_partial"
    case verbosePrecisionLoss = "verbose_precision_loss"
    case lowOverlap = "low_overlap"
    case success = "success"
}

final class LongMemoryBenchmarkHarness: XCTestCase {
    private let benchmarkDocIDKey = "benchmark_doc_id"

    private var isEnabled: Bool {
        ProcessInfo.processInfo.environment["WAX_BENCHMARK_LONG_MEMORY"] == "1"
    }

    override func setUpWithError() throws {
        try super.setUpWithError()
        guard isEnabled else {
            throw XCTSkip("Set WAX_BENCHMARK_LONG_MEMORY=1 to run long-memory benchmark harness.")
        }
    }

    func testLongMemoryRecallAndAnswerQuality() async throws {
        let env = ProcessInfo.processInfo.environment
        let config = LongMemoryRunConfig.current()
        let fixture = try LongMemoryFixtureLoader.load(pathOverride: env["WAX_LONG_MEMORY_FIXTURE"])

        let url = Self.makeTempURL()
        defer { try? FileManager.default.removeItem(at: url) }

        let wax = try await Wax.create(at: url)
        let text = try await wax.enableTextSearch()

        let embedder: DeterministicEmbedder?
        let vector: WaxVectorSearchSession?
        if config.includeVectors {
            let local = DeterministicEmbedder(dimensions: config.vectorDimensions)
            embedder = local
            vector = try await wax.enableVectorSearch(dimensions: local.dimensions)
        } else {
            embedder = nil
            vector = nil
        }

        var docIDByFrameID: [UInt64: String] = [:]
        docIDByFrameID.reserveCapacity(fixture.documents.count)

        for document in fixture.documents {
            var metadata = document.metadata ?? [:]
            metadata[benchmarkDocIDKey] = document.id

            let tags = (document.tags ?? []).map { TagPair(key: $0.key, value: $0.value) }
            let labels = document.labels ?? []
            let options = FrameMetaSubset(
                tags: tags,
                labels: labels,
                searchText: document.text,
                metadata: Metadata(metadata)
            )
            let payload = Data(document.text.utf8)

            let frameID: UInt64
            if let vector, let embedder {
                let raw = try await embedder.embed(document.text)
                let embedding = embedder.normalize ? VectorMath.normalizeL2(raw) : raw
                frameID = try await vector.putWithEmbedding(
                    payload,
                    embedding: embedding,
                    options: options,
                    identity: embedder.identity
                )
            } else {
                frameID = try await wax.put(payload, options: options)
            }

            docIDByFrameID[frameID] = document.id
            try await text.index(frameId: frameID, text: document.text)
        }

        try await text.stageForCommit()
        if let vector {
            try await vector.stageForCommit()
        }
        try await wax.commit()

        let judge = TokenF1AnswerJudge()
        let ragBuilder = FastRAGContextBuilder()
        let answerExtractor = DeterministicAnswerExtractor()
        let ragConfig = FastRAGConfig(
            maxContextTokens: 180,
            expansionMaxTokens: 120,
            snippetMaxTokens: 45,
            maxSnippets: 4,
            searchTopK: max(config.topK, 12),
            searchMode: config.includeVectors ? .hybrid(alpha: config.searchAlpha) : .textOnly
        )

        var outcomes: [LongMemoryQueryOutcome] = []
        outcomes.reserveCapacity(fixture.queries.count)
        var diagnostics: [LongMemoryQueryDiagnostics] = []
        diagnostics.reserveCapacity(fixture.queries.count)

        for query in fixture.queries {
            let searchQuery = Self.sanitizedQuery(query.text)
            let embedding = try await Self.queryEmbedding(searchQuery, embedder: embedder)
            let request = SearchRequest(
                query: searchQuery,
                embedding: embedding,
                vectorEnginePreference: .cpuOnly,
                mode: config.includeVectors ? .hybrid(alpha: config.searchAlpha) : .textOnly,
                topK: config.topK
            )
            let response = try await wax.search(request)
            let rankedDocIDs = try await resolveDocIDs(
                from: response.results,
                wax: wax,
                cache: &docIDByFrameID
            )

            let expectedSet = Set(query.expectedDocumentIds)
            let requiredHits = max(
                1,
                min(expectedSet.count, query.requiredDocumentHits ?? 1)
            )
            let matchedCount = Set(rankedDocIDs).intersection(expectedSet).count
            let hitAtK = matchedCount >= requiredHits

            var reciprocalRank = 0.0
            for (index, docID) in rankedDocIDs.enumerated() where expectedSet.contains(docID) {
                reciprocalRank = 1.0 / Double(index + 1)
                break
            }

            let answerScore: Double?
            let predictedAnswer: String?
            let overlap: LongMemoryAnswerOverlap?
            let selectedKind: String?
            let selectedDocID: String?
            let selectedText: String?
            let bucket: LongMemoryAnswerBucket
            if let expected = query.expectedAnswer {
                let context = try await ragBuilder.build(
                    query: searchQuery,
                    embedding: embedding,
                    vectorEnginePreference: .cpuOnly,
                    wax: wax,
                    config: ragConfig
                )
                let selected = Self.bestAnswerItem(query: searchQuery, items: context.items)
                let predicted = answerExtractor.extractAnswer(query: searchQuery, items: context.items)
                answerScore = judge.score(predicted: predicted, expected: expected)
                predictedAnswer = predicted
                selectedKind = selected.map { String(describing: $0.kind) }
                selectedDocID = selected.flatMap { docIDByFrameID[$0.frameId] }
                selectedText = selected?.text
                overlap = Self.answerOverlap(predicted: predicted, expected: expected)
                bucket = Self.bucket(
                    hitAtK: hitAtK,
                    selectedDocID: selectedDocID,
                    expectedDocIDs: expectedSet,
                    requiredDocumentHits: query.requiredDocumentHits ?? 1,
                    overlap: overlap
                )
            } else {
                answerScore = nil
                predictedAnswer = nil
                overlap = nil
                selectedKind = nil
                selectedDocID = nil
                selectedText = nil
                bucket = hitAtK ? .success : .retrievalMiss
            }

            outcomes.append(
                LongMemoryQueryOutcome(
                    queryID: query.id,
                    hitAtK: hitAtK,
                    reciprocalRank: reciprocalRank,
                    topDocumentIDs: rankedDocIDs,
                    answerScore: answerScore
                )
            )

            if config.enableDiagnostics {
                diagnostics.append(
                    LongMemoryQueryDiagnostics(
                        queryID: query.id,
                        queryText: query.text,
                        expectedDocumentIDs: query.expectedDocumentIds,
                        topDocumentIDs: rankedDocIDs,
                        selectedKind: selectedKind,
                        selectedDocumentID: selectedDocID,
                        selectedText: selectedText,
                        expectedAnswer: query.expectedAnswer,
                        predictedAnswer: predictedAnswer,
                        overlap: overlap,
                        bucket: bucket.rawValue
                    )
                )
            }
        }

        let metrics = buildMetrics(outcomes: outcomes)
        let latency = try await latencySummary(
            fixture: fixture,
            wax: wax,
            embedder: embedder,
            topK: config.topK,
            includeVectors: config.includeVectors,
            alpha: config.searchAlpha
        )

        try await wax.close()

        let report = LongMemoryReport(
            fixtureName: fixture.name,
            topK: config.topK,
            includeVectors: config.includeVectors,
            documentCount: fixture.documents.count,
            queryCount: fixture.queries.count,
            metrics: metrics,
            latency: latency,
            failureBuckets: Self.failureBucketCounts(diagnostics)
        )
        printReport(report)
        if config.enableDiagnostics {
            Self.printDiagnostics(diagnostics)
        }

        XCTAssertGreaterThanOrEqual(metrics.recallAtK, config.minRecallAtK, "Recall@K below threshold")
        XCTAssertGreaterThanOrEqual(metrics.meanReciprocalRank, config.minMRR, "MRR below threshold")
        if metrics.judgedQueries > 0 {
            XCTAssertGreaterThanOrEqual(metrics.meanJudgeScore, config.minJudgeScore, "Answer score below threshold")
        }
    }

    private static func makeTempURL() -> URL {
        FileManager.default.temporaryDirectory
            .appendingPathComponent(UUID().uuidString)
            .appendingPathExtension("mv2s")
    }

    private static func sanitizedQuery(_ query: String) -> String {
        let cleaned = query.unicodeScalars.map { scalar -> Character in
            if CharacterSet.alphanumerics.contains(scalar) {
                return Character(scalar)
            }
            return " "
        }
        return String(cleaned)
            .split(whereSeparator: \.isWhitespace)
            .joined(separator: " ")
    }

    private static func answerTokens(_ text: String) -> [String] {
        text.lowercased()
            .split(whereSeparator: { !$0.isLetter && !$0.isNumber })
            .map(String.init)
    }

    private static func bestAnswerItem(query: String, items: [RAGContext.Item]) -> RAGContext.Item? {
        guard !items.isEmpty else { return nil }
        let analyzer = QueryAnalyzer()
        let queryTerms = Set(analyzer.normalizedTerms(query: query))
        let intent = analyzer.detectIntent(query: query)

        func score(_ item: RAGContext.Item) -> Float {
            guard !item.text.isEmpty else { return -.infinity }
            let terms = Set(analyzer.normalizedTerms(query: item.text))
            let overlap = Float(queryTerms.intersection(terms).count)
            let overlapScore = overlap / Float(max(1, queryTerms.count))
            var total = item.score + overlapScore * 0.6
            let lower = item.text.lowercased()
            if intent.contains(.asksLocation), lower.contains("moved to") { total += 0.35 }
            if intent.contains(.asksDate), lower.contains("public launch") { total += 0.35 }
            if intent.contains(.asksOwnership), lower.contains("owns deployment readiness") { total += 0.35 }
            return total
        }

        return items.max { lhs, rhs in
            let lhsScore = score(lhs)
            let rhsScore = score(rhs)
            if lhsScore != rhsScore { return lhsScore < rhsScore }
            return lhs.frameId > rhs.frameId
        }
    }

    private static func answerOverlap(predicted: String, expected: String) -> LongMemoryAnswerOverlap {
        let predictedTokens = answerTokens(predicted)
        let expectedTokens = answerTokens(expected)
        guard !predictedTokens.isEmpty, !expectedTokens.isEmpty else {
            return LongMemoryAnswerOverlap(
                f1: 0,
                precision: 0,
                recall: 0,
                overlapTokens: 0,
                predictedTokens: predictedTokens.count,
                expectedTokens: expectedTokens.count
            )
        }

        var predictedCounts: [String: Int] = [:]
        var expectedCounts: [String: Int] = [:]
        for token in predictedTokens {
            predictedCounts[token, default: 0] += 1
        }
        for token in expectedTokens {
            expectedCounts[token, default: 0] += 1
        }

        var overlap = 0
        for (token, count) in predictedCounts {
            if let expectedCount = expectedCounts[token] {
                overlap += min(count, expectedCount)
            }
        }

        if overlap == 0 {
            return LongMemoryAnswerOverlap(
                f1: 0,
                precision: 0,
                recall: 0,
                overlapTokens: 0,
                predictedTokens: predictedTokens.count,
                expectedTokens: expectedTokens.count
            )
        }

        let precision = Double(overlap) / Double(predictedTokens.count)
        let recall = Double(overlap) / Double(expectedTokens.count)
        let denom = precision + recall
        let f1 = denom > 0 ? (2 * precision * recall / denom) : 0
        return LongMemoryAnswerOverlap(
            f1: f1,
            precision: precision,
            recall: recall,
            overlapTokens: overlap,
            predictedTokens: predictedTokens.count,
            expectedTokens: expectedTokens.count
        )
    }

    private static func bucket(
        hitAtK: Bool,
        selectedDocID: String?,
        expectedDocIDs: Set<String>,
        requiredDocumentHits: Int,
        overlap: LongMemoryAnswerOverlap?
    ) -> LongMemoryAnswerBucket {
        guard hitAtK else { return .retrievalMiss }
        guard let overlap else { return .missingContext }
        if overlap.f1 >= 0.30 {
            return .success
        }
        if requiredDocumentHits > 1, overlap.recall < 0.99 {
            return .multiHopPartial
        }
        guard let selectedDocID else { return .missingContext }
        if !expectedDocIDs.contains(selectedDocID) {
            return .wrongContext
        }
        if overlap.predictedTokens >= max(overlap.expectedTokens * 3, overlap.expectedTokens + 6),
           overlap.precision < 0.35 {
            return .verbosePrecisionLoss
        }
        return .lowOverlap
    }

    private static func failureBucketCounts(_ diagnostics: [LongMemoryQueryDiagnostics]) -> [String: Int] {
        diagnostics.reduce(into: [:]) { acc, entry in
            acc[entry.bucket, default: 0] += 1
        }
    }

    private static func queryEmbedding(
        _ query: String,
        embedder: DeterministicEmbedder?
    ) async throws -> [Float]? {
        guard let embedder else { return nil }
        let raw = try await embedder.embed(query)
        return embedder.normalize ? VectorMath.normalizeL2(raw) : raw
    }

    private func resolveDocIDs(
        from results: [SearchResponse.Result],
        wax: Wax,
        cache: inout [UInt64: String]
    ) async throws -> [String] {
        var ranked: [String] = []
        ranked.reserveCapacity(results.count)

        for result in results {
            if let cached = cache[result.frameId] {
                ranked.append(cached)
                continue
            }

            let meta = try await wax.frameMeta(frameId: result.frameId)
            if let docID = meta.metadata?.entries[benchmarkDocIDKey] {
                cache[result.frameId] = docID
                ranked.append(docID)
            }
        }

        return ranked
    }

    private func buildMetrics(outcomes: [LongMemoryQueryOutcome]) -> LongMemoryMetrics {
        let queryCount = outcomes.count
        let hitCount = outcomes.filter(\.hitAtK).count
        let recallAtK = queryCount > 0 ? Double(hitCount) / Double(queryCount) : 0

        let mrr = queryCount > 0
            ? outcomes.map(\.reciprocalRank).reduce(0, +) / Double(queryCount)
            : 0

        let scored = outcomes.compactMap(\.answerScore)
        let meanJudge = scored.isEmpty ? 0 : scored.reduce(0, +) / Double(scored.count)

        return LongMemoryMetrics(
            queryCount: queryCount,
            hitAtKCount: hitCount,
            recallAtK: recallAtK,
            meanReciprocalRank: mrr,
            judgedQueries: scored.count,
            meanJudgeScore: meanJudge
        )
    }

    private func latencySummary(
        fixture: LongMemoryFixture,
        wax: Wax,
        embedder: DeterministicEmbedder?,
        topK: Int,
        includeVectors: Bool,
        alpha: Float
    ) async throws -> LongMemoryLatencySummary {
        let queryCount = max(1, fixture.queries.count)
        let iterations = min(20, queryCount * 2)
        let cycler = QueryCycler()

        let stats = try await timedSamples(
            label: "long_memory_query_latency",
            iterations: iterations,
            warmup: 1
        ) {
            let index = await cycler.next(max: fixture.queries.count)
            let query = fixture.queries[index]
            let searchQuery = Self.sanitizedQuery(query.text)
            let embedding = try await Self.queryEmbedding(searchQuery, embedder: embedder)
            let request = SearchRequest(
                query: searchQuery,
                embedding: embedding,
                vectorEnginePreference: .cpuOnly,
                mode: includeVectors ? .hybrid(alpha: alpha) : .textOnly,
                topK: topK
            )
            _ = try await wax.search(request)
        }

        return LongMemoryLatencySummary(
            samples: stats.samples.count,
            meanSeconds: stats.mean,
            p95Seconds: stats.p95
        )
    }

    private func printReport(_ report: LongMemoryReport) {
        print("🧪 Long-memory benchmark (\(report.fixtureName))")
        print("   docs=\(report.documentCount) queries=\(report.queryCount) topK=\(report.topK) vectors=\(report.includeVectors)")
        print("   recall@k=\(String(format: "%.3f", report.metrics.recallAtK)) mrr=\(String(format: "%.3f", report.metrics.meanReciprocalRank)) judge=\(String(format: "%.3f", report.metrics.meanJudgeScore))")
        print("   latency mean=\(String(format: "%.4f", report.latency.meanSeconds))s p95=\(String(format: "%.4f", report.latency.p95Seconds))s")

        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        if let data = try? encoder.encode(report),
           let json = String(data: data, encoding: .utf8) {
            print("🧪 Long-memory report JSON")
            print(json)
        }
    }

    private static func printDiagnostics(_ diagnostics: [LongMemoryQueryDiagnostics]) {
        guard !diagnostics.isEmpty else { return }

        let bucketCounts = failureBucketCounts(diagnostics)
        let orderedBuckets = bucketCounts
            .sorted { lhs, rhs in
                if lhs.value != rhs.value { return lhs.value > rhs.value }
                return lhs.key < rhs.key
            }
            .map { "\($0.key)=\($0.value)" }
            .joined(separator: ", ")

        print("🧪 Long-memory diagnostics buckets: \(orderedBuckets)")

        let lowest = diagnostics
            .filter { $0.expectedAnswer != nil }
            .filter { $0.bucket != LongMemoryAnswerBucket.success.rawValue }
            .sorted { lhs, rhs in
                let lhsF1 = lhs.overlap?.f1 ?? 0
                let rhsF1 = rhs.overlap?.f1 ?? 0
                if lhsF1 != rhsF1 { return lhsF1 < rhsF1 }
                return lhs.queryID < rhs.queryID
            }
            .prefix(12)

        guard !lowest.isEmpty else { return }

        for entry in lowest {
            let top3 = Array(entry.topDocumentIDs.prefix(3)).joined(separator: ",")
            let predicted = entry.predictedAnswer?.replacingOccurrences(of: "\n", with: " ") ?? ""
            let expected = entry.expectedAnswer ?? ""
            let f1 = entry.overlap?.f1 ?? 0
            print("🧪 fail query=\(entry.queryID) bucket=\(entry.bucket) f1=\(String(format: "%.3f", f1)) top3=[\(top3)] selected=\(entry.selectedDocumentID ?? "nil")")
            print("   q=\(entry.queryText)")
            print("   expected=\(expected)")
            print("   predicted=\(predicted)")
        }
    }
}
