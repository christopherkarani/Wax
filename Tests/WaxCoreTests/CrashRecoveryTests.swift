import Foundation
import Testing
@testable import WaxCore

@Test func closeWithPendingMutationsCommitsBeforeShutdown() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("uncommitted".utf8))
        try await wax.close()
    }

    do {
        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == 1)
        #expect(stats.pendingFrames == 0)

        try await wax.commit()
        let newStats = await wax.stats()
        #expect(newStats.frameCount == 1)
        #expect(newStats.pendingFrames == 0)
        try await wax.close()
    }
}

@Test func recoveryWithCorruptHeaderPageAStillOpensViaPageB() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("test data".utf8))
        try await wax.commit()
        try await wax.close()
    }

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        try file.writeAll(Data(repeating: 0, count: Int(Constants.headerPageSize)), at: 0)
        try file.fsync()
    }

    do {
        let wax = try await Wax.open(at: url)
        let content = try await wax.frameContent(frameId: 0)
        #expect(content == Data("test data".utf8))
        try await wax.close()
    }
}

@Test func closeAfterCommittedAndPendingMutationsPersistsAllFrames() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("committed".utf8))
        try await wax.commit()
        _ = try await wax.put(Data("uncommitted".utf8))
        try await wax.close()
    }

    do {
        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == 2)
        #expect(stats.pendingFrames == 0)
        try await wax.close()
    }
}
