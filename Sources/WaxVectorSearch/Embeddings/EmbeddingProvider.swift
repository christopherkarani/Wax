import Foundation

/// Declares whether a provider runs entirely on-device or may use network services.
public enum ProviderExecutionMode: String, Sendable, Equatable {
    /// Provider runs entirely on-device with no network calls.
    case onDeviceOnly
    /// Provider may call network services (e.g., cloud API).
    case mayUseNetwork
}

/// How a store ranks stored vectors against a query vector.
///
/// Declare the similarity your model was trained for through
/// ``EmbeddingProvider/similarity``. A store records the similarity of its vector index
/// when it first commits vectors, and refuses to open with an embedder that declares a
/// different one.
public enum VectorSimilarity: String, Sendable, Equatable {
    /// Cosine similarity: vectors are compared by angle, and their length is ignored.
    /// The right choice for most sentence-embedding models.
    case cosine
    /// Inner (dot) product: vector length counts, so a longer vector can outrank a
    /// better-aligned one. Use it for models trained with a dot-product objective, such
    /// as `facebook/contriever`. Pair it with `normalize = false`; with `normalize = true`
    /// every vector has unit length and dot product ranks exactly like cosine.
    case dotProduct
}

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var normalize: Bool { get }
    /// The similarity the store ranks this provider's vectors by. Default ``VectorSimilarity/cosine``.
    var similarity: VectorSimilarity { get }
    var identity: EmbeddingIdentity? { get }
    var executionMode: ProviderExecutionMode { get }
    func embed(_ text: String) async throws -> [Float]
    /// Retrieval-optimized query embedding. Default calls ``embed(_:)``.
    func embedQuery(_ text: String) async throws -> [Float]
    /// Batch embedding. Default maps ``embed(_:)`` sequentially.
    func embed(batch texts: [String]) async throws -> [[Float]]
}

public extension EmbeddingProvider {
    var executionMode: ProviderExecutionMode { .onDeviceOnly }

    var similarity: VectorSimilarity { .cosine }

    func embedQuery(_ text: String) async throws -> [Float] {
        try await embed(text)
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        var vectors: [[Float]] = []
        vectors.reserveCapacity(texts.count)
        for text in texts {
            try Task.checkCancellation()
            vectors.append(try await embed(text))
        }
        return vectors
    }
}

public protocol BatchEmbeddingProvider: EmbeddingProvider {
    func embed(batch texts: [String]) async throws -> [[Float]]
}

/// An embedding provider that can produce query-optimized embeddings.
///
/// Some models (e.g. Snowflake Arctic Embed) benefit from prepending a task-specific
/// prefix to the query text at recall time. Providers that do not need special query
/// handling can simply call through to `embed(_:)`.
public protocol QueryAwareEmbeddingProvider: EmbeddingProvider {
    /// Produce an embedding optimized for retrieval queries.
    func embedQuery(_ text: String) async throws -> [Float]
}

public struct EmbeddingIdentity: Sendable, Equatable {
    public var provider: String?
    public var model: String?
    public var dimensions: Int?
    public var normalized: Bool?

    public init(
        provider: String? = nil,
        model: String? = nil,
        dimensions: Int? = nil,
        normalized: Bool? = nil
    ) {
        self.provider = provider
        self.model = model
        self.dimensions = dimensions
        self.normalized = normalized
    }
}
