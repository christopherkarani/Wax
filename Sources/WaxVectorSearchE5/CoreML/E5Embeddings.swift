import Foundation
#if canImport(CoreML)
@preconcurrency import CoreML
import WaxCore
import WaxBertTokenizer

/// On-device `intfloat/e5-small-v2` sentence embedding model via CoreML, producing 384-dimensional vectors.
///
/// The CoreML graph mean-pools over the attention mask and L2-normalizes (MiniLM's graph mean-pools
/// and leaves L2 normalization to `MiniLMEmbedder`), so the output tensor is the final embedding.
@available(macOS 15.0, iOS 18.0, *)
package final class E5Embeddings {
    package enum InitError: LocalizedError, Sendable {
        case missingModelResource
        case modelLoadFailed(String)
        case tokenizerLoadFailed(String)

        package var errorDescription: String? {
            switch self {
            case .missingModelResource:
                return "Could not find a Core ML model resource in the E5Embeddings bundle."
            case .modelLoadFailed(let details):
                return "Failed to load the e5 Core ML model: \(details)"
            case .tokenizerLoadFailed(let details):
                return "Failed to initialize tokenizer: \(details)"
            }
        }
    }

    /// The Core ML output was not a finite sentence-embedding tensor of the expected layout.
    package enum OutputError: LocalizedError, Sendable, Equatable {
        case missingOutput(name: String)
        case unsupportedDataType(rawValue: Int)
        case unexpectedShape(shape: [Int], batchSize: Int, outputDimension: Int)
        case nonFiniteValue

        package var errorDescription: String? {
            switch self {
            case .missingOutput(let name):
                return "E5 Core ML prediction has no multi-array output named '\(name)'."
            case .unsupportedDataType(let rawValue):
                return "E5 Core ML output has unsupported data type \(rawValue); expected Float16 or Float32."
            case .unexpectedShape(let shape, let batchSize, let outputDimension):
                return "E5 Core ML output shape \(shape) does not match \(batchSize) x \(outputDimension) sentence embeddings."
            case .nonFiniteValue:
                return "E5 Core ML output contains a non-finite value."
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

    package let model: e5_small_v2
    package let tokenizer: BertTokenizer
    package let inputDimension: Int = 512
    package let outputDimension: Int = 384
    private static let sequenceLengthBuckets = [32, 64, 128, 256, 384, 512]

    /// Dedicated queue for CoreML prediction calls. CoreML's `model.prediction()` is synchronous
    /// and can block for seconds during sequence-length recompilation. Running it on a dedicated
    /// (non-cooperative) queue prevents starvation of the Swift concurrency cooperative thread pool,
    /// which the MCP server's transport readLoop and send operations depend on for progress.
    ///
    /// `.workItem` drains the autorelease pool after every prediction. CoreML autoreleases
    /// IOSurface-backed outputs, and a GCD thread otherwise drains only when it goes idle, so
    /// back-to-back predictions from concurrent callers grow memory until IOSurface allocation
    /// fails with an uncaught NSException ("Failed to allocate E5 buffer object").
    private static let predictionQueue = DispatchQueue(
        label: "wax.e5.coreml-prediction",
        qos: .userInitiated,
        autoreleaseFrequency: .workItem
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
    ) async throws -> E5Embeddings {
        try await AsyncTimeout.run(timeout: timeout, operation: "E5 model load") {
            try E5Embeddings(configuration: configuration, overrides: overrides)
        }
    }

    init(configuration: MLModelConfiguration? = nil, overrides: Overrides) throws {
        let config = configuration ?? {
            let defaultConfig = MLModelConfiguration()
            // CPU by default, as for Arctic: the Neural Engine runs this FP32 graph in Float16.
            // ANE stays available as an explicit opt-in.
            defaultConfig.computeUnits = .cpuOnly
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

        let model: e5_small_v2
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

    /// Dispatches CoreML prediction to a dedicated non-cooperative queue to prevent
    /// starvation of the Swift concurrency cooperative thread pool.
    ///
    /// Prediction and decode errors propagate to the caller; they are never mapped to `nil`.
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
                        try output.embeddings,
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

    /// Encode a batch of sentences to embedding vectors, with optional buffer reuse for efficiency.
    package func encode(batch sentences: [String]) async throws -> [[Float]]? {
        var reuse: BatchInputBuffers?
        return try await encode(batch: sentences, reuseBuffers: &reuse)
    }

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
extension e5_small_v2: @unchecked Sendable {}

@available(macOS 15.0, iOS 18.0, *)
extension e5_small_v2Output: @unchecked Sendable {}

@available(macOS 15.0, iOS 18.0, *)
private extension E5Embeddings {
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

    static func loadModelFromBundle(configuration: MLModelConfiguration) throws -> e5_small_v2 {
        let bundle = WaxBundleResolver.resolveModule(
            named: "Wax_WaxVectorSearchE5.bundle",
            moduleFallback: .module
        )
        if let compiledURL = bundle.url(forResource: "e5-small-v2", withExtension: "mlmodelc") {
            let core = try MLModel(contentsOf: compiledURL, configuration: configuration)
            return e5_small_v2(model: core)
        }
        throw InitError.missingModelResource
    }

    static func loadModel(configuration: MLModelConfiguration, overrides: Overrides) throws -> e5_small_v2 {
        applyBlockingLoadDelay(overrides)

        if let modelURLProvider = overrides.modelURLProvider {
            guard let modelURL = modelURLProvider() else {
                throw InitError.missingModelResource
            }
            do {
                let model = try MLModel(contentsOf: modelURL, configuration: configuration)
                return e5_small_v2(model: model)
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

    /// Decodes the model's `embeddings` output into one vector per input row.
    ///
    /// Only unambiguous sentence-embedding layouts are accepted: `[batch, dim]`, `[dim]` for a
    /// single row, or `[batch, 1, dim]` / `[batch, dim, 1]`. Anything else (for example
    /// `[batch, sequence, hidden]` token embeddings, or a different hidden size) throws instead of
    /// being reinterpreted. Non-finite values throw too, so a broken compute path cannot store NaNs.
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
            return try requireFinite((0..<layout.rows).map { row in
                let start = row * layout.rowStride
                if layout.columnStride == 1 {
                    return Array(UnsafeBufferPointer(start: pointer.advanced(by: start), count: layout.dimension))
                }
                return (0..<layout.dimension).map { pointer[start + $0 * layout.columnStride] }
            })
        }

        let bits = embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: capacity)
        return try requireFinite((0..<layout.rows).map { row in
            let start = row * layout.rowStride
            return (0..<layout.dimension).map { floatFromFloat16Bits(bits[start + $0 * layout.columnStride]) }
        })
    }

    static func requireFinite(_ rows: [[Float]]) throws -> [[Float]] {
        guard rows.allSatisfy({ $0.allSatisfy(\.isFinite) }) else {
            throw OutputError.nonFiniteValue
        }
        return rows
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
extension E5Embeddings {
    struct ModelCacheKey: Hashable {
        let computeUnits: MLComputeUnits
        let allowLowPrecisionAccumulationOnGPU: Bool
    }

    /// Process-wide cache of loaded models, one per compute-unit configuration.
    ///
    /// Callers asking for the same configuration share one load, so one configuration is never
    /// compiled twice at once. A load for one configuration never waits for a load of another: a
    /// GPU load of a model with range input shapes can spend many minutes in MPSGraph shape
    /// solving, and it must not stall the CPU load.
    final class ModelCache: Sendable {
        static let shared = ModelCache { try E5Embeddings.loadModelFromBundle(configuration: $0) }

        private let models = KeyedLoadCache<ModelCacheKey, e5_small_v2>()
        private let loader: @Sendable (MLModelConfiguration) throws -> e5_small_v2

        init(loader: @escaping @Sendable (MLModelConfiguration) throws -> e5_small_v2) {
            self.loader = loader
        }

        func model(configuration: MLModelConfiguration) throws -> e5_small_v2 {
            let hasParameters = !(configuration.parameters?.isEmpty ?? true)
            if configuration.preferredMetalDevice != nil || hasParameters {
                return try loader(configuration)
            }
            let key = ModelCacheKey(
                computeUnits: configuration.computeUnits,
                allowLowPrecisionAccumulationOnGPU: configuration.allowLowPrecisionAccumulationOnGPU
            )
            return try models.value(for: key) { try loader(configuration) }
        }
    }

    static func cachedModel(configuration: MLModelConfiguration) throws -> e5_small_v2 {
        try ModelCache.shared.model(configuration: configuration)
    }
}

@available(macOS 15.0, iOS 18.0, *)
@_spi(Testing)
package extension E5Embeddings {
    static func _decodeEmbeddingsForTesting(
        _ embeddings: MLMultiArray,
        batchSize: Int,
        outputDimension: Int
    ) throws -> [[Float]] {
        try decodeEmbeddings(embeddings, batchSize: batchSize, outputDimension: outputDimension)
    }

    func _predictForTesting(
        inputIds: MLMultiArray,
        attentionMask: MLMultiArray,
        batchSize: Int
    ) async throws -> [[Float]] {
        try await batchPredictionOffPool(inputIds: inputIds, attentionMask: attentionMask, batchSize: batchSize)
    }
}
#endif // canImport(CoreML)
