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
