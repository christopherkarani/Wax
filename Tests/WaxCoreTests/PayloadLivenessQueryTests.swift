import Foundation
import Testing
@testable import WaxCore

@Test
func committedPayloadLivenessBytesCountsCommittedDeadAndLivePayloadsOnly() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let largeDeadPayload = Data(repeating: 0x41, count: 192 * 1024)

    let superseded = try await wax.put(
        largeDeadPayload,
        options: FrameMetaSubset(searchText: "old scheduled payload")
    )
    let replacement = try await wax.put(
        Data("active replacement".utf8),
        options: FrameMetaSubset(searchText: "active replacement")
    )
    try await wax.supersede(supersededId: superseded, supersedingId: replacement)

    let deleted = try await wax.put(
        largeDeadPayload,
        options: FrameMetaSubset(searchText: "to delete")
    )
    try await wax.delete(frameId: deleted)

    _ = try await wax.put(
        Data(),
        options: FrameMetaSubset(searchText: "zero-length payload")
    )

    try await wax.commit()

    _ = try await wax.put(
        Data("pending payload".utf8),
        options: FrameMetaSubset(searchText: "pending payload")
    )

    let stats = await wax.committedPayloadLivenessBytes()

    #expect(stats.totalPayloadBytes == 393_234)
    #expect(stats.deadPayloadBytes == 393_216)

    try await wax.close()
}

@Test
func committedPayloadLivenessBytesReturnsZeroForEmptyStore() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let stats = await wax.committedPayloadLivenessBytes()

    #expect(stats.totalPayloadBytes == 0)
    #expect(stats.deadPayloadBytes == 0)

    try await wax.close()
}
