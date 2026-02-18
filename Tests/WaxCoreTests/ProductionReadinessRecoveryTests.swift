import Foundation
import Testing
@testable import WaxCore

@Test
func abruptTerminationMidWriteRecoversPendingPutFrame() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("seed".utf8), options: FrameMetaSubset(searchText: "seed"))
        try await wax.commit()
        try await wax.close()
    }

    let pendingPayload = Data("pending-after-crash".utf8)
    let pendingFrameID: UInt64 = 1

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }

        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
            Issue.record("Expected valid header pages")
            return
        }

        let payloadOffset = try file.size()
        try file.writeAll(pendingPayload, at: payloadOffset)

        let checksum = SHA256Checksum.digest(pendingPayload)
        let put = PutFrame(
            frameId: pendingFrameID,
            timestampMs: 1_700_000_000_000,
            options: FrameMetaSubset(searchText: "pending-after-crash"),
            payloadOffset: payloadOffset,
            payloadLength: UInt64(pendingPayload.count),
            canonicalEncoding: .plain,
            canonicalLength: UInt64(pendingPayload.count),
            canonicalChecksum: checksum,
            storedChecksum: checksum
        )

        let writer = WALRingWriter(
            file: file,
            walOffset: selected.page.walOffset,
            walSize: selected.page.walSize,
            writePos: selected.page.walWritePos,
            checkpointPos: selected.page.walCheckpointPos,
            pendingBytes: 0,
            lastSequence: selected.page.walCommittedSeq
        )
        let walPayload = try WALEntryCodec.encode(.putFrame(put))
        _ = try writer.append(payload: walPayload)
        try file.fsync()
    }

    do {
        let reopened = try await Wax.open(at: url)
        let committedStats = await reopened.stats()
        #expect(committedStats.frameCount == 1)

        let pendingMeta = try await reopened.frameMetaIncludingPending(frameId: pendingFrameID)
        #expect(pendingMeta.searchText == "pending-after-crash")
        let pendingContent = try await reopened.frameContentIncludingPending(frameId: pendingFrameID)
        #expect(pendingContent == pendingPayload)

        try await reopened.commit()
        try await reopened.close()
    }

    do {
        let reopened = try await Wax.open(at: url)
        let stats = await reopened.stats()
        #expect(stats.frameCount == 2)
        #expect(try await reopened.frameContent(frameId: pendingFrameID) == pendingPayload)
        try await reopened.close()
    }
}

@Test
func walReplayAppliesDeleteAndPutInSequence() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("v0".utf8), options: FrameMetaSubset(searchText: "v0"))
        _ = try await wax.put(Data("v1".utf8), options: FrameMetaSubset(searchText: "v1"))
        try await wax.commit()
        try await wax.close()
    }

    let pendingPayload = Data("v2-pending".utf8)

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }

        let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
        let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
        guard let selected = MV2SHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
            Issue.record("Expected valid header pages")
            return
        }

        let payloadOffset = try file.size()
        try file.writeAll(pendingPayload, at: payloadOffset)

        let writer = WALRingWriter(
            file: file,
            walOffset: selected.page.walOffset,
            walSize: selected.page.walSize,
            writePos: selected.page.walWritePos,
            checkpointPos: selected.page.walCheckpointPos,
            pendingBytes: 0,
            lastSequence: selected.page.walCommittedSeq
        )

        let deletePayload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 0)))
        _ = try writer.append(payload: deletePayload)

        let checksum = SHA256Checksum.digest(pendingPayload)
        let put = PutFrame(
            frameId: 2,
            timestampMs: 1_700_000_000_001,
            options: FrameMetaSubset(searchText: "v2-pending"),
            payloadOffset: payloadOffset,
            payloadLength: UInt64(pendingPayload.count),
            canonicalEncoding: .plain,
            canonicalLength: UInt64(pendingPayload.count),
            canonicalChecksum: checksum,
            storedChecksum: checksum
        )
        let putPayload = try WALEntryCodec.encode(.putFrame(put))
        _ = try writer.append(payload: putPayload)
        try file.fsync()
    }

    do {
        let reopened = try await Wax.open(at: url)
        let meta0 = try await reopened.frameMetaIncludingPending(frameId: 0)
        #expect(meta0.status == .deleted)
        let meta2 = try await reopened.frameMetaIncludingPending(frameId: 2)
        #expect(meta2.searchText == "v2-pending")
        #expect(try await reopened.frameContentIncludingPending(frameId: 2) == pendingPayload)
        try await reopened.commit()
        try await reopened.close()
    }

    do {
        let reopened = try await Wax.open(at: url)
        let stats = await reopened.stats()
        #expect(stats.frameCount == 3)
        let meta0 = try await reopened.frameMeta(frameId: 0)
        #expect(meta0.status == .deleted)
        #expect(try await reopened.frameContent(frameId: 2) == pendingPayload)
        try await reopened.close()
    }
}

