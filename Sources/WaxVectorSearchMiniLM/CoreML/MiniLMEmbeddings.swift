import CoreML
import Foundation

@available(macOS 12.0, iOS 15.0, *)
public final class MiniLMEmbeddings {
    public let model: all_MiniLM_L6_v2
    public let tokenizer: BertTokenizer
    public let inputDimension: Int = 512
    public let outputDimension: Int = 384

    public var computeUnits: MLComputeUnits {
        model.model.configuration.computeUnits
    }

    public init(configuration: MLModelConfiguration? = nil) {
        let config = configuration ?? {
            let defaultConfig = MLModelConfiguration()
            defaultConfig.computeUnits = .all
            return defaultConfig
        }()

        do {
            let coreModel = try Self.loadModel(configuration: config)
            self.model = all_MiniLM_L6_v2(model: coreModel)
        } catch {
            fatalError("Failed to load the Core ML model. Error: \(error.localizedDescription)")
        }

        self.tokenizer = BertTokenizer()
    }

    // MARK: - Dense Embeddings

    public func encode(sentence: String) async -> [Float]? {
        let inputTokens = tokenizer.buildModelTokens(sentence: sentence)
        let (inputIds, attentionMask) = tokenizer.buildModelInputs(from: inputTokens)
        return generateEmbeddings(inputIds: inputIds, attentionMask: attentionMask)
    }

    public func encode(batch sentences: [String]) async -> [[Float]]? {
        guard !sentences.isEmpty else { return [] }

        var inputs: [all_MiniLM_L6_v2Input] = []
        inputs.reserveCapacity(sentences.count)

        for sentence in sentences {
            let inputTokens = tokenizer.buildModelTokens(sentence: sentence)
            let (inputIds, attentionMask) = tokenizer.buildModelInputs(from: inputTokens)
            inputs.append(all_MiniLM_L6_v2Input(input_ids: inputIds, attention_mask: attentionMask))
        }

        guard let outputs = try? model.predictions(inputs: inputs) else {
            return nil
        }

        var results: [[Float]] = []
        results.reserveCapacity(outputs.count)
        for output in outputs {
            let embeddings = output.embeddings
            var vector: [Float] = []
            vector.reserveCapacity(embeddings.count)
            for idx in 0..<embeddings.count {
                vector.append(Float(embeddings[idx].floatValue))
            }
            results.append(vector)
        }
        return results
    }

    public func generateEmbeddings(inputIds: MLMultiArray, attentionMask: MLMultiArray) -> [Float]? {
        let inputFeatures = all_MiniLM_L6_v2Input(input_ids: inputIds, attention_mask: attentionMask)
        let output = try? model.prediction(input: inputFeatures)

        guard let embeddings = output?.embeddings else {
            return nil
        }

        var vector: [Float] = []
        vector.reserveCapacity(embeddings.count)
        for idx in 0..<embeddings.count {
            vector.append(Float(embeddings[idx].floatValue))
        }
        return vector
    }
}

@available(macOS 12.0, iOS 15.0, *)
private extension MiniLMEmbeddings {
    enum ModelLoadError: LocalizedError {
        case missingModelResource

        var errorDescription: String? {
            switch self {
            case .missingModelResource:
                return "Could not find a Core ML model resource in the MiniLMAll bundle."
            }
        }
    }

    static func loadModel(configuration: MLModelConfiguration) throws -> MLModel {
        if let compiledURL = Bundle.module.url(forResource: "all-MiniLM-L6-v2", withExtension: "mlmodelc") {
            return try MLModel(contentsOf: compiledURL, configuration: configuration)
        }

        guard let resourceURL = Bundle.module.resourceURL else {
            throw ModelLoadError.missingModelResource
        }

        let modelURL = resourceURL.appendingPathComponent("model.mlmodel")
        let weightsAtRootURL = resourceURL.appendingPathComponent("weight.bin")
        let weightsInFolderURL = resourceURL.appendingPathComponent("weights/weight.bin")

        guard FileManager.default.fileExists(atPath: modelURL.path) else {
            throw ModelLoadError.missingModelResource
        }

        let weightsURL: URL
        if FileManager.default.fileExists(atPath: weightsInFolderURL.path) {
            weightsURL = weightsInFolderURL
        } else if FileManager.default.fileExists(atPath: weightsAtRootURL.path) {
            weightsURL = weightsAtRootURL
        } else {
            throw ModelLoadError.missingModelResource
        }

        let fileManager = FileManager.default
        let tempRoot = fileManager.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        let tempWeightsDir = tempRoot.appendingPathComponent("weights")
        let tempModelURL = tempRoot.appendingPathComponent("model.mlmodel")
        let tempWeightsURL = tempWeightsDir.appendingPathComponent("weight.bin")

        try fileManager.createDirectory(at: tempWeightsDir, withIntermediateDirectories: true)
        try fileManager.copyItem(at: modelURL, to: tempModelURL)
        try fileManager.copyItem(at: weightsURL, to: tempWeightsURL)

        let compiledURL = try MLModel.compileModel(at: tempModelURL)
        return try MLModel(contentsOf: compiledURL, configuration: configuration)
    }
}
