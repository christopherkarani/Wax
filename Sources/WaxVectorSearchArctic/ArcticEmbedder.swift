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
extension ArcticEmbeddings: @unchecked Sendable {}

/// High-performance Snowflake Arctic Embed Small embedder with batch and query-aware support.
///
/// Arctic uses the same BERT WordPiece tokenizer as MiniLM but benefits from a query prefix
/// at retrieval time: `"Represent this sentence for searching relevant passages: "`.
/// The model's CoreML graph already includes CLS extraction and L2 normalization.
@available(macOS 15.0, iOS 18.0, *)
package actor ArcticEmbedder: EmbeddingProvider, BatchEmbeddingProvider, QueryAwareEmbeddingProvider {
    package nonisolated let dimensions: Int = 384
    /// L2 normalization is baked into the CoreML graph (CLS extraction + L2 norm),
    /// so the caller (MemoryOrchestrator.embedOne) should NOT re-normalize.
    package nonisolated let normalize: Bool = false
    package nonisolated let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Wax",
        model: "ArcticEmbedS",
        dimensions: 384,
        normalized: true
    )

    private nonisolated let model: ArcticEmbeddings

    /// Configurable batch size to balance throughput and memory usage.
    private let batchSize: Int
    private static let maximumBatchSize = 256
    private static let maximumCoreMLPredictionBatchSize = 64
    private var batchInputBuffers: BatchInputBuffers?

    /// The query prefix recommended by Snowflake for Arctic retrieval tasks.
    private static let queryPrefix = "Represent this sentence for searching relevant passages: "

    package struct Config {
        package var batchSize: Int
        package var modelConfiguration: MLModelConfiguration?

        package init(batchSize: Int = 256, modelConfiguration: MLModelConfiguration? = nil) {
            self.batchSize = batchSize
            self.modelConfiguration = modelConfiguration
        }
    }

    private init(model: ArcticEmbeddings, batchSize: Int) {
        self.model = model
        self.batchSize = max(1, batchSize)
        logComputeUnits()
    }

    package init() throws {
        self.model = try ArcticEmbeddings()
        self.batchSize = Self.maximumBatchSize
        logComputeUnits()
    }

    package init(model: ArcticEmbeddings) {
        self.init(model: model, batchSize: Self.maximumBatchSize)
    }

    package init(config: Config) throws {
        self.model = try ArcticEmbeddings(configuration: config.modelConfiguration)
        self.batchSize = max(1, config.batchSize)
        logComputeUnits()
    }

    package init(overrides: ArcticEmbeddings.Overrides, config: Config = Config()) throws {
        self.model = try ArcticEmbeddings(configuration: config.modelConfiguration, overrides: overrides)
        self.batchSize = max(1, config.batchSize)
        logComputeUnits()
    }

    package static func make(
        config: Config = Config(),
        overrides: ArcticEmbeddings.Overrides = .default,
        timeout: Duration,
        skipPrewarm: Bool = false,
        prewarmBatchSize: Int = 1
    ) async throws -> ArcticEmbedder {
        let model = try await ArcticEmbeddings.make(
            configuration: config.modelConfiguration,
            overrides: overrides,
            timeout: timeout
        )
        let embedder = ArcticEmbedder(model: model, batchSize: max(1, config.batchSize))
        if !skipPrewarm {
            try await AsyncTimeout.run(timeout: timeout, operation: "Arctic embedder prewarm") {
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
        let logger = Logger(subsystem: "com.wax.vectormodel", category: "ArcticEmbedder")
        let units = currentComputeUnits()
        let aneAvailable = isUsingANE()
        logger.info("ArcticEmbedder initialized with computeUnits: \(units.rawValue, privacy: .public)")
        logger.info("ANE configured: \(aneAvailable ? "Yes" : "No", privacy: .public)")
#endif
    }

    // MARK: - EmbeddingProvider

    package func embed(_ text: String) async throws -> [Float] {
        guard let vector = await model.encode(sentence: text) else {
            throw WaxError.io("Arctic embedding failed to produce a vector.")
        }
        if vector.count != dimensions {
            throw WaxError.io("Arctic produced \(vector.count) dims, expected \(dimensions).")
        }
        return vector
    }

    // MARK: - QueryAwareEmbeddingProvider

    /// Embed text with the Arctic query prefix for improved retrieval performance.
    package func embedQuery(_ text: String) async throws -> [Float] {
        return try await embed(Self.queryPrefix + text)
    }

    // MARK: - BatchEmbeddingProvider

    package func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let plannedBatches = Self.planBatchSizes(for: texts.count, maxBatchSize: batchSize)
        var results = Array(repeating: [Float](), count: texts.count)
        var startIndex = 0
        for size in plannedBatches {
            let batchStart = startIndex
            let batchEnd = batchStart + size
            let chunk = Array(texts[batchStart..<batchEnd])
            if size == 1 {
                results[batchStart] = try await embed(chunk[0])
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
    /// then prediction is dispatched off the cooperative pool via ArcticEmbeddings.
    private func embedBatchCoreML(texts: [String]) async throws -> [[Float]] {
        guard let vectors = await model.encode(batch: texts) else {
            throw WaxError.io("Arctic batch embedding failed.")
        }
        guard vectors.count == texts.count else {
            throw WaxError.io("Arctic batch embedding count mismatch: expected \(texts.count), got \(vectors.count).")
        }
        for vector in vectors {
            if vector.count != dimensions {
                throw WaxError.io("Arctic produced \(vector.count) dims, expected \(dimensions).")
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
extension ArcticEmbedder {
    /// Builds an Arctic embedder with CLI/MCP-friendly defaults and compute-unit fallback.
    package static func makeCommandLineEmbedder(
        prewarmBatchSize: Int = 1,
        skipPrewarm: Bool = false,
        computeUnitsOrder: [MLComputeUnits] = [],
        tuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws -> ArcticEmbedder {
        var failures: [String] = []
        let resolvedUnits = computeUnitsOrder.isEmpty
            ? tuning.computeUnitsOrder.map(\.coreMLValue)
            : computeUnitsOrder
        for units in resolvedUnits {
            let matchingUnit = tuning.computeUnitsOrder.first(where: { $0.coreMLValue == units }) ?? .cpuOnly
            let modelConfiguration = tuning.modelConfiguration(for: matchingUnit)
            do {
                let embedder = try ArcticEmbedder(
                    config: Config(batchSize: tuning.batchSize, modelConfiguration: modelConfiguration)
                )
                if !skipPrewarm {
                    try await embedder.prewarm(batchSize: prewarmBatchSize)
                }
                return embedder
            } catch {
                failures.append("\(describe(units)): \(error.localizedDescription)")
            }
        }

        throw WaxError.io(
            "Arctic init failed for all compute units (\(failures.joined(separator: " | ")))."
        )
    }

    /// Test helper for deterministic batch planning verification.
    package static func _planBatchSizesForTesting(totalCount: Int, maxBatchSize: Int) -> [Int] {
        planBatchSizes(for: totalCount, maxBatchSize: maxBatchSize)
    }
}

@available(macOS 15.0, iOS 18.0, *)
private extension ArcticEmbedder {
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
