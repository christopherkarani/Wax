import Foundation
import Testing
@testable import WaxCore

@Test
func activeFrameIDsMatchingMetadataReturnsOnlyCommittedLiveMatches() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url)

    let activeDocument = try await wax.put(
        Data("active document".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata(["session_id": "session-alpha"])
        )
    )
    let activeChunk = try await wax.put(
        Data("active chunk".utf8),
        options: FrameMetaSubset(
            role: .chunk,
            parentId: activeDocument,
            chunkIndex: 0,
            chunkCount: 1,
            metadata: Metadata(["session_id": "session-alpha"])
        )
    )

    let superseded = try await wax.put(
        Data("superseded".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata(["session_id": "session-alpha"])
        )
    )
    let replacement = try await wax.put(
        Data("replacement".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata(["session_id": "session-alpha"])
        )
    )
    try await wax.supersede(supersededId: superseded, supersedingId: replacement)

    let deleted = try await wax.put(
        Data("deleted".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata(["session_id": "session-alpha"])
        )
    )
    try await wax.delete(frameId: deleted)

    _ = try await wax.put(
        Data("other session".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata(["session_id": "session-beta"])
        )
    )

    try await wax.commit()

    let uncommitted = try await wax.put(
        Data("pending".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata(["session_id": "session-alpha"])
        )
    )

    let ids = await wax.activeFrameIDs(matchingMetadataKey: "session_id", value: "session-alpha")

    #expect(ids == [activeDocument, activeChunk, replacement])
    #expect(ids.contains(superseded) == false)
    #expect(ids.contains(deleted) == false)
    #expect(ids.contains(uncommitted) == false)

    try await wax.close()
}
