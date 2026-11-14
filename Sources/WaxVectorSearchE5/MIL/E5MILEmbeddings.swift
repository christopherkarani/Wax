import Foundation
import WaxBertTokenizer
import WaxCore
import WaxMILEncoder

/// `intfloat/e5-small-v2` run by WaxMILRuntime, without Core ML: the bundled `.mlmodelc` graph,
/// tokenizer and 512-token truncation that the Core ML `E5Embeddings` uses.
///
/// The graph mean-pools over `attention_mask` and L2-normalises (output `embeddings`,
/// `[batch, 384]`), so its output is the final embedding. Text is encoded as given: the
/// `"query: "` / `"passage: "` prefixes are added by `E5Embedder`. On platforms without Core ML
/// this is `E5Embeddings`. It is built everywhere so Apple test runs can compare the two runtimes.
package final class E5MILEmbeddings: Sendable {
    package enum InitError: LocalizedError, Sendable {
        case missingModelResource
        case modelLoadFailed(String)
        case tokenizerLoadFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingModelResource:
                return "Could not find the e5-small-v2 model resource in the WaxVectorSearchE5 bundle."
            case .modelLoadFailed(let details):
                return "Failed to load the e5-small-v2 model in WaxMILRuntime: \(details)"
            case .tokenizerLoadFailed(let details):
                return "Failed to initialize tokenizer: \(details)"
            }
        }
    }

    package struct Overrides: Sendable {
        var modelURLProvider: (@Sendable () -> URL?)?
        var tokenizerFactory: (@Sendable () throws -> BertTokenizer)?
        var usesBundleFallback: Bool
        var blockingModelLoadDelay: Duration?

        static let `default` = Overrides(
            modelURLProvider: nil,
            tokenizerFactory: nil,
            usesBundleFallback: true,
            blockingModelLoadDelay: nil
        )

        static let missingModel = Overrides(
            modelURLProvider: { nil },
            tokenizerFactory: nil,
            usesBundleFallback: false,
            blockingModelLoadDelay: nil
        )

        static let missingTokenizer = Overrides(
            modelURLProvider: nil,
            tokenizerFactory: { throw InitError.tokenizerLoadFailed("override requested failure") },
            usesBundleFallback: true,
            blockingModelLoadDelay: nil
        )
    }

    /// The tokenizer's 512-token maximum, as the Core ML wrapper uses.
    package static let maxSequenceLength = 512
    package let inputDimension: Int = E5MILEmbeddings.maxSequenceLength
    package let outputDimension: Int = 384
    package let encoder: MILSentenceEncoder

    package var tokenizer: BertTokenizer { encoder.tokenizer }

    package convenience init() throws {
        try self.init(overrides: .default)
    }

    init(overrides: Overrides) throws {
        let tokenizer: BertTokenizer
        do {
            tokenizer = try overrides.tokenizerFactory?() ?? BertTokenizer()
        } catch let error as InitError {
            throw error
        } catch {
            throw InitError.tokenizerLoadFailed(error.localizedDescription)
        }
        Self.applyBlockingLoadDelay(overrides)
        let directory: URL
        if let modelURLProvider = overrides.modelURLProvider {
            guard let url = modelURLProvider() else { throw InitError.missingModelResource }
            directory = url
        } else {
            guard overrides.usesBundleFallback, let url = Self.bundledModelDirectory() else {
                throw InitError.missingModelResource
            }
            directory = url
        }
        do {
            encoder = MILSentenceEncoder(
                model: try MILBundledModels.model(at: directory),
                tokenizer: tokenizer,
                maxSequenceLength: Self.maxSequenceLength,
                outputName: "embeddings",
                dimension: 384
            )
        } catch {
            throw InitError.modelLoadFailed(String(describing: error))
        }
    }

    /// Loads under `timeout` on a GCD thread: parsing and dequantising the weights blocks.
    package static func make(overrides: Overrides = .default, timeout: Duration) async throws -> E5MILEmbeddings {
        try await AsyncTimeout.run(timeout: timeout, operation: "E5 model load") {
            try await BlockingWork.run { () throws -> E5MILEmbeddings in
                try E5MILEmbeddings(overrides: overrides)
            }
        }
    }

    package static func bundledModelDirectory() -> URL? {
        MILBundledModels.modelDirectory(
            named: "e5-small-v2",
            bundleBaseName: "Wax_WaxVectorSearchE5",
            module: .module
        )
    }

    /// The unit-length embedding of `sentence`, which must already carry its prefix.
    package func encode(sentence: String) async throws -> [Float]? {
        try await encoder.encode([sentence]).first
    }

    /// Unit-length embeddings, one per (already prefixed) sentence, in order.
    package func encode(batch sentences: [String]) async throws -> [[Float]]? {
        try await encoder.encode(sentences)
    }

    private static func applyBlockingLoadDelay(_ overrides: Overrides) {
        guard let delay = overrides.blockingModelLoadDelay else { return }
        let components = delay.components
        let interval = TimeInterval(components.seconds)
            + TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }
}

#if !canImport(CoreML)
/// Without Core ML, the e5 model runs on WaxMILRuntime.
package typealias E5Embeddings = E5MILEmbeddings
#endif
