import Foundation
import Testing
@testable import WaxCore

@Test func deleteCommittedFrameMarksDeleted() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let frameId = try await wax.put(Data("payload".utf8))
    try await wax.commit()

    try await wax.delete(frameId: frameId)
    try await wax.commit()

    let meta = try await wax.frameMeta(frameId: frameId)
    #expect(meta.status == .deleted)
    let timeline = await wax.timeline(TimelineQuery(limit: 10))
    #expect(timeline.isEmpty)
    try await wax.close()
}

@Test func deletePendingFrameInSameCommit() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let frameId = try await wax.put(Data("payload".utf8))
    try await wax.delete(frameId: frameId)
    try await wax.commit()

    let meta = try await wax.frameMeta(frameId: frameId)
    #expect(meta.status == .deleted)
    try await wax.close()
}

@Test func supersedeUpdatesBothSidesAfterCommit() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let oldId = try await wax.put(Data("old".utf8))
    try await wax.commit()

    let newId = try await wax.put(Data("new".utf8))
    try await wax.supersede(supersededId: oldId, supersedingId: newId)
    try await wax.commit()

    let oldMeta = try await wax.frameMeta(frameId: oldId)
    let newMeta = try await wax.frameMeta(frameId: newId)
    #expect(oldMeta.supersededBy == newId)
    #expect(newMeta.supersedes == oldId)
    try await wax.close()
}

@Test func supersedeWithinSameCommit() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let oldId = try await wax.put(Data("old".utf8))
    let newId = try await wax.put(Data("new".utf8))
    try await wax.supersede(supersededId: oldId, supersedingId: newId)
    try await wax.commit()

    let oldMeta = try await wax.frameMeta(frameId: oldId)
    let newMeta = try await wax.frameMeta(frameId: newId)
    #expect(oldMeta.supersededBy == newId)
    #expect(newMeta.supersedes == oldId)
    try await wax.close()
}

@Test func supersedeRejectsUnknownIds() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)

    do {
        try await wax.supersede(supersededId: 1, supersedingId: 2)
        try await wax.commit()
        #expect(Bool(false))
    } catch let error as WaxError {
        if case .invalidToc = error {
            #expect(Bool(true))
        } else {
            #expect(Bool(false))
        }
    }

    // `close()` auto-commits pending mutations; this test intentionally leaves an invalid mutation pending.
    _ = try? await wax.close()
}

@Test func pendingDeleteIsVisibleInIncludingPendingReads() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let frameId = try await wax.put(Data("payload".utf8))
    try await wax.commit()

    try await wax.delete(frameId: frameId)

    let single = try await wax.frameMetaIncludingPending(frameId: frameId)
    #expect(single.status == .deleted)

    let batch = await wax.frameMetasIncludingPending(frameIds: [frameId])
    #expect(batch[frameId]?.status == .deleted)

    try await wax.close()
}

@Test func supersedeCycleDetected() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let a = try await wax.put(Data("a".utf8))
    let b = try await wax.put(Data("b".utf8))
    try await wax.supersede(supersededId: a, supersedingId: b)
    try await wax.commit()

    // Reverse supersede should throw
    await #expect(throws: WaxError.self) {
        try await wax.supersede(supersededId: b, supersedingId: a)
    }
    try await wax.close()
}

@Test func supersedeCycleDetectedWithinSameCommit() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let a = try await wax.put(Data("a".utf8))
    let b = try await wax.put(Data("b".utf8))
    try await wax.supersede(supersededId: a, supersedingId: b)

    // Reverse supersede in same commit should throw
    await #expect(throws: WaxError.self) {
        try await wax.supersede(supersededId: b, supersedingId: a)
    }
    try await wax.close()
}

@Test func supersedeSelfReferenceThrows() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let a = try await wax.put(Data("a".utf8))
    // Self-supersede is caught at commit time — distinct IDs are required
    try await wax.supersede(supersededId: a, supersedingId: a)
    await #expect(throws: WaxError.self) {
        try await wax.commit()
    }
    _ = try? await wax.close()
}

@Test func supersedeChainABCIsNotACycle() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let a = try await wax.put(Data("a".utf8))
    let b = try await wax.put(Data("b".utf8))
    let c = try await wax.put(Data("c".utf8))

    // A -> B -> C is a chain, not a cycle
    try await wax.supersede(supersededId: a, supersedingId: b)
    try await wax.supersede(supersededId: b, supersedingId: c)
    try await wax.commit()

    let metaA = try await wax.frameMeta(frameId: a)
    let metaB = try await wax.frameMeta(frameId: b)
    let metaC = try await wax.frameMeta(frameId: c)
    #expect(metaA.supersededBy == b)
    #expect(metaB.supersedes == a)
    #expect(metaB.supersededBy == c)
    #expect(metaC.supersedes == b)
    try await wax.close()
}

@Test func supersedeAfterDeletedFrameStillWorks() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let a = try await wax.put(Data("a".utf8))
    let b = try await wax.put(Data("b".utf8))
    try await wax.commit()

    try await wax.delete(frameId: a)
    try await wax.commit()

    // Superseding a deleted frame should still work (the relationship is valid)
    try await wax.supersede(supersededId: a, supersedingId: b)
    try await wax.commit()

    let metaA = try await wax.frameMeta(frameId: a)
    #expect(metaA.supersededBy == b)
    try await wax.close()
}

@Test func supersedeSurvivesReopenRecovery() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let a = try await wax.put(Data("a".utf8))
    let b = try await wax.put(Data("b".utf8))
    try await wax.supersede(supersededId: a, supersedingId: b)
    try await wax.commit()
    try await wax.close()

    // Reopen and verify supersede relationship persisted
    let reopened = try await Wax.open(at: url)
    let metaA = try await reopened.frameMeta(frameId: a)
    let metaB = try await reopened.frameMeta(frameId: b)
    #expect(metaA.supersededBy == b)
    #expect(metaB.supersedes == a)
    try await reopened.close()
}

@Test func supersededFrameExcludedFromTimeline() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let old = try await wax.put(Data("old".utf8))
    let new = try await wax.put(Data("new".utf8))
    try await wax.supersede(supersededId: old, supersedingId: new)
    try await wax.commit()

    let timeline = await wax.timeline(TimelineQuery(limit: 10))
    // Only the superseding frame should appear
    let ids = timeline.map(\.id)
    #expect(!ids.contains(old))
    #expect(ids.contains(new))
    try await wax.close()
}

@Test func pendingSupersedeIsVisibleInIncludingPendingReads() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    let wax = try await Wax.create(at: url)
    let oldId = try await wax.put(Data("old".utf8))
    try await wax.commit()

    let newId = try await wax.put(Data("new".utf8))
    try await wax.supersede(supersededId: oldId, supersedingId: newId)

    let oldSingle = try await wax.frameMetaIncludingPending(frameId: oldId)
    #expect(oldSingle.supersededBy == newId)

    let newSingle = try await wax.frameMetaIncludingPending(frameId: newId)
    #expect(newSingle.supersedes == oldId)

    let batch = await wax.frameMetasIncludingPending(frameIds: [oldId, newId])
    #expect(batch[oldId]?.supersededBy == newId)
    #expect(batch[newId]?.supersedes == oldId)

    try await wax.close()
}
