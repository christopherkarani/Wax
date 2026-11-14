import Foundation
import WaxBertTokenizer
import WaxCore
import WaxMILEncoder

/// Snowflake Arctic Embed Small run by WaxMILRuntime, without Core ML: the bundled `.mlmodelc`
/// graph, tokenizer and 512-token truncation that the Core ML `ArcticEmbeddings` uses.
///
/// The graph takes the `[CLS]` token state and L2-normalises it (output `embeddings`,
/// `[batch, 384]`), so its output is the final embedding. Text is encoded as given: the query
/// prefix is added by `ArcticEmbedder`. On platforms without Core ML this is `ArcticEmbeddings`.
/// It is built everywhere so Apple test runs can compare the two runtimes.
package final class ArcticMILEmbeddings: Sendable {
    package enum InitError: LocalizedError, Sendable {
        case missingModelResource
        case modelLoadFailed(String)
        case tokenizerLoadFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingModelResource:
                return "Could not find the snowflake-arctic-embed-s model resource in the WaxVectorSearchArctic bundle."
            case .modelLoadFailed(let details):
                return "Failed to load the snowflake-arctic-embed-s model in WaxMILRuntime: \(details)"
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
    package let inputDimension: Int = ArcticMILEmbeddings.maxSequenceLength
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
    package static func make(overrides: Overrides = .default, timeout: Duration) async throws -> ArcticMILEmbeddings {
        try await AsyncTimeout.run(timeout: timeout, operation: "Arctic model load") {
            try await BlockingWork.run { () throws -> ArcticMILEmbeddings in
                try ArcticMILEmbeddings(overrides: overrides)
            }
        }
    }

    package static func bundledModelDirectory() -> URL? {
        MILBundledModels.modelDirectory(
            named: "snowflake-arctic-embed-s",
            bundleBaseName: "Wax_WaxVectorSearchArctic",
            module: .module
        )
    }

    /// The unit-length embedding of `sentence`, encoded as given.
    package func encode(sentence: String) async throws -> [Float]? {
        try await encoder.encode([sentence]).first
    }

    /// Unit-length embeddings, one per sentence, in order.
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
/// Without Core ML, the Arctic model runs on WaxMILRuntime.
package typealias ArcticEmbeddings = ArcticMILEmbeddings
#endif
