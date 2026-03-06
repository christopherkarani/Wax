import Foundation
import Testing
@testable import WaxCore

@Test
func latestCommittedActiveSystemFrameMetaReturnsLatestCommittedLiveMatch() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    _ = try await wax.put(
        Data("wrong role".utf8),
        options: FrameMetaSubset(
            kind: "wax.internal.access_stats",
            role: .document
        ),
        timestampMs: 1_000
    )

    _ = try await wax.put(
        Data("legacy marker".utf8),
        options: FrameMetaSubset(
            role: .system,
            metadata: Metadata(["wax.internal.kind": "access_stats"])
        ),
        timestampMs: 2_000
    )

    let superseded = try await wax.put(
        Data("superseded".utf8),
        options: FrameMetaSubset(
            kind: "wax.internal.access_stats",
            role: .system
        ),
        timestampMs: 3_000
    )
    let replacement = try await wax.put(
        Data("replacement".utf8),
        options: FrameMetaSubset(
            kind: "wax.internal.access_stats",
            role: .system
        ),
        timestampMs: 4_000
    )
    try await wax.supersede(supersededId: superseded, supersedingId: replacement)

    let deleted = try await wax.put(
        Data("deleted".utf8),
        options: FrameMetaSubset(
            kind: "wax.internal.access_stats",
            role: .system
        ),
        timestampMs: 5_000
    )
    try await wax.delete(frameId: deleted)

    let latest = try await wax.put(
        Data("latest".utf8),
        options: FrameMetaSubset(
            kind: "wax.internal.access_stats",
            role: .system
        ),
        timestampMs: 6_000
    )

    try await wax.commit()

    let pending = try await wax.put(
        Data("pending".utf8),
        options: FrameMetaSubset(
            kind: "wax.internal.access_stats",
            role: .system
        ),
        timestampMs: 7_000
    )

    let result = await wax.latestCommittedActiveSystemFrameMeta(
        kind: "wax.internal.access_stats",
        fallbackMetadataKey: "wax.internal.kind",
        fallbackMetadataValue: "access_stats"
    )

    #expect(result?.id == latest)
    #expect(result?.timestamp == 6_000)
    #expect(result?.id != pending)
    #expect(result?.id != replacement)

    try await wax.close()
}

@Test
func latestCommittedActiveSystemFrameMetaKeepsEarlierCommittedFrameOnTimestampTie() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let earlier = try await wax.put(
        Data("earlier".utf8),
        options: FrameMetaSubset(
            role: .system,
            metadata: Metadata(["wax.internal.kind": "access_stats"])
        ),
        timestampMs: 10_000
    )
    let later = try await wax.put(
        Data("later".utf8),
        options: FrameMetaSubset(
            kind: "wax.internal.access_stats",
            role: .system
        ),
        timestampMs: 10_000
    )

    try await wax.commit()

    let result = await wax.latestCommittedActiveSystemFrameMeta(
        kind: "wax.internal.access_stats",
        fallbackMetadataKey: "wax.internal.kind",
        fallbackMetadataValue: "access_stats"
    )

    #expect(result?.id == earlier)
    #expect(result?.id != later)

    try await wax.close()
}
