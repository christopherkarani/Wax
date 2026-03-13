import Foundation
import Testing
@testable import WaxCore

@Test
func latestCommittedActiveHandoffMetaReturnsLatestProjectMatchAcrossCompatibilityForms() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    _ = try await wax.put(
        Data("plain document".utf8),
        options: FrameMetaSubset(role: .document),
        timestampMs: 1_000
    )

    _ = try await wax.put(
        Data("metadata-only target".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata([
                "kind": "handoff",
                "project": "wax",
            ])
        ),
        timestampMs: 2_000
    )

    _ = try await wax.put(
        Data("label-only other".utf8),
        options: FrameMetaSubset(
            labels: ["handoff"],
            role: .document,
            metadata: Metadata(["project": "other"])
        ),
        timestampMs: 3_000
    )

    let superseded = try await wax.put(
        Data("superseded target".utf8),
        options: FrameMetaSubset(
            kind: "handoff",
            role: .document,
            metadata: Metadata(["project": "wax"])
        ),
        timestampMs: 4_000
    )
    let replacement = try await wax.put(
        Data("replacement other".utf8),
        options: FrameMetaSubset(
            kind: "handoff",
            role: .document,
            metadata: Metadata(["project": "other"])
        ),
        timestampMs: 4_500
    )
    try await wax.supersede(supersededId: superseded, supersedingId: replacement)

    let deleted = try await wax.put(
        Data("deleted target".utf8),
        options: FrameMetaSubset(
            labels: ["handoff"],
            role: .document,
            metadata: Metadata(["project": "wax"])
        ),
        timestampMs: 5_000
    )
    try await wax.delete(frameId: deleted)

    let latest = try await wax.put(
        Data("latest target".utf8),
        options: FrameMetaSubset(
            labels: ["handoff"],
            role: .document,
            metadata: Metadata(["project": "wax"])
        ),
        timestampMs: 6_000
    )

    try await wax.commit()

    let pending = try await wax.put(
        Data("pending target".utf8),
        options: FrameMetaSubset(
            kind: "handoff",
            role: .document,
            metadata: Metadata(["project": "wax"])
        ),
        timestampMs: 7_000
    )

    let result = await wax.latestCommittedActiveHandoffMeta(project: "wax")

    #expect(result?.id == latest)
    #expect(result?.timestamp == 6_000)
    #expect(result?.id != pending)
    #expect(result?.id != superseded)
    #expect(result?.id != deleted)

    try await wax.close()
}

@Test
func latestCommittedActiveHandoffMetaPrefersHigherFrameIDOnTimestampTieAndTreatsEmptyProjectAsUnfiltered() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    let earlier = try await wax.put(
        Data("earlier".utf8),
        options: FrameMetaSubset(
            kind: "handoff",
            role: .document,
            metadata: Metadata(["project": "wax"])
        ),
        timestampMs: 10_000
    )
    let later = try await wax.put(
        Data("later".utf8),
        options: FrameMetaSubset(
            role: .document,
            metadata: Metadata([
                "kind": "handoff",
                "project": "wax",
            ])
        ),
        timestampMs: 10_000
    )

    try await wax.commit()

    let unfiltered = await wax.latestCommittedActiveHandoffMeta(project: nil)
    let emptyProject = await wax.latestCommittedActiveHandoffMeta(project: "")

    #expect(unfiltered?.id == later)
    #expect(unfiltered?.id != earlier)
    #expect(emptyProject?.id == later)

    try await wax.close()
}
