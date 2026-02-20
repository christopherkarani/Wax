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

@Test func openUsesPersistedReplaySnapshotWhenNewestHeaderPageIsMissing() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(
            at: url,
            walSize: 2 * 1024 * 1024,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )
        _ = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
        try await wax.commit()

        for index in 0..<2_000 {
            _ = try await wax.put(
                Data("payload-\(index)".utf8),
                options: FrameMetaSubset(searchText: "payload-\(index)")
            )
        }
        try await wax.commit()
        try await wax.close()
    }

    // Simulate a missing latest header page and force selection of the older page.
    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }

        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
            Issue.record("Expected valid header pages")
            return
        }
        let selectedOffset = UInt64(selected.pageIndex) * Constants.headerPageSize
        try file.writeAll(Data(repeating: 0, count: Int(Constants.headerPageSize)), at: selectedOffset)
        try file.fsync()
    }

    do {
        let reopened = try await Wax.open(
            at: url,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )
        let stats = await reopened.stats()
        #expect(stats.frameCount == 2_001)
        let walStats = await reopened.walStats()
        #expect(walStats.replaySnapshotHitCount == 1)
        try await reopened.close()
    }
}

@Test func openFallsBackToReplayScanWhenPersistedCursorNoLongerTerminal() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url, walSize: 256 * 1024)
        _ = try await wax.put(
            Data("seed".utf8),
            options: FrameMetaSubset(searchText: "seed")
        )
        try await wax.commit()
        try await wax.close()
    }

    // Simulate crash window by appending WAL after the persisted cursor without updating header/footer.
    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }

        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
            Issue.record("Expected valid header pages")
            return
        }

        let writer = WALRingWriter(
            file: file,
            walOffset: selected.page.walOffset,
            walSize: selected.page.walSize,
            writePos: selected.page.walWritePos,
            checkpointPos: selected.page.walCheckpointPos,
            pendingBytes: 0,
            lastSequence: selected.page.walCommittedSeq
        )
        let payload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 0)))
        _ = try writer.append(payload: payload)
        try file.fsync()
    }

    do {
        let reopened = try await Wax.open(at: url)
        let meta = try await reopened.frameMetaIncludingPending(frameId: 0)
        #expect(meta.status == .deleted)

        let walStats = await reopened.walStats()
        #expect(walStats.pendingBytes > 0)
        try await reopened.close()
    }
}

@Test func openScansPastStaleSnapshotFooterWhenOnlyHeaderPageIsStale() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    func selectedHeader(at fileURL: URL) throws -> MV2SHeaderPage {
        let file = try FDFile.open(at: fileURL)
        defer { try? file.close() }
        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
            throw WaxError.invalidHeader(reason: "no valid header pages")
        }
        return selected.page
    }

    do {
        let wax = try await Wax.create(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        _ = try await wax.put(Data("v1".utf8), options: FrameMetaSubset(searchText: "v1"))
        try await wax.commit()
        try await wax.close()
    }
    let gen1Header = try selectedHeader(at: url)

    do {
        let wax = try await Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        _ = try await wax.put(Data("v2".utf8), options: FrameMetaSubset(searchText: "v2"))
        try await wax.commit()
        try await wax.close()
    }
    let gen2Header = try selectedHeader(at: url)

    do {
        let wax = try await Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        _ = try await wax.put(Data("v3".utf8), options: FrameMetaSubset(searchText: "v3"))
        try await wax.commit()
        try await wax.close()
    }
    let latestHeader = try selectedHeader(at: url)

    // Build a stale-but-valid header where:
    // - header points at generation 1
    // - replay snapshot points at generation 2 (newer than header)
    // - newest footer on disk is generation 3
    // With the old bypass, open would choose generation 2 and miss generation 3.
    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }

        var staleHeader = latestHeader
        staleHeader.fileGeneration = gen1Header.fileGeneration
        staleHeader.footerOffset = gen1Header.footerOffset
        staleHeader.walCommittedSeq = gen1Header.walCommittedSeq
        staleHeader.tocChecksum = gen1Header.tocChecksum
        staleHeader.walReplaySnapshot = MV2SHeaderPage.WALReplaySnapshot(
            fileGeneration: gen2Header.fileGeneration,
            walCommittedSeq: gen2Header.walCommittedSeq,
            footerOffset: gen2Header.footerOffset,
            walWritePos: gen2Header.walWritePos,
            walCheckpointPos: gen2Header.walCheckpointPos,
            walPendingBytes: 0,
            walLastSequence: gen2Header.walCommittedSeq
        )
        staleHeader.headerPageGeneration = latestHeader.headerPageGeneration &+ 1

        try file.writeAll(try staleHeader.encodeWithChecksum(), at: 0)
        try file.writeAll(Data(repeating: 0, count: Int(Constants.headerPageSize)), at: Constants.headerPageSize)
        try file.fsync()
    }

    do {
        let reopened = try await Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
        let stats = await reopened.stats()
        #expect(stats.frameCount == 3)
        #expect(try await reopened.frameContent(frameId: 0) == Data("v1".utf8))
        #expect(try await reopened.frameContent(frameId: 1) == Data("v2".utf8))
        #expect(try await reopened.frameContent(frameId: 2) == Data("v3".utf8))
        try await reopened.close()
    }
}

@Test func openFallsBackToWalScanWhenReplaySnapshotMetadataMismatchesCommittedFooter() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(
            at: url,
            walSize: 256 * 1024,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )
        _ = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
        try await wax.commit()
        try await wax.close()
    }

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }

        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
            Issue.record("Expected valid header pages")
            return
        }

        let writer = WALRingWriter(
            file: file,
            walOffset: selected.page.walOffset,
            walSize: selected.page.walSize,
            writePos: selected.page.walWritePos,
            checkpointPos: selected.page.walCheckpointPos,
            pendingBytes: 0,
            lastSequence: selected.page.walCommittedSeq
        )
        let payload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 0)))
        _ = try writer.append(payload: payload)

        var mutatedHeader = selected.page
        mutatedHeader.headerPageGeneration = selected.page.headerPageGeneration &+ 1
        mutatedHeader.walReplaySnapshot = MV2SHeaderPage.WALReplaySnapshot(
            fileGeneration: selected.page.fileGeneration &+ 9,
            walCommittedSeq: selected.page.walCommittedSeq &+ 1,
            footerOffset: selected.page.footerOffset &+ 64,
            walWritePos: writer.writePos,
            walCheckpointPos: writer.writePos,
            walPendingBytes: 0,
            walLastSequence: writer.lastSequence
        )

        let selectedOffset = UInt64(selected.pageIndex) * Constants.headerPageSize
        try file.writeAll(try mutatedHeader.encodeWithChecksum(), at: selectedOffset)
        try file.fsync()
    }

    do {
        let reopened = try await Wax.open(
            at: url,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )
        let meta = try await reopened.frameMetaIncludingPending(frameId: 0)
        #expect(meta.status == .deleted)

        let walStats = await reopened.walStats()
        #expect(walStats.pendingBytes > 0)
        #expect(walStats.replaySnapshotHitCount == 0)
        try await reopened.close()
    }
}
