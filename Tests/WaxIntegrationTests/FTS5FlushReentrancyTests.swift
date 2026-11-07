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
