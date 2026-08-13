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

    package enum DecodeError: LocalizedError, Sendable, Equatable {
        case unexpectedOutput(
            shape: [Int],
            strides: [Int],
            dataType: String,
            expectedBatch: Int,
            expectedDimension: Int
        )

        package var errorDescription: String? {
            switch self {
            case let .unexpectedOutput(shape, strides, dataType, expectedBatch, expectedDimension):
                return "Unexpected MiniLM output shape=\(shape) strides=\(strides) dtype=\(dataType) expectedBatch=\(expectedBatch) expectedDimension=\(expectedDimension)"
            }
        }
    }

    package struct Overrides: Sendable {
        var modelURLProvider: (@Sendable () -> URL?)?
        var tokenizerFactory: (@Sendable () throws -> BertTokenizer)?
        var usesBundleFallback: Bool
        var blockingModelLoadDelay: Duration?
        /// When set, `loadModelFromBundle` uses this bundle instead of the module
        /// resource bundle. Tests inject an empty bundle directory to prove the
        /// production path throws rather than hitting the generated force-unwrap.
        var resourceBundleURL: URL?

        static let `default` = Overrides(
            modelURLProvider: nil,
            tokenizerFactory: nil,
            usesBundleFallback: true,
            blockingModelLoadDelay: nil,
            resourceBundleURL: nil
        )

        static let missingModel = Overrides(
            modelURLProvider: { nil },
            tokenizerFactory: nil,
            usesBundleFallback: false,
            blockingModelLoadDelay: nil,
            resourceBundleURL: nil
        )

        static let missingTokenizer = Overrides(
            modelURLProvider: nil,
            tokenizerFactory: { throw InitError.tokenizerLoadFailed("override requested failure") },
            usesBundleFallback: true,
            blockingModelLoadDelay: nil,
            resourceBundleURL: nil
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
    ) async throws -> [[Float]]? {
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
                        output.var_554,
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
        let batchInputs = try tokenizer.buildBatchInputs(
            sentences: [sentence],
            sequenceLengthBuckets: Self.sequenceLengthBuckets
        )
        guard batchInputs.sequenceLength > 0 else { return nil }

        guard let embeddings = try await batchPredictionOffPool(
            inputIds: batchInputs.inputIds,
            attentionMask: batchInputs.attentionMask,
            batchSize: 1
        ) else {
            return nil
        }

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

        let batchInputs = try tokenizer.buildBatchInputsWithReuse(
            sentences: sentences,
            sequenceLengthBuckets: Self.sequenceLengthBuckets,
            reuse: &reuseBuffers
        )
        guard batchInputs.sequenceLength > 0 else { return [] }

        return try await batchPredictionOffPool(
            inputIds: batchInputs.inputIds,
            attentionMask: batchInputs.attentionMask,
            batchSize: sentences.count
        )
    }

    /// Generate embeddings from pre-tokenized input IDs and attention mask (for advanced use cases).
    package func generateEmbeddings(inputIds: MLMultiArray, attentionMask: MLMultiArray) async throws -> [[Float]]? {
        guard let batchSize = Self.preTokenizedBatchSize(inputIds: inputIds, attentionMask: attentionMask) else {
            return nil
        }
        guard let embeddings = try await batchPredictionOffPool(
            inputIds: inputIds,
            attentionMask: attentionMask,
            batchSize: batchSize
        ) else {
            return nil
        }

        return embeddings
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

    /// Production MiniLM loads go through this throwing helper. The generated
    /// CoreML convenience accessor that force-unwraps the class bundle URL is
    /// `private` and unreachable from this type or any other package entry point.
    static func loadModelFromBundle(
        configuration: MLModelConfiguration,
        resourceBundleURL: URL? = nil
    ) throws -> all_MiniLM_L6_v2 {
        let bundle: Bundle
        if let resourceBundleURL {
            guard let injected = Bundle(url: resourceBundleURL) else {
                throw InitError.missingModelResource
            }
            bundle = injected
        } else {
            bundle = WaxBundleResolver.resolveModule(
                named: "Wax_WaxVectorSearchMiniLM.bundle",
                moduleFallback: .module
            )
        }
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
            if overrides.resourceBundleURL != nil {
                return try loadModelFromBundle(
                    configuration: configuration,
                    resourceBundleURL: overrides.resourceBundleURL
                )
            }
            return try cachedModel(configuration: configuration)
        } catch let error as InitError {
            throw error
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
    ) throws -> [[Float]] {
        guard batchSize > 0 else { return [] }
        let shape = embeddings.shape.map(\.intValue)
        let strides = embeddings.strides.map(\.intValue)
        let dataType = embeddings.dataType

        func fail() -> DecodeError {
            DecodeError.unexpectedOutput(
                shape: shape,
                strides: strides,
                dataType: describeDataType(dataType),
                expectedBatch: batchSize,
                expectedDimension: outputDimension
            )
        }

        guard dataType == .float16 || dataType == .float32 else {
            throw fail()
        }
        guard shape.count == strides.count, !shape.isEmpty else {
            throw fail()
        }

        if shape.count == 1 {
            guard batchSize == 1, shape[0] == outputDimension else { throw fail() }
            try requirePositiveStride(strides[0], fail)
            return try [readVector(embeddings, offset: 0, count: outputDimension, stride: strides[0], dataType: dataType)]
        }

        if shape.count == 2 {
            let batch = shape[0]
            let dim = shape[1]
            guard batch == batchSize, dim == outputDimension else { throw fail() }
            try requirePositiveStride(strides[0], fail)
            try requirePositiveStride(strides[1], fail)
            return try readRows(
                embeddings,
                batch: batch,
                dimension: dim,
                rowStride: strides[0],
                colStride: strides[1],
                dataType: dataType
            )
        }

        if shape.count == 3, shape[1] == 1 {
            let batch = shape[0]
            let dim = shape[2]
            guard batch == batchSize, dim == outputDimension else { throw fail() }
            try requirePositiveStride(strides[0], fail)
            try requirePositiveStride(strides[2], fail)
            return try readRows(
                embeddings,
                batch: batch,
                dimension: dim,
                rowStride: strides[0],
                colStride: strides[2],
                dataType: dataType
            )
        }

        if shape.count == 3, shape[2] == 1 {
            let batch = shape[0]
            let dim = shape[1]
            guard batch == batchSize, dim == outputDimension else { throw fail() }
            try requirePositiveStride(strides[0], fail)
            try requirePositiveStride(strides[1], fail)
            return try readRows(
                embeddings,
                batch: batch,
                dimension: dim,
                rowStride: strides[0],
                colStride: strides[1],
                dataType: dataType
            )
        }

        throw fail()
    }

    static func requirePositiveStride(_ stride: Int, _ fail: () -> DecodeError) throws {
        guard stride > 0 else { throw fail() }
    }

    static func describeDataType(_ dataType: MLMultiArrayDataType) -> String {
        switch dataType {
        case .float16:
            return "float16"
        case .float32:
            return "float32"
        case .int32:
            return "int32"
        default:
            return "unknown(\(dataType.rawValue))"
        }
    }

    static func pointerCapacity(shape: [Int], strides: [Int]) -> Int {
        zip(shape, strides).map { max(0, $0 - 1) * $1 }.reduce(0, +) + 1
    }

    static func readRows(
        _ embeddings: MLMultiArray,
        batch: Int,
        dimension: Int,
        rowStride: Int,
        colStride: Int,
        dataType: MLMultiArrayDataType
    ) throws -> [[Float]] {
        let isContiguous = colStride == 1 && rowStride == dimension
        let capacity = max(embeddings.count, pointerCapacity(shape: embeddings.shape.map(\.intValue), strides: embeddings.strides.map(\.intValue)))

        if isContiguous && dataType == .float32 {
            let floatPtr = embeddings.dataPointer.bindMemory(to: Float.self, capacity: capacity)
            return (0..<batch).map { row in
                let start = row * dimension
                return Array(UnsafeBufferPointer(start: floatPtr.advanced(by: start), count: dimension))
            }
        }

        if isContiguous && dataType == .float16 {
            let float16BitsPtr = embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: capacity)
            return (0..<batch).map { row in
                let start = row * dimension
                return (0..<dimension).map { col in
                    floatFromFloat16Bits(float16BitsPtr[start + col])
                }
            }
        }

        return try (0..<batch).map { row in
            try readVector(
                embeddings,
                offset: row * rowStride,
                count: dimension,
                stride: colStride,
                dataType: dataType
            )
        }
    }

    static func readVector(
        _ embeddings: MLMultiArray,
        offset: Int,
        count: Int,
        stride: Int,
        dataType: MLMultiArrayDataType
    ) throws -> [Float] {
        guard count > 0, offset >= 0, stride > 0 else {
            throw DecodeError.unexpectedOutput(
                shape: embeddings.shape.map(\.intValue),
                strides: embeddings.strides.map(\.intValue),
                dataType: describeDataType(dataType),
                expectedBatch: 1,
                expectedDimension: count
            )
        }
        let span = (count - 1).multipliedReportingOverflow(by: stride)
        let lastIndex = offset.addingReportingOverflow(span.overflow ? 0 : span.partialValue)
        guard !span.overflow, !lastIndex.overflow else {
            throw DecodeError.unexpectedOutput(
                shape: embeddings.shape.map(\.intValue),
                strides: embeddings.strides.map(\.intValue),
                dataType: describeDataType(dataType),
                expectedBatch: 1,
                expectedDimension: count
            )
        }
        let capacity = max(embeddings.count, lastIndex.partialValue + 1)
        switch dataType {
        case .float32:
            let floatPtr = embeddings.dataPointer.bindMemory(to: Float.self, capacity: capacity)
            if stride == 1 {
                return Array(UnsafeBufferPointer(start: floatPtr.advanced(by: offset), count: count))
            }
            return (0..<count).map { floatPtr[offset + $0 * stride] }
        case .float16:
            let float16BitsPtr = embeddings.dataPointer.bindMemory(to: UInt16.self, capacity: capacity)
            return (0..<count).map { floatFromFloat16Bits(float16BitsPtr[offset + $0 * stride]) }
        default:
            throw DecodeError.unexpectedOutput(
                shape: embeddings.shape.map(\.intValue),
                strides: embeddings.strides.map(\.intValue),
                dataType: describeDataType(dataType),
                expectedBatch: 1,
                expectedDimension: count
            )
        }
    }

    static func preTokenizedBatchSize(inputIds: MLMultiArray, attentionMask: MLMultiArray) -> Int? {
        let inputShape = inputIds.shape.map(\.intValue)
        let maskShape = attentionMask.shape.map(\.intValue)
        guard inputShape == maskShape else { return nil }
        guard !inputShape.isEmpty else { return nil }

        if inputShape.count == 1 {
            return inputShape[0] > 0 ? 1 : nil
        }

        let batchSize = inputShape[0]
        let sequenceLength = inputShape[1]
        guard batchSize > 0, sequenceLength > 0 else { return nil }
        return batchSize
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

    static func _preTokenizedBatchSizeForTesting(
        inputIds: MLMultiArray,
        attentionMask: MLMultiArray
    ) -> Int? {
        preTokenizedBatchSize(inputIds: inputIds, attentionMask: attentionMask)
    }
}
#endif // canImport(CoreML)
