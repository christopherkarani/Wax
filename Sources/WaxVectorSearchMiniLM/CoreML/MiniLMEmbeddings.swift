import Foundation
#if canImport(CoreML)
@preconcurrency import CoreML
import Accelerate
import WaxCore

/// On-device all-MiniLM-L6-v2 sentence embedding model via CoreML, producing 384-dimensional vectors.
///
/// The bundled graph returns sentence-transformers embeddings: token states mean-pooled over
/// `attention_mask` (output `embeddings`, `[batch, 384]`). `MiniLMEmbedder` L2-normalizes them.
@available(macOS 15.0, iOS 18.0, *)
package final class MiniLMEmbeddings {
    package enum InitError: LocalizedError, Sendable {
        case missingModelResource
        case modelLoadFailed(String)
        case tokenizerLoadFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingModelResource:
                return "Could not find a Core ML model resource in the MiniLMAll bundle."
            case .modelLoadFailed(let details):
                return "Failed to load the Core ML model: \(details)"
            case .tokenizerLoadFailed(let details):
                return "Failed to initialize tokenizer: \(details)"
            }
        }
    }

    /// The Core ML output did not have the expected sentence-embedding layout.
    package enum OutputError: LocalizedError, Sendable, Equatable {
        case unsupportedDataType(rawValue: Int)
        case unexpectedShape(shape: [Int], batchSize: Int, outputDimension: Int)

        package var errorDescription: String? {
            switch self {
            case .unsupportedDataType(let rawValue):
                return "MiniLM Core ML output has unsupported data type \(rawValue); expected Float16 or Float32."
            case .unexpectedShape(let shape, let batchSize, let outputDimension):
                return "MiniLM Core ML output shape \(shape) does not match \(batchSize) x \(outputDimension) sentence embeddings."
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

    package let model: all_MiniLM_L6_v2
    package let tokenizer: BertTokenizer
    package let inputDimension: Int = 512
    package let outputDimension: Int = 384
    private static let sequenceLengthBuckets = [32, 64, 128, 256, 384, 512]

    /// Dedicated queue for CoreML prediction calls. CoreML's `model.prediction()` is synchronous
    /// and can block for seconds during sequence-length recompilation. Running it on a dedicated
    /// (non-cooperative) queue prevents starvation of the Swift concurrency cooperative thread pool,
    /// which the MCP server's transport readLoop and send operations depend on for progress.
    private static let predictionQueue = DispatchQueue(
        label: "wax.minilm.coreml-prediction",
        qos: .userInitiated
    )

    package var computeUnits: MLComputeUnits {
        model.model.configuration.computeUnits
    }

    package convenience init(configuration: MLModelConfiguration? = nil) throws {
        try self.init(configuration: configuration, overrides: .default)
    }

    package static func make(
        configuration: MLModelConfiguration? = nil,
        overrides: Overrides = .default,
        timeout: Duration
    ) async throws -> MiniLMEmbeddings {
        try await AsyncTimeout.run(timeout: timeout, operation: "MiniLM model load") {
            try MiniLMEmbeddings(configuration: configuration, overrides: overrides)
        }
    }

    init(configuration: MLModelConfiguration? = nil, overrides: Overrides) throws {
        let config = configuration ?? {
            let defaultConfig = MLModelConfiguration()
            // Use ANE + CPU for embedding models - ANE is optimized for transformer attention ops
            // Avoids GPU dispatch overhead and provides 1.5-2x speedup over .all
            defaultConfig.computeUnits = .cpuAndNeuralEngine
            defaultConfig.allowLowPrecisionAccumulationOnGPU = true
            return defaultConfig
        }()

        let tokenizer: BertTokenizer
        do {
            if let factory = overrides.tokenizerFactory {
                tokenizer = try factory()
            } else {
                tokenizer = try BertTokenizer()
            }
        } catch {
            if let initError = error as? InitError {
                throw initError
            }
            throw InitError.tokenizerLoadFailed(error.localizedDescription)
        }

        let model: all_MiniLM_L6_v2
        do {
            model = try Self.loadModel(configuration: config, overrides: overrides)
        } catch {
            if let initError = error as? InitError {
                throw initError
            }
            throw InitError.modelLoadFailed(error.localizedDescription)
        }

        self.tokenizer = tokenizer
        self.model = model
    }

    // MARK: - Off-Pool Prediction

    /// Run CoreML prediction on a dedicated dispatch queue instead of a cooperative thread.
    ///
    /// CoreML's `model.prediction()` is synchronous — the calling thread blocks until the
    /// neural engine / CPU finishes inference. If that thread belongs to the Swift concurrency
    /// cooperative pool (typical), no other async work (transport I/O, MCP message dispatch)
    /// can make progress on it until prediction returns. On cold sequence-length buckets the
    /// block can last 5–30 s while CoreML recompiles the execution plan.
    ///
    /// Dispatching to `predictionQueue` keeps the cooperative pool free.
    private func batchPredictionOffPool(
        inputIds: MLMultiArray,
        attentionMask: MLMultiArray,
        batchSize: Int
    ) async throws -> [[Float]] {
        let localModel = model
        let outputDimension = self.outputDimension
        return try await withCheckedThrowingContinuation { continuation in
            Self.predictionQueue.async {
                do {
                    let output = try localModel.prediction(
                        input_ids: inputIds,
                        attention_mask: attentionMask
                    )
                    let decoded = try Self.decodeEmbeddings(
                        output.embeddings,
                        batchSize: batchSize,
                        outputDimension: outputDimension
                    )
                    continuation.resume(returning: decoded)
                } catch {
                    continuation.resume(throwing: error)
                }
            }
        }
    }

    // MARK: - Dense Embeddings

    /// Encode a single sentence to a 384-dimensional embedding vector.
    package func encode(sentence: String) async throws -> [Float]? {
        guard let batchInputs = try? tokenizer.buildBatchInputs(
            sentences: [sentence],
            sequenceLengthBuckets: Self.sequenceLengthBuckets
        ), batchInputs.sequenceLength > 0 else { return nil }

        let embeddings = try await batchPredictionOffPool(
            inputIds: batchInputs.inputIds,
            attentionMask: batchInputs.attentionMask,
            batchSize: 1
        )
        return embeddings.first
    }

    /// Encode a batch of sentences to embedding vectors, reusing input buffers across calls.
    package func encode(
        batch sentences: [String],
        reuseBuffers: inout BatchInputBuffers?
    ) async throws -> [[Float]]? {
        guard !sentences.isEmpty else { return [] }

        guard let batchInputs = try? tokenizer.buildBatchInputsWithReuse(
            sentences: sentences,
            sequenceLengthBuckets: Self.sequenceLengthBuckets,
            reuse: &reuseBuffers
        ), batchInputs.sequenceLength > 0 else { return [] }

        return try await batchPredictionOffPool(
            inputIds: batchInputs.inputIds,
            attentionMask: batchInputs.attentionMask,
            batchSize: sentences.count
        )
    }
}

// MARK: - Sendable Conformances for CoreML Types
// These auto-generated CoreML wrapper types are safe for concurrent prediction
// and produce immutable output objects. @unchecked Sendable is appropriate here.
@available(macOS 15.0, iOS 18.0, *)
extension all_MiniLM_L6_v2: @unchecked Sendable {}

@available(macOS 15.0, iOS 18.0, *)
extension all_MiniLM_L6_v2Output: @unchecked Sendable {}

@available(macOS 15.0, iOS 18.0, *)
private extension MiniLMEmbeddings {
    @inline(__always)
    static func floatFromFloat16Bits(_ bits: UInt16) -> Float {
        let sign = UInt32(bits & 0x8000) << 16
        let exponent = UInt32((bits & 0x7C00) >> 10)
        let mantissa = UInt32(bits & 0x03FF)

        let resultBits: UInt32
        if exponent == 0 {
            if mantissa == 0 {
                resultBits = sign
            } else {
                // Normalize subnormal half-precision values.
                var normalizedMantissa = mantissa
                var adjustedExponent: Int32 = -14
                while (normalizedMantissa & 0x0400) == 0 {
                    normalizedMantissa <<= 1
                    adjustedExponent -= 1
                }
                normalizedMantissa &= 0x03FF
                let exponentBits = UInt32(adjustedExponent + 127) << 23
                let mantissaBits = normalizedMantissa << 13
                resultBits = sign | exponentBits | mantissaBits
            }
        } else if exponent == 0x1F {
            // Preserve Inf/NaN payloads.
            let exponentBits = UInt32(0xFF) << 23
            let mantissaBits = mantissa << 13
            resultBits = sign | exponentBits | mantissaBits
        } else {
            let exponentBits = UInt32(Int32(exponent) - 15 + 127) << 23
            let mantissaBits = mantissa << 13
            resultBits = sign | exponentBits | mantissaBits
        }

        return Float(bitPattern: resultBits)
    }

    static func loadModelFromBundle(configuration: MLModelConfiguration) throws -> all_MiniLM_L6_v2 {
        let bundle = WaxBundleResolver.resolveModule(
            named: "Wax_WaxVectorSearchMiniLM.bundle",
            moduleFallback: .module
        )
        if let compiledURL = bundle.url(forResource: "all-MiniLM-L6-v2", withExtension: "mlmodelc") {
            let core = try MLModel(contentsOf: compiledURL, configuration: configuration)
            return all_MiniLM_L6_v2(model: core)
        }
        throw InitError.missingModelResource
    }

    static func loadModel(configuration: MLModelConfiguration, overrides: Overrides) throws -> all_MiniLM_L6_v2 {
        applyBlockingLoadDelay(overrides)

        if let modelURLProvider = overrides.modelURLProvider {
            guard let modelURL = modelURLProvider() else {
                throw InitError.missingModelResource
            }
            do {
                let model = try MLModel(contentsOf: modelURL, configuration: configuration)
                return all_MiniLM_L6_v2(model: model)
            } catch {
                throw InitError.modelLoadFailed(error.localizedDescription)
            }
        }

        guard overrides.usesBundleFallback else {
            throw InitError.missingModelResource
        }

        do {
            return try cachedModel(configuration: configuration)
        } catch {
            throw InitError.modelLoadFailed(error.localizedDescription)
        }
    }

    static func applyBlockingLoadDelay(_ overrides: Overrides) {
        guard let delay = overrides.blockingModelLoadDelay else { return }
        let components = delay.components
        let seconds = TimeInterval(components.seconds)
        let attoseconds = TimeInterval(components.attoseconds) / 1_000_000_000_000_000_000
        let interval = max(0, seconds + attoseconds)
        guard interval > 0 else { return }
        Thread.sleep(forTimeInterval: interval)
    }

    struct ModelCacheKey: Hashable {
        let computeUnits: MLComputeUnits
        let allowLowPrecisionAccumulationOnGPU: Bool
    }

    final class ModelCache: @unchecked Sendable {
        static let shared = ModelCache()
        private var models: [ModelCacheKey: all_MiniLM_L6_v2] = [:]
        private let lock = NSLock()

        func model(configuration: MLModelConfiguration) throws -> all_MiniLM_L6_v2 {
            let hasParameters = !(configuration.parameters?.isEmpty ?? true)
            if configuration.preferredMetalDevice != nil || hasParameters {
                return try MiniLMEmbeddings.loadModelFromBundle(configuration: configuration)
            }
            let key = ModelCacheKey(
                computeUnits: configuration.computeUnits,
                allowLowPrecisionAccumulationOnGPU: configuration.allowLowPrecisionAccumulationOnGPU
            )
            lock.lock()
            if let cached = models[key] {
                lock.unlock()
                return cached
            }
            defer { lock.unlock() }

            // NOTE: CoreML / Espresso compilation has been observed to deadlock when multiple threads
            // load the same model concurrently. Serializing model loads avoids that class of issues
            // and preserves determinism for callers initializing `MiniLMEmbeddings` in parallel.
            let model = try MiniLMEmbeddings.loadModelFromBundle(configuration: configuration)
            models[key] = model
            return model
        }
    }

    static func cachedModel(configuration: MLModelConfiguration) throws -> all_MiniLM_L6_v2 {
        try ModelCache.shared.model(configuration: configuration)
    }

    /// Decodes the model's `embeddings` output into one vector per input row.
    ///
    /// Only unambiguous sentence-embedding layouts are accepted: `[batch, dim]`, `[dim]` for a
    /// single row, or `[batch, 1, dim]` / `[batch, dim, 1]`. Anything else (for example
    /// `[batch, sequence, hidden]` token embeddings, or a different hidden size) throws instead of
    /// being reinterpreted, so a wrong model output cannot become a plausible-looking vector.
    static func decodeEmbeddings(
        _ embeddings: MLMultiArray,
        batchSize: Int,
        outputDimension: Int
    ) throws -> [[Float]] {
        guard batchSize > 0 else { return [] }
        let dataType = embeddings.dataType
        guard dataType == .float16 || dataType == .float32 else {
            throw OutputError.unsupportedDataType(rawValue: dataType.rawValue)
        }
        let shape = embeddings.shape.map(\.intValue)
        guard let layout = RowLayout(shape: shape, strides: embeddings.strides.map(\.intValue)),
              layout.rows == batchSize,
              layout.dimension == outputDimension
        else {
            throw OutputError.unexpectedShape(shape: shape, batchSize: batchSize, outputDimension: outputDimension)
        }

        let capacity = (layout.rows - 1) * layout.rowStride + (layout.dimension - 1) * layout.columnStride + 1
        if dataType == .float32 {
            let pointer = embeddings.dataPointer.bindMemory(to: Float.self, capacity: capacity)
            return (0..<layout.rows).map { row in
                let start = row * layout.rowStride
                if layout.columnStride == 1 {
                    return Array(UnsafeBufferPointer(start: pointer.advanced(by: start), count: layout.dimension))
                }
                return (0..<layout.dimension).map { pointer[start + $0 * layout.columnStride] }
            }
        }

        let bits = embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: capacity)
        return (0..<layout.rows).map { row in
            let start = row * layout.rowStride
            return (0..<layout.dimension).map { floatFromFloat16Bits(bits[start + $0 * layout.columnStride]) }
        }
    }

    /// Row/column geometry of an accepted sentence-embedding output layout.
    struct RowLayout {
        let rows: Int
        let dimension: Int
        let rowStride: Int
        let columnStride: Int

        init?(shape: [Int], strides: [Int]) {
            guard shape.count == strides.count else { return nil }
            switch shape.count {
            case 1:
                (rows, dimension, rowStride, columnStride) = (1, shape[0], 0, strides[0])
            case 2:
                (rows, dimension, rowStride, columnStride) = (shape[0], shape[1], strides[0], strides[1])
            case 3 where shape[1] == 1:
                (rows, dimension, rowStride, columnStride) = (shape[0], shape[2], strides[0], strides[2])
            case 3 where shape[2] == 1:
                (rows, dimension, rowStride, columnStride) = (shape[0], shape[1], strides[0], strides[1])
            default:
                return nil
            }
            guard rows > 0, dimension > 0 else { return nil }
        }
    }
}

@available(macOS 15.0, iOS 18.0, *)
@_spi(Testing)
package extension MiniLMEmbeddings {
    static func _decodeEmbeddingsForTesting(
        _ embeddings: MLMultiArray,
        batchSize: Int,
        outputDimension: Int
    ) throws -> [[Float]] {
        try decodeEmbeddings(embeddings, batchSize: batchSize, outputDimension: outputDimension)
    }
}
#endif // canImport(CoreML)
