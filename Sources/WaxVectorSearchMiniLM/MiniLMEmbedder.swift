import Foundation
import WaxCore
import WaxVectorSearch
#if canImport(CoreML)
@preconcurrency import CoreML
#if canImport(OSLog)
import OSLog
#endif

extension MiniLMEmbeddings: @unchecked Sendable {}

// MARK: - Logging
private let logger = Logger(subsystem: "com.wax.vectormodel", category: "MiniLMEmbedder")

/// High-performance MiniLM embedder with batch support for optimal ANE/GPU utilization.
/// Implements BatchEmbeddingProvider for significant throughput improvements during ingest.
@available(macOS 15.0, iOS 18.0, *)
public actor MiniLMEmbedder: EmbeddingProvider, BatchEmbeddingProvider {
    public nonisolated let dimensions: Int = 384
    public nonisolated let normalize: Bool = true
    public nonisolated let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Wax",
        model: "MiniLMAll",
        dimensions: 384,
        normalized: true
    )

    private nonisolated let model: MiniLMEmbeddings
    
    /// Configurable batch size to balance throughput and memory usage.
    private let batchSize: Int
    private static let maximumBatchSize = 256
    private var batchInputBuffers: BatchInputBuffers?

    public struct Config {
        public var batchSize: Int
        public var modelConfiguration: MLModelConfiguration?

        public init(batchSize: Int = 256, modelConfiguration: MLModelConfiguration? = nil) {
            self.batchSize = batchSize
            self.modelConfiguration = modelConfiguration
        }
    }

    public init() throws {
        self.model = try MiniLMEmbeddings()
        self.batchSize = Self.maximumBatchSize
        logComputeUnits()
    }

    public init(model: MiniLMEmbeddings) {
        self.model = model
        self.batchSize = Self.maximumBatchSize
        logComputeUnits()
    }

    public init(config: Config) throws {
        self.model = try MiniLMEmbeddings(configuration: config.modelConfiguration)
        self.batchSize = max(1, config.batchSize)
        logComputeUnits()
    }

    public init(overrides: MiniLMEmbeddings.Overrides, config: Config = Config()) throws {
        self.model = try MiniLMEmbeddings(configuration: config.modelConfiguration, overrides: overrides)
        self.batchSize = max(1, config.batchSize)
        logComputeUnits()
    }

    // MARK: - Diagnostics

    /// Checks if the model is configured to use the Apple Neural Engine (ANE).
    /// Note: This checks the configuration preference, not whether ANE is actually being used at runtime.
    public nonisolated func isUsingANE() -> Bool {
        return model.computeUnits == .all || model.computeUnits == .cpuAndNeuralEngine
    }

    /// Returns the current compute units configuration.
    public nonisolated func currentComputeUnits() -> MLComputeUnits {
        return model.computeUnits
    }

    private nonisolated func logComputeUnits() {
        let units = currentComputeUnits()
        let aneAvailable = isUsingANE()
        logger.info("MiniLMEmbedder initialized with computeUnits: \(units.rawValue, privacy: .public)")
        logger.info("ANE configured: \(aneAvailable ? "Yes" : "No", privacy: .public)")

        // TODO: Expose MLModelConfiguration knobs (e.g. low-precision accumulation) for more tuning.
    }

    public func embed(_ text: String) async throws -> [Float] {
        guard let vector = await model.encode(sentence: text) else {
            throw WaxError.io("MiniLMAll embedding failed to produce a vector.")
        }
        if vector.count != dimensions {
            throw WaxError.io("MiniLMAll produced \(vector.count) dims, expected \(dimensions).")
        }
        return vector
    }
    
    /// Batch embed multiple texts using Core ML batch prediction for optimal ANE/GPU utilization.
    ///
    /// Performance characteristics:
    /// - Uses exact batch sizes (no padding waste)
    /// - Streams batches with limited concurrency to avoid memory spikes
    /// - Returns embeddings in same order as input texts
    public func embed(batch texts: [String]) async throws -> [[Float]] {
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
    
    /// Core ML batch prediction path (true batching).
    private func embedBatchCoreML(texts: [String]) async throws -> [[Float]] {
        guard let vectors = model.encode(batch: texts, reuseBuffers: &batchInputBuffers) else {
            throw WaxError.io("MiniLMAll batch embedding failed.")
        }
        guard vectors.count == texts.count else {
            throw WaxError.io("MiniLMAll batch embedding count mismatch: expected \(texts.count), got \(vectors.count).")
        }
        for vector in vectors {
            if vector.count != dimensions {
                throw WaxError.io("MiniLMAll produced \(vector.count) dims, expected \(dimensions).")
            }
        }
        return vectors
    }

    public func prewarm(batchSize: Int = 16) async throws {
        _ = try await embed(" ")
        let clamped = max(1, min(batchSize, 32))
        if clamped > 1 {
            let batch = Array(repeating: " ", count: clamped)
            _ = try await embed(batch: batch)
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
extension MiniLMEmbedder {
    /// SPI for deterministic batch planning tests.
    @_spi(Testing)
    public static func _planBatchSizesForTesting(totalCount: Int, maxBatchSize: Int) -> [Int] {
        planBatchSizes(for: totalCount, maxBatchSize: maxBatchSize)
    }
}

private extension MiniLMEmbedder {
    static func planBatchSizes(for totalCount: Int, maxBatchSize: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        let clampedMax = Swift.max(1, maxBatchSize)

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
