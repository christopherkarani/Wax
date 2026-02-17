import CoreGraphics
import Foundation

/// A recognized text block from OCR, with bounding box and confidence.
public struct RecognizedTextBlock: Sendable, Equatable {
    /// The recognized text content.
    public var text: String
    /// Normalized bounding box in `[0, 1]` coordinates with top-left origin.
    public var bbox: PhotoNormalizedRect
    /// Recognition confidence in `[0, 1]`.
    public var confidence: Float
    /// Detected language code (e.g., "en"), if available.
    public var language: String?

    public init(text: String, bbox: PhotoNormalizedRect, confidence: Float, language: String? = nil) {
        self.text = text
        self.bbox = bbox
        self.confidence = confidence
        self.language = language
    }
}

/// Provider for on-device optical character recognition.
///
/// Conforming types must be `Sendable`.
public protocol OCRProvider: Sendable {
    /// Declares whether this provider may call network services.
    var executionMode: ProviderExecutionMode { get }
    /// Recognize text blocks within an image.
    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock]
}

/// Provider for on-device image captioning.
///
/// Conforming types must be `Sendable`.
public protocol CaptionProvider: Sendable {
    /// Declares whether this provider may call network services.
    var executionMode: ProviderExecutionMode { get }
    /// Produce a short, human-readable caption for an image.
    func caption(for image: CGImage) async throws -> String
}
