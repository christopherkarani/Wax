import Foundation
import WaxBertTokenizer
import WaxCore
import WaxMILRuntime

/// A model run by WaxMILRuntime returned an output the caller cannot use.
package enum MILEncoderOutputError: LocalizedError, Sendable, Equatable {
    case missingOutput(name: String)
    case unexpectedShape(shape: [Int], rows: Int, columns: Int)
    case nonFiniteValue

    package var errorDescription: String? {
        switch self {
        case .missingOutput(let name):
            "The WaxMILRuntime prediction has no output named '\(name)'."
        case .unexpectedShape(let shape, let rows, let columns):
            "The WaxMILRuntime output shape \(shape) does not hold \(rows) rows of \(columns) values."
        case .nonFiniteValue:
            "The WaxMILRuntime output contains a non-finite value."
        }
    }
}

/// Locates and loads the bundled `.mlmodelc` directories for WaxMILRuntime.
package enum MILBundledModels {
    private static let cache = KeyedLoadCache<String, MILModel>()

    /// The model in `directory`, parsed and prepared once per process. Concurrent callers for
    /// the same directory share one load.
    package static func model(at directory: URL) throws -> MILModel {
        let key = directory.standardizedFileURL.path
        return try cache.value(for: key) { try MILModel(contentsOf: directory) }
    }

    /// The `<name>.mlmodelc` directory in a target's SwiftPM resource bundle.
    ///
    /// SwiftPM names the bundle `<bundleBaseName>.bundle` on Apple platforms and
    /// `<bundleBaseName>.resources` elsewhere. Directories next to the (symlink-resolved)
    /// executable are searched before `module`, the target's `Bundle.module`.
    package static func modelDirectory(
        named name: String,
        bundleBaseName: String,
        module: @autoclosure () -> Bundle
    ) -> URL? {
        #if canImport(Darwin)
        let bundleName = bundleBaseName + ".bundle"
        #else
        let bundleName = bundleBaseName + ".resources"
        #endif
        let bundle = WaxBundleResolver.resolveModule(named: bundleName, moduleFallback: module())
        if let url = bundle.url(forResource: name, withExtension: "mlmodelc") {
            return url
        }
        guard let resources = bundle.resourceURL else { return nil }
        let candidate = resources.appendingPathComponent(name + ".mlmodelc", isDirectory: true)
        let program = candidate.appendingPathComponent("model.mil")
        return FileManager.default.fileExists(atPath: program.path) ? candidate : nil
    }

    /// Reads `rows` x `columns` values from a `[rows, columns]` output, rejecting any other shape
    /// and any non-finite value.
    package static func rows(_ output: MILOutput, rows: Int, columns: Int) throws -> [[Float]] {
        guard output.shape == [rows, columns], output.values.count == rows * columns else {
            throw MILEncoderOutputError.unexpectedShape(shape: output.shape, rows: rows, columns: columns)
        }
        guard output.values.allSatisfy(\.isFinite) else {
            throw MILEncoderOutputError.nonFiniteValue
        }
        return (0..<rows).map { row in
            Array(output.values[(row * columns)..<((row + 1) * columns)])
        }
    }
}

/// A BERT sentence-embedding graph run by WaxMILRuntime: WordPiece-tokenizes text, runs the
/// graph and returns its `[batch, dimension]` output. Pooling and any normalisation are the
/// graph's; this type adds none.
package final class MILSentenceEncoder: Sendable {
    package let model: MILModel
    package let tokenizer: BertTokenizer
    /// Tokens per row, `[CLS]` and `[SEP]` included; longer text is truncated.
    package let maxSequenceLength: Int
    package let outputName: String
    package let dimension: Int

    package init(
        model: MILModel,
        tokenizer: BertTokenizer,
        maxSequenceLength: Int,
        outputName: String,
        dimension: Int
    ) {
        self.model = model
        self.tokenizer = tokenizer
        self.maxSequenceLength = maxSequenceLength
        self.outputName = outputName
        self.dimension = dimension
    }

    /// One vector per sentence, in order. Rows are padded to the longest row; padding is masked.
    ///
    /// Blocks the calling thread while the interpreter's worker threads run.
    package func encodeBlocking(_ sentences: [String]) throws -> [[Float]] {
        guard !sentences.isEmpty else { return [] }
        let batch = try tokenizer.buildTokenIDBatch(sentences: sentences, maxSequenceLength: maxSequenceLength)
        let outputs = try model.predict(inputIDs: batch.inputIDs, attentionMask: batch.attentionMask)
        guard let output = outputs[outputName] else {
            throw MILEncoderOutputError.missingOutput(name: outputName)
        }
        return try MILBundledModels.rows(output, rows: sentences.count, columns: dimension)
    }

    /// `encodeBlocking` on a GCD thread, so the interpreter's `concurrentPerform` never holds a
    /// Swift concurrency cooperative thread.
    package func encode(_ sentences: [String]) async throws -> [[Float]] {
        try await BlockingWork.run { [self] () throws -> [[Float]] in
            try encodeBlocking(sentences)
        }
    }
}
