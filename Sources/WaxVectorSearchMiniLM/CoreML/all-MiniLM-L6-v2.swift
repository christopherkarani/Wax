//
// all_MiniLM_L6_v2.swift
//
// This file was automatically generated and should not be edited.
//

@preconcurrency import CoreML


/// Model Prediction Input Type
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
public class all_MiniLM_L6_v2Input : MLFeatureProvider {

    /// input_ids as 1 by 512 matrix of floats
    public var input_ids: MLMultiArray

    /// attention_mask as 1 by 512 matrix of floats
    public var attention_mask: MLMultiArray

    public var featureNames: Set<String> { ["input_ids", "attention_mask"] }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        if featureName == "input_ids" {
            return MLFeatureValue(multiArray: input_ids)
        }
        if featureName == "attention_mask" {
            return MLFeatureValue(multiArray: attention_mask)
        }
        return nil
    }

    public init(input_ids: MLMultiArray, attention_mask: MLMultiArray) {
        self.input_ids = input_ids
        self.attention_mask = attention_mask
    }

    public convenience init(input_ids: MLShapedArray<Float>, attention_mask: MLShapedArray<Float>) {
        self.init(input_ids: MLMultiArray(input_ids), attention_mask: MLMultiArray(attention_mask))
    }

}


/// Model Prediction Output Type
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
public class all_MiniLM_L6_v2Output : MLFeatureProvider {

    /// Source provided by CoreML
    private let provider : any MLFeatureProvider

    /// embeddings as multidimensional array of floats
    public var embeddings: MLMultiArray {
        provider.featureValue(for: "embeddings")!.multiArrayValue!
    }

    /// embeddings as multidimensional array of floats
    public var embeddingsShapedArray: MLShapedArray<Float> {
        MLShapedArray<Float>(embeddings)
    }

    public var featureNames: Set<String> {
        provider.featureNames
    }

    public func featureValue(for featureName: String) -> MLFeatureValue? {
        provider.featureValue(for: featureName)
    }

    public init(embeddings: MLMultiArray) {
        self.provider = try! MLDictionaryFeatureProvider(dictionary: ["embeddings" : MLFeatureValue(multiArray: embeddings)])
    }

    public init(features: any MLFeatureProvider) {
        self.provider = features
    }
}


/// Class for model loading and prediction
@available(macOS 12.0, iOS 15.0, tvOS 15.0, watchOS 8.0, visionOS 1.0, *)
public class all_MiniLM_L6_v2 {
    public let model: MLModel

    /// URL of model assuming it was installed in the same bundle as this class
    class var urlOfModelInThisBundle : URL {
        let bundle = Bundle.module
        return bundle.url(forResource: "all-MiniLM-L6-v2", withExtension:"mlmodelc")!
    }

    /**
        Construct all_MiniLM_L6_v2 instance with an existing MLModel object.

        Usually the application does not use this initializer unless it makes a subclass of all_MiniLM_L6_v2.
        Such application may want to use `MLModel(contentsOfURL:configuration:)` and `all_MiniLM_L6_v2.urlOfModelInThisBundle` to create a MLModel object to pass-in.

        - parameters:
          - model: MLModel object
    */
    init(model: MLModel) {
        self.model = model
    }

    /**
        Construct a model with configuration

        - parameters:
           - configuration: the desired model configuration

        - throws: an NSError object that describes the problem
    */
    public convenience init(configuration: MLModelConfiguration = MLModelConfiguration()) throws {
        try self.init(contentsOf: type(of:self).urlOfModelInThisBundle, configuration: configuration)
    }

    /**
        Construct all_MiniLM_L6_v2 instance with explicit path to mlmodelc file
        - parameters:
           - modelURL: the file url of the model

        - throws: an NSError object that describes the problem
    */
    public convenience init(contentsOf modelURL: URL) throws {
        try self.init(model: MLModel(contentsOf: modelURL))
    }

    /**
        Construct a model with URL of the .mlmodelc directory and configuration

        - parameters:
           - modelURL: the file url of the model
           - configuration: the desired model configuration

        - throws: an NSError object that describes the problem
    */
    public convenience init(contentsOf modelURL: URL, configuration: MLModelConfiguration) throws {
        try self.init(model: MLModel(contentsOf: modelURL, configuration: configuration))
    }

