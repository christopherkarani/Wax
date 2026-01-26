//
//  EmbeddingProtocols.swift
//
//
//  Created by Zach Nagengast on 4/7/23.
//

import Foundation
import CoreML
import NaturalLanguage
import Combine

/// A protocol for embedding models that can generate vector representations of text.
/// Implement this protocol to support different models for encoding text into vectors.
@available(macOS 11.0, iOS 15.0, *)
public protocol EmbeddingsProtocol {
    /// The associated tokenizer type for the embedding model.
    associatedtype TokenizerType

    /// The associated Core ML model type for the embedding model.
    associatedtype ModelType

    /// The tokenizer used to tokenize input text.
    var tokenizer: TokenizerType { get }

    /// The Core ML model used for generating embeddings.
    var model: ModelType { get }

    /// Encodes the input sentence into a vector representation.
    ///
    /// - Parameter sentence: The input sentence to encode.
    /// - Returns: An optional array of `Float` values representing the encoded sentence.
    func encode(sentence: String) async -> [Float]?
}

/// A protocol for arbitrary methods of calculating similarities between vectors.
public protocol DistanceMetricProtocol {
    /// Find the nearest neighbors given a query embedding vector and a list of embeddings vectors.
    ///
    /// - Parameters:
    ///   - queryEmbedding: A `[Float]` array representing the query embedding vector.
    ///   - itemEmbeddings: A `[[Float]]` array representing the list of embeddings vectors to search within.
    ///   - resultsCount: An Int representing the number of nearest neighbors to return.
    ///
    /// - Returns: A `[(Float, Int)]` array, where each tuple contains the similarity score and the index of the corresponding item in `neighborEmbeddings`. The array is sorted by decreasing similarity ranking.
    func findNearest(for queryEmbedding: [Float], in neighborEmbeddings: [[Float]], resultsCount: Int) -> [(Float, Int)]

    /// Calculate the distance between two embedding vectors.
    ///
    /// - Parameters:
    ///   - firstEmbedding: A `[Float]` array representing the first embedding vector.
    ///   - secondEmbedding: A `[Float]` array representing the second embedding vector.
    ///
    /// - Returns: A `Float` value representing the distance between the two input embedding vectors. Depending on the similarity metric implementation, the distance can represent different notions of similarity or dissimilarity.
    func distance(between firstEmbedding: [Float], and secondEmbedding: [Float]) -> Float
}

public protocol TextSplitterProtocol {
    /// Splits the input text into a tuple of chunks and optionally token ids.
    ///
    /// - Parameters:
    ///   - text: The input text to be chunked.
    ///   - chunkSize: The number of tokens per chunk.
    ///   - overlapSize: The number of overlapping tokens between consecutive chunks.
    /// - Returns: A tuple containing an array of chunked text and an optional array of token ids.
    func split(text: String, chunkSize: Int, overlapSize: Int) -> ([String], [[String]]?)
}

public protocol TokenizerProtocol {
    func tokenize(text: String) -> [String]
    func detokenize(tokens: [String]) -> String
}
