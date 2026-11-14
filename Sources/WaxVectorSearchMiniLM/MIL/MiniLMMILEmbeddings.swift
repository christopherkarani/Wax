import Foundation
import WaxBertTokenizer
import WaxCore
import WaxMILEncoder

/// all-MiniLM-L6-v2 run by WaxMILRuntime, without Core ML: the bundled `.mlmodelc` graph,
/// tokenizer and 256-token truncation that the Core ML `MiniLMEmbeddings` uses.
///
/// The graph mean-pools token states over `attention_mask` (output `embeddings`, `[batch, 384]`)
/// and does not normalise; `MiniLMEmbedder` L2-normalises. On platforms without Core ML this is
/// `MiniLMEmbeddings`. It is built everywhere so Apple test runs can compare the two runtimes.
package final class MiniLMMILEmbeddings: Sendable {
    package enum InitError: LocalizedError, Sendable {
        case missingModelResource
        case modelLoadFailed(String)
        case tokenizerLoadFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingModelResource:
                return "Could not find the all-MiniLM-L6-v2 model resource in the WaxVectorSearchMiniLM bundle."
            case .modelLoadFailed(let details):
                return "Failed to load the all-MiniLM-L6-v2 model in WaxMILRuntime: \(details)"
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

    /// sentence-transformers all-MiniLM-L6-v2 `max_seq_length`, as in the Core ML wrapper.
    package static let maxSequenceLength = 256
    package let inputDimension: Int = MiniLMMILEmbeddings.maxSequenceLength
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

    /// Loads under `timeout` on a GCD thread: parsing and preparing the weights blocks.
    package static func make(overrides: Overrides = .default, timeout: Duration) async throws -> MiniLMMILEmbeddings {
        try await AsyncTimeout.run(timeout: timeout, operation: "MiniLM model load") {
            try await BlockingWork.run { () throws -> MiniLMMILEmbeddings in
                try MiniLMMILEmbeddings(overrides: overrides)
            }
        }
    }

    package static func bundledModelDirectory() -> URL? {
        MILBundledModels.modelDirectory(
            named: "all-MiniLM-L6-v2",
            bundleBaseName: "Wax_WaxVectorSearchMiniLM",
            module: .module
        )
    }

    /// The mean-pooled, unnormalised embedding of `sentence`.
    package func encode(sentence: String) async throws -> [Float]? {
        try await encoder.encode([sentence]).first
    }

    /// Mean-pooled, unnormalised embeddings, one per sentence, in order.
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
/// Without Core ML, the MiniLM model runs on WaxMILRuntime.
package typealias MiniLMEmbeddings = MiniLMMILEmbeddings
#endif
