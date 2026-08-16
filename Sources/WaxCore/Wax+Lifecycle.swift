import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Wax {
    // MARK: - Lifecycle

    static func walProactiveCommitThresholdBytes(
        walSize: UInt64,
        thresholdPercent: UInt8?,
        maxWalSizeBytes: UInt64?
    ) -> UInt64? {
        if let maxWalSizeBytes, walSize > maxWalSizeBytes {
            return nil
        }
        guard let thresholdPercent else { return nil }
        guard thresholdPercent > 0 else { return nil }
        guard thresholdPercent < 100 else { return nil }

        let threshold = (walSize * UInt64(thresholdPercent)) / 100
        return max(1, min(threshold, walSize))
    }

    static func walProactiveCommitMaxWalSizeBytes(_ maxWalSizeBytes: UInt64?) -> UInt64? {
        guard let maxWalSizeBytes else { return nil }
        guard maxWalSizeBytes > 0 else { return nil }
        return maxWalSizeBytes
    }

    static func walProactiveCommitMinPendingBytes(_ minPendingBytes: UInt64) -> UInt64 {
        max(1, minPendingBytes)
    }

    private static func applyDataProtectionIfSupported(at url: URL) throws {
        #if os(iOS) || os(watchOS) || os(tvOS) || os(visionOS)
        try FileManager.default.setAttributes(
            [.protectionKey: FileProtectionType.complete],
            ofItemAtPath: url.path
        )
        #endif
    }

    /// Create a new, empty `.wax` file.
    package static func create(
        at url: URL,
        walSize: UInt64 = Constants.defaultWalSize,
        options: WaxOptions = .init()
    ) async throws -> Wax {
        guard walSize >= Constants.walRecordHeaderSize else {
            throw WaxError.invalidHeader(reason: "wal_size must be >= \(Constants.walRecordHeaderSize)")
        }

        let io = BlockingIOExecutor(label: options.ioQueueLabel, qos: options.ioQueueQos)
        let created = try await io.run { () throws -> (
            file: FDFile,
            lock: FileLock,
            header: WaxHeaderPage,
            toc: WaxTOC,
            wal: WALRingWriter,
            dataEnd: UInt64
        ) in
            let lock = try FileLock.acquireExclusiveOrCreate(
                at: url,
                timeout: options.lockWaitTimeout
            )
            let file: FDFile
            do {
                file = try FDFile.open(at: url)
                try file.truncate(to: 0)
            } catch {
                try? lock.release()
                throw error
            }
            var createSucceeded = false
            defer {
                if !createSucceeded {
                    try? file.close()
                    try? lock.release()
                }
            }

            let walOffset = Constants.walOffset
            let dataStart = walOffset + walSize

            var toc = WaxTOC.emptyV1()
            let tocBytes = try toc.encode()
            let tocChecksum = tocBytes.suffix(32)
            toc.tocChecksum = Data(tocChecksum)

            let tocOffset = dataStart
            try file.writeAll(tocBytes, at: tocOffset)
            let footerOffset = tocOffset + UInt64(tocBytes.count)
            let footer = WaxFooter(
                tocLen: UInt64(tocBytes.count),
                tocHash: Data(tocChecksum),
                generation: 0,
                walCommittedSeq: 0
            )
            try file.writeAll(try footer.encode(), at: footerOffset)
            try file.fsync()

            let headerA = WaxHeaderPage(
                headerPageGeneration: 1,
                fileGeneration: 0,
                footerOffset: footerOffset,
                walOffset: walOffset,
                walSize: walSize,
                walWritePos: 0,
                walCheckpointPos: 0,
                walCommittedSeq: 0,
                tocChecksum: Data(tocChecksum)
            )
            let pageABytes = try headerA.encodeWithChecksum()
            try file.writeAll(pageABytes, at: 0)
            var headerB = headerA
            headerB.headerPageGeneration = 0
            let pageBBytes = try headerB.encodeWithChecksum()
            try file.writeAll(pageBBytes, at: Constants.headerPageSize)
            try file.fsync()

            let wal = WALRingWriter(
                file: file,
                walOffset: walOffset,
                walSize: walSize,
                fsyncPolicy: options.walFsyncPolicy
            )

            createSucceeded = true
            return (
                file: file,
                lock: lock,
                header: headerA,
                toc: toc,
                wal: wal,
                dataEnd: footerOffset + Constants.footerSize
            )
        }

        let wax = Wax(
            url: url,
            io: io,
            file: created.file,
            lock: created.lock,
            header: created.header,
            selectedHeaderPageIndex: 0,
            toc: created.toc,
            wal: created.wal,
            pendingMutations: [],
            encodedCommittedFramePayloadCache: Data(),
            stagedLexIndex: nil,
            stagedVecIndex: nil,
            stagedLexIndexStamp: nil,
            stagedVecIndexStamp: nil,
            stagedLexIndexStampCounter: 0,
            stagedVecIndexStampCounter: 0,
            dataEnd: created.dataEnd,
            generation: 0,
            dirty: false,
            walAutoCommitCount: 0,
            walReplaySnapshotHitCount: 0,
            walProactiveCommitThresholdBytes: walProactiveCommitThresholdBytes(
                walSize: walSize,
                thresholdPercent: options.walProactiveCommitThresholdPercent,
                maxWalSizeBytes: walProactiveCommitMaxWalSizeBytes(
                    options.walProactiveCommitMaxWalSizeBytes
                )
            ),
            walProactiveCommitMaxWalSizeBytes: walProactiveCommitMaxWalSizeBytes(
                options.walProactiveCommitMaxWalSizeBytes
            ),
            walProactiveCommitMinPendingBytes: walProactiveCommitMinPendingBytes(
                options.walProactiveCommitMinPendingBytes
            ),
            walReplayStateSnapshotEnabled: options.walReplayStateSnapshotEnabled
        )
        do {
            try Self.applyDataProtectionIfSupported(at: url)
        } catch {
            try? await wax.close()
            throw error
        }
        return wax
    }

    /// Open an existing `.wax` file.
    ///
    /// By default, Wax will repair trailing bytes beyond the last valid footer while preserving any
    /// uncommitted payload bytes referenced by the pending WAL.
    package static func open(at url: URL, options: WaxOptions = .init()) async throws -> Wax {
        try await open(at: url, repair: true, options: options)
    }

    /// Open an existing `.wax` file, optionally repairing trailing bytes past the last valid footer.
    ///
    /// If `repair` is true and the file contains bytes beyond the last valid footer, the file is truncated to the
    /// smallest safe end offset:
    /// - `footerOffset + footerSize` (latest committed state), and
    /// - the highest `payloadOffset + payloadLength` referenced by the pending WAL (to preserve uncommitted puts).
    package static func open(at url: URL, repair: Bool, options: WaxOptions = .init()) async throws -> Wax {
        let io = BlockingIOExecutor(label: options.ioQueueLabel, qos: options.ioQueueQos)
        let opened = try await io.run { () throws -> (
            file: FDFile,
            lock: FileLock,
            header: WaxHeaderPage,
            selectedHeaderPageIndex: Int,
            toc: WaxTOC,
            wal: WALRingWriter,
            pendingMutations: [PendingMutation],
            dataEnd: UInt64,
            generation: UInt64,
            dirty: Bool,
            replaySnapshotUsed: Bool
        ) in
            let lock = try FileLock.acquire(
                at: url,
                mode: .exclusive,
                timeout: options.lockWaitTimeout
            )
            let file = try FDFile.open(at: url)

            let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
            let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
            guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
                throw WaxError.invalidHeader(reason: "no valid header pages")
            }
            var header = selected.page
            let selectedHeaderFileGeneration = header.fileGeneration

            func newerFooter(_ lhs: FooterSlice, _ rhs: FooterSlice) -> FooterSlice {
                if rhs.footer.generation > lhs.footer.generation { return rhs }
                if rhs.footer.generation == lhs.footer.generation,
                   rhs.footerOffset > lhs.footerOffset {
                    return rhs
                }
                return lhs
            }

            let fastFooter = try FooterScanner.findFooter(at: header.footerOffset, in: url)
            let snapshotFooter: FooterSlice?
            if options.walReplayStateSnapshotEnabled,
               let snapshot = header.walReplaySnapshot {
                snapshotFooter = try FooterScanner.findFooter(at: snapshot.footerOffset, in: url)
            } else {
                snapshotFooter = nil
            }
            var fileSize = try file.size()

            let footerSlice: FooterSlice
            let shouldScanForNewerFooter: Bool = {
                guard let fastFooter else { return true }
                guard selectedHeaderFileGeneration == fastFooter.footer.generation else { return true }
                guard header.tocChecksum == fastFooter.footer.tocHash else { return true }
                let expectedEnd = fastFooter.footerOffset + Constants.footerSize
                guard fileSize == expectedEnd else { return true }
                if let snapshotFooter {
                    if snapshotFooter.footer.generation > fastFooter.footer.generation {
                        return true
                    }
                    if snapshotFooter.footer.generation == fastFooter.footer.generation,
                       snapshotFooter.footerOffset > fastFooter.footerOffset {
                        return true
                    }
                }
                return false
            }()
            let scannedFooter = shouldScanForNewerFooter
                ? try FooterScanner.findLastValidFooter(in: url)
                : nil
            var footerCandidates: [FooterSlice] = []
            footerCandidates.reserveCapacity(3)
            if let fastFooter {
                footerCandidates.append(fastFooter)
            }
            if let snapshotFooter {
                footerCandidates.append(snapshotFooter)
            }
            if let scannedFooter {
                footerCandidates.append(scannedFooter)
            }
            guard let firstFooterCandidate = footerCandidates.first else {
                throw WaxError.invalidFooter(reason: "no valid footer found within max_footer_scan_bytes")
            }
            footerSlice = footerCandidates.dropFirst().reduce(firstFooterCandidate, newerFooter)

            let toc = try WaxTOC.decode(from: footerSlice.tocBytes)
            let dataStart = header.walOffset + header.walSize
            try Self.validateTocRanges(toc, dataStart: dataStart, dataEnd: footerSlice.footerOffset)
            let recoveredCommittedSeq = footerSlice.footer.walCommittedSeq
            let selectedHeaderWasStale = selectedHeaderFileGeneration != footerSlice.footer.generation
            header.footerOffset = footerSlice.footerOffset
            header.fileGeneration = footerSlice.footer.generation
            header.walCommittedSeq = recoveredCommittedSeq
            header.tocChecksum = footerSlice.footer.tocHash

            let walReader = WALRingReader(file: file, walOffset: header.walOffset, walSize: header.walSize)
            let committedSeq = recoveredCommittedSeq
            let persistedReplaySnapshot = header.walReplaySnapshot
            let shouldAttemptPersistedReplaySnapshot = options.walReplayStateSnapshotEnabled
                && persistedReplaySnapshot?.fileGeneration == footerSlice.footer.generation
                && persistedReplaySnapshot?.walCommittedSeq == committedSeq
                && persistedReplaySnapshot?.footerOffset == footerSlice.footerOffset
            let shouldAttemptHeaderCursorSnapshot = options.walReplayStateSnapshotEnabled
                && !selectedHeaderWasStale
                && header.walCheckpointPos == header.walWritePos

            let pendingMutations: [PendingMutation]
            let scanState: WALScanState
            var usedReplaySnapshot = false
            if shouldAttemptPersistedReplaySnapshot,
               let snapshot = persistedReplaySnapshot,
               snapshot.walCheckpointPos == snapshot.walWritePos,
               try walReader.isTerminalMarker(at: snapshot.walWritePos)
            {
                // Fast path: replay snapshot persisted with the committed generation (survives stale header pointers).
                pendingMutations = []
                scanState = WALScanState(
                    lastSequence: max(committedSeq, snapshot.walLastSequence),
                    writePos: snapshot.walWritePos % header.walSize,
                    pendingBytes: 0
                )
                usedReplaySnapshot = true
            } else if shouldAttemptHeaderCursorSnapshot,
                      try walReader.isTerminalMarker(at: header.walWritePos)
            {
                // Fast path for files that predate replay snapshots but have consistent header cursors.
                pendingMutations = []
                scanState = WALScanState(
                    lastSequence: committedSeq,
                    writePos: header.walWritePos % header.walSize,
                    pendingBytes: 0
                )
                usedReplaySnapshot = true
            } else {
                let pendingScan = try walReader.scanPendingMutationsWithState(
                    from: header.walCheckpointPos,
                    committedSeq: committedSeq
                )
                pendingMutations = pendingScan.pendingMutations
                scanState = pendingScan.state
            }
            let lastSequence = max(committedSeq, scanState.lastSequence)
            let effectiveCheckpointPos: UInt64
            let effectivePendingBytes: UInt64
            if scanState.lastSequence <= committedSeq {
                effectiveCheckpointPos = scanState.writePos
                effectivePendingBytes = 0
            } else {
                effectiveCheckpointPos = header.walCheckpointPos
                effectivePendingBytes = scanState.pendingBytes
            }
            header.walWritePos = scanState.writePos
            header.walCheckpointPos = effectiveCheckpointPos
            let wal = WALRingWriter(
                file: file,
                walOffset: header.walOffset,
                walSize: header.walSize,
                writePos: scanState.writePos,
                checkpointPos: effectiveCheckpointPos,
                pendingBytes: effectivePendingBytes,
                lastSequence: lastSequence,
                fsyncPolicy: options.walFsyncPolicy
            )

            let expectedEnd = footerSlice.footerOffset + Constants.footerSize
            var requiredEnd = expectedEnd
            for mutation in pendingMutations {
                guard case .putFrame(let put) = mutation.entry else { continue }
                guard put.payloadOffset <= UInt64.max - put.payloadLength else {
                    throw WaxError.invalidToc(reason: "pending frame \(put.frameId) payload range overflows")
                }
                let end = put.payloadOffset + put.payloadLength
                if end > requiredEnd { requiredEnd = end }
            }

            guard requiredEnd <= fileSize else {
                throw WaxError.invalidToc(reason: "pending WAL references bytes beyond file size")
            }
            try Self.validatePendingPayloadChecksums(pendingMutations, file: file)
            if repair, fileSize > requiredEnd {
                try file.truncate(to: requiredEnd)
                try file.fsync()
                fileSize = requiredEnd
            }
            let dataEnd = max(fileSize, requiredEnd)

            return (
                file: file,
                lock: lock,
                header: header,
                selectedHeaderPageIndex: selected.pageIndex,
                toc: toc,
                wal: wal,
                pendingMutations: pendingMutations,
                dataEnd: dataEnd,
                generation: footerSlice.footer.generation,
                dirty: !pendingMutations.isEmpty,
                replaySnapshotUsed: usedReplaySnapshot
            )
        }

        let wax = Wax(
            url: url,
            io: io,
            file: opened.file,
            lock: opened.lock,
            header: opened.header,
            selectedHeaderPageIndex: opened.selectedHeaderPageIndex,
            toc: opened.toc,
            wal: opened.wal,
            pendingMutations: opened.pendingMutations,
            encodedCommittedFramePayloadCache: nil,
            stagedLexIndex: nil,
            stagedVecIndex: nil,
            stagedLexIndexStamp: nil,
            stagedVecIndexStamp: nil,
            stagedLexIndexStampCounter: 0,
            stagedVecIndexStampCounter: 0,
            dataEnd: opened.dataEnd,
            generation: opened.generation,
            dirty: opened.dirty,
            walAutoCommitCount: 0,
            walReplaySnapshotHitCount: opened.replaySnapshotUsed ? 1 : 0,
            walProactiveCommitThresholdBytes: walProactiveCommitThresholdBytes(
                walSize: opened.header.walSize,
                thresholdPercent: options.walProactiveCommitThresholdPercent,
                maxWalSizeBytes: walProactiveCommitMaxWalSizeBytes(
                    options.walProactiveCommitMaxWalSizeBytes
                )
            ),
            walProactiveCommitMaxWalSizeBytes: walProactiveCommitMaxWalSizeBytes(
                options.walProactiveCommitMaxWalSizeBytes
            ),
            walProactiveCommitMinPendingBytes: walProactiveCommitMinPendingBytes(
                options.walProactiveCommitMinPendingBytes
            ),
            walReplayStateSnapshotEnabled: options.walReplayStateSnapshotEnabled
        )
        do {
            try Self.applyDataProtectionIfSupported(at: url)
        } catch {
            try? await wax.close()
            throw error
        }
        return wax
    }

}
