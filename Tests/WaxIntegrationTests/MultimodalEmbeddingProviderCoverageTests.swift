import CoreGraphics
import Testing
import Wax

private struct DefaultExecutionModeProvider: MultimodalEmbeddingProvider {
    let dimensions: Int = 2
    let normalize: Bool = false
    let identity: EmbeddingIdentity? = nil

    func embed(text: String) async throws -> [Float] {
        _ = text
        return [1, 0]
    }

    func embed(image: CGImage) async throws -> [Float] {
        _ = image
        return [0, 1]
    }
}

@Test
func multimodalEmbeddingProviderDefaultExecutionModeIsOnDeviceOnly() async {
    let provider = DefaultExecutionModeProvider()
    #expect(provider.executionMode == .onDeviceOnly)
}
