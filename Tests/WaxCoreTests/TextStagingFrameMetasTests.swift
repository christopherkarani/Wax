import Foundation
import Testing
@testable import WaxCore

// Text staging reads the frames at or above its coverage watermark plus the inactive frames
// below it. They must be exactly those entries of the full pending-applied frame list.

private func isInactive(_ meta: FrameMeta) -> Bool {
    meta.status == .deleted || meta.supersededBy != nil
}

private func expectedStagingMetas(_ all: [FrameMeta], floor: UInt64) -> [FrameMeta] {
    all.filter { $0.id >= floor || isInactive($0) }
}

@Test func textStagingFrameMetasMatchTheFullListAboveTheFloorAndInactiveBelow() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url)
    for index in 0..<12 {
        _ = try await wax.put(Data("committed \(index)".utf8))
    }
    try await wax.delete(frameId: 1)
    try await wax.supersede(supersededId: 2, supersedingId: 3)
    try await wax.commit()

    // Pending: puts, and deletes and supersedes of committed and pending frames on both
    // sides of each floor below.
    for index in 12..<16 {
        _ = try await wax.put(Data("pending \(index)".utf8))
    }
    try await wax.delete(frameId: 4)
    try await wax.delete(frameId: 9)
    try await wax.supersede(supersededId: 5, supersedingId: 13)
    try await wax.supersede(supersededId: 10, supersedingId: 11)
    try await wax.delete(frameId: 14)

    let all = await wax.frameMetasIncludingPending()
    #expect(all.count == 16)
    for floor in [UInt64(0), 3, 6, 10, 12, 14, 16, 40] {
        let staged = await wax.frameMetasForTextStaging(atOrAbove: floor)
        #expect(staged == expectedStagingMetas(all, floor: floor), "floor \(floor)")
    }

    // Nothing pending: the committed list alone.
    try await wax.commit()
    let committed = await wax.frameMetasIncludingPending()
    for floor in [UInt64(0), 7, 16, 17] {
        let staged = await wax.frameMetasForTextStaging(atOrAbove: floor)
        #expect(staged == expectedStagingMetas(committed, floor: floor), "committed floor \(floor)")
    }
    try await wax.close()
}
