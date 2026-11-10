#if canImport(CoreML)
import CoreML
import Foundation
import Testing
import WaxBertTokenizer
@testable import WaxRerankerMiniLM

/// Hugging Face windows and PyTorch fp32 scores, from cross-encoder/ms-marco-MiniLM-L-6-v2 at
/// `max_length=288, stride=64` (three LongMemEval-S sessions per query, plus the model card's
/// Berlin example and an empty document).
struct RerankerReference: Decodable {
    struct Window: Decodable {
        let documentIndex: Int
        let inputIds: [Int32]
        let tokenTypeIds: [Int32]
    }

    struct Case: Decodable {
        let query: String
        let documents: [String]
        let windows: [Window]
        let scores: [Float]
    }

    let cases: [Case]

    static func load() throws -> RerankerReference {
        let url = try #require(Bundle.module.url(forResource: "minilm_reranker_reference", withExtension: "json"))
        return try JSONDecoder().decode(RerankerReference.self, from: Data(contentsOf: url))
    }
}

struct CrossEncoderWindowingTests {
    let windowing = CrossEncoderWindowing(maxLength: 16, stride: 3, maxQueryTokens: 4, maxWindowsPerDocument: 16)

    @Test func shortDocumentIsOneWindowWithSegmentIds() {
        let rows = windowing.windows(queryTokens: [7, 8], documentTokens: [[20, 21, 22]], clsToken: 101, sepToken: 102)
        #expect(rows == [CrossEncoderWindow(
            documentIndex: 0,
            inputIds: [101, 7, 8, 102, 20, 21, 22, 102],
            tokenTypeIds: [0, 0, 0, 0, 1, 1, 1, 1]
        )])
    }

    @Test func longDocumentSplitsIntoOverlappingWindows() {
        // 16 - 2 query - 3 special = 11 document tokens per window, each starting 8 after the last.
        let document = Array(0..<25)
        let rows = windowing.windows(queryTokens: [7, 8], documentTokens: [document], clsToken: 101, sepToken: 102)
        let bodies = rows.map { Array($0.inputIds.dropFirst(4).dropLast()).map(Int.init) }
        #expect(bodies == [Array(0..<11), Array(8..<19), Array(16..<25)])
        #expect(rows.allSatisfy { $0.inputIds.count <= 16 && $0.documentIndex == 0 })
    }

    @Test func emptyDocumentStillGetsOneWindow() {
        let rows = windowing.windows(queryTokens: [7], documentTokens: [[]], clsToken: 101, sepToken: 102)
        #expect(rows.map(\.inputIds) == [[101, 7, 102, 102]])
    }

    @Test func longQueryIsTruncatedAndWindowsAreCapped() {
        let capped = CrossEncoderWindowing(maxLength: 16, stride: 0, maxQueryTokens: 4, maxWindowsPerDocument: 2)
        let rows = capped.windows(
            queryTokens: Array(1...10),
            documentTokens: [Array(100..<200), [5]],
            clsToken: 101,
            sepToken: 102
        )
        #expect(rows.map(\.documentIndex) == [0, 0, 1])
        #expect(rows.allSatisfy { Array($0.inputIds.prefix(6)) == [101, 1, 2, 3, 4, 102] })
        #expect(rows[1].inputIds.dropFirst(6).first == 109)
    }

    @Test func strideAtLeastTheWindowFallsBackToNoOverlap() {
        let wide = CrossEncoderWindowing(maxLength: 8, stride: 50, maxQueryTokens: 1, maxWindowsPerDocument: 16)
        let rows = wide.windows(queryTokens: [7], documentTokens: [Array(0..<9)], clsToken: 101, sepToken: 102)
        // 8 - 1 - 3 = 4 tokens per window, no overlap.
        let documentTokens: [[Int]] = rows.map { (row: CrossEncoderWindow) -> [Int] in
            row.inputIds.dropFirst(3).dropLast().map { Int($0) }
        }
        let expected: [[Int]] = [[0, 1, 2, 3], [4, 5, 6, 7], [8]]
        #expect(documentTokens == expected)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test func matchesHuggingFaceWindowsOnReferenceText() throws {
        let reference = try RerankerReference.load()
        let tokenizer = try BertTokenizer()
        for item in reference.cases {
            let rows = try MiniLMReranker.windows(
                query: item.query,
                documents: item.documents,
                tokenizer: tokenizer,
                windowing: MiniLMReranker.defaultWindowing
            )
            #expect(rows.map(\.inputIds) == item.windows.map(\.inputIds), "query: \(item.query)")
            #expect(rows.map(\.tokenTypeIds) == item.windows.map(\.tokenTypeIds))
            #expect(rows.map(\.documentIndex) == item.windows.map(\.documentIndex))
        }
    }
}

struct BertCleanTextTests {
    @available(macOS 15.0, iOS 18.0, *)
    @Test func dropsFormatAndControlScalarsButKeepsWhitespace() {
        #expect(MiniLMReranker.cleanedForBert("if:\u{200B}\nThe\u{0}\u{FFFD} a\tb\r") == "if:\nThe a\tb\r")
        #expect(MiniLMReranker.cleanedForBert("caf\u{E9} \u{1F600}") == "caf\u{E9} \u{1F600}")
    }
}