    /**
        Construct all_MiniLM_L6_v2 instance asynchronously with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - configuration: the desired model configuration
          - handler: the completion handler to be called when the model loading completes successfully or unsuccessfully
    */
    public class func load(configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<all_MiniLM_L6_v2, any Error>) -> Void) {
        load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration, completionHandler: handler)
    }

    /**
        Construct all_MiniLM_L6_v2 instance asynchronously with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - configuration: the desired model configuration
    */
    public class func load(configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> all_MiniLM_L6_v2 {
        try await load(contentsOf: self.urlOfModelInThisBundle, configuration: configuration)
    }

    /**
        Construct all_MiniLM_L6_v2 instance asynchronously with URL of the .mlmodelc directory with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - modelURL: the URL to the model
          - configuration: the desired model configuration
          - handler: the completion handler to be called when the model loading completes successfully or unsuccessfully
    */
    public class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration(), completionHandler handler: @escaping (Swift.Result<all_MiniLM_L6_v2, any Error>) -> Void) {
        MLModel.load(contentsOf: modelURL, configuration: configuration) { result in
            switch result {
            case .failure(let error):
                handler(.failure(error))
            case .success(let model):
                handler(.success(all_MiniLM_L6_v2(model: model)))
            }
        }
    }

    /**
        Construct all_MiniLM_L6_v2 instance asynchronously with URL of the .mlmodelc directory with optional configuration.

        Model loading may take time when the model content is not immediately available (e.g. encrypted model). Use this factory method especially when the caller is on the main thread.

        - parameters:
          - modelURL: the URL to the model
          - configuration: the desired model configuration
    */
    public class func load(contentsOf modelURL: URL, configuration: MLModelConfiguration = MLModelConfiguration()) async throws -> all_MiniLM_L6_v2 {
        let model = try await MLModel.load(contentsOf: modelURL, configuration: configuration)
        return all_MiniLM_L6_v2(model: model)
    }

    /**
        Make a prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as all_MiniLM_L6_v2Input

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as all_MiniLM_L6_v2Output
    */
    public func prediction(input: all_MiniLM_L6_v2Input) throws -> all_MiniLM_L6_v2Output {
        try prediction(input: input, options: MLPredictionOptions())
    }

    /**
        Make a prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as all_MiniLM_L6_v2Input
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as all_MiniLM_L6_v2Output
    */
    public func prediction(input: all_MiniLM_L6_v2Input, options: MLPredictionOptions) throws -> all_MiniLM_L6_v2Output {
        let outFeatures = try model.prediction(from: input, options: options)
        return all_MiniLM_L6_v2Output(features: outFeatures)
    }

    /**
        Make an asynchronous prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - input: the input to the prediction as all_MiniLM_L6_v2Input
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as all_MiniLM_L6_v2Output
    */
    @available(macOS 14.0, iOS 17.0, tvOS 17.0, watchOS 10.0, visionOS 1.0, *)
    public func prediction(input: all_MiniLM_L6_v2Input, options: MLPredictionOptions = MLPredictionOptions()) async throws -> all_MiniLM_L6_v2Output {
        let outFeatures = try await model.prediction(from: input, options: options)
        return all_MiniLM_L6_v2Output(features: outFeatures)
    }

    /**
        Make a prediction using the convenience interface

        It uses the default function if the model has multiple functions.

        - parameters:
            - input_ids: 1 by 512 matrix of floats
            - attention_mask: 1 by 512 matrix of floats

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as all_MiniLM_L6_v2Output
    */
    public func prediction(input_ids: MLMultiArray, attention_mask: MLMultiArray) throws -> all_MiniLM_L6_v2Output {
        let input_ = all_MiniLM_L6_v2Input(input_ids: input_ids, attention_mask: attention_mask)
        return try prediction(input: input_)
    }

    /**
        Make a prediction using the convenience interface

        It uses the default function if the model has multiple functions.

        - parameters:
            - input_ids: 1 by 512 matrix of floats
            - attention_mask: 1 by 512 matrix of floats

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as all_MiniLM_L6_v2Output
    */

    public func prediction(input_ids: MLShapedArray<Float>, attention_mask: MLShapedArray<Float>) throws -> all_MiniLM_L6_v2Output {
        let input_ = all_MiniLM_L6_v2Input(input_ids: input_ids, attention_mask: attention_mask)
        return try prediction(input: input_)
    }

    /**
        Make a batch prediction using the structured interface

        It uses the default function if the model has multiple functions.

        - parameters:
           - inputs: the inputs to the prediction as [all_MiniLM_L6_v2Input]
           - options: prediction options

        - throws: an NSError object that describes the problem

        - returns: the result of the prediction as [all_MiniLM_L6_v2Output]
    */
    public func predictions(inputs: [all_MiniLM_L6_v2Input], options: MLPredictionOptions = MLPredictionOptions()) throws -> [all_MiniLM_L6_v2Output] {
        let batchIn = MLArrayBatchProvider(array: inputs)
        let batchOut = try model.predictions(from: batchIn, options: options)
        var results : [all_MiniLM_L6_v2Output] = []
        results.reserveCapacity(inputs.count)
        for i in 0..<batchOut.count {
            let outProvider = batchOut.features(at: i)
            let result =  all_MiniLM_L6_v2Output(features: outProvider)
            results.append(result)
        }
        return results
    }
}
