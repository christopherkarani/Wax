import Foundation
import Wax

// Deterministic embedders shared by the Wax test targets. Each one replaces stubs that were
// copied, with identical output, into several test files. Stubs that record calls, fail on
// purpose, block, or route keywords to lanes stay next to the tests that rely on them.

/// Returns the same vector for every input.
package struct ConstantEmbedder: EmbeddingProvider, Sendable {
    package let dimensions: Int
    package let normalize: Bool
    package let identity: EmbeddingIdentity?
    package let executionMode: ProviderExecutionMode
    private let vector: [Float]

    package init(
        vector: [Float],
        identity: EmbeddingIdentity?,
        normalized: Bool = true,
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.vector = vector
        self.dimensions = vector.count
        self.normalize = normalized
        self.identity = identity
        self.executionMode = executionMode
    }

    /// Identified as `provider` / `model` at `vector.count` dimensions.
    package init(
        vector: [Float],
        provider: String,
        model: String,
        normalized: Bool = true,
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.init(
            vector: vector,
            identity: EmbeddingIdentity(
                provider: provider,
                model: model,
                dimensions: vector.count,
                normalized: normalized
            ),
            normalized: normalized,
            executionMode: executionMode
        )
    }

    package func embed(_ text: String) async throws -> [Float] {
        _ = text
        return vector
    }
}

/// Maps text to an L2-normalized 2-D vector built from its UTF-8 and scalar lengths, so texts
/// of different lengths land at different points. `dimensions` only labels the provider: the
/// vector always has two components.
package struct DeterministicTextEmbedder: EmbeddingProvider, Sendable {
    package let dimensions: Int
    package let normalize: Bool
    package let identity: EmbeddingIdentity?
    package let executionMode: ProviderExecutionMode

    /// Identified as provider `Mock`, model `DeterministicText`.
    package init(
        dimensions: Int = 2,
        normalize: Bool = true,
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.init(
            dimensions: dimensions,
            normalize: normalize,
            identity: EmbeddingIdentity(
                provider: "Mock",
                model: "DeterministicText",
                dimensions: dimensions,
                normalized: normalize
            ),
            executionMode: executionMode
        )
    }

    package init(
        dimensions: Int = 2,
        normalize: Bool = true,
        identity: EmbeddingIdentity?,
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.dimensions = dimensions
        self.normalize = normalize
        self.identity = identity
        self.executionMode = executionMode
    }

    package func embed(_ text: String) async throws -> [Float] {
        let a = Float(text.utf8.count % 97) / 97.0
        let b = Float(text.unicodeScalars.count % 89) / 89.0
        return VectorMath.normalizeL2([a, b])
    }
}

/// Seeds a 64-bit LCG with the FNV-1a hash of the text's UTF-8 bytes and fills `dimensions`
/// components from it, so equal texts get equal vectors and different texts spread out.
package struct SeededHashEmbedder: EmbeddingProvider, Sendable {
    package let dimensions: Int
    package let normalize: Bool
    package let identity: EmbeddingIdentity?

    /// Identified as `provider`, model `fnv1a-lcg`.
    package init(dimensions: Int, normalize: Bool = true, provider: String = "bench") {
        self.dimensions = dimensions
        self.normalize = normalize
        self.identity = EmbeddingIdentity(
            provider: provider,
            model: "fnv1a-lcg",
            dimensions: dimensions,
            normalized: normalize
        )
    }

    package func embed(_ text: String) async throws -> [Float] {
        var state = fnv1a64(text)
        var vector = [Float](repeating: 0, count: dimensions)
        for index in vector.indices {
            state = state &* 6364136223846793005 &+ 1442695040888963407
            let signed = Int64(bitPattern: state)
            vector[index] = Float(signed) / Float(Int64.max)
        }
        return normalize ? VectorMath.normalizeL2(vector) : vector
    }
}

/// An 8-D vector whose first component is the text's FNV-1a hash modulo 1000, scaled into
/// `[0, 1)`; the other components are zero. Identified as provider `Test` with `model`.
package struct HashBucketEmbedder: EmbeddingProvider, Sendable {
    package let dimensions = 8
    package let normalize = true
    package let identity: EmbeddingIdentity?

    package init(model: String) {
        identity = EmbeddingIdentity(provider: "Test", model: model, dimensions: 8, normalized: true)
    }

    package func embed(_ text: String) async throws -> [Float] {
        var vector = [Float](repeating: 0, count: dimensions)
        vector[0] = Float(fnv1a64(text) % 1_000) / 1_000
        return vector
    }
}

private func fnv1a64(_ text: String) -> UInt64 {
    var hash: UInt64 = 14_695_981_039_346_656_037
    for byte in text.utf8 {
        hash ^= UInt64(byte)
        hash &*= 1_099_511_628_211
    }
    return hash
}

#if canImport(ImageIO)
import CoreGraphics

/// Embeds every text as `[1, 0, 0, 0]` and every image as `[0, 1, 0, 0]`.
package struct DeterministicMultimodalEmbedder: MultimodalEmbeddingProvider, Sendable {
    package let dimensions = 4
    package let normalize = true
    package let identity: EmbeddingIdentity?
    package let executionMode: ProviderExecutionMode

    /// `identity` defaults to provider `Mock`, model `DeterministicMultimodal`.
    package init(
        identity: EmbeddingIdentity? = EmbeddingIdentity(
            provider: "Mock",
            model: "DeterministicMultimodal",
            dimensions: 4,
            normalized: true
        ),
        executionMode: ProviderExecutionMode = .onDeviceOnly
    ) {
        self.identity = identity
        self.executionMode = executionMode
    }

    package func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0, 0, 0]
    }

    package func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [0, 1, 0, 0]
    }
}

/// An 8-D multimodal embedder: text maps from the sum of its UTF-8 bytes, an image from its
/// width and height, each L2-normalized. Identified as provider `Test` with `model`.
package struct ByteSumMultimodalEmbedder: MultimodalEmbeddingProvider, Sendable {
    package let executionMode: ProviderExecutionMode = .onDeviceOnly
    package let dimensions = 8
    package let normalize = true
    package let identity: EmbeddingIdentity?

    package init(model: String) {
        identity = EmbeddingIdentity(provider: "Test", model: model, dimensions: 8, normalized: true)
    }

    package func embed(text: String) async throws -> [Float] {
        let hash = text.utf8.reduce(0) { $0 &+ Int($1) }
        let raw = (0..<dimensions).map { i in Float((hash &+ i) % 97) / 97.0 }
        return VectorMath.normalizeL2(raw)
    }

    package func embed(image: CGImage) async throws -> [Float] {
        let hash = (image.width &* 31) &+ image.height
        let raw = (0..<dimensions).map { i in Float((hash &+ i &* 13) % 101) / 101.0 }
        return VectorMath.normalizeL2(raw)
    }
}
#endif
