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

    // Single-chunk remembers are stored as searchable documents, and those
    // documents are eligible surrogate sources just like multi-chunk frames.
    #expect(sources.map(\.id) == [0, activeChunk, replacement])
    #expect(sources.map(\.searchText) == ["document", "active chunk", "replacement chunk"])
    #expect(sources.contains(where: { $0.id == superseded }) == false)
    #expect(sources.contains(where: { $0.id == deleted }) == false)
    #expect(sources.contains(where: { $0.id == pending }) == false)

    try await wax.close()
}

/// Text with nothing to trim is returned as stored; padded text is still trimmed.
@Test
func activeSurrogateSourceFramesTrimsPaddedText() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let texts = ["plain text", "  leading", "trailing\n", "\u{00A0}no-break\u{2003}", "in  side", "\t", "x"]
    for text in texts {
        _ = try await wax.put(Data(text.utf8), options: FrameMetaSubset(role: .chunk, searchText: text))
    }
    try await wax.commit()

    let sources = await wax.activeSurrogateSourceFrames()
    #expect(sources.map(\.searchText) == ["plain text", "leading", "trailing", "no-break", "in  side", "x"])
    #expect(sources.map(\.id) == [0, 1, 2, 3, 4, 6])

    try await wax.close()
}

/// The open's coverage check answers what `activeSurrogateSourceFrames()` would: whether
/// every live source with embeddable text is in the set. Frames that are not sources (a
/// system frame, whitespace-only text, a surrogate, a superseded or deleted frame) never
/// need a vector.
@Test
func activeSurrogateSourcesAreCoveredMatchesTheSourceList() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let document = try await wax.put(Data("d".utf8), options: FrameMetaSubset(role: .document, searchText: "document"))
    let chunk = try await wax.put(Data("c".utf8), options: FrameMetaSubset(role: .chunk, searchText: "chunk"))
    let system = try await wax.put(Data("s".utf8), options: FrameMetaSubset(role: .system, searchText: "system"))
    let blank = try await wax.put(Data("b".utf8), options: FrameMetaSubset(role: .chunk, searchText: " \n "))
    let surrogate = try await wax.put(
        Data("g".utf8), options: FrameMetaSubset(kind: "surrogate", role: .chunk, searchText: "surrogate")
    )
    let superseded = try await wax.put(Data("o".utf8), options: FrameMetaSubset(role: .chunk, searchText: "old"))
    let replacement = try await wax.put(Data("n".utf8), options: FrameMetaSubset(role: .chunk, searchText: "new"))
    try await wax.supersede(supersededId: superseded, supersedingId: replacement)
    let deleted = try await wax.put(Data("x".utf8), options: FrameMetaSubset(role: .chunk, searchText: "gone"))
    try await wax.delete(frameId: deleted)
    try await wax.commit()

    let sources = Set(await wax.activeSurrogateSourceFrames().map(\.id))
    #expect(sources == [document, chunk, replacement])
    #expect(await wax.activeSurrogateSourcesAreCovered(by: sources))
    #expect(await wax.activeSurrogateSourcesAreCovered(by: sources.union([system, blank, surrogate, superseded, deleted])))
    for missing in sources {
        #expect(await wax.activeSurrogateSourcesAreCovered(by: sources.subtracting([missing])) == false)
    }
    #expect(await wax.activeSurrogateSourcesAreCovered(by: [system, blank, surrogate, superseded, deleted]) == false)

    try await wax.close()
}
