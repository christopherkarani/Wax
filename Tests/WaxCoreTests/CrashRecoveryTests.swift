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
        guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
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

/// Builds a two-commit snapshot store and loses its newest header page: the surviving page points
/// at the older footer, but its replay snapshot points at the newest one, which ends the file.
private func makeStoreWithLostNewestHeaderPage() async throws -> URL {
    let url = TempFiles.uniqueURL()
    let wax = try await Wax.create(
        at: url,
        walSize: 256 * 1024,
        options: WaxOptions(walReplayStateSnapshotEnabled: true)
    )
    _ = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
    try await wax.commit()
    _ = try await wax.put(Data("latest".utf8), options: FrameMetaSubset(searchText: "latest"))
    try await wax.commit()
    try await wax.close()

    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
    let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
    let selected = try #require(WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB))
    let selectedOffset = UInt64(selected.pageIndex) * Constants.headerPageSize
    try file.writeAll(Data(repeating: 0, count: Int(Constants.headerPageSize)), at: selectedOffset)
    try file.fsync()
    return url
}

private func fileSize(at url: URL) throws -> UInt64 {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    return try file.size()
}

private func appendBytes(_ data: Data, to url: URL) throws {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    try file.writeAll(data, at: try file.size())
    try file.fsync()
}

/// The replay snapshot on the surviving header page already names the newest footer. When that
/// footer is valid and ends the file, no newer footer can follow it, so open must not pay for a
/// scan of the whole file tail (most of reopen time on a large store).
@Test func openSkipsFooterScanWhenReplaySnapshotFooterEndsFile() async throws {
    for snapshotEnabled in [true, false] {
        // A fresh store each time: open rewrites the lost header page once it recovers.
        let url = try await makeStoreWithLostNewestHeaderPage()
        defer { try? FileManager.default.removeItem(at: url) }
        let reopened = try await Wax.open(
            at: url,
            options: WaxOptions(walReplayStateSnapshotEnabled: snapshotEnabled)
        )
        let stats = await reopened.stats()
        #expect(stats.frameCount == 2)
        #expect(try await reopened.frameContent(frameId: 1) == Data("latest".utf8))
        let walStats = await reopened.walStats()
        // Without the snapshot, the stale header gives no proof of the newest footer: scan.
        #expect(walStats.replayFooterScanCount == (snapshotEnabled ? 0 : 1))
        #expect(walStats.replaySnapshotHitCount == (snapshotEnabled ? 1 : 0))
        try await reopened.close()
    }
}

/// Bytes left past the snapshot footer by a crash.
enum TailPastSnapshotFooter: String, CaseIterable, Sendable {
    /// A partial next commit: TOC bytes, then a torn footer magic.
    case tornCommit
    case zeroPadding

    var bytes: Data {
        switch self {
        case .tornCommit:
            var torn = Data((0..<300).map { UInt8($0 & 0xff) })
            torn.append(contentsOf: Constants.footerMagic.prefix(4))
            return torn
        case .zeroPadding:
            return Data(repeating: 0, count: 64 * 1024)
        }
    }
}

/// Bytes past the snapshot footer mean it no longer ends the file, so open must scan, recover the
/// newest valid generation, and truncate the tail back to the clean end.
@Test(arguments: TailPastSnapshotFooter.allCases)
func openScansAndTruncatesTailPastReplaySnapshotFooter(_ tail: TailPastSnapshotFooter) async throws {
    let url = try await makeStoreWithLostNewestHeaderPage()
    defer { try? FileManager.default.removeItem(at: url) }
    let cleanSize = try fileSize(at: url)
    try appendBytes(tail.bytes, to: url)

    let reopened = try await Wax.open(at: url, options: WaxOptions(walReplayStateSnapshotEnabled: true))
    let stats = await reopened.stats()
    #expect(stats.frameCount == 2)
    #expect(try await reopened.frameContent(frameId: 1) == Data("latest".utf8))
    let walStats = await reopened.walStats()
    #expect(walStats.replayFooterScanCount == 1)
    try await reopened.close()
    #expect(try fileSize(at: url) == cleanSize)
}

@Test func cleanReopenUsesReplaySnapshotFastPath() async throws {
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
        try await wax.close()
    }

    do {
        let reopened = try await Wax.open(
            at: url,
            options: WaxOptions(walReplayStateSnapshotEnabled: true)
        )
        let stats = await reopened.stats()
        #expect(stats.frameCount == 1)
        #expect(try await reopened.frameContent(frameId: 0) == Data("seed".utf8))
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
        guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
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

    func selectedHeader(at fileURL: URL) throws -> WaxHeaderPage {
        let file = try FDFile.open(at: fileURL)
        defer { try? file.close() }
        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
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
        staleHeader.walReplaySnapshot = WaxHeaderPage.WALReplaySnapshot(
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
        // The snapshot footer (generation 2) does not end the file, so only a scan finds generation 3.
        let walStats = await reopened.walStats()
        #expect(walStats.replayFooterScanCount == 1)
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
        guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
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
        mutatedHeader.walReplaySnapshot = WaxHeaderPage.WALReplaySnapshot(
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
