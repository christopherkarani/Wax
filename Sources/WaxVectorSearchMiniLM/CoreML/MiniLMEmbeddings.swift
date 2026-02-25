import Foundation
#if canImport(CoreML)
import CoreML
import Accelerate

/// On-device all-MiniLM-L6-v2 sentence embedding model via CoreML, producing 384-dimensional vectors.
@available(macOS 15.0, iOS 18.0, *)
public final class MiniLMEmbeddings {
    public enum InitError: LocalizedError, Sendable {
        case missingModelResource
        case modelLoadFailed(String)
        case tokenizerLoadFailed(String)

        public var errorDescription: String? {
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

    public struct Overrides: Sendable {
        var modelURLProvider: (@Sendable () -> URL?)?
        var tokenizerFactory: (@Sendable () throws -> BertTokenizer)?
        var usesBundleFallback: Bool

        static let `default` = Overrides(
            modelURLProvider: nil,
            tokenizerFactory: nil,
            usesBundleFallback: true
        )

        static let missingModel = Overrides(
            modelURLProvider: { nil },
            tokenizerFactory: nil,
            usesBundleFallback: false
        )

        static let missingTokenizer = Overrides(
            modelURLProvider: nil,
            tokenizerFactory: { throw InitError.tokenizerLoadFailed("override requested failure") },
            usesBundleFallback: true
        )
    }

    public let model: all_MiniLM_L6_v2
    public let tokenizer: BertTokenizer
    public let inputDimension: Int = 512
    public let outputDimension: Int = 384
    private static let sequenceLengthBuckets = [32, 64, 128, 256, 384, 512]

    public var computeUnits: MLComputeUnits {
        model.model.configuration.computeUnits
    }

    public convenience init(configuration: MLModelConfiguration? = nil) throws {
        try self.init(configuration: configuration, overrides: .default)
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

    // MARK: - Dense Embeddings

    /// Encode a single sentence to a 384-dimensional embedding vector.
    public func encode(sentence: String) async -> [Float]? {
        guard let batchInputs = try? tokenizer.buildBatchInputs(
            sentences: [sentence],
            sequenceLengthBuckets: Self.sequenceLengthBuckets
        ), batchInputs.sequenceLength > 0 else { return nil }

        guard let output = try? model.prediction(
            input_ids: batchInputs.inputIds,
            attention_mask: batchInputs.attentionMask
        ) else {
            return nil
        }

        return Self.decodeEmbeddings(
            output.var_554,
            batchSize: 1,
            outputDimension: outputDimension
        )?.first
    }

    /// Encode a batch of sentences to embedding vectors, with optional buffer reuse for efficiency.
    public func encode(batch sentences: [String]) async -> [[Float]]? {
        var reuse: BatchInputBuffers?
        return encode(batch: sentences, reuseBuffers: &reuse)
    }

    public func encode(
        batch sentences: [String],
        reuseBuffers: inout BatchInputBuffers?
    ) -> [[Float]]? {
        guard !sentences.isEmpty else { return [] }

        guard let batchInputs = try? tokenizer.buildBatchInputsWithReuse(
            sentences: sentences,
            sequenceLengthBuckets: Self.sequenceLengthBuckets,
            reuse: &reuseBuffers
        ), batchInputs.sequenceLength > 0 else { return [] }

        guard let output = try? model.prediction(
            input_ids: batchInputs.inputIds,
            attention_mask: batchInputs.attentionMask
        ) else {
            return nil
        }

        return Self.decodeEmbeddings(
            output.var_554,
            batchSize: sentences.count,
            outputDimension: outputDimension
        )
    }

    /// Generate an embedding from pre-tokenized input IDs and attention mask (for advanced use cases).
    public func generateEmbeddings(inputIds: MLMultiArray, attentionMask: MLMultiArray) -> [Float]? {
        let inputFeatures = all_MiniLM_L6_v2Input(input_ids: inputIds, attention_mask: attentionMask)
        let output = try? model.prediction(input: inputFeatures)

        guard let embeddings = output?.var_554 else {
            return nil
        }

        return Self.decodeEmbeddings(embeddings, batchSize: 1, outputDimension: outputDimension)?.first
    }

}

@available(macOS 15.0, iOS 18.0, *)
private extension MiniLMEmbeddings {
    static func loadModelFromBundle(configuration: MLModelConfiguration) throws -> all_MiniLM_L6_v2 {
        if let compiledURL = Bundle.module.url(forResource: "all-MiniLM-L6-v2", withExtension: "mlmodelc") {
            let core = try MLModel(contentsOf: compiledURL, configuration: configuration)
            return all_MiniLM_L6_v2(model: core)
        }
        throw InitError.missingModelResource
    }

    static func loadModel(configuration: MLModelConfiguration, overrides: Overrides) throws -> all_MiniLM_L6_v2 {
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
                let float16Ptr = embeddings.dataPointer.bindMemory(to: Float16.self, capacity: elementCount)
                return (0..<batch).map { row in
                    let start = row * dim
                    var vector = [Float](repeating: 0, count: dim)
                    // Use Accelerate SIMD for 8-16x faster Float16→Float32 conversion
                    let srcPtr = float16Ptr.advanced(by: start)
                    vDSP.convertElements(of: UnsafeBufferPointer(start: srcPtr, count: dim), to: &vector)
                    return vector
                }
            }
        }

        let float16Ptr: UnsafeMutablePointer<Float16>? = dataType == .float16
            ? embeddings.dataPointer.bindMemory(to: Float16.self, capacity: elementCount)
            : nil
        let floatPtr: UnsafeMutablePointer<Float>? = dataType == .float32
            ? embeddings.dataPointer.bindMemory(to: Float.self, capacity: elementCount)
            : nil

        func readValue(at index: Int) -> Float {
            if let floatPtr {
                return floatPtr[index]
            }
            if let float16Ptr {
                return Float(float16Ptr[index])
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
public extension MiniLMEmbeddings {
    static func _decodeEmbeddingsForTesting(
        _ embeddings: MLMultiArray,
        batchSize: Int,
        outputDimension: Int
    ) -> [[Float]]? {
        decodeEmbeddings(embeddings, batchSize: batchSize, outputDimension: outputDimension)
    }
}
#endif // canImport(CoreML)
