import Foundation
import Wax

enum MockEmbedderError: Error {
    case forcedFailure
}

struct DeterministicTextEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int
    let normalize: Bool
    let identity: EmbeddingIdentity?
    let executionMode: ProviderExecutionMode

    init(
        dimensions: Int = 2,
        normalize: Bool = true,
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.dimensions = dimensions
        self.normalize = normalize
        self.executionMode = executionMode
        self.identity = EmbeddingIdentity(
            provider: "Mock",
            model: "DeterministicText",
            dimensions: dimensions,
            normalized: normalize
        )
    }

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        return VectorMath.normalizeL2([a, b])
    }
}

final class WrongCountBatchEmbedder: BatchEmbeddingProvider, @unchecked Sendable {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "WrongCountBatch",
        dimensions: 2,
        normalized: true
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1, 0]
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        if texts.count <= 1 { return texts.map { _ in [1, 0] } }
        return Array(repeating: [1, 0], count: texts.count - 1)
    }
}

/// Query-aware provider that does not conform to `QueryAwareEmbeddingProvider`.
/// Used to prove `embedQuery` dispatches through `any EmbeddingProvider`.
actor RecordingPrefixQueryEmbedder: EmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Test",
        model: "PrefixQuery",
        dimensions: 2,
        normalized: true
    )

    private(set) var embedCallCount = 0
    private(set) var embedQueryCallCount = 0
    private(set) var batches: [[String]] = []

    func embed(_ text: String) async throws -> [Float] {
        embedCallCount += 1
        return Self.vector(for: text, query: false)
    }

    func embedQuery(_ text: String) async throws -> [Float] {
        embedQueryCallCount += 1
        return Self.vector(for: text, query: true)
    }

    func embed(batch texts: [String]) async throws -> [[Float]] {
        batches.append(texts)
        return texts.map { Self.vector(for: $0, query: false) }
    }

    private static func vector(for text: String, query: Bool) -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        let offset: Float = query ? 0.01 : 0
        return VectorMath.normalizeL2([a + offset, b])
    }
}

struct ConfigurableIdentityEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int
    let normalize: Bool
    let identity: EmbeddingIdentity?

    init(
        dimensions: Int = 2,
        normalize: Bool = true,
        identity: EmbeddingIdentity?
    ) {
        self.dimensions = dimensions
        self.normalize = normalize
        self.identity = identity
    }

    func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        return VectorMath.normalizeL2([a, b])
    }
}

struct WrongDimensionTextEmbedder: EmbeddingProvider, Sendable {
    let dimensions: Int = 4
    let normalize: Bool = false
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "WrongDimension",
        dimensions: 4,
        normalized: false
    )

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        return [1, 0]
    }
}

#if canImport(CoreGraphics)
import CoreGraphics

struct DeterministicMultimodalEmbedder: MultimodalEmbeddingProvider, Sendable {
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "Mock",
        model: "DeterministicMultimodal",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode

    init(executionMode: ProviderExecutionMode = .onDeviceOnly) {
        self.executionMode = executionMode
    }

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [0, 1, 0, 0]
    }
}
#endif

// MARK: - Hanging Mocks

/// An embedder that never completes its `embed` call (used to verify timeout/fallback logic).
actor HangingCountingEmbedder: EmbeddingProvider {
    let dimensions: Int
    let normalize: Bool
    let identity: EmbeddingIdentity?
    private var calls: Int = 0

    init(
        dimensions: Int = 2,
        normalize: Bool = false,
        identity: EmbeddingIdentity? = EmbeddingIdentity(
            provider: "Mock",
            model: "HangingCounting",
            dimensions: 2,
            normalized: false
        )
    ) {
        self.dimensions = dimensions
        self.normalize = normalize
        self.identity = identity
    }

    func embed(_ text: String) async throws -> [Float] {
        _ = text
        calls += 1
        // Sleep "forever" (cancellable) to simulate a hung provider without triggering
        // Swift's checked-continuation misuse diagnostics in tests.
        try await Task.sleep(for: .seconds(60))
        return Array(repeating: 0, count: dimensions)
    }

    func callCount() -> Int { calls }
}
