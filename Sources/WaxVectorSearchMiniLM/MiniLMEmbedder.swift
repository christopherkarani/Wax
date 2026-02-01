import Foundation
import WaxCore
import WaxVectorSearch
@preconcurrency import CoreML
import OSLog

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
    private static let minimumBatchSize = 64
    private static let maximumBatchSize = 256
    private static let maxConcurrentBatches = 4

    public struct Config {
        public var batchSize: Int
        public var modelConfiguration: MLModelConfiguration?

        public init(batchSize: Int = 256, modelConfiguration: MLModelConfiguration? = nil) {
            self.batchSize = batchSize
            self.modelConfiguration = modelConfiguration
        }
    }

    public init() {
        self.model = MiniLMEmbeddings()
        self.batchSize = Self.maximumBatchSize
        logComputeUnits()
    }

    public init(model: MiniLMEmbeddings) {
        self.model = model
        self.batchSize = Self.maximumBatchSize
        logComputeUnits()
    }

    public init(config: Config) {
        self.model = MiniLMEmbeddings(configuration: config.modelConfiguration)
        self.batchSize = max(1, config.batchSize)
        logComputeUnits()
    }

    // MARK: - Diagnostics

    /// Checks if the model is configured to use the Apple Neural Engine (ANE).
    /// Note: This checks the configuration preference, not whether ANE is actually being used at runtime.
    public nonisolated func isUsingANE() -> Bool {
        return model.computeUnits == .all
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
        var batchIndex = 0

        while batchIndex < plannedBatches.count {
            let windowEnd = Swift.min(batchIndex + Self.maxConcurrentBatches, plannedBatches.count)
            try await withThrowingTaskGroup(of: (Int, [[Float]]).self) { group in
                var localStart = startIndex
                for index in batchIndex..<windowEnd {
                    let size = plannedBatches[index]
                    let batchStart = localStart
                    let batchEnd = batchStart + size
                    let chunk = Array(texts[batchStart..<batchEnd])
                    group.addTask {
                        let embeddings = try await self.embedBatchCoreML(texts: chunk)
                        return (batchStart, embeddings)
                    }
                    localStart = batchEnd
                }

                for try await (batchStart, embeddings) in group {
                    for (offset, vector) in embeddings.enumerated() {
                        results[batchStart + offset] = vector
                    }
                }
            }

            startIndex += plannedBatches[batchIndex..<windowEnd].reduce(0, +)
            batchIndex = windowEnd
        }

        return results
    }
    
    /// Core ML batch prediction path (true batching).
    private nonisolated func embedBatchCoreML(texts: [String]) async throws -> [[Float]] {
        guard let vectors = await model.encode(batch: texts) else {
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

private extension MiniLMEmbedder {
    static func planBatchSizes(for totalCount: Int, maxBatchSize: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        let clampedMax = Swift.max(minimumBatchSize, Swift.min(maxBatchSize, maximumBatchSize))

        if totalCount <= minimumBatchSize {
            return [totalCount]
        }

        if totalCount <= clampedMax {
            return [minimumBatchSize, totalCount - minimumBatchSize]
        }

        var remaining = totalCount
        var sizes: [Int] = []
        sizes.reserveCapacity((totalCount / clampedMax) + 2)

        while remaining > 0 {
            if remaining >= clampedMax {
                sizes.append(clampedMax)
                remaining -= clampedMax
                continue
            }

            if remaining > minimumBatchSize {
                sizes.append(minimumBatchSize)
                remaining -= minimumBatchSize
            } else {
                sizes.append(remaining)
                remaining = 0
            }
        }

        return sizes
    }
}
