import Foundation
import Testing
@testable import WaxCore

@Test func closePropagatesMissingVecIndexAutoCommitError() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("frame".utf8))
    try await wax.putEmbedding(frameId: 0, vector: [0.1, 0.2])

    do {
        try await wax.close()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .vectorIndexNotStaged = error else {
            #expect(Bool(false))
            return
        }
        let reason = error.errorDescription ?? ""
        #expect(reason.contains("vector index dimension and similarity must be set before committing the first embeddings"))
    }
}

/// An embedding written after the vector configuration is set still commits: the commit
/// writes every pending embedding from the WAL, so there is no index to fall behind.
@Test func closeCommitsAnEmbeddingWrittenAfterTheVectorConfiguration() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("frame".utf8))
    try await wax.putEmbedding(frameId: 0, vector: [0.1, 0.2])
    try await wax.setVectorIndexConfiguration(dimension: 2, similarity: .cosine)
    try await wax.putEmbedding(frameId: 0, vector: [0.3, 0.4])
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    let committed = try #require(try await reopened.readCommittedVectors())
    #expect(committed.frameIds == [0])
    #expect(committed.vectors == [0.3, 0.4])
    try await reopened.close()
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

@Test func commitLockedRestoresActorStateWhenDurableCommitFails() throws {
    let source = try String(
        contentsOfFile: "Sources/WaxCore/Wax.swift",
        encoding: .utf8
    )
    let start = try #require(source.range(of: "    func commitLocked(frameImport importing: FrameImport? = nil) async throws {"))
    let remainder = source[start.lowerBound...]
    let end = try #require(remainder.range(of: "    private struct CommitRollbackState {"))
    let body = String(remainder[..<end.lowerBound])

    let rollbackCapture = try #require(body.range(of: "let rollbackState = CommitRollbackState.capture(from: self)"))
    let applyPending = try #require(body.range(of: "let applied = try applyPendingMutationsIntoTOC(frameImport: importing)"))
    let restoreDefer = try #require(body.range(of: "defer {\n            if !commitSucceeded {\n                rollbackState.restore(into: self)"))
    let successMark = try #require(body.range(of: "commitSucceeded = true"))

    #expect(rollbackCapture.lowerBound < applyPending.lowerBound)
    #expect(rollbackCapture.lowerBound < restoreDefer.lowerBound)
    #expect(applyPending.lowerBound < successMark.lowerBound)
}
