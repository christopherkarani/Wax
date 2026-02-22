import CoreGraphics
import Foundation
import Testing

#if MCPServer
import Wax
import WaxVectorSearch
@testable import WaxMCPServer

private actor RecordingEmbedder: EmbeddingProvider {
    let dimensions: Int = 4
    let normalize: Bool = true
    let identity: EmbeddingIdentity? = EmbeddingIdentity(
        provider: "test-provider",
        model: "test-model",
        dimensions: 4,
        normalized: true
    )
    let executionMode: ProviderExecutionMode = .onDeviceOnly

    private var inputs: [String] = []

    func embed(_ text: String) async throws -> [Float] {
        inputs.append(text)
        return [Float(text.count), 1, 0, 0]
    }

    func snapshotInputs() -> [String] {
        inputs
    }
}

private func makeSolidImage(width: Int = 8, height: Int = 8) -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    let bytesPerPixel = 4
    let bytesPerRow = width * bytesPerPixel
    let data = Data(repeating: 255, count: bytesPerRow * height)
    let provider = CGDataProvider(data: data as CFData)!
    return CGImage(
        width: width,
        height: height,
        bitsPerComponent: 8,
        bitsPerPixel: 32,
        bytesPerRow: bytesPerRow,
        space: colorSpace,
        bitmapInfo: CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue),
        provider: provider,
        decode: nil,
        shouldInterpolate: false,
        intent: .defaultIntent
    )!
}

@Test
func multimodalAdapterForwardsProviderPropertiesAndTextEmbedding() async throws {
    let embedder = RecordingEmbedder()
    let adapter = MultimodalAdapter(base: embedder)
    let expectedIdentity = embedder.identity

    #expect(adapter.dimensions == 4)
    #expect(adapter.normalize)
    #expect(adapter.identity == expectedIdentity)
    #expect(adapter.executionMode == .onDeviceOnly)

    let vector = try await adapter.embed(text: "hello")
    #expect(vector == [5, 1, 0, 0])
    #expect(await embedder.snapshotInputs() == ["hello"])
}

@Test
func multimodalAdapterEmbedsImageViaSynthesizedDescription() async throws {
    let embedder = RecordingEmbedder()
    let adapter = MultimodalAdapter(base: embedder)

    let image = makeSolidImage()
    let vector = try await adapter.embed(image: image)

    #expect(vector.count == 4)
    let inputs = await embedder.snapshotInputs()
    #expect(inputs.count == 1)
    #expect(inputs[0].lowercased().contains("image"))
}
#endif
