#if canImport(Metal)
import Metal
import Testing
@testable import WaxVectorSearch

@Test
func metalSearchReusesTransientBuffers() async throws {
    guard MTLCreateSystemDefaultDevice() != nil else { return }
    let engine = try MetalVectorEngine(metric: .cosine, dimensions: 2)
    try await engine.add(frameId: 1, vector: [1.0, 0.0])

    _ = try await engine.search(vector: [1.0, 0.0], topK: 1)
    let first = await engine.debugBufferPoolStats()

    _ = try await engine.search(vector: [1.0, 0.0], topK: 1)
    let second = await engine.debugBufferPoolStats()

    #expect(second.transientAllocations == first.transientAllocations)
    #expect(second.reuseCount >= first.reuseCount)
}
#endif
