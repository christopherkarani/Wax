#if !canImport(CoreML)
import Foundation
import WaxCore
import WaxVectorSearch

/// Snowflake Arctic Embed Small embedder for platforms without Core ML, running the bundled
/// graph on WaxMILRuntime.
///
/// It records the same identity and adds the same query prefix as the Core ML `ArcticEmbedder`:
/// ``embedQuery(_:)`` prepends `"Represent this sentence for searching relevant passages: "`;
/// documents are embedded as given. The graph takes `[CLS]` and L2-normalizes, so vectors are
/// not re-normalized.
package actor ArcticEmbedder: EmbeddingProvider, BatchEmbeddingProvider, QueryAwareEmbeddingProvider {
    package nonisolated let dimensions: Int = 384
    /// L2 normalization is in the graph, so the caller should not re-normalize.
    package nonisolated let normalize: Bool = false
    /// The identity a store records for vectors from this model (as on Apple platforms).
    package static let bindingIdentity = EmbeddingIdentity(
        provider: "Wax",
        model: "ArcticEmbedS",
        dimensions: 384,
        normalized: true
    )
    package nonisolated let identity: EmbeddingIdentity? = ArcticEmbedder.bindingIdentity

    private nonisolated let model: ArcticEmbeddings
    private let batchSize: Int
    private static let maximumBatchSize = 256
    /// Rows per WaxMILRuntime prediction. Bounds the attention scores' memory
    /// (rows x 12 heads x 512^2 floats) on long texts.
    private static let maximumPredictionBatchSize = 8

    /// The query prefix recommended by Snowflake for Arctic retrieval tasks.
    private static let queryPrefix = "Represent this sentence for searching relevant passages: "

    package struct Config {
        package var batchSize: Int

        package init(batchSize: Int = 256) {
            self.batchSize = batchSize
        }
    }

    private init(model: ArcticEmbeddings, batchSize: Int) {
        self.model = model
        self.batchSize = max(1, batchSize)
    }

    package init() throws {
        self.init(model: try ArcticEmbeddings(), batchSize: Self.maximumBatchSize)
    }

    package init(model: ArcticEmbeddings) {
        self.init(model: model, batchSize: Self.maximumBatchSize)
    }

    package init(config: Config) throws {
        self.init(model: try ArcticEmbeddings(), batchSize: config.batchSize)
    }

    package init(overrides: ArcticEmbeddings.Overrides, config: Config = Config()) throws {
        self.init(model: try ArcticEmbeddings(overrides: overrides), batchSize: config.batchSize)
    }

    package static func make(
        config: Config = Config(),
        overrides: ArcticEmbeddings.Overrides = .default,
        timeout: Duration,
        skipPrewarm: Bool = false,
        prewarmBatchSize: Int = 1
    ) async throws -> ArcticEmbedder {
        let model = try await ArcticEmbeddings.make(overrides: overrides, timeout: timeout)
        let embedder = ArcticEmbedder(model: model, batchSize: config.batchSize)
        if !skipPrewarm {
            try await AsyncTimeout.run(timeout: timeout, operation: "Arctic embedder prewarm") {
                try await embedder.prewarm(batchSize: prewarmBatchSize)
            }
        }
        return embedder
    }

    package func embed(_ text: String) async throws -> [Float] {
        guard let vector = try await model.encode(sentence: text) else {
            throw WaxError.io("Arctic embedding failed to produce a vector.")
        }
        return try checked(vector)
    }

    /// Embed text with the Arctic query prefix for improved retrieval performance.
    package func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(Self.queryPrefix + text)
    }

    package func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        var start = 0
        for size in Self.planBatchSizes(for: texts.count, maxBatchSize: batchSize) {
            let chunk = Array(texts[start..<(start + size)])
            if size == 1 {
                results.append(try await embed(chunk[0]))
            } else {
                guard let vectors = try await model.encode(batch: chunk) else {
                    throw WaxError.io("Arctic batch embedding failed.")
                }
                guard vectors.count == chunk.count else {
                    throw WaxError.io("Arctic batch embedding count mismatch: expected \(chunk.count), got \(vectors.count).")
                }
                for vector in vectors {
                    results.append(try checked(vector))
                }
            }
            start += size
        }
        return results
    }

    /// The model is fully prepared at load; one short run touches the kernels' buffers.
    package func prewarm(batchSize: Int = 16) async throws {
        _ = try await embed(" ")
        let clamped = max(1, min(batchSize, 32))
        if clamped > 1 {
            _ = try await embed(batch: Array(repeating: String(repeating: "token ", count: 12), count: clamped))
        }
    }

    private func checked(_ vector: [Float]) throws -> [Float] {
        guard vector.count == dimensions else {
            throw WaxError.invalidEmbedding(reason: "Arctic produced \(vector.count) dims, expected \(dimensions).")
        }
        return vector
    }
}

extension ArcticEmbedder {
    /// Builds the Arctic embedder for the CLI, MCP server and `BuiltInEmbeddings`.
    ///
    /// Core ML compute units in `tuning` do not apply to WaxMILRuntime, which runs on the CPU;
    /// they are accepted and ignored. The batch size, prewarm batch size and timeout apply.
    package static func makeCommandLineEmbedder(
        prewarmBatchSize: Int = 1,
        skipPrewarm: Bool = false,
        tuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws -> ArcticEmbedder {
        let model = try await ArcticEmbeddings.make(timeout: tuning.timeoutDuration)
        let embedder = ArcticEmbedder(model: model, batchSize: tuning.batchSize)
        // Probe so a broken model fails here, not on the first real save or search.
        _ = try await embedder.embed("wax")
        if !skipPrewarm {
            try await embedder.prewarm(batchSize: prewarmBatchSize)
        }
        return embedder
    }

    /// Test helper for deterministic batch planning verification.
    package static func _planBatchSizesForTesting(totalCount: Int, maxBatchSize: Int) -> [Int] {
        planBatchSizes(for: totalCount, maxBatchSize: maxBatchSize)
    }

    private static func planBatchSizes(for totalCount: Int, maxBatchSize: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        let clampedMax = Swift.max(1, Swift.min(maxBatchSize, maximumPredictionBatchSize))
        let fullBatchCount = totalCount / clampedMax
        let remainder = totalCount % clampedMax
        return Array(repeating: clampedMax, count: fullBatchCount) + (remainder > 0 ? [remainder] : [])
    }
}
#endif // !canImport(CoreML)
