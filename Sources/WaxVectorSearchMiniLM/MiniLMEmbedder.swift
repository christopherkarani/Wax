import Foundation
import WaxCore
import WaxVectorSearch
@preconcurrency import CoreML
@preconcurrency import OSLog

extension MiniLMEmbeddings: @unchecked Sendable {}

// MARK: - Logging
private let logger = Logger(subsystem: "com.wax.vectormodel", category: "MiniLMEmbedder")

/// High-performance MiniLM embedder with batch support for optimal ANE/GPU utilization.
/// Implements BatchEmbeddingProvider for significant throughput improvements during ingest.
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
    private let maxConcurrentBatches: Int
    private let tokenizationParallelism: Int

    public struct Config {
        public var batchSize: Int
        public var maxConcurrentBatches: Int
        public var tokenizationParallelism: Int
        public var modelConfiguration: MLModelConfiguration?

        public init(
            batchSize: Int = 16,
            maxConcurrentBatches: Int = 2,
            tokenizationParallelism: Int = ProcessInfo.processInfo.activeProcessorCount,
            modelConfiguration: MLModelConfiguration? = nil
        ) {
            self.batchSize = batchSize
            self.maxConcurrentBatches = maxConcurrentBatches
            self.tokenizationParallelism = tokenizationParallelism
            self.modelConfiguration = modelConfiguration
        }
    }

    public init() {
        self.model = MiniLMEmbeddings()
        self.batchSize = 16
        self.maxConcurrentBatches = 2
        self.tokenizationParallelism = ProcessInfo.processInfo.activeProcessorCount
        logComputeUnits()
    }

    public init(model: MiniLMEmbeddings) {
        self.model = model
        self.batchSize = 16
        self.maxConcurrentBatches = 2
        self.tokenizationParallelism = ProcessInfo.processInfo.activeProcessorCount
        logComputeUnits()
    }

    public init(config: Config) {
        self.model = MiniLMEmbeddings(configuration: config.modelConfiguration)
        self.batchSize = max(1, config.batchSize)
        self.maxConcurrentBatches = max(1, config.maxConcurrentBatches)
        self.tokenizationParallelism = max(1, config.tokenizationParallelism)
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
    /// - Sub-batches of 16 texts processed concurrently (optimal for CoreML)
    /// - Up to 8 concurrent sub-batches to saturate compute resources
    /// - Returns embeddings in same order as input texts
    public func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let chunks = texts.chunked(into: batchSize)
        if chunks.count == 1 {
            return try await Self.embedBatchCoreML(
                model: model,
                texts: chunks[0],
                tokenizationParallelism: tokenizationParallelism,
                dimensions: dimensions
            )
        }

        let maxConcurrent = min(maxConcurrentBatches, chunks.count)
        var chunkResults: [[[Float]]] = Array(repeating: [], count: chunks.count)

        try await withThrowingTaskGroup(of: (Int, [[Float]]).self) { group in
            var iterator = chunks.enumerated().makeIterator()

            func enqueue(_ next: (offset: Int, element: [String])) {
                let index = next.offset
                let chunk = next.element
                let model = self.model
                let tokenizationParallelism = self.tokenizationParallelism
                let dimensions = self.dimensions
                group.addTask {
                    let vectors = try await Self.embedBatchCoreML(
                        model: model,
                        texts: chunk,
                        tokenizationParallelism: tokenizationParallelism,
                        dimensions: dimensions
                    )
                    return (index, vectors)
                }
            }

            for _ in 0..<maxConcurrent {
                if let next = iterator.next() {
                    enqueue(next)
                }
            }

            while let result = try await group.next() {
                chunkResults[result.0] = result.1
                if let next = iterator.next() {
                    enqueue(next)
                }
            }
        }

        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        for chunk in chunkResults {
            results.append(contentsOf: chunk)
        }
        return results
    }
    
    /// Core ML batch prediction path (true batching).
    private nonisolated static func embedBatchCoreML(
        model: MiniLMEmbeddings,
        texts: [String],
        tokenizationParallelism: Int,
        dimensions: Int
    ) async throws -> [[Float]] {
        guard let vectors = await model.encode(batch: texts, tokenizationParallelism: tokenizationParallelism) else {
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

    public func prewarm() async throws {
        _ = try await embed(" ")
    }
}

// MARK: - Array Chunking Extension

private extension Array {
    /// Splits the array into chunks of the specified size.
    func chunked(into size: Int) -> [[Element]] {
        guard size > 0 else { return [self] }
        return stride(from: 0, to: count, by: size).map {
            Array(self[$0..<Swift.min($0 + size, count)])
        }
    }
}
