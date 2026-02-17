@_exported import CoreGraphics
import Foundation
import WaxVectorSearch

/// A host-supplied multimodal embedding provider shared by Photo and Video RAG.
///
/// Requirements:
/// - `embed(text:)` and `embed(image:)` must return vectors in the same embedding space.
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
    /// Compute an image embedding in the same space as text embeddings.
    func embed(image: CGImage) async throws -> [Float]
}

// MARK: - Deprecated Default (migration aid)

extension MultimodalEmbeddingProvider {
    /// Default removed to enforce explicit execution mode declaration.
    /// Provide an explicit `executionMode` property on your conformance.
    @available(*, deprecated, message: "Provide an explicit 'executionMode' on your MultimodalEmbeddingProvider conformance.")
    public var executionMode: ProviderExecutionMode { .onDeviceOnly }
}
