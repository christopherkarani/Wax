#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WaxVectorSearch

/// Image encoding declared by public multimodal APIs.
public enum WaxImageFormat: Sendable, Equatable {
    case jpeg
    case png
    case heic
    case other(uti: String)
}

/// A host-supplied multimodal embedding provider shared by Photo and Video memory.
///
/// Requirements:
/// - `embed(text:)` and `embed(imageData:format:)` must return vectors in the same embedding space.
/// - If `normalize == true`, Wax will L2-normalize embeddings before storage/search.
public protocol MultimodalEmbeddingProvider: Sendable {
    /// Dimensionality of all embeddings produced by this provider.
    var dimensions: Int { get }
    /// Whether embeddings are expected to be L2-normalized.
    var normalize: Bool { get }
    /// Optional identity metadata to stamp into Wax frame metadata at write time.
    var identity: EmbeddingIdentity? { get }
    /// Declares whether the provider may call network services.
    var executionMode: ProviderExecutionMode { get }

    /// Compute a text embedding in the same space as image embeddings.
    func embed(text: String) async throws -> [Float]
    /// Compute an image embedding from encoded bytes in the same space as text embeddings.
    func embed(imageData: Data, format: WaxImageFormat) async throws -> [Float]
}

/// Package-only CGImage embedding pipeline used by Photo/Video orchestrators.
package protocol CGImageEmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var normalize: Bool { get }
    var identity: EmbeddingIdentity? { get }
    var executionMode: ProviderExecutionMode { get }
    func embed(text: String) async throws -> [Float]
    func embed(image: CGImage) async throws -> [Float]
}

extension CGImageEmbeddingProvider {
    /// Default removed to enforce explicit execution mode declaration.
    /// Provide an explicit `executionMode` property on your conformance.
    @available(*, deprecated, message: "Provide an explicit 'executionMode' on your CGImageEmbeddingProvider conformance.")
    package var executionMode: ProviderExecutionMode { .onDeviceOnly }
}

/// Bridges a public byte-oriented embedder into the CGImage pipeline.
package struct MultimodalEmbeddingProviderAdapter: CGImageEmbeddingProvider {
    private let wrapped: any MultimodalEmbeddingProvider

    package init(_ wrapped: any MultimodalEmbeddingProvider) {
        self.wrapped = wrapped
    }

    package var dimensions: Int { wrapped.dimensions }
    package var normalize: Bool { wrapped.normalize }
    package var identity: EmbeddingIdentity? { wrapped.identity }
    package var executionMode: ProviderExecutionMode { wrapped.executionMode }

    package func embed(text: String) async throws -> [Float] {
        try await wrapped.embed(text: text)
    }

    package func embed(image: CGImage) async throws -> [Float] {
        let data = try WaxImageCodec.encodePNG(image)
        return try await wrapped.embed(imageData: data, format: .png)
    }
}

package enum WaxImageCodec {
    package static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(
            data as CFMutableData,
            UTType.png.identifier as CFString,
            1,
            nil
        ) else {
            throw WaxError.io("failed to create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WaxError.io("failed to encode png")
        }
        return data as Data
    }
}

#endif // canImport(ImageIO)
