import Foundation
import Testing
import Wax

@Test
func frameAccessStatsRecordAccessUpdatesFieldsAndWrapsOnOverflow() {
    var stats = FrameAccessStats(frameId: 42, nowMs: 100)
    #expect(stats.accessCount == 1)
    #expect(stats.firstAccessMs == 100)
    #expect(stats.lastAccessMs == 100)

    stats.recordAccess(nowMs: 200)
    #expect(stats.accessCount == 2)
    #expect(stats.lastAccessMs == 200)

    stats.accessCount = UInt32.max
    stats.recordAccess(nowMs: 300)
    #expect(stats.accessCount == 0)
    #expect(stats.lastAccessMs == 300)
}

@Test
func accessStatsManagerCoversDirtyNoOpPruneAndImportLifecycle() async {
    let manager = AccessStatsManager()

    #expect(await manager.count == 0)
    #expect(await manager.exportStatsIfDirty() == nil)

    await manager.recordAccesses(frameIds: [])
    #expect(await manager.count == 0)
    #expect(await manager.exportStatsIfDirty() == nil)

    await manager.recordAccess(frameId: 10)
    await manager.recordAccesses(frameIds: [10, 20])

    #expect(await manager.count == 2)

    let ten = await manager.getStats(frameId: 10)
    #expect(ten?.frameId == 10)
    #expect((ten?.accessCount ?? 0) >= 2)

    let subset = await manager.getStats(frameIds: [20, 30, 10])
    #expect(subset.keys.sorted() == [10, 20])

    let exportedDirty = await manager.exportStatsIfDirty()
    #expect(exportedDirty?.map(\.frameId) == [10, 20])

    await manager.markPersisted()
    #expect(await manager.exportStatsIfDirty() == nil)

    await manager.pruneStats(keepingOnly: [10])
    let afterPrune = await manager.exportStatsIfDirty()
    #expect(afterPrune?.map(\.frameId) == [10])

    await manager.markPersisted()
    await manager.pruneStats(keepingOnly: [10])
    #expect(await manager.exportStatsIfDirty() == nil)

    await manager.importStats([
        FrameAccessStats(frameId: 3, nowMs: 11),
        FrameAccessStats(frameId: 1, nowMs: 9),
    ])
    #expect(await manager.count == 2)
    #expect(await manager.exportStatsIfDirty() == nil)

    let imported = await manager.exportStats()
    #expect(imported.map(\.frameId) == [1, 3])
}
