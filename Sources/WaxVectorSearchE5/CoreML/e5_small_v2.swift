//
// e5_small_v2.swift
//
// This file was automatically generated and should not be edited.
//

#if canImport(CoreML)
import CoreML


/// Model Prediction Input Type
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
package class e5_small_v2Input : MLFeatureProvider {

    /// input_ids as 1 by 32 matrix of 32-bit integers
    package var input_ids: MLMultiArray

    /// attention_mask as 1 by 32 matrix of 32-bit integers
    package var attention_mask: MLMultiArray

    package var featureNames: Set<String> { ["input_ids", "attention_mask"] }

    package func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "input_ids" {
            return MLFeatureValue(multiArray: input_ids)
        }
        if featureName == "attention_mask" {
            return MLFeatureValue(multiArray: attention_mask)
        }
        return nil
    }

    package init(input_ids: MLMultiArray, attention_mask: MLMultiArray) {
        self.input_ids = input_ids
        self.attention_mask = attention_mask
    }

    package convenience init(input_ids: MLShapedArray<Int32>, attention_mask: MLShapedArray<Int32>) {
        self.init(input_ids: MLMultiArray(input_ids), attention_mask: MLMultiArray(attention_mask))
    }

}


/// Model Prediction Output Type
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
package class e5_small_v2Output : MLFeatureProvider {

    /// Source provided by CoreML
    private let provider : MLFeatureProvider

    /// embeddings as multidimensional array of 32-bit floats
    package var embeddings: MLMultiArray {
        get throws {
            guard let array = provider.featureValue(for: "embeddings")?.multiArrayValue else {
                throw E5Embeddings.OutputError.missingOutput(name: "embeddings")
            }
            return array
        }
    }

    /// embeddings as multidimensional array of 32-bit floats
    #if !(os(macOS) || targetEnvironment(macCatalyst))
    package var embeddingsShapedArray: MLShapedArray<Float> {
        get throws { MLShapedArray<Float>(try embeddings) }
    }
    #endif

    package var featureNames: Set<String> {
        provider.featureNames
    }

    package func featureValue(for featureName: String) -> MLFeatureValue? {
        provider.featureValue(for: featureName)
    }

    package init(embeddings: MLMultiArray) throws {
        self.provider = try MLDictionaryFeatureProvider(dictionary: ["embeddings" : MLFeatureValue(multiArray: embeddings)])
    }

    package init(features: MLFeatureProvider) {
        self.provider = features
    }
}


/// Class for model loading and prediction
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
package class e5_small_v2 {
    package let model: MLModel

    /// URL of model assuming it was installed in the same bundle as this class
    class var urlOfModelInThisBundle : URL {
        #if SWIFT_PACKAGE
        let moduleBundle = Bundle.module
        if let url = moduleBundle.url(forResource: "e5-small-v2", withExtension: "mlmodelc") {
            return url
        }
        #endif
        let bundle = Bundle(for: self)
        return bundle.url(forResource: "e5-small-v2", withExtension: "mlmodelc")!
    }

    init(model: MLModel) {
        self.model = model
    }

    package convenience init(configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        try self.init(contentsOf: type(of:self).urlOfModelInThisBundle, configuration: configuration)
    }

    package convenience init(contentsOf modelURL: URL) throws {
        try self.init(model: MLModel(contentsOf: modelURL))
    }

    package convenience init(contentsOf modelURL: URL, configuration: MLModelConfiguration) throws {
        try self.init(model: MLModel(contentsOf: modelURL, configuration: configuration))
    }

    package class func load(configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<e5_small_v2, Error>) -> Void) {
        load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration, completionHandler: handler)
    }

    package class func load(configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> e5_small_v2 {
        try await load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration)
    }

    package class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<e5_small_v2, Error>) -> Void) {
        MLModel.load(contentsOf: modelURL, configuration: configuration) { result in
            switch result {
            case .failure(let error):
                handler(.failure(error))
            case .success(let model):
                handler(.success(e5_small_v2(model: model)))
            }
        }
    }

    package class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> e5_small_v2 {
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        return e5_small_v2(model: model)
    }

    package func prediction(input: e5_small_v2Input) throws -> e5_small_v2Output {
        try prediction(input: input, options: MLPredictionOptions())
    }

    package func prediction(input: e5_small_v2Input, options: MLPredictionOptions) throws -> e5_small_v2Output {
        let outFeatures = try model.prediction(from: input, options: options)
        return e5_small_v2Output(features: outFeatures)
    }

    package func prediction(input: e5_small_v2Input, options: MLPredictionOptions = MLPredictionOptions()) async throws -> e5_small_v2Output {
        let outFeatures = try await model.prediction(from: input, options: options)
        return e5_small_v2Output(features: outFeatures)
    }

    package func prediction(input_ids: MLMultiArray, attention_mask: MLMultiArray) throws -> e5_small_v2Output {
        let input_ = e5_small_v2Input(input_ids: input_ids, attention_mask: attention_mask)
        return try prediction(input: input_)
    }

    package func prediction(input_ids: MLShapedArray<Int32>, attention_mask: MLShapedArray<Int32>) throws -> e5_small_v2Output {
        let input_ = e5_small_v2Input(input_ids: input_ids, attention_mask: attention_mask)
        return try prediction(input: input_)
    }

    package func predictions(inputs: [e5_small_v2Input], options: MLPredictionOptions = MLPredictionOptions()) throws -> [e5_small_v2Output] {
        let batchIn = MLArrayBatchProvider(array: inputs)
        let batchOut = try model.predictions(from: batchIn, options: options)
        var results : [e5_small_v2Output] = []
        results.reserveCapacity(inputs.count)
        for i in 0..<batchOut.count {
            let outProvider = batchOut.features(at: i)
            let result = e5_small_v2Output(features: outProvider)
            results.append(result)
        }
        return results
    }
}
#endif // canImport(CoreML)
