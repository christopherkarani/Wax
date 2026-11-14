#if !canImport(CoreML)
import Foundation
import WaxCore
import WaxVectorSearch

/// The MiniLM model behind `MiniLMEmbedder`; a seam for tests.
package protocol MiniLMEmbeddingModel: Sendable {
    func encode(sentence: String) async throws -> [Float]?
    func encode(batch sentences: [String]) async throws -> [[Float]]?
}

extension MiniLMMILEmbeddings: MiniLMEmbeddingModel {}

/// all-MiniLM-L6-v2 embedder for platforms without Core ML, running the bundled graph on
/// WaxMILRuntime.
///
/// It records the same identity as the Core ML `MiniLMEmbedder`, so stores move between
/// platforms. As there, the graph mean-pools and this actor L2-normalizes.
package actor MiniLMEmbedder: EmbeddingProvider, BatchEmbeddingProvider {
    package nonisolated let dimensions: Int = 384
    package nonisolated let normalize: Bool = true
    /// The identity a store records for vectors from this model (as on Apple platforms).
    package static let bindingIdentity = EmbeddingIdentity(
        provider: "Wax",
        model: "MiniLMAll-mean",
        dimensions: 384,
        normalized: true
    )
    package nonisolated let identity: EmbeddingIdentity? = MiniLMEmbedder.bindingIdentity

    private nonisolated let model: any MiniLMEmbeddingModel
    private let batchSize: Int
    private static let maximumBatchSize = 256
    /// Rows per WaxMILRuntime prediction. Bounds the attention scores' memory
    /// (rows x 12 heads x 256^2 floats) on long texts.
    private static let maximumPredictionBatchSize = 8

    package struct Config {
        package var batchSize: Int

        package init(batchSize: Int = 256) {
            self.batchSize = batchSize
        }
    }

    package init(model: any MiniLMEmbeddingModel, batchSize: Int) {
        self.model = model
        self.batchSize = max(1, batchSize)
    }

    package init() throws {
        self.init(model: try MiniLMEmbeddings(), batchSize: Self.maximumBatchSize)
    }

    package init(model: MiniLMEmbeddings) {
        self.init(model: model, batchSize: Self.maximumBatchSize)
    }

    package init(config: Config) throws {
        self.init(model: try MiniLMEmbeddings(), batchSize: config.batchSize)
    }

    package init(overrides: MiniLMEmbeddings.Overrides, config: Config = Config()) throws {
        self.init(model: try MiniLMEmbeddings(overrides: overrides), batchSize: config.batchSize)
    }

    package static func make(
        config: Config = Config(),
        overrides: MiniLMEmbeddings.Overrides = .default,
        timeout: Duration,
        skipPrewarm: Bool = false,
        prewarmBatchSize: Int = 1
    ) async throws -> MiniLMEmbedder {
        let model = try await MiniLMEmbeddings.make(overrides: overrides, timeout: timeout)
        let embedder = MiniLMEmbedder(model: model, batchSize: config.batchSize)
        if !skipPrewarm {
            try await AsyncTimeout.run(timeout: timeout, operation: "MiniLM embedder prewarm") {
                try await embedder.prewarm(batchSize: prewarmBatchSize)
            }
        }
        return embedder
    }

    package func embed(_ text: String) async throws -> [Float] {
        guard let vector = try await model.encode(sentence: text) else {
            throw WaxError.io("MiniLMAll embedding failed to produce a vector.")
        }
        return try Self.validatedNormalizedVector(vector, dimensions: dimensions)
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
                    throw WaxError.io("MiniLMAll batch embedding failed.")
                }
                guard vectors.count == chunk.count else {
                    throw WaxError.io("MiniLMAll batch embedding count mismatch: expected \(chunk.count), got \(vectors.count).")
                }
                for vector in vectors {
                    results.append(try Self.validatedNormalizedVector(vector, dimensions: dimensions))
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
}

extension MiniLMEmbedder {
    /// Builds the MiniLM embedder for the CLI, MCP server and `BuiltInEmbeddings`.
    ///
    /// Core ML compute units in `tuning` do not apply to WaxMILRuntime, which runs on the CPU;
    /// they are accepted and ignored. The batch size, prewarm batch size and timeout apply.
    package static func makeCommandLineEmbedder(
        prewarmBatchSize: Int = 1,
        skipPrewarm: Bool = false,
        tuning: CommandLineEmbedderRuntimeTuning = .fromEnvironment()
    ) async throws -> MiniLMEmbedder {
        let model = try await MiniLMEmbeddings.make(timeout: tuning.timeoutDuration)
        let embedder = MiniLMEmbedder(model: model, batchSize: tuning.batchSize)
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
}

private extension MiniLMEmbedder {
    static func validatedNormalizedVector(_ vector: [Float], dimensions: Int) throws -> [Float] {
        guard vector.count == dimensions else {
            throw WaxError.invalidEmbedding(reason: "MiniLMAll produced \(vector.count) dims, expected \(dimensions).")
        }
        guard vector.allSatisfy(\.isFinite) else {
            throw WaxError.invalidEmbedding(reason: "MiniLMAll produced a non-finite embedding value.")
        }
        let sumOfSquares = vector.reduce(Float(0)) { $0 + $1 * $1 }
        guard sumOfSquares.isFinite else {
            throw WaxError.invalidEmbedding(reason: "MiniLMAll produced a non-finite embedding magnitude.")
        }
        guard sumOfSquares > 0 else {
            throw WaxError.invalidEmbedding(reason: "MiniLMAll produced a zero-magnitude embedding.")
        }
        let inverseMagnitude = 1 / sumOfSquares.squareRoot()
        return vector.map { $0 * inverseMagnitude }
    }

    static func planBatchSizes(for totalCount: Int, maxBatchSize: Int) -> [Int] {
        guard totalCount > 0 else { return [] }
        let clampedMax = Swift.max(1, Swift.min(maxBatchSize, maximumPredictionBatchSize))
        let fullBatchCount = totalCount / clampedMax
        let remainder = totalCount % clampedMax
        return Array(repeating: clampedMax, count: fullBatchCount) + (remainder > 0 ? [remainder] : [])
    }
}
#endif // !canImport(CoreML)
