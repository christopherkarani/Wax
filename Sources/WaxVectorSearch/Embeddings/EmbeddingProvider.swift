import Foundation

/// Declares whether a provider runs entirely on-device or may use network services.
public enum ProviderExecutionMode: String, Sendable, Equatable {
    /// Provider runs entirely on-device with no network calls.
    case onDeviceOnly
    /// Provider may call network services (e.g., cloud API).
    case mayUseNetwork
}

public protocol EmbeddingProvider: Sendable {
    var dimensions: Int { get }
    var normalize: Bool { get }
    var identity: EmbeddingIdentity? { get }
    var executionMode: ProviderExecutionMode { get }
    func embed(_ text: String) async throws -> [Float]
}

public extension EmbeddingProvider {
    var executionMode: ProviderExecutionMode { .onDeviceOnly }
}

public protocol BatchEmbeddingProvider: EmbeddingProvider {
    func embed(batch texts: [String]) async throws -> [[Float]]
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
