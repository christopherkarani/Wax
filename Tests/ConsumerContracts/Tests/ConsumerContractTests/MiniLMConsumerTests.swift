import Foundation
import Testing
import Wax

@Suite("MiniLMConsumerTests")
struct MiniLMConsumerTests {
@Test
func embeddingStatusAndAutomaticOptionsArePublic() {
    let disabled = EmbeddingStatus.disabled
    let unavailable = EmbeddingStatus.unavailable(reason: "model missing")
    let active = EmbeddingStatus.active(identity: nil)
    #expect(disabled != unavailable)
    #expect(active != disabled)

    #expect(BuiltInEmbeddingProviderOptions.automatic.timeoutSeconds == 15)
    #expect(BuiltInEmbeddingProviderOptions.default.timeoutSeconds == 120)
    #expect(BuiltInEmbeddingProviderOptions.automatic.computeUnitsOrder == [
        .cpuAndNeuralEngine,
        .cpuOnly,
        .cpuAndGPU,
        .all,
    ])

    let stats = Memory.Stats(
        frameCount: 0,
        pendingFrames: 0,
        vectorSearchEnabled: false,
        queryEmbedderConfigured: false,
        queryEmbeddingCircuitOpen: false,
        embedderIdentity: nil
    )
    #expect(stats.embeddingStatus == .disabled)
}

@Test
func memoryStatsReportDisabledEmbeddingWhenVectorSearchOff() async throws {
    let url = FileManager.default.temporaryDirectory
        .appending(path: "wax-minilm-consumer-\(UUID().uuidString).wax")
    defer { try? FileManager.default.removeItem(at: url) }

    let memory = try await Memory(
        at: url,
        config: .init(
            enableVectorSearch: false,
            requireOnDeviceProviders: false
        )
    )
    let stats = await memory.stats()
    #expect(stats.embeddingStatus == .disabled)
    #expect(stats.queryEmbedderConfigured == false)
    try await memory.close()
}
}