struct MiniLMRerankerOutputTests {
    /// Measured on CPU: batches of 8 were fastest (LongMemEval N=20: 297 ms p50 vs 355 ms at 64;
    /// LoCoMo N=50: 89 ms vs 135 ms), because length-sorted windows pad less in small batches.
    @available(macOS 15.0, iOS 18.0, *)
    @Test func defaultBatchSizeIsTheMeasuredFastest() {
        #expect(MiniLMReranker.defaultBatchSize == 8)
        #expect(MiniLMReranker.defaultBatchSize <= MiniLMRerankerModel.maximumPredictionBatchSize)
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test func decodesOneScorePerRow() throws {
        let array = try MLMultiArray(shape: [3, 1], dataType: .float32)
        for (index, value) in [Float(1.5), -2, 0.25].enumerated() {
            array[index] = NSNumber(value: value)
        }
        #expect(try MiniLMRerankerModel.decode(array, batchSize: 3) == [1.5, -2, 0.25])
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test func rejectsTheWrongShapeTypeOrNonFiniteScores() throws {
        let wide = try MLMultiArray(shape: [2, 2], dataType: .float32)
        #expect(throws: MiniLMRerankerModel.OutputError.unexpectedShape(shape: [2, 2], batchSize: 2)) {
            try MiniLMRerankerModel.decode(wide, batchSize: 2)
        }
        let doubles = try MLMultiArray(shape: [1, 1], dataType: .double)
        #expect(throws: MiniLMRerankerModel.OutputError.unsupportedDataType(rawValue: MLMultiArrayDataType.double.rawValue)) {
            try MiniLMRerankerModel.decode(doubles, batchSize: 1)
        }
        let nan = try MLMultiArray(shape: [1, 1], dataType: .float32)
        nan[0] = NSNumber(value: Float.nan)
        #expect(throws: MiniLMRerankerModel.OutputError.nonFiniteValue) {
            try MiniLMRerankerModel.decode(nan, batchSize: 1)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test func bucketsPadToTheSmallestFittingLength() {
        #expect(MiniLMRerankerModel.bucket(for: 5) == 32)
        #expect(MiniLMRerankerModel.bucket(for: 200) == 256)
        #expect(MiniLMRerankerModel.bucket(for: 288) == 288)
    }
}

/// Real Core ML inference against the bundled model. Guarded by WAX_TEST_RERANKER=1, like the
/// embedders' inference suites.
@Suite(.disabled(if: ProcessInfo.processInfo.environment["WAX_TEST_RERANKER"] != "1",
                 "Set WAX_TEST_RERANKER=1 to run MiniLM reranker inference tests"))
struct MiniLMRerankerInferenceTests {
    /// INT8 weights and FP16 compute against PyTorch fp32: max |d| 0.084 logits on the CPU and
    /// 0.020 on the GPU over the 12 reference scores (scores span about -11.5 to 8.6). Retrieval
    /// matched the FP32 graph: LongMemEval R_all@5 0.938 both, LoCoMo 0.6085 against 0.6091.
    static let tolerance: Float = 0.1

    @available(macOS 15.0, iOS 18.0, *)
    @Test(arguments: [MLComputeUnits.cpuOnly, .cpuAndGPU, .all])
    func scoresMatchPyTorch(computeUnits: MLComputeUnits) async throws {
        let reference = try RerankerReference.load()
        let reranker = try await MiniLMReranker.make(computeUnits: computeUnits, timeout: .seconds(300))
        for item in reference.cases {
            let scores = try await reranker.scores(query: item.query, documents: item.documents)
            #expect(scores.count == item.scores.count)
            for (actual, expected) in zip(scores, item.scores) {
                #expect(abs(actual - expected) < Self.tolerance, "\(item.query): \(actual) vs \(expected)")
            }
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test func batchSizeDoesNotChangeScores() async throws {
        let reference = try RerankerReference.load()
        let model = try MiniLMRerankerModel.bundled(computeUnits: .cpuOnly)
        let single = try MiniLMReranker(model: model, tokenizer: BertTokenizer(), batchSize: 1)
        let batched = try MiniLMReranker(model: model, tokenizer: BertTokenizer(), batchSize: 64)
        let item = reference.cases[0]
        let a = try await single.scores(query: item.query, documents: item.documents)
        let b = try await batched.scores(query: item.query, documents: item.documents)
        for (x, y) in zip(a, b) {
            #expect(abs(x - y) < 1e-3)
        }
    }

    @available(macOS 15.0, iOS 18.0, *)
    @Test func noDocumentsMeansNoPrediction() async throws {
        let reranker = try await MiniLMReranker.make(timeout: .seconds(300))
        #expect(try await reranker.scores(query: "anything", documents: []).isEmpty)
    }
}
#endif
