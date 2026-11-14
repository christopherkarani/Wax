import Foundation
import Testing
import WaxBertTokenizer
import WaxMILEncoder
import WaxMILRuntime

/// The text-in, vector-out path the built-in embedders use without Core ML: `BertTokenizer`
/// token rows into the bundled graphs.
struct MILSentenceEncoderTests {
    static func encoder(_ model: BundledModel, maxSequenceLength: Int) throws -> MILSentenceEncoder {
        MILSentenceEncoder(
            model: try MILBundledModels.model(at: model.url),
            tokenizer: try BertTokenizer(),
            maxSequenceLength: maxSequenceLength,
            outputName: "embeddings",
            dimension: 384
        )
    }

    /// The fixture texts carry their prefixes (e5 `passage: ` / `query: `, Arctic's query
    /// prefix), so this checks tokenization and the graph together against PyTorch / NumPy.
    @Test(arguments: [BundledModel.miniLM, .e5, .arctic])
    func textMatchesTheReferenceVectors(model: BundledModel) async throws {
        let reference = try MILReference.load().models
        let cases = switch model {
        case .miniLM: reference.minilm.cases
        case .e5: reference.e5.cases
        default: reference.arctic.cases
        }
        let encoder = try Self.encoder(model, maxSequenceLength: model == .miniLM ? 256 : 512)
        let batch = try encoder.tokenizer.buildTokenIDBatch(sentences: cases.map(\.text))
        for (row, item) in zip(batch.inputIDs, cases) {
            #expect(Array(row.prefix(item.inputIDs.count)) == item.inputIDs, "\(model) '\(item.text)'")
        }

        let padded = try await encoder.encode(cases.map(\.text))
        #expect(padded.count == cases.count)
        for (vector, item) in zip(padded, cases) {
            #expect(cosine(vector, item.numpy) >= 0.999_99, "\(model) '\(item.text)' in a padded batch")
            let alone = try await encoder.encode([item.text])[0]
            #expect(cosine(alone, item.numpy) >= 0.999_99, "\(model) '\(item.text)'")
        }
    }

    @Test func truncatesAtMaxSequenceLength() async throws {
        let encoder = try Self.encoder(.miniLM, maxSequenceLength: 256)
        let words = Array(repeating: "memory", count: 300)
        let long = try await encoder.encode([words.joined(separator: " ")])[0]
        let longer = try await encoder.encode([(words + ["extra", "words", "after", "the", "cut"]).joined(separator: " ")])[0]
        #expect(long == longer, "text past 256 tokens must not change the vector")
    }

    @Test func emptyInputNeedsNoPrediction() async throws {
        #expect(try await Self.encoder(.miniLM, maxSequenceLength: 256).encode([]).isEmpty)
    }

    @Test func rowsRejectTheWrongShapeAndNonFiniteValues() throws {
        let good = MILOutput(shape: [2, 2], values: [1, 2, 3, 4])
        #expect(try MILBundledModels.rows(good, rows: 2, columns: 2) == [[1, 2], [3, 4]])
        #expect(throws: MILEncoderOutputError.unexpectedShape(shape: [2, 2], rows: 1, columns: 4)) {
            try MILBundledModels.rows(good, rows: 1, columns: 4)
        }
        let tokens = MILOutput(shape: [1, 2, 2], values: [1, 2, 3, 4])
        #expect(throws: MILEncoderOutputError.unexpectedShape(shape: [1, 2, 2], rows: 1, columns: 2)) {
            try MILBundledModels.rows(tokens, rows: 1, columns: 2)
        }
        let nan = MILOutput(shape: [1, 2], values: [1, .nan])
        #expect(throws: MILEncoderOutputError.nonFiniteValue) {
            try MILBundledModels.rows(nan, rows: 1, columns: 2)
        }
    }

    @Test func aModelDirectoryLoadsOncePerProcess() throws {
        let first = try MILBundledModels.model(at: BundledModel.e5.url)
        let second = try MILBundledModels.model(at: BundledModel.e5.url.appendingPathComponent("."))
        #expect(first === second)
    }
}
