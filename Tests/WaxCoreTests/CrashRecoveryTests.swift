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

@Test func openUsesNewestFooterWhenHeaderPointsToOlderValidFooter() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    var oldPageA = Data()
    var oldPageB = Data()

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("v1".utf8))
        try await wax.commit()
        try await wax.close()
    }

    do {
        let file = try FDFile.open(at: url)
        oldPageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        oldPageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        try file.close()
    }

    do {
        let wax = try await Wax.open(at: url)
        _ = try await wax.put(Data("v2".utf8))
        try await wax.commit()
        try await wax.close()
    }

    // Simulate crash window where latest footer is durable but header pages still point to old footer.
    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        try file.writeAll(oldPageA, at: 0)
        try file.writeAll(oldPageB, at: Constants.headerPageSize)
        try file.fsync()
    }

    do {
        let wax = try await Wax.open(at: url)
        let stats = await wax.stats()
        #expect(stats.frameCount == 2)
        #expect(try await wax.frameContent(frameId: 0) == Data("v1".utf8))
        #expect(try await wax.frameContent(frameId: 1) == Data("v2".utf8))
        try await wax.close()
    }
}
