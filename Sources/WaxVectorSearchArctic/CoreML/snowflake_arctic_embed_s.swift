//
// snowflake_arctic_embed_s.swift
//
// This file was automatically generated and should not be edited.
//

#if canImport(CoreML)
import CoreML


/// Model Prediction Input Type
@available(macOS 15.0, iOS 18.0, tvOS 18.0, watchOS 11.0, visionOS 2.0, *)
package class snowflake_arctic_embed_sInput : MLFeatureProvider {

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
package class snowflake_arctic_embed_sOutput : MLFeatureProvider {

    /// Source provided by CoreML
    private let provider : MLFeatureProvider

    /// embeddings as multidimensional array of 16-bit floats
    package var embeddings: MLMultiArray {
        provider.featureValue(for: "embeddings")!.multiArrayValue!
    }

    /// embeddings as multidimensional array of 16-bit floats
    #if !(os(macOS) || targetEnvironment(macCatalyst))
    package var embeddingsShapedArray: MLShapedArray<Float16> {
        MLShapedArray<Float16>(embeddings)
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
package class snowflake_arctic_embed_s {
    package let model: MLModel

    /// URL of model assuming it was installed in the same bundle as this class
    class var urlOfModelInThisBundle : URL {
        #if SWIFT_PACKAGE
        let moduleBundle = Bundle.module
        if let url = moduleBundle.url(forResource: "snowflake-arctic-embed-s", withExtension: "mlmodelc") {
            return url
        }
        #endif
        let bundle = Bundle(for: self)
        return bundle.url(forResource: "snowflake-arctic-embed-s", withExtension: "mlmodelc")!
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

    package class func load(configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<snowflake_arctic_embed_s, Error>) -> Void) {
        load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration, completionHandler: handler)
    }

    package class func load(configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> snowflake_arctic_embed_s {
        try await load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration)
    }

    package class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<snowflake_arctic_embed_s, Error>) -> Void) {
        MLModel.load(contentsOf: modelURL, configuration: configuration) { result in
            switch result {
            case .failure(let error):
                handler(.failure(error))
            case .success(let model):
                handler(.success(snowflake_arctic_embed_s(model: model)))
            }
        }
    }

    package class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> snowflake_arctic_embed_s {
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        return snowflake_arctic_embed_s(model: model)
    }

    package func prediction(input: snowflake_arctic_embed_sInput) throws -> snowflake_arctic_embed_sOutput {
        try prediction(input: input, options: MLPredictionOptions())
    }

    package func prediction(input: snowflake_arctic_embed_sInput, options: MLPredictionOptions) throws -> snowflake_arctic_embed_sOutput {
        let outFeatures = try model.prediction(from: input, options: options)
        return snowflake_arctic_embed_sOutput(features: outFeatures)
    }

    package func prediction(input: snowflake_arctic_embed_sInput, options: MLPredictionOptions = MLPredictionOptions()) async throws -> snowflake_arctic_embed_sOutput {
        let outFeatures = try await model.prediction(from: input, options: options)
        return snowflake_arctic_embed_sOutput(features: outFeatures)
    }

    package func prediction(input_ids: MLMultiArray, attention_mask: MLMultiArray) throws -> snowflake_arctic_embed_sOutput {
        let input_ = snowflake_arctic_embed_sInput(input_ids: input_ids, attention_mask: attention_mask)
        return try prediction(input: input_)
    }

    package func prediction(input_ids: MLShapedArray<Int32>, attention_mask: MLShapedArray<Int32>) throws -> snowflake_arctic_embed_sOutput {
        let input_ = snowflake_arctic_embed_sInput(input_ids: input_ids, attention_mask: attention_mask)
        return try prediction(input: input_)
    }

    package func predictions(inputs: [snowflake_arctic_embed_sInput], options: MLPredictionOptions = MLPredictionOptions()) throws -> [snowflake_arctic_embed_sOutput] {
        let batchIn = MLArrayBatchProvider(array: inputs)
        let batchOut = try model.predictions(from: batchIn, options: options)
        var results : [snowflake_arctic_embed_sOutput] = []
        results.reserveCapacity(inputs.count)
        for i in 0..<batchOut.count {
            let outProvider = batchOut.features(at: i)
            let result = snowflake_arctic_embed_sOutput(features: outProvider)
            results.append(result)
        }
        return results
    }
}
#endif // canImport(CoreML)
