#if MCPServer && canImport(CoreGraphics) && canImport(ImageIO)
import CoreGraphics
import Foundation
import Wax
import WaxVectorSearch

#if canImport(Vision)
@preconcurrency import Vision
#endif

/// Adapter that approximates multimodal embeddings by converting image content into text.
///
/// This is intentionally not a CLIP-style joint vision-language encoder. Instead, it derives
/// lightweight labels and OCR text from an image, then embeds that synthesized description
/// with the base text embedding provider. This is sufficient for caption-style retrieval.
struct MultimodalAdapter: MultimodalEmbeddingProvider, Sendable {
    /// Minimum Vision classification confidence to include a label in the image description.
    private static let minimumLabelConfidence: Float = 0.3

    let base: any EmbeddingProvider

    var dimensions: Int { base.dimensions }
    var normalize: Bool { base.normalize }
    var identity: EmbeddingIdentity? { base.identity }
    var executionMode: ProviderExecutionMode { base.executionMode }

    init(base: any EmbeddingProvider) {
        self.base = base
    }

    func embed(text: String) async throws -> [Float] {
        try await base.embed(text)
    }

    func embed(image: CGImage) async throws -> [Float] {
        let description = await Self.describe(image: image)
        return try await base.embed(description)
    }

    /// Vision work is synchronous and heavy, so it runs on the concurrent pool.
    @concurrent
    private static func describe(image: CGImage) async -> String {
        #if canImport(Vision)
        var labels: [String] = []
        var ocrText: [String] = []

        let classifyRequest = VNClassifyImageRequest()
        let textRequest = VNRecognizeTextRequest()
        textRequest.recognitionLevel = .fast
        textRequest.usesLanguageCorrection = false

        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        // If Vision fails (e.g. unsupported format), fall through to a
        // generic description rather than propagating to the caller.
        do {
            try handler.perform([classifyRequest, textRequest])
        } catch {
            return "image content"
        }

        if let observations = classifyRequest.results {
            labels = observations
                .filter { $0.confidence > MultimodalAdapter.minimumLabelConfidence }
                .prefix(5)
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
        #else
        return "image content"
        #endif
    }
}
#endif
