#if canImport(ImageIO)
import CoreGraphics
import Foundation
import WaxVectorSearch

#if canImport(Vision)
@preconcurrency import Vision
#endif

/// Factory for built-in multimodal embedding providers backed by Wax's on-device
/// text embedders.
///
/// The returned provider is not a CLIP-style joint vision-language encoder. Images
/// are described on device (Vision classification labels plus fast OCR) and the
/// synthesized description is embedded with the selected text provider, so image
/// and text vectors share one embedding space. This supports caption-style photo
/// and video retrieval with the same model that backs ``Memory``; the underlying
/// text embedder instance is shared through Wax's embedding load coordinator.
public enum BuiltInMultimodalEmbeddings {
    /// Construct a multimodal provider over a built-in text embedder.
    ///
    /// - Throws: ``BuiltInEmbeddingProviderError`` when the text provider is
    ///   unavailable on this platform or build configuration.
    public static func make(
        _ provider: BuiltInEmbeddingProvider = .miniLM,
        options: BuiltInEmbeddingProviderOptions = .default
    ) async throws -> any MultimodalEmbeddingProvider {
        let base = try await BuiltInEmbeddings.make(provider, options: options)
        return TextBridgedMultimodalEmbedder(base: base)
    }
}

/// Bridges any text ``EmbeddingProvider`` into a ``MultimodalEmbeddingProvider``
/// by describing images as text before embedding.
///
/// Image descriptions come from on-device Vision classification labels and fast
/// OCR. When Vision is unavailable or fails, a generic description is embedded so
/// ingestion never hard-fails on a single undecodable image.
public struct TextBridgedMultimodalEmbedder: MultimodalEmbeddingProvider, Sendable {
    /// Minimum Vision classification confidence for a label to be included.
    private static let minimumLabelConfidence: Float = 0.3
    /// Maximum number of classification labels included in a description.
    private static let maximumLabelCount = 5

    /// The text embedding provider that produces all vectors.
    public let base: any EmbeddingProvider

    public var dimensions: Int { base.dimensions }
    public var normalize: Bool { base.normalize }
    public var identity: EmbeddingIdentity? { base.identity }
    public var executionMode: ProviderExecutionMode { base.executionMode }

    public init(base: any EmbeddingProvider) {
        self.base = base
    }

    public func embed(text: String) async throws -> [Float] {
        try await base.embed(text)
    }

    public func embed(image: CGImage) async throws -> [Float] {
        let description = await Self.describe(image: image)
        return try await base.embed(description)
    }

    private static func describe(image: CGImage) async -> String {
        #if canImport(Vision)
        return await Task.detached(priority: .utility) {
            var labels: [String] = []
            var ocrText: [String] = []

            let classifyRequest = VNClassifyImageRequest()
            let textRequest = VNRecognizeTextRequest()
            textRequest.recognitionLevel = .fast
            textRequest.usesLanguageCorrection = false

            let handler = VNImageRequestHandler(cgImage: image, options: [:])
            do {
                try handler.perform([classifyRequest, textRequest])
            } catch {
                return "image content"
            }

            if let observations = classifyRequest.results {
                labels = observations
                    .filter { $0.confidence > minimumLabelConfidence }
                    .prefix(maximumLabelCount)
                    .map(\.identifier)
            }

            if let observations = textRequest.results {
                ocrText = observations.compactMap { observation in
                    observation.topCandidates(1).first?.string
                }
            }

            let compactOCR = ocrText
                .joined(separator: " ")
                .trimmingCharacters(in: .whitespacesAndNewlines)

            let labelText = labels.isEmpty ? "unknown scene" : labels.joined(separator: ", ")
            if compactOCR.isEmpty {
                return "image labels: \(labelText)"
            }
            return "image labels: \(labelText). recognized text: \(compactOCR)"
        }.value
        #else
        return "image content"
        #endif
    }
}
#endif // canImport(ImageIO)
