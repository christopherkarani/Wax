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
        bytes: Data([0x01, 0x02, 0x03]),
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
