import Testing
@testable import WaxVectorSearch

@Test func usearchQuantizationRoundTripHeader() async throws {
    let dimensions = 8
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: dimensions, quantization: .f16)
    try await engine.add(frameId: 1, vector: [Float](repeating: 0.1, count: dimensions))

    let data = try await engine.serialize()
    let decoded = try VectorSerializer.decodeVecSegment(from: data)
    guard case .uSearch(let info, _) = decoded else {
        #expect(Bool(false))
        return
    }
    #expect(info.quantization == .f16)
}

@Test func usearchQuantizationMismatchThrows() async throws {
    let dimensions = 8
    let engine = try USearchVectorEngine(metric: .cosine, dimensions: dimensions, quantization: .f16)
    try await engine.add(frameId: 1, vector: [Float](repeating: 0.2, count: dimensions))
    let data = try await engine.serialize()

    let mismatched = try USearchVectorEngine(metric: .cosine, dimensions: dimensions, quantization: .f32)
    do {
        try await mismatched.deserialize(data)
        #expect(Bool(false))
    } catch {
        #expect(Bool(true))
    }
}
