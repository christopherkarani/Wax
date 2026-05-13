import Foundation
import Testing
@testable import WaxCore

@Test func closePropagatesMissingVecIndexAutoCommitError() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.putEmbedding(frameId: 0, vector: [0.1, 0.2])

    do {
        try await wax.close()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .io(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("vector index must be staged before committing embeddings"))
    }
}

@Test func closePropagatesStaleVecIndexAutoCommitError() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    try await wax.putEmbedding(frameId: 0, vector: [0.1, 0.2])
    try await wax.stageVecIndexForNextCommit(
        bytes: validFlatVecIndexSegment(vectors: [0.1, 0.2], frameIds: [0], dimension: 2, similarity: .cosine),
        vectorCount: 1,
        dimension: 2,
        similarity: .cosine
    )
    try await wax.putEmbedding(frameId: 0, vector: [0.3, 0.4])

    do {
        try await wax.close()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .io(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("vector index is stale relative to pending embeddings"))
    }
}

private func validFlatVecIndexSegment(
    vectors: [Float],
    frameIds: [UInt64],
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
    var vectorCountLE = UInt64(frameIds.count).littleEndian
    withUnsafeBytes(of: &vectorCountLE) { data.append(contentsOf: $0) }
    var payloadLength = UInt64(vectors.count * MemoryLayout<Float>.stride).littleEndian
    withUnsafeBytes(of: &payloadLength) { data.append(contentsOf: $0) }
    data.append(Data(repeating: 0, count: 8))
    vectors.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    var frameIdLength = UInt64(frameIds.count * MemoryLayout<UInt64>.stride).littleEndian
    withUnsafeBytes(of: &frameIdLength) { data.append(contentsOf: $0) }
    frameIds.withUnsafeBufferPointer { data.append(Data(buffer: $0)) }
    return data
}

@Test func frameContentRejectsCorruptedPayloadChecksum() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("payload".utf8))
        try await wax.commit()
        try await wax.close()
    }

    guard let slice = try FooterScanner.findLastValidFooter(in: url) else {
        #expect(Bool(false))
        return
    }
    let toc = try WaxTOC.decode(from: slice.tocBytes)
    guard let frame = toc.frames.first else {
        #expect(Bool(false))
        return
    }

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        var firstByte = try file.readExactly(length: 1, at: frame.payloadOffset)
        firstByte[0] ^= 0xFF
        try file.writeAll(firstByte, at: frame.payloadOffset)
        try file.fsync()
    }

    let wax = try await Wax.open(at: url)
    do {
        _ = try await wax.frameContent(frameId: 0)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .checksumMismatch = error else {
            #expect(Bool(false))
            return
        }
    }
    try await wax.close()
}
