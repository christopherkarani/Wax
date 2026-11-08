import Foundation
import WaxCore
import WaxVectorSearch
import WaxBertTokenizer
#if canImport(CoreML)
@preconcurrency import CoreML
#if canImport(OSLog)
@preconcurrency import OSLog
#endif

@available(macOS 15.0, iOS 18.0, *)
extension E5Embeddings: @unchecked Sendable {}

/// On-device `intfloat/e5-small-v2` embedder with batch support.
///
/// e5-small-v2 uses the same bert-base-uncased WordPiece vocabulary as MiniLM and Arctic.
/// The model was trained with input prefixes, so ``embedQuery(_:)`` prepends `"query: "` and
/// the document paths, ``embed(_:)`` and ``embed(batch:)``, prepend `"passage: "`.
/// The model's CoreML graph already includes masked mean pooling and L2 normalization.
@available(macOS 15.0, iOS 18.0, *)
package actor E5Embedder: EmbeddingProvider, BatchEmbeddingProvider, QueryAwareEmbeddingProvider {
    package nonisolated let dimensions: Int = 384
    /// L2 normalization is baked into the CoreML graph (mean pooling + L2 norm),
    /// so the caller (MemoryOrchestrator.embedOne) should NOT re-normalize.
    package nonisolated let normalize: Bool = false
    package nonisolated let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Wax",
        // The suffix marks query/passage-prefixed vectors, so a store written by the earlier
        // unprefixed e5 build refuses to open instead of mixing two embedding spaces.
        model: "E5SmallV2-prefixed",
        dimensions: 384,
        normalized: true
    )

    private nonisolated let model: E5Embeddings

    /// Configurable batch size to balance throughput and memory usage.
    private let batchSize: Int
    private static let maximumBatchSize = 256
    private static let maximumCoreMLPredictionBatchSize = 64
    private var batchInputBuffers: BatchInputBuffers?

    /// The prefixes e5 was trained with: `"query: "` for retrieval queries and
    /// `"passage: "` for the documents they search.
    private static let queryPrefix = "query: "
    private static let passagePrefix = "passage: "

    package struct Config {
        package var batchSize: Int
        package var modelConfiguration: MLModelConfiguration?

        package init(batchSize: Int = 256, modelConfiguration: MLModelConfiguration? = nil) {
            self.batchSize = batchSize
            self.modelConfiguration = modelConfiguration
        }
    }

    private init(model: E5Embeddings, batchSize: Int) {
        self.model = model
        self.batchSize = max(1, batchSize)
        logComputeUnits()
    }

    package init() throws {
        self.model = try E5Embeddings()
        self.batchSize = Self.maximumBatchSize
        logComputeUnits()
    }

    package init(model: E5Embeddings) {
        self.init(model: model, batchSize: Self.maximumBatchSize)
    }

    package init(config: Config) throws {
        self.model = try E5Embeddings(configuration: config.modelConfiguration)
        self.batchSize = max(1, config.batchSize)
        logComputeUnits()
    }

    package init(overrides: E5Embeddings.Overrides, config: Config = Config()) throws {
        self.model = try E5Embeddings(configuration: config.modelConfiguration, overrides: overrides)
        self.batchSize = max(1, config.batchSize)
        logComputeUnits()
    }

    package static func make(
        config: Config = Config(),
        overrides: E5Embeddings.Overrides = .default,
        timeout: Duration,
        skipPrewarm: Bool = false,
        prewarmBatchSize: Int = 1
    ) async throws -> E5Embedder {
        let model = try await E5Embeddings.make(
            configuration: config.modelConfiguration,
            overrides: overrides,
            timeout: timeout
        )
        let embedder = E5Embedder(model: model, batchSize: max(1, config.batchSize))
        if !skipPrewarm {
            try await AsyncTimeout.run(timeout: timeout, operation: "E5 embedder prewarm") {
                try await embedder.prewarm(batchSize: prewarmBatchSize)
            }
        }
        return embedder
    }

    // MARK: - Diagnostics

    package nonisolated func isUsingANE() -> Bool {
        return model.computeUnits == .all || model.computeUnits == .cpuAndNeuralEngine
    }

    package nonisolated func currentComputeUnits() -> MLComputeUnits {
        return model.computeUnits
    }

    private nonisolated func logComputeUnits() {
#if canImport(OSLog)
        let logger = Logger(subsystem: "com.wax.vectormodel", category: "E5Embedder")
        let units = currentComputeUnits()
        let aneAvailable = isUsingANE()
        logger.info("E5Embedder initialized with computeUnits: \(units.rawValue, privacy: .public)")
        logger.info("ANE configured: \(aneAvailable ? "Yes" : "No", privacy: .public)")
#endif
    }

    // MARK: - EmbeddingProvider

    /// Embed document text with the e5 `"passage: "` prefix.
    package func embed(_ text: String) async throws -> [Float] {
        try await encode(Self.passagePrefix + text)
    }

    // MARK: - QueryAwareEmbeddingProvider

    /// Embed a retrieval query with the e5 `"query: "` prefix.
    package func embedQuery(_ text: String) async throws -> [Float] {
        try await encode(Self.queryPrefix + text)
    }

    /// Encodes text that already carries its prefix.
    private func encode(_ prefixedText: String) async throws -> [Float] {
        guard let vector = try await model.encode(sentence: prefixedText) else {
            throw WaxError.io("E5 embedding failed to produce a vector.")
        }
        if vector.count != dimensions {
            throw WaxError.invalidEmbedding(reason: "E5 produced \(vector.count) dims, expected \(dimensions).")
        }
        return vector
    }

    // MARK: - BatchEmbeddingProvider

    /// Embed document texts, each with the e5 `"passage: "` prefix.
    package func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let texts = texts.map { Self.passagePrefix + $0 }
        let plannedBatches = Self.planBatchSizes(for: texts.count, maxBatchSize: batchSize)
        var results = Array(repeating: [Float](), count: texts.count)
        var startIndex = 0
        for size in plannedBatches {
            let batchStart = startIndex
            let batchEnd = batchStart + size
            let chunk = Array(texts[batchStart..<batchEnd])
            if size == 1 {
                results[batchStart] = try await encode(chunk[0])
            } else {
                let embeddings = try await embedBatchCoreML(texts: chunk)
                for (offset, vector) in embeddings.enumerated() {
                    results[batchStart + offset] = vector
                }
            }
            startIndex = batchEnd
        }

        return results
    }

    /// Core ML batch prediction path.
    ///
    /// Tokenization happens synchronously on the actor (needs inout access to buffers),
    /// then prediction is dispatched off the cooperative pool via E5Embeddings.
    private func embedBatchCoreML(texts: [String]) async throws -> [[Float]] {
        guard let vectors = try await model.encode(batch: texts) else {
            throw WaxError.io("E5 batch embedding failed.")
        }
        guard vectors.count == texts.count else {
            throw WaxError.io("E5 batch embedding count mismatch: expected \(texts.count), got \(vectors.count).")
        }
        for vector in vectors {
            if vector.count != dimensions {
                throw WaxError.invalidEmbedding(reason: "E5 produced \(vector.count) dims, expected \(dimensions).")
            }
        }
        return vectors
    }

    package func prewarm(batchSize: Int = 16) async throws {
        _ = try await embed(" ")

        let medium = String(repeating: "token ", count: 12)
        let longer = String(repeating: "token ", count: 30)
        let longest = String(repeating: "token ", count: 60)
        _ = try await embed(longer)
        _ = try await embed(longest)

        let clamped = max(1, min(batchSize, 32))
        if clamped > 1 {
            let batch = Array(repeating: medium, count: clamped)
            _ = try await embed(batch: batch)
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension E5Embedder {
    /// Builds an e5 embedder with CLI/MCP-friendly defaults and compute-unit fallback.
    package static func makeCommandLineEmbedder(
        prewarmBatchSize: Int = 1,
        skipPrewarm: Bool = false,
        computeUnitsOrder: [MLComputeUnits] = [],
        tuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws -> E5Embedder {
        var failures: [String] = []
        let resolvedUnits = resolveComputeUnitsOrder(explicit: computeUnitsOrder, tuning: tuning)
        for units in resolvedUnits {
            let matchingUnit = tuning.computeUnitsOrder.first(where: { $0.coreMLValue == units }) ?? .cpuOnly
            let modelConfiguration = tuning.modelConfiguration(for: matchingUnit)
            do {
                let embedder = try E5Embedder(
                    config: Config(batchSize: tuning.batchSize, modelConfiguration: modelConfiguration)
                )
                // Probe immediately so failing / non-finite compute-unit paths fall through
                // to the next candidate instead of failing later on the first real save/search.
                _ = try await embedder.embed("wax")
                if !skipPrewarm {
                    try await embedder.prewarm(batchSize: prewarmBatchSize)
                }
                return embedder
            } catch {
                failures.append("\(describe(units)): \(error.localizedDescription)")
            }
        }

        throw WaxError.io(
            "E5 init failed for all compute units (\(failures.joined(separator: " | ")))."
        )
    }

    /// e5's fallback order when neither the caller nor `WAX_EMBEDDER_COMPUTE_UNITS` chose one.
    /// It matches Arctic: the graph computes in FP32 over INT8 weights, the Neural Engine runs
    /// it in Float16, and a single startup probe cannot prove that path finite, so ANE is opt-in.
    /// There is no GPU fallback: `E5Embeddings` refuses `.cpuAndGPU`, whose load stalls.
    package static let defaultComputeUnitsOrder: [MLComputeUnits] = [.cpuOnly]

    /// Explicit order wins, then a customized tuning order, then `defaultComputeUnitsOrder`.
    package static func resolveComputeUnitsOrder(
        explicit: [MLComputeUnits],
        tuning: CommandLineEmbedderRuntimeTuning
    ) -> [MLComputeUnits] {
        if !explicit.isEmpty { return explicit }
        if tuning.computeUnitsOrder != CommandLineEmbedderRuntimeTuning.defaultComputeUnitsOrder {
            return tuning.computeUnitsOrder.map(\.coreMLValue)
        }
        return defaultComputeUnitsOrder
    }

    /// Test helper for deterministic batch planning verification.
    package static func _planBatchSizesForTesting(totalCount: Int, maxBatchSize: Int) -> [Int] {
        planBatchSizes(for: totalCount, maxBatchSize: maxBatchSize)
    }
}

@available(macOS 15.0, iOS 18.0, *)
private extension E5Embedder {
    static func describe(_ units: MLComputeUnits) -> String {
        switch units {
        case .all:
            return "all"
        case .cpuAndGPU:
            return "cpuAndGPU"
        case .cpuAndNeuralEngine:
            return "cpuAndNeuralEngine"
        case .cpuOnly:
            return "cpuOnly"
        @unknown default:
            return "unknown(\(units.rawValue))"
        }
    }

    static func planBatchSizes(for totalCount: Int, maxBatchSize: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        let clampedMax = Swift.max(1, Swift.min(maxBatchSize, maximumCoreMLPredictionBatchSize))

        if totalCount <= clampedMax {
            return [totalCount]
        }

        let fullBatchCount = totalCount / clampedMax
        let remainder = totalCount % clampedMax
        var sizes = Array(repeating: clampedMax, count: fullBatchCount)
        if remainder > 0 {
            sizes.append(remainder)
        }

        return sizes
    }
}
#endif // canImport(CoreML)
