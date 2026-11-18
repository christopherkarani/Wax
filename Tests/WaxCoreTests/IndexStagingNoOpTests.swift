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

@Test func settingTheCommittedVectorConfigurationAgainIsNoOp() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    _ = try await wax.put(Data("frame".utf8))
    try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
    try await wax.putEmbedding(frameId: 0, vector: [1, 0, 0, 0])
    try await wax.commit()

    let generationAfterFirstCommit = await wax.stats().generation
    #expect(generationAfterFirstCommit > 0)

    try await wax.setVectorIndexConfiguration(dimension: 4, similarity: .cosine)
    try await wax.commit()
    let generationAfterNoOpCommit = await wax.stats().generation
    #expect(generationAfterNoOpCommit == generationAfterFirstCommit)

    try await wax.close()
}

@Test func vectorConfigurationRejectsAZeroDimension() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    await #expect(throws: WaxError.self) {
        try await wax.setVectorIndexConfiguration(dimension: 0, similarity: .cosine)
    }

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
