#if canImport(ImageIO)
import CoreGraphics
import Foundation

/// A recognized text block from OCR, with bounding box and confidence.
package struct RecognizedTextBlock: Sendable, Equatable {
    /// The recognized text content.
    package var text: String
    /// Normalized bounding box in `[0, 1]` coordinates with top-left origin.
    package var bbox: PhotoNormalizedRect
    /// Recognition confidence in `[0, 1]`.
    package var confidence: Float
    /// Detected language code (e.g., "en"), if available.
    package var language: String?

    package init(text: String, bbox: PhotoNormalizedRect, confidence: Float, language: String? = nil) {
        self.text = text
        self.bbox = bbox
        self.confidence = confidence
        self.language = language
    }
}

/// Provider for on-device optical character recognition.
///
/// Conforming types must be `Sendable`.
package protocol OCRProvider: Sendable {
    /// Declares whether this provider may call network services.
    var executionMode: ProviderExecutionMode { get }
    /// Recognize text blocks within an image.
    func recognizeText(in image: CGImage) async throws -> [RecognizedTextBlock]
}

/// Provider for on-device image captioning.
///
/// Conforming types must be `Sendable`.
package protocol CaptionProvider: Sendable {
    /// Declares whether this provider may call network services.
    var executionMode: ProviderExecutionMode { get }
    /// Produce a short, human-readable caption for an image.
    func caption(for image: CGImage) async throws -> String
}

// MARK: - Deprecated Defaults (migration aid)

extension OCRProvider {
    /// Default removed to enforce explicit execution mode declaration.
    /// Provide an explicit `executionMode` property on your conformance.
    @available(*, deprecated, message: "Provide an explicit 'executionMode' on your OCRProvider conformance.")
    package var executionMode: ProviderExecutionMode { .onDeviceOnly }
}

extension CaptionProvider {
    /// Default removed to enforce explicit execution mode declaration.
    /// Provide an explicit `executionMode` property on your conformance.
    @available(*, deprecated, message: "Provide an explicit 'executionMode' on your CaptionProvider conformance.")
    package var executionMode: ProviderExecutionMode { .onDeviceOnly }
}

#endif // canImport(ImageIO)
