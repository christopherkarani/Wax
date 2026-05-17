import Foundation
#if canImport(CoreML)
@preconcurrency import CoreML
import Accelerate
import WaxCore

/// On-device all-MiniLM-L6-v2 sentence embedding model via CoreML, producing 384-dimensional vectors.
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
    ) async -> [[Float]]? {
        let localModel = model
        let outputDimension = self.outputDimension
        return await withCheckedContinuation { continuation in
            Self.predictionQueue.async {
                let output: all_MiniLM_L6_v2Output? = try? localModel.prediction(
                    input_ids: inputIds,
                    attention_mask: attentionMask
                )
                let decoded = output.flatMap {
                    Self.decodeEmbeddings(
                        $0.var_554,
                        batchSize: batchSize,
                        outputDimension: outputDimension
                    )
                }
                continuation.resume(returning: decoded)
            }
        }
    }

    // MARK: - Dense Embeddings

    /// Encode a single sentence to a 384-dimensional embedding vector.
    package func encode(sentence: String) async -> [Float]? {
        guard let batchInputs = try? tokenizer.buildBatchInputs(
            sentences: [sentence],
            sequenceLengthBuckets: Self.sequenceLengthBuckets
        ), batchInputs.sequenceLength > 0 else { return nil }

        guard let embeddings = await batchPredictionOffPool(
            inputIds: batchInputs.inputIds,
            attentionMask: batchInputs.attentionMask,
            batchSize: 1
        ) else {
            return nil
        }

        return embeddings.first
    }

    /// Encode a batch of sentences to embedding vectors, with optional buffer reuse for efficiency.
    package func encode(batch sentences: [String]) async -> [[Float]]? {
        var reuse: BatchInputBuffers?
        return await encode(batch: sentences, reuseBuffers: &reuse)
    }

    package func encode(
        batch sentences: [String],
        reuseBuffers: inout BatchInputBuffers?
    ) async -> [[Float]]? {
        guard !sentences.isEmpty else { return [] }

        guard let batchInputs = try? tokenizer.buildBatchInputsWithReuse(
            sentences: sentences,
            sequenceLengthBuckets: Self.sequenceLengthBuckets,
            reuse: &reuseBuffers
        ), batchInputs.sequenceLength > 0 else { return [] }

        return await batchPredictionOffPool(
            inputIds: batchInputs.inputIds,
            attentionMask: batchInputs.attentionMask,
            batchSize: sentences.count
        )
    }

    /// Generate an embedding from pre-tokenized input IDs and attention mask (for advanced use cases).
    package func generateEmbeddings(inputIds: MLMultiArray, attentionMask: MLMultiArray) async -> [Float]? {
        guard let embeddings = await batchPredictionOffPool(
            inputIds: inputIds,
            attentionMask: attentionMask,
            batchSize: 1
        ) else {
            return nil
        }

        return embeddings.first
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
        if let compiledURL = Bundle.module.url(forResource: "all-MiniLM-L6-v2", withExtension: "mlmodelc") {
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

    static func decodeEmbeddings(
        _ embeddings: MLMultiArray,
        batchSize: Int,
        outputDimension: Int
    ) -> [[Float]]? {
        guard batchSize > 0 else { return [] }
        let elementCount = embeddings.count
        let shape = embeddings.shape.map { $0.intValue }
        let strides = embeddings.strides.map { $0.intValue }
        let dataType = embeddings.dataType
        guard dataType == .float16 || dataType == .float32 else {
            return nil
        }

        if shape.count == 2 {
            let batch = shape[0]
            let dim = shape[1]
            guard batch == batchSize else { return nil }
            
            let isContiguous = strides[1] == 1 && strides[0] == dim
            
            if isContiguous && dataType == .float32 {
                let floatPtr = embeddings.dataPointer.bindMemory(to: Float.self, capacity: elementCount)
                return (0..<batch).map { row in
                    let start = row * dim
                    return Array(UnsafeBufferPointer(start: floatPtr.advanced(by: start), count: dim))
                }
            }
            
            if isContiguous && dataType == .float16 {
                let float16BitsPtr = embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: elementCount)
                return (0..<batch).map { row in
                    let start = row * dim
                    return (0..<dim).map { col in
                        floatFromFloat16Bits(float16BitsPtr[start + col])
                    }
                }
            }
        }

        let float16BitsPtr: UnsafeMutablePointer<UInt16>? = dataType == .float16
            ? embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: elementCount)
            : nil
        let floatPtr: UnsafeMutablePointer<Float>? = dataType == .float32
            ? embeddings.dataPointer.bindMemory(to: Float.self, capacity: elementCount)
            : nil

        func readValue(at index: Int) -> Float {
            if let floatPtr {
                return floatPtr[index]
            }
            if let float16BitsPtr {
                return floatFromFloat16Bits(float16BitsPtr[index])
            }
            return 0
        }

        if shape.count == 1 {
            guard batchSize == 1 else { return nil }
            let dim = shape[0]
            if dataType == .float32, let floatPtr {
                return [Array(UnsafeBufferPointer(start: floatPtr, count: dim))]
            }
            return [(0..<dim).map { readValue(at: $0) }]
        }

        if shape.count == 2 {
            let batch = shape[0]
            let dim = shape[1]
            guard batch == batchSize else { return nil }
            return (0..<batch).map { row in
                var vector = [Float](repeating: 0, count: dim)
                for col in 0..<dim {
                    let index = row * strides[0] + col * strides[1]
                    vector[col] = readValue(at: index)
                }
                return vector
            }
        }

        if shape.count == 3, shape[1] == 1 {
            let batch = shape[0]
            let dim = shape[2]
            guard batch == batchSize else { return nil }
            
            let isContiguous = strides[2] == 1 && strides[0] == dim
            if isContiguous && dataType == .float32, let floatPtr {
                return (0..<batch).map { row in
                    let start = row * dim
                    return Array(UnsafeBufferPointer(start: floatPtr.advanced(by: start), count: dim))
                }
            }
            
            return (0..<batch).map { row in
                var vector = [Float](repeating: 0, count: dim)
                for col in 0..<dim {
                    let index = row * strides[0] + col * strides[2]
                    vector[col] = readValue(at: index)
                }
                return vector
            }
        }

        if shape.count == 3, shape[2] == 1 {
            let batch = shape[0]
            let dim = shape[1]
            guard batch == batchSize else { return nil }
            return (0..<batch).map { row in
                var vector = [Float](repeating: 0, count: dim)
                for col in 0..<dim {
                    let index = row * strides[0] + col * strides[1]
                    vector[col] = readValue(at: index)
                }
                return vector
            }
        }

        if embeddings.count % batchSize == 0 {
            let rowStride = embeddings.count / batchSize
            let dim = min(outputDimension, rowStride)
            guard dim > 0 else { return nil }
            
            if dataType == .float32, let floatPtr {
                return (0..<batchSize).map { row in
                    let start = row * rowStride
                    return Array(UnsafeBufferPointer(start: floatPtr.advanced(by: start), count: dim))
                }
            }
            
            return (0..<batchSize).map { row in
                let start = row * rowStride
                return (0..<dim).map { readValue(at: start + $0) }
            }
        }

        return nil
    }
}

@available(macOS 15.0, iOS 18.0, *)
@_spi(Testing)
package extension MiniLMEmbeddings {
    static func _decodeEmbeddingsForTesting(
        _ embeddings: MLMultiArray,
        batchSize: Int,
        outputDimension: Int
    ) -> [[Float]]? {
        decodeEmbeddings(embeddings, batchSize: batchSize, outputDimension: outputDimension)
    }
}
#endif // canImport(CoreML)
