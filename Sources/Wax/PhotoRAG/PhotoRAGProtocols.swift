import CoreGraphics
import Foundation
import WaxVectorSearch

public protocol MultimodalEmbeddingProvider: Sendable {
    /// The dimensionality of embeddings produced by this provider.
    var dimensions: Int { get }
    /// Whether the provider produces (or expects) L2-normalized embeddings.
    ///
    /// - Important: Wax’s Metal vector search requires L2-normalized embeddings.
    var normalize: Bool { get }
    /// Optional identity metadata to stamp into Wax frame metadata at write time.
    var identity: EmbeddingIdentity? { get }

    /// Compute a text embedding in the same space as image embeddings.
    func embed(text: String) async throws -> [Float]
    /// Compute an image embedding in the same space as text embeddings.
    func embed(image: CGImage) async throws -> [Float]
}

public struct RecognizedTextBlock: Sendable, Equatable {
    public var text: String
    public var bbox: PhotoNormalizedRect
    public var confidence: Float
    public var language: String?

    public init(text: String, bbox: PhotoNormalizedRect, confidence: Float, language: String? = nil) {
        self.text = text
        self.bbox = bbox
        self.confidence = confidence
        self.language = language
    }
}

public protocol OCRProvider: Sendable {
    /// Recognize text blocks within an image.
    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock]
}

public protocol CaptionProvider: Sendable {
    /// Produce a short, human-readable caption for an image.
    func caption(for image: CGImage) async throws -> String
}
