import Foundation
import Testing
@testable import Wax

@Test func frameAccessStatsRecordAccessIncrementsCount() {
    var stats = FrameAccessStats(frameId: 1, nowMs: 1000)
    #expect(stats.accessCount == 1)
    #expect(stats.firstAccessMs == 1000)

    stats.recordAccess(nowMs: 2000)
    #expect(stats.accessCount == 2)
    #expect(stats.lastAccessMs == 2000)
    #expect(stats.firstAccessMs == 1000) // unchanged
}

@Test func accessStatsManagerRecordAndGetSingle() async {
    let manager = AccessStatsManager()
    await manager.recordAccess(frameId: 42)

    let stats = await manager.getStats(frameId: 42)
    #expect(stats != nil)
    #expect(stats?.frameId == 42)
    #expect(stats?.accessCount == 1)
}

@Test func accessStatsManagerRecordMultiple() async {
    let manager = AccessStatsManager()
    await manager.recordAccesses(frameIds: [1, 2, 3])

    let batch = await manager.getStats(frameIds: [1, 2, 3, 99])
    #expect(batch.count == 3)
    #expect(batch[99] == nil)
    #expect(batch[1]?.accessCount == 1)
}

@Test func accessStatsManagerRecordAccessesSameFrameTwice() async {
    let manager = AccessStatsManager()
    await manager.recordAccesses(frameIds: [1, 1, 1])

    let stats = await manager.getStats(frameId: 1)
    #expect(stats?.accessCount == 3)
}

@Test func accessStatsManagerPruneStats() async {
    let manager = AccessStatsManager()
    await manager.recordAccesses(frameIds: [1, 2, 3, 4])

    await manager.pruneStats(keepingOnly: [2, 4])
    #expect(await manager.count == 2)
    #expect(await manager.getStats(frameId: 1) == nil)
    #expect(await manager.getStats(frameId: 2) != nil)
}

@Test func accessStatsManagerExportImport() async {
    let manager = AccessStatsManager()
    await manager.recordAccesses(frameIds: [10, 20])

    let exported = await manager.exportStats()
    #expect(exported.count == 2)

    let manager2 = AccessStatsManager()
    await manager2.importStats(exported)
    #expect(await manager2.count == 2)
    #expect(await manager2.getStats(frameId: 10) != nil)
}

@Test func accessStatsManagerExportIfDirtyReturnsNilWhenClean() async {
    let manager = AccessStatsManager()
    let result = await manager.exportStatsIfDirty()
    #expect(result == nil)
}

@Test func accessStatsManagerExportIfDirtyReturnsStatsWhenDirty() async {
    let manager = AccessStatsManager()
    await manager.recordAccess(frameId: 1)
    let result = await manager.exportStatsIfDirty()
    #expect(result != nil)
    #expect(result?.count == 1)
}

@Test func accessStatsManagerMarkPersistedClearsDirty() async {
    let manager = AccessStatsManager()
    await manager.recordAccess(frameId: 1)
    await manager.markPersisted()
    let result = await manager.exportStatsIfDirty()
    #expect(result == nil) // not dirty after markPersisted
}

@Test func accessStatsManagerRecordAccessesEmptyIsNoOp() async {
    let manager = AccessStatsManager()
    await manager.recordAccesses(frameIds: [])
    #expect(await manager.count == 0)
}
