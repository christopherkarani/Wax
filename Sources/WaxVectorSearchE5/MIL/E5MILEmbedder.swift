#if !canImport(CoreML)
import Foundation
import WaxCore
import WaxVectorSearch

/// `intfloat/e5-small-v2` embedder for platforms without Core ML, running the bundled graph on
/// WaxMILRuntime.
///
/// It records the same identity and adds the same prefixes as the Core ML `E5Embedder`:
/// ``embedQuery(_:)`` prepends `"query: "`, ``embed(_:)`` and ``embed(batch:)`` prepend
/// `"passage: "`. The graph mean-pools and L2-normalizes, so vectors are not re-normalized.
package actor E5Embedder: EmbeddingProvider, BatchEmbeddingProvider, QueryAwareEmbeddingProvider {
    package nonisolated let dimensions: Int = 384
    /// L2 normalization is in the graph, so the caller should not re-normalize.
    package nonisolated let normalize: Bool = false
    /// The identity a store records for vectors from this model (as on Apple platforms).
    package static let bindingIdentity = EmbeddingIdentity(
        provider: "Wax",
        model: "E5SmallV2-prefixed",
        dimensions: 384,
        normalized: true
    )
    package nonisolated let identity: EmbeddingIdentity? = E5Embedder.bindingIdentity

    private nonisolated let model: E5Embeddings
    private let batchSize: Int
    private static let maximumBatchSize = 256
    /// Rows per WaxMILRuntime prediction. Bounds the attention scores' memory
    /// (rows x 12 heads x 512^2 floats) on long texts.
    private static let maximumPredictionBatchSize = 8

    /// The prefixes e5 was trained with.
    private static let queryPrefix = "query: "
    private static let passagePrefix = "passage: "

    package struct Config {
        package var batchSize: Int

        package init(batchSize: Int = 256) {
            self.batchSize = batchSize
        }
    }

    private init(model: E5Embeddings, batchSize: Int) {
        self.model = model
        self.batchSize = max(1, batchSize)
    }

    package init() throws {
        self.init(model: try E5Embeddings(), batchSize: Self.maximumBatchSize)
    }

    package init(model: E5Embeddings) {
        self.init(model: model, batchSize: Self.maximumBatchSize)
    }

    package init(config: Config) throws {
        self.init(model: try E5Embeddings(), batchSize: config.batchSize)
    }

    package init(overrides: E5Embeddings.Overrides, config: Config = Config()) throws {
        self.init(model: try E5Embeddings(overrides: overrides), batchSize: config.batchSize)
    }

    package static func make(
        config: Config = Config(),
        overrides: E5Embeddings.Overrides = .default,
        timeout: Duration,
        skipPrewarm: Bool = false,
        prewarmBatchSize: Int = 1
    ) async throws -> E5Embedder {
        let model = try await E5Embeddings.make(overrides: overrides, timeout: timeout)
        let embedder = E5Embedder(model: model, batchSize: config.batchSize)
        if !skipPrewarm {
            try await AsyncTimeout.run(timeout: timeout, operation: "E5 embedder prewarm") {
                try await embedder.prewarm(batchSize: prewarmBatchSize)
            }
        }
        return embedder
    }

    /// Embed document text with the e5 `"passage: "` prefix.
    package func embed(_ text: String) async throws -> [Float] {
        try await encode(Self.passagePrefix + text)
    }

    /// Embed a retrieval query with the e5 `"query: "` prefix.
    package func embedQuery(_ text: String) async throws -> [Float] {
        try await encode(Self.queryPrefix + text)
    }

    /// Embed document texts, each with the e5 `"passage: "` prefix.
    package func embed(batch texts: [String]) async throws -> [[Float]] {
        guard !texts.isEmpty else { return [] }
        let texts = texts.map { Self.passagePrefix + $0 }
        var results: [[Float]] = []
        results.reserveCapacity(texts.count)
        var start = 0
        for size in Self.planBatchSizes(for: texts.count, maxBatchSize: batchSize) {
            let chunk = Array(texts[start..<(start + size)])
            if size == 1 {
                results.append(try await encode(chunk[0]))
            } else {
                guard let vectors = try await model.encode(batch: chunk) else {
                    throw WaxError.io("E5 batch embedding failed.")
                }
                guard vectors.count == chunk.count else {
                    throw WaxError.io("E5 batch embedding count mismatch: expected \(chunk.count), got \(vectors.count).")
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

    /// Encodes text that already carries its prefix.
    private func encode(_ prefixedText: String) async throws -> [Float] {
        guard let vector = try await model.encode(sentence: prefixedText) else {
            throw WaxError.io("E5 embedding failed to produce a vector.")
        }
        return try checked(vector)
    }

    private func checked(_ vector: [Float]) throws -> [Float] {
        guard vector.count == dimensions else {
            throw WaxError.invalidEmbedding(reason: "E5 produced \(vector.count) dims, expected \(dimensions).")
        }
        return vector
    }
}

extension E5Embedder {
    /// Builds the e5 embedder for the CLI, MCP server and `BuiltInEmbeddings`.
    ///
    /// Core ML compute units in `tuning` do not apply to WaxMILRuntime, which runs on the CPU;
    /// they are accepted and ignored. The batch size, prewarm batch size and timeout apply.
    package static func makeCommandLineEmbedder(
        prewarmBatchSize: Int = 1,
        skipPrewarm: Bool = false,
        tuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws -> E5Embedder {
        let model = try await E5Embeddings.make(timeout: tuning.timeoutDuration)
        let embedder = E5Embedder(model: model, batchSize: tuning.batchSize)
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
