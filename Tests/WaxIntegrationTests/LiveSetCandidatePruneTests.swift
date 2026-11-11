import Foundation
import Testing
@testable import Wax

/// A store's rewrite candidates sit next to it, so pruning them has to read the store's
/// directory, which can be a crowded folder such as TMPDIR or Documents.
@Test
func liveSetCandidatePruneKeepsTheNewestCandidatesAndLeavesOtherFilesAlone() async throws {
    let directory = FileManager.default.temporaryDirectory
        .appendingPathComponent("wax-prune-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(at: directory) }

    let bystanders = [
        "notes.wax",
        "notes-liveset-sidecar.txt",
        "other-liveset-1.wax",
        ".notes-liveset-hidden.wax",
    ]
    for name in bystanders {
        try Data().write(to: directory.appendingPathComponent(name))
    }
    // Oldest first: candidate 0 is a day old, candidate 3 is a minute old.
    let candidates = (0..<4).map { directory.appendingPathComponent("notes-liveset-\($0).wax") }
    for (age, url) in zip([86_400.0, 3_600, 600, 60], candidates) {
        try Data().write(to: url)
        try FileManager.default.setAttributes(
            [.modificationDate: Date(timeIntervalSinceNow: -age)],
            ofItemAtPath: url.path
        )
    }

    try await MemoryOrchestrator.pruneScheduledRewriteCandidates(in: directory, baseName: "notes", keepLatest: 2)

    let remaining = Set(try FileManager.default.contentsOfDirectory(atPath: directory.path))
    #expect(remaining == Set(bystanders + ["notes-liveset-2.wax", "notes-liveset-3.wax"]))
}
