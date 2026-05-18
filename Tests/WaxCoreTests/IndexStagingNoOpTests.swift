import Foundation
import Testing
@testable import WaxCore

@Test func stageLexIndexIdenticalToCommittedIsNoOp() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let bytes = Data("lex-v1".utf8)
    try await wax.stageLexIndexForNextCommit(bytes: bytes, docCount: 1, version: 1)
    try await wax.commit()

    let generationAfterFirstCommit = await wax.stats().generation
    #expect(generationAfterFirstCommit > 0)

    try await wax.stageLexIndexForNextCommit(bytes: bytes, docCount: 1, version: 1)
    let stagedStamp = await wax.stagedLexIndexStamp()
    #expect(stagedStamp == nil)

    try await wax.commit()
    let generationAfterNoOpCommit = await wax.stats().generation
    #expect(generationAfterNoOpCommit == generationAfterFirstCommit)

    try await wax.close()
}

@Test func stageVecIndexIdenticalToCommittedIsNoOp() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let bytes = validFlatVecIndexSegment(vectorCount: 2, dimension: 4, similarity: .cosine)
    try await wax.stageVecIndexForNextCommit(
        bytes: bytes,
        vectorCount: 2,
        dimension: 4,
        similarity: .cosine
    )
    try await wax.commit()

    let generationAfterFirstCommit = await wax.stats().generation
    #expect(generationAfterFirstCommit > 0)

    try await wax.stageVecIndexForNextCommit(
        bytes: bytes,
        vectorCount: 2,
        dimension: 4,
        similarity: .cosine
    )
    let stagedStamp = await wax.stagedVecIndexStamp()
    #expect(stagedStamp == nil)

    try await wax.commit()
    let generationAfterNoOpCommit = await wax.stats().generation
    #expect(generationAfterNoOpCommit == generationAfterFirstCommit)

    try await wax.close()
}

@Test func stageVecIndexRejectsMalformedSegmentBytes() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    await #expect(throws: WaxError.self) {
        try await wax.stageVecIndexForNextCommit(
            bytes: Data([0x01]),
            vectorCount: 0,
            dimension: 4,
            similarity: .cosine
        )
    }

    try await wax.close()
}

private func validFlatVecIndexSegment(
    vectorCount: UInt64,
    dimension: UInt32,
    similarity: VecSimilarity
) -> Data {
    var data = Data([0x4D, 0x56, 0x32, 0x56])
    var version = UInt16(1).littleEndian
    withUnsafeBytes(of: &version) { data.append(contentsOf: $0) }
    data.append(3)
    data.append(similarity.rawValue)
    var dimensionLE = dimension.littleEndian
    withUnsafeBytes(of: &dimensionLE) { data.append(contentsOf: $0) }
    var vectorCountLE = vectorCount.littleEndian
    withUnsafeBytes(of: &vectorCountLE) { data.append(contentsOf: $0) }

    let floatCount = Int(vectorCount) * Int(dimension)
    let vectors = [Float](repeating: 0, count: floatCount)
    var payloadLength = UInt64(floatCount * MemoryLayout<Float>.stride).littleEndian
    withUnsafeBytes(of: &payloadLength) { data.append(contentsOf: $0) }
    data.append(Data(repeating: 0, count: 8))
    vectors.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }

    let frameIds = (0..<vectorCount).map { UInt64($0) }
    var frameIdLength = UInt64(frameIds.count * MemoryLayout<UInt64>.stride).littleEndian
    withUnsafeBytes(of: &frameIdLength) { data.append(contentsOf: $0) }
    frameIds.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    return data
}

@Test func noOpLexStagingDoesNotBlockFrameCommit() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let bytes = Data("lex-v1".utf8)
    try await wax.stageLexIndexForNextCommit(bytes: bytes, docCount: 1, version: 1)
    try await wax.commit()
    let baselineGeneration = await wax.stats().generation

    _ = try await wax.put(Data("pending-frame".utf8), options: FrameMetaSubset(searchText: "pending-frame"))
    try await wax.stageLexIndexForNextCommit(bytes: bytes, docCount: 1, version: 1)
    try await wax.commit()

    let stats = await wax.stats()
    #expect(stats.frameCount == 1)
    #expect(stats.generation == baselineGeneration + 1)

    try await wax.close()
}
