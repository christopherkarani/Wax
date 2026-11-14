import Foundation
import Testing
import WaxMILRuntime

/// End-to-end runs of the four bundled programs on synthetic token ids. These check structure
/// (shapes, finiteness, normalisation, batching and padding invariance); numerical parity with
/// the original checkpoints is in `MILReferenceParityTests`.
struct MILBundledModelTests {
    static let cls: Int32 = 101
    static let sep: Int32 = 102

    /// [CLS] body [SEP] with deterministic word-piece ids from the ordinary vocabulary range.
    static func sequence(length: Int, seed: UInt64) -> [Int32] {
        var rng = SplitMix64(seed: seed)
        let body = (0..<(length - 2)).map { _ in Int32.random(in: 1000..<29000, using: &rng) }
        return [cls] + body + [sep]
    }

    /// Cross-encoder segment ids: 0 for "[CLS] query [SEP]", 1 for "document [SEP]".
    static func segments(length: Int) -> [Int32] {
        let split = length / 2
        return (0..<length).map { $0 < split ? 0 : 1 }
    }

    static func run(_ model: BundledModel, _ rows: [[Int32]], padTo width: Int? = nil) throws -> MILOutput {
        let width = width ?? rows.map(\.count).max() ?? 0
        let ids = rows.map { $0 + [Int32](repeating: 0, count: width - $0.count) }
        let mask = rows.map { [Int32](repeating: 1, count: $0.count) + [Int32](repeating: 0, count: width - $0.count) }
        let types = model == .reranker
            ? rows.map { segments(length: $0.count) + [Int32](repeating: 0, count: width - $0.count) }
            : nil
        let outputs = try model.model.predict(inputIDs: ids, attentionMask: mask, tokenTypeIDs: types)
        return try #require(outputs[model.outputName])
    }

    static func rows(_ output: MILOutput) -> [[Float]] {
        let width = output.shape.last ?? 0
        return stride(from: 0, to: output.values.count, by: width).map { Array(output.values[$0..<($0 + width)]) }
    }

    static func expectSame(_ a: [Float], _ b: [Float], _ model: BundledModel, _ what: String) {
        if model == .reranker {
            #expect(abs(a[0] - b[0]) <= 1e-3, "\(model) \(what): \(a[0]) vs \(b[0])")
        } else {
            let similarity = cosine(a, b)
            #expect(similarity >= 0.999_99, "\(model) \(what): cosine \(similarity)")
            #expect(maxAbsDifference(a, b) <= 1e-3, "\(model) \(what): max |diff| \(maxAbsDifference(a, b))")
        }
    }

    @Test(arguments: BundledModel.allCases)
    func producesFiniteOutputOfTheDeclaredShape(model: BundledModel) throws {
        let output = try Self.run(model, [Self.sequence(length: 12, seed: 7)])
        #expect(output.shape == (model == .reranker ? [1, 1] : [1, 384]))
        #expect(output.values.allSatisfy { $0.isFinite })
        if model.normalisesOutput {
            #expect(abs(l2Norm(output.values[...]) - 1) <= 1e-4, "\(model) norm \(l2Norm(output.values[...]))")
        } else if model == .miniLM {
            // Mean pooling without normalisation: a non-degenerate vector.
            #expect(l2Norm(output.values[...]) > 0.1)
        }
    }

    @Test(arguments: BundledModel.allCases)
    func aBatchOfTwoMatchesTwoSingleRuns(model: BundledModel) throws {
        let a = Self.sequence(length: 9, seed: 11)
        let b = Self.sequence(length: 14, seed: 12)
        let batch = try Self.run(model, [a, b])
        #expect(batch.shape.first == 2)
        let rows = Self.rows(batch)
        Self.expectSame(rows[0], try Self.run(model, [a]).values, model, "row 0 (padded 9 -> 14)")
        Self.expectSame(rows[1], try Self.run(model, [b]).values, model, "row 1")
        if model == .reranker {
            #expect(abs(rows[0][0] - rows[1][0]) > 1e-3, "different inputs gave the same score")
        } else {
            #expect(cosine(rows[0], rows[1]) < 0.9999, "\(model): different inputs gave the same output")
        }
    }

    @Test(arguments: BundledModel.allCases)
    func maskedPaddingDoesNotChangeTheOutput(model: BundledModel) throws {
        let tokens = Self.sequence(length: 10, seed: 21)
        let unpadded = try Self.run(model, [tokens]).values
        let padded = try Self.run(model, [tokens], padTo: 32).values
        Self.expectSame(padded, unpadded, model, "10 tokens padded to 32")
    }

    @Test func concurrentPredictionsOnOneModelAgree() async throws {
        let model = try BundledModel.miniLM.model
        let tokens = Self.sequence(length: 16, seed: 31)
        let mask = [Int32](repeating: 1, count: tokens.count)
        let expected = try model.predict(inputIDs: [tokens], attentionMask: [mask])["embeddings"]
        let results = try await withThrowingTaskGroup(of: MILOutput?.self) { group -> [MILOutput?] in
            for _ in 0..<4 {
                group.addTask { @Sendable () throws -> MILOutput? in
                    try model.predict(inputIDs: [tokens], attentionMask: [mask])["embeddings"]
                }
            }
            var collected: [MILOutput?] = []
            for try await result in group { collected.append(result) }
            return collected
        }
        #expect(results.count == 4)
        #expect(results.allSatisfy { $0 == expected })
    }

    @Test func rejectsMisshapenOrUnexpectedTokenInputs() throws {
        let model = try BundledModel.miniLM.model
        #expect(throws: MILRuntimeError.self) {
            try model.predict(inputIDs: [[101, 102], [101]], attentionMask: [[1, 1], [1]])
        }
        #expect(throws: MILRuntimeError.self) {
            try model.predict(inputIDs: [101, 102], attentionMask: [1, 1, 1], shape: [1, 2])
        }
        #expect(throws: MILRuntimeError.unexpectedInput("token_type_ids")) {
            try model.predict(inputIDs: [[101, 102]], attentionMask: [[1, 1]], tokenTypeIDs: [[0, 0]])
        }
    }
}
