import Foundation
import Testing
@testable import WaxCore

@Test
func activeSurrogateSourceFramesReturnsOnlyCommittedEligibleChunks() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    _ = try await wax.put(
        Data("document".utf8),
        options: FrameMetaSubset(
            role: .document,
            searchText: "document"
        )
    )

    let activeChunk = try await wax.put(
        Data("active chunk".utf8),
        options: FrameMetaSubset(
            role: .chunk,
            searchText: "active chunk"
        )
    )

    _ = try await wax.put(
        Data("whitespace chunk".utf8),
        options: FrameMetaSubset(
            role: .chunk,
            searchText: "   \n  "
        )
    )

    _ = try await wax.put(
        Data("surrogate-labeled chunk".utf8),
        options: FrameMetaSubset(
            kind: "surrogate",
            role: .chunk,
            searchText: "surrogate-labeled chunk"
        )
    )

    let superseded = try await wax.put(
        Data("superseded chunk".utf8),
        options: FrameMetaSubset(
            role: .chunk,
            searchText: "superseded chunk"
        )
    )
    let replacement = try await wax.put(
        Data("replacement chunk".utf8),
        options: FrameMetaSubset(
            role: .chunk,
            searchText: "replacement chunk"
        )
    )
    try await wax.supersede(supersededId: superseded, supersedingId: replacement)

    let deleted = try await wax.put(
        Data("deleted chunk".utf8),
        options: FrameMetaSubset(
            role: .chunk,
            searchText: "deleted chunk"
        )
    )
    try await wax.delete(frameId: deleted)

    try await wax.commit()

    let pending = try await wax.put(
        Data("pending chunk".utf8),
        options: FrameMetaSubset(
            role: .chunk,
            searchText: "pending chunk"
        )
    )

    let sources = await wax.activeSurrogateSourceFrames()

    #expect(sources.map(\.id) == [activeChunk, replacement])
    #expect(sources.map(\.searchText) == ["active chunk", "replacement chunk"])
    #expect(sources.contains(where: { $0.id == superseded }) == false)
    #expect(sources.contains(where: { $0.id == deleted }) == false)
    #expect(sources.contains(where: { $0.id == pending }) == false)

    try await wax.close()
}
