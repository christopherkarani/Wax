import Foundation
import Testing
@testable import WaxCore

/// The remember dedup probe looks documents up by content hash instead of scanning every
/// frame, and must keep the scan's answers across puts, commits, reopens, deletes and
/// supersedes.
private enum DedupFixture {
    static let hashKey = "wax.content.hash"

    static func hash(_ text: String) -> String {
        ContentHasher.hash(Data(text.utf8)).hexString
    }

    static func documentMetadata(_ text: String, _ metadata: [String: String]) -> [String: String] {
        var entries = metadata
        entries[hashKey] = hash(text)
        return entries
    }

    @discardableResult
    static func putDocument(
        _ wax: Wax,
        _ text: String,
        metadata: [String: String] = [:],
        chunks: Int = 0
    ) async throws -> (document: UInt64, chunks: [UInt64]) {
        let documentId = try await wax.put(
            Data(text.utf8),
            options: FrameMetaSubset(role: .document, metadata: Metadata(documentMetadata(text, metadata)))
        )
        var chunkIds: [UInt64] = []
        for index in 0..<chunks {
            chunkIds.append(try await wax.put(
                Data("\(text) chunk \(index)".utf8),
                options: FrameMetaSubset(
                    role: .chunk,
                    parentId: documentId,
                    chunkIndex: UInt32(index),
                    chunkCount: UInt32(chunks),
                    searchText: "\(text) chunk \(index)",
                    metadata: Metadata(metadata)
                )
            ))
        }
        return (documentId, chunkIds)
    }

    static func probe(
        _ wax: Wax,
        _ text: String,
        metadata: [String: String] = [:],
        expectedChunks: Int = 0
    ) async -> RememberDedupProbe? {
        await wax.rememberDedupProbe(
            contentHash: hash(text),
            metadata: documentMetadata(text, metadata),
            expectedChunkCount: expectedChunks,
            embeddingIdentity: nil
        )
    }
}

@Test func rememberDedupProbeFindsDocumentWhilePendingAfterCommitAndAfterReopen() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    #expect(await DedupFixture.probe(wax, "alpha", expectedChunks: 2) == nil)
    let alpha = try await DedupFixture.putDocument(wax, "alpha", chunks: 2)

    #expect(await DedupFixture.probe(wax, "alpha", expectedChunks: 2)?.documentId == alpha.document)
    #expect(await DedupFixture.probe(wax, "alpha", expectedChunks: 2)?.isComplete == true)

    try await wax.commit()
    #expect(await DedupFixture.probe(wax, "alpha", expectedChunks: 2)?.isComplete == true)
    let beta = try await DedupFixture.putDocument(wax, "beta")
    #expect(await DedupFixture.probe(wax, "beta")?.documentId == beta.document)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    #expect(await DedupFixture.probe(reopened, "alpha", expectedChunks: 2)?.documentId == alpha.document)
    #expect(await DedupFixture.probe(reopened, "beta")?.documentId == beta.document)
    #expect(await DedupFixture.probe(reopened, "gamma") == nil)
    try await reopened.close()
}

@Test func rememberDedupProbeSkipsDeletedDocuments() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let first = try await DedupFixture.putDocument(wax, "doomed")
    #expect(await DedupFixture.probe(wax, "doomed")?.documentId == first.document)

    try await wax.delete(frameId: first.document)
    #expect(await DedupFixture.probe(wax, "doomed") == nil)
    try await wax.commit()
    #expect(await DedupFixture.probe(wax, "doomed") == nil)

    let second = try await DedupFixture.putDocument(wax, "doomed")
    try await wax.commit()
    #expect(await DedupFixture.probe(wax, "doomed")?.documentId == second.document)
    try await wax.delete(frameId: second.document)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    #expect(await DedupFixture.probe(reopened, "doomed") == nil)
    try await reopened.close()
}

@Test func rememberDedupProbeFallsBackToOlderDocumentWhenNewestIsSuperseded() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let older = try await DedupFixture.putDocument(wax, "twin")
    try await wax.commit()
    let newer = try await DedupFixture.putDocument(wax, "twin")
    #expect(await DedupFixture.probe(wax, "twin")?.documentId == newer.document)

    let replacement = try await DedupFixture.putDocument(wax, "replacement")
    try await wax.supersede(supersededId: newer.document, supersedingId: replacement.document)
    #expect(await DedupFixture.probe(wax, "twin")?.documentId == older.document)
    try await wax.commit()
    #expect(await DedupFixture.probe(wax, "twin")?.documentId == older.document)

    try await wax.supersede(supersededId: older.document, supersedingId: replacement.document)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    #expect(await DedupFixture.probe(reopened, "twin") == nil)
    #expect(await DedupFixture.probe(reopened, "replacement")?.documentId == replacement.document)
    try await reopened.close()
}

@Test func rememberDedupProbeMatchesMetadataIgnoringCreatedAt() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let alpha = try await DedupFixture.putDocument(
        wax, "shared", metadata: ["scope": "alpha", "wax.created_at_ms": "1"]
    )
    let beta = try await DedupFixture.putDocument(wax, "shared", metadata: ["scope": "beta"])

    #expect(await DedupFixture.probe(
        wax, "shared", metadata: ["scope": "alpha", "wax.created_at_ms": "2"]
    )?.documentId == alpha.document)
    #expect(await DedupFixture.probe(wax, "shared", metadata: ["scope": "beta"])?.documentId == beta.document)
    #expect(await DedupFixture.probe(wax, "shared", metadata: ["scope": "gamma"]) == nil)
    #expect(await DedupFixture.probe(wax, "shared") == nil)
    try await wax.close()
}

@Test func rememberDedupProbeCountsOnlyLiveChunks() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let doc = try await DedupFixture.putDocument(wax, "chunked", chunks: 3)
    try await wax.commit()
    #expect(await DedupFixture.probe(wax, "chunked", expectedChunks: 3)?.isComplete == true)

    try await wax.delete(frameId: doc.chunks[1])
    #expect(await DedupFixture.probe(wax, "chunked", expectedChunks: 3)?.isComplete == false)
    try await wax.commit()
    #expect(await DedupFixture.probe(wax, "chunked", expectedChunks: 3)?.isComplete == false)
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    let probe = await DedupFixture.probe(reopened, "chunked", expectedChunks: 3)
    #expect(probe?.documentId == doc.document)
    #expect(probe?.isComplete == false)
    try await reopened.close()
}

@Test func rememberDedupProbeExaminesOnlyCandidateFrames() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    for index in 0..<200 {
        try await DedupFixture.putDocument(wax, "committed \(index)")
    }
    try await wax.commit()
    for index in 0..<100 {
        try await DedupFixture.putDocument(wax, "pending \(index)")
    }
    let target = try await DedupFixture.putDocument(wax, "target", chunks: 2)
    // The first probe may build the lookup; later probes must not revisit unrelated frames.
    _ = await DedupFixture.probe(wax, "absent")

    let before = await wax.rememberDedupFramesExaminedForTesting()
    #expect(await DedupFixture.probe(wax, "absent") == nil)
    #expect(await DedupFixture.probe(wax, "committed 7")?.documentId == 7)
    #expect(await DedupFixture.probe(wax, "target", expectedChunks: 2)?.documentId == target.document)
    let examined = await wax.rememberDedupFramesExaminedForTesting() - before
    // One committed document, plus the target document and its two chunks.
    #expect(examined <= 4)
    try await wax.close()
}
