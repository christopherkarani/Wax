import Foundation
import Testing
import WaxCore
@testable import WaxTextSearch

/// A flush awaits its database write, and the engine is an actor, so another call can queue
/// text-index ops while the write runs. Clearing every pending op afterwards dropped those
/// ops: the frames were never indexed and silently missed every text search.
@Test
func opsQueuedDuringAFlushWriteAreKept() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 1, text: "alpha harbor")
    await engine.setAfterFlushWriteForTesting {
        await engine.setAfterFlushWriteForTesting(nil)
        try await engine.index(frameId: 2, text: "beta lantern")
    }

    // Flushes frame 1; frame 2 is queued while that write is in flight.
    _ = try await engine.count()

    let hits = try await engine.search(matchQuery: "\"lantern\"", topK: 10)
    #expect(hits.map(\.frameId) == [2])
    #expect(try await engine.count() == 2)
}

/// An op that replaces one being written must survive the flush that wrote the old op.
@Test
func opReplacedDuringAFlushWriteIsKept() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 1, text: "alpha harbor")
    await engine.setAfterFlushWriteForTesting {
        await engine.setAfterFlushWriteForTesting(nil)
        try await engine.index(frameId: 1, text: "gamma meadow")
    }

    _ = try await engine.count()

    #expect(try await engine.search(matchQuery: "\"meadow\"", topK: 10).map(\.frameId) == [1])
    #expect(try await engine.search(matchQuery: "\"harbor\"", topK: 10).isEmpty)
    #expect(try await engine.count() == 1)
}

/// The structured-memory flush cleared its queue the same way, so an entity upserted while
/// another flush was writing was lost and `upsertEntity` failed its own lookup.
@Test
func structuredOpsQueuedDuringAFlushWriteAreKept() async throws {
    let engine = try FTS5SearchEngine.inMemory()
    await engine.enqueueStructuredOp(.upsertEntity(key: EntityKey("person:ada"), kind: "person", aliases: ["Ada"], nowMs: 1))
    await engine.setAfterFlushWriteForTesting {
        await engine.setAfterFlushWriteForTesting(nil)
        await engine.enqueueStructuredOp(
            .upsertEntity(key: EntityKey("person:grace"), kind: "person", aliases: ["Grace"], nowMs: 2)
        )
    }

    // Flushes the first entity; the second is queued while that write is in flight.
    _ = try await engine.count()

    #expect(try await engine.entity(forKey: EntityKey("person:ada")) != nil)
    #expect(try await engine.entity(forKey: EntityKey("person:grace")) != nil)
}

/// `stageForCommit` awaits its flushes and the store, so another call can queue ops while it
/// runs. Those ops are not in the staged image; clearing `dirty` once the stage finished made
/// the next stage flush them, see a clean engine and stage nothing, so the committed index
/// silently missed their frames.
@Test
func opsQueuedWhileStagingAreStagedByTheNextCommit() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url)
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 1, text: "alpha harbor")
    let queued = QueuedFrameIds()
    // Every flush queues one more frame, so the last is queued after the stage's last flush.
    await engine.setAfterFlushWriteForTesting {
        let frameId = await queued.next()
        try await engine.index(frameId: frameId, text: "lantern \(frameId)")
    }
    try await engine.stageForCommit(into: wax)
    await engine.setAfterFlushWriteForTesting(nil)
    try await wax.commit()
    try await engine.stageForCommit(into: wax)
    try await wax.commit()

    let expected = await queued.all()
    #expect(!expected.isEmpty)
    let committed = try #require(try await wax.readCommittedLexIndexBytes())
    let reopened = try FTS5SearchEngine.deserialize(from: committed)
    let hits = try await reopened.search(matchQuery: "lantern", topK: 10).map { (hit: TextSearchResult) -> UInt64 in hit.frameId }.sorted()
    #expect(hits == expected)
    try await wax.close()
}

/// A borrowed image keeps the engine's writes waiting until the store has read it. When a
/// commit holds the store's write lock, the stage copies the image instead, so writes to the
/// engine do not wait for the commit's fsyncs.
@Test
func aStageThatFindsTheStoreBusyCopiesTheImageAndKeepsTheEngineWritable() async throws {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent(UUID().uuidString)
        .appendingPathExtension("wax")
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url)
    let engine = try FTS5SearchEngine.inMemory()
    try await engine.index(frameId: 1, text: "alpha harbor")
    // The stage's first flush runs after it read the store's frames; a commit takes the
    // store's write lock there.
    await engine.setAfterFlushWriteForTesting {
        await engine.setAfterFlushWriteForTesting(nil)
        await wax.acquireWriteLockForTesting()
    }
    let stage = Task { () async throws -> Void in
        try await engine.stageForCommit(into: wax)
    }
    // Only once the stage holds the image and waits for the store does the write below test
    // anything; before that, its own flush would run the hook.
    let stageWaits = await waitUntil { () async -> Bool in await wax.writeLockWaitersForTesting() == 1 }
    try #require(stageWaits, "the stage never waited for the store")
    let written = Flag()
    let write = Task { () async throws -> Int in
        try await engine.index(frameId: 2, text: "beta lantern")
        let count = try await engine.count()
        await written.set()
        return count
    }
    let writtenWhileBusy = await waitUntil { () async -> Bool in await written.isSet }
    await wax.releaseWriteLockForTesting()
    try await stage.value
    #expect(try await write.value == 2)
    #expect(writtenWhileBusy, "an engine write waited for the commit")
    #expect(await engine.lastStagedImageWasBorrowedForTesting() == false)

    try await wax.commit()
    let committed = try #require(try await wax.readCommittedLexIndexBytes())
    let reopened = try FTS5SearchEngine.deserialize(from: committed)
    let hits = try await reopened.search(matchQuery: "harbor", topK: 10).map { (hit: TextSearchResult) -> UInt64 in hit.frameId }
    #expect(hits == [1])
    try await wax.close()
}

/// Polls `condition` until it holds. The bound only keeps a regression from hanging the run:
/// a write the stage blocks never finishes while the store is held, so the bound is generous
/// and does not weaken the check when the suite runs under load.
private func waitUntil(_ condition: @Sendable () async -> Bool) async -> Bool {
    let deadline = ContinuousClock.now + .seconds(60)
    while ContinuousClock.now < deadline {
        if await condition() { return true }
        try? await Task.sleep(for: .milliseconds(2))
    }
    return false
}

private actor Flag {
    private(set) var isSet = false

    func set() { isSet = true }
}

private actor QueuedFrameIds {
    private var frameIds: [UInt64] = []

    func next() -> UInt64 {
        let frameId = UInt64(100 + frameIds.count)
        frameIds.append(frameId)
        return frameId
    }

    func all() -> [UInt64] { frameIds }
}