@Test
func truncatedMv2sFailsFastWithExplicitFooterError() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("truncated".utf8), options: FrameMetaSubset(searchText: "truncated"))
        try await wax.commit()
        try await wax.close()
    }

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        // Remove the full data/footer region so no historical footer remains recoverable.
        try file.truncate(to: Constants.headerPageSize * 2)
        try file.fsync()
    }

    do {
        _ = try await Wax.open(at: url)
        Issue.record("Expected open to fail for truncated .mv2s")
    } catch let error as WaxError {
        guard case .invalidFooter(let reason) = error else {
            Issue.record("Expected WaxError.invalidFooter, got \(error)")
            return
        }
        #expect(reason.contains("no valid footer"))
    }
}

@Test
func abruptTerminationMidCompactionRecoversFromPreviousValidFooter() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("stable-before-compaction".utf8), options: FrameMetaSubset(searchText: "stable-before-compaction"))
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

        let garbageOffset = try file.size()
        try file.writeAll(Data(repeating: 0xCD, count: 256), at: garbageOffset)

        var crashHeader = selected.page
        crashHeader.headerPageGeneration = selected.page.headerPageGeneration &+ 1
        crashHeader.fileGeneration = selected.page.fileGeneration &+ 1
        crashHeader.footerOffset = garbageOffset

        let selectedOffset = UInt64(selected.pageIndex) * Constants.headerPageSize
        try file.writeAll(try crashHeader.encodeWithChecksum(), at: selectedOffset)
        try file.fsync()
    }

    do {
        let reopened = try await Wax.open(at: url)
        let stats = await reopened.stats()
        #expect(stats.frameCount == 1)
        #expect(try await reopened.frameContent(frameId: 0) == Data("stable-before-compaction".utf8))
        try await reopened.close()
    }
}

@Test
func corruptedTocVersionFailsFastWithExplicitInvalidTocError() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    do {
        let wax = try await Wax.create(at: url)
        _ = try await wax.put(Data("corrupt".utf8), options: FrameMetaSubset(searchText: "corrupt"))
        try await wax.commit()
        try await wax.close()
    }

    guard var footerSlice = try FooterScanner.findLastValidFooter(in: url) else {
        Issue.record("Expected a valid footer for corruption setup")
        return
    }

    var corruptedToc = footerSlice.tocBytes
    var tocVersion: UInt64 = 2
    withUnsafeBytes(of: &tocVersion) { bytes in
        corruptedToc.replaceSubrange(0..<8, with: bytes)
    }
    let checksum = MV2STOC.computeChecksum(for: corruptedToc)
    corruptedToc.replaceSubrange((corruptedToc.count - 32)..<corruptedToc.count, with: checksum)

    var corruptedFooter = footerSlice.footer
    corruptedFooter.tocHash = checksum

    do {
        let file = try FDFile.open(at: url)
        defer { try? file.close() }
        try file.writeAll(corruptedToc, at: footerSlice.tocOffset)
        try file.writeAll(try corruptedFooter.encode(), at: footerSlice.footerOffset)
        try file.fsync()
    }

    do {
        _ = try await Wax.open(at: url)
        Issue.record("Expected open to fail for corrupted toc_version")
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            Issue.record("Expected WaxError.invalidToc, got \(error)")
            return
        }
        #expect(reason.contains("unsupported toc_version"))
    }
}

@Test
func migrationFixturesNMinus1AndNMinus2Load() async throws {
    let fixtureNMinus1 = TempFiles.uniqueURL()
    let fixtureNMinus2 = TempFiles.uniqueURL()
    defer {
        try? FileManager.default.removeItem(at: fixtureNMinus1)
        try? FileManager.default.removeItem(at: fixtureNMinus2)
    }

    try await buildMigrationFixture(
        at: fixtureNMinus1,
        label: "n-1",
        options: WaxOptions(walReplayStateSnapshotEnabled: true)
    )
    try await buildMigrationFixture(
        at: fixtureNMinus2,
        label: "n-2",
        options: WaxOptions(walReplayStateSnapshotEnabled: false)
    )

    do {
        let wax = try await Wax.open(at: fixtureNMinus1)
        let stats = await wax.stats()
        #expect(stats.frameCount == 2)
        #expect(try await wax.frameContent(frameId: 0) == Data("n-1-frame-0".utf8))
        #expect(try await wax.frameContent(frameId: 1) == Data("n-1-frame-1".utf8))
        try await wax.close()
    }

    do {
        let wax = try await Wax.open(at: fixtureNMinus2)
        let stats = await wax.stats()
        #expect(stats.frameCount == 2)
        #expect(try await wax.frameContent(frameId: 0) == Data("n-2-frame-0".utf8))
        #expect(try await wax.frameContent(frameId: 1) == Data("n-2-frame-1".utf8))
        try await wax.close()
    }
}

private func buildMigrationFixture(at url: URL, label: String, options: WaxOptions) async throws {
    let wax = try await Wax.create(at: url, options: options)
    _ = try await wax.put(Data("\(label)-frame-0".utf8), options: FrameMetaSubset(searchText: "\(label)-frame-0"))
    _ = try await wax.put(Data("\(label)-frame-1".utf8), options: FrameMetaSubset(searchText: "\(label)-frame-1"))
    try await wax.commit()
    try await wax.close()
}
