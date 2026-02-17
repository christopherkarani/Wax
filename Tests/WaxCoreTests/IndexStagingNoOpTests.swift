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
    let bytes = Data("vec-v1".utf8)
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
