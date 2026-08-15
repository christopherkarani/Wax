import Foundation
import Wax

/// Bring-your-own embedder. Keep dimensions + identity stable for a given .wax file.
actor MyEmbedder: EmbeddingProvider {
    let dimensions = 384
    let normalize = true
    let identity: EmbeddingIdentity? = .init(
        provider: "Local",
        model: "v1",
        dimensions: 384,
        normalized: true
    )
    // Default is on-device. For networked models set `executionMode = .mayUseNetwork`
    // and open Memory with `requireOnDeviceProviders = false`.

    func embed(_ text: String) async throws -> [Float] {
        [Float](repeating: 0, count: dimensions)
    }
}

func openWithCustomEmbedder(at url: URL) async throws -> Memory {
    try FileManager.default.createDirectory(
        at: url.deletingLastPathComponent(),
        withIntermediateDirectories: true
    )
    return try await Memory(at: url) { config in
        config.embedding = .custom(MyEmbedder())
    }
}
