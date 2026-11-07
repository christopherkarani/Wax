import Foundation

extension Wax {
    /// Internal only because of the file split.
    struct WriterWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    // MARK: - Writer lease

    package func acquireWriterLease(policy: WaxWriterPolicy) async throws -> UUID {
        if let _ = writerLeaseId {
            switch policy {
            case .fail:
                throw WaxError.writerBusy
            case .wait:
                return try await enqueueWriterWaiter(timeout: nil)
            case .timeout(let duration):
                return try await enqueueWriterWaiter(timeout: duration)
            }
        }

        let leaseId = UUID()
        writerLeaseId = leaseId
        return leaseId
    }

    package func releaseWriterLease(_ leaseId: UUID) {
        guard writerLeaseId == leaseId else { return }

        if writerWaiters.isEmpty {
            writerLeaseId = nil
            return
        }

        let next = writerWaiters.removeFirst()
        let nextLeaseId = UUID()
        writerLeaseId = nextLeaseId
        next.continuation.resume(returning: nextLeaseId)
    }

    private func enqueueWriterWaiter(timeout: Duration?) async throws -> UUID {
        let waiterId = UUID()
        return try await withCheckedThrowingContinuation { continuation in
            writerWaiters.append(WriterWaiter(id: waiterId, continuation: continuation))
            if let timeout {
                Task { [waiterId] in
                    await self.timeoutWriterWaiter(id: waiterId, duration: timeout)
                }
            }
        }
    }

    private func timeoutWriterWaiter(id: UUID, duration: Duration) async {
        do {
            try await Task.sleep(for: duration)
        } catch {
            return
        }

        if let index = writerWaiters.firstIndex(where: { $0.id == id }) {
            let waiter = writerWaiters.remove(at: index)
            waiter.continuation.resume(throwing: WaxError.writerTimeout)
        }
    }

    // MARK: - Lifecycle

    private static func walProactiveCommitThresholdBytes(
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

    private static func walProactiveCommitMaxWalSizeBytes(_ maxWalSizeBytes: UInt64?) -> UInt64? {
        guard let maxWalSizeBytes else { return nil }
        guard maxWalSizeBytes > 0 else { return nil }
        return maxWalSizeBytes
    }

    private static func walProactiveCommitMinPendingBytes(_ minPendingBytes: UInt64) -> UInt64 {
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
                // Create-new semantics: callers check for the file first, but another
                // process can create it in between. Never clobber a store with bytes;
                // only an empty file (e.g. left by a crash before the first write) is reused.
                let existingSize = try file.size()
                guard existingSize == 0 else {
                    try? file.close()
                    throw WaxError.io("refusing to create \(url.path): file already exists (\(existingSize) bytes)")
                }
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
            // Throws only for real I/O errors; filesystems that cannot sync a directory
            // (EINVAL/ENOTSUP on some network/FUSE mounts) are skipped inside.
            try FDFile.fsyncParentDirectory(of: url)

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
            walReplayTruncationCount: 0,
            walReplayFooterScanCount: 0,
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
        await wax.initializeDataSpace(
            committedTocRange: (Constants.walOffset + walSize)..<created.dataEnd,
            mayHoldUnreferencedFooter: false
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
            committedTocRange: Range<UInt64>,
            headerCommitRanges: [Range<UInt64>],
            releasesHeaderCommitsAfterNextCommit: Bool,
            generation: UInt64,
            dirty: Bool,
            replaySnapshotUsed: Bool,
            replayTruncated: Bool,
            footerScanned: Bool
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
            // The other page names an older commit that open falls back to when the newest
            // page is torn; space reuse keeps it intact, and its footer may end the file.
            let otherHeaderPageIndex = selected.pageIndex == 0 ? 1 : 0
            let otherHeaderPage = try? WaxHeaderPage.decodeWithChecksumValidation(
                from: otherHeaderPageIndex == 0 ? pageA : pageB
            )
            let otherPageFooter = otherHeaderPage.flatMap {
                try? FooterScanner.findFooter(at: $0.footerOffset, in: url)
            }
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
                // Each commit appends its footer past the previous one, so a valid footer that
                // ends the file is the newest. The replay snapshot names that footer even when
                // the header page that pointed at it was lost.
                if let snapshotFooter,
                   let snapshot = header.walReplaySnapshot,
                   snapshot.fileGeneration == snapshotFooter.footer.generation,
                   snapshot.walCommittedSeq == snapshotFooter.footer.walCommittedSeq,
                   snapshotFooter.footer.generation >= (fastFooter?.footer.generation ?? 0),
                   fileSize == snapshotFooter.footerOffset + Constants.footerSize
                {
                    return false
                }
                guard let fastFooter else { return true }
                guard selectedHeaderFileGeneration == fastFooter.footer.generation else { return true }
                guard header.tocChecksum == fastFooter.footer.tocHash else { return true }
                let expectedEnd = fastFooter.footerOffset + Constants.footerSize
                let otherPageFooterEndsFile = otherPageFooter.map {
                    $0.footer.generation < fastFooter.footer.generation
                        && fileSize == $0.footerOffset + Constants.footerSize
                } ?? false
                guard fileSize == expectedEnd || otherPageFooterEndsFile else { return true }
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
            var replayTruncated = false
            // Highest sequence in the scanned chain, dropped torn-tail records included.
            var highestScannedSequence: UInt64 = 0
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
                highestScannedSequence = pendingScan.state.lastSequence
                let statuses = try pendingScan.pendingMutations.map {
                    try Self.pendingPayloadStatus($0, file: file, fileSize: fileSize)
                }
                // Truncation is destructive, so it needs `repair`. With `.always` fsync every payload
                // was synced before its WAL record, so any damage is corruption rather than a torn write.
                // The policy that wrote the WAL is not persisted; this is the opener's policy.
                let decision = PendingReplayPolicy.decide(
                    statuses,
                    allowsTruncation: repair && options.walFsyncPolicy != .always
                )
                switch decision {
                case .replayAll:
                    pendingMutations = pendingScan.pendingMutations
                    scanState = pendingScan.state
                case .failClosed(let index):
                    throw Self.pendingPayloadError(pendingScan.pendingMutations[index], status: statuses[index])
                case .truncateTornTail(let index):
                    scanState = try PendingReplayPolicy.truncateTornTail(
                        pendingScan,
                        at: index,
                        checkpointPos: header.walCheckpointPos,
                        ring: (offset: header.walOffset, size: header.walSize),
                        file: file
                    )
                    pendingMutations = Array(pendingScan.pendingMutations.prefix(index))
                    replayTruncated = true
                }
            }
            // Resume above every sequence that can still be in the ring, so stale bytes past the
            // chain end (a dropped tail, or records behind a torn envelope) never chain after a new record.
            let lastSequence = try PendingReplayPolicy.resumeSequence(
                above: max(
                    committedSeq,
                    scanState.lastSequence,
                    highestScannedSequence,
                    persistedReplaySnapshot?.walLastSequence ?? 0
                ),
                walSize: header.walSize
            )
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
                fsyncPolicy: options.walFsyncPolicy,
                needsDurableAnchor: true
            )

            let expectedEnd = footerSlice.footerOffset + Constants.footerSize
            var requiredEnd = expectedEnd
            // Replayed puts passed `pendingPayloadStatus`, so their ranges are in bounds.
            for mutation in pendingMutations {
                guard case .putFrame(let put) = mutation.entry else { continue }
                requiredEnd = max(requiredEnd, put.payloadOffset + put.payloadLength)
            }

            // Ranges of commits a header page names besides the recovered one: they stay
            // reserved, and repair must not truncate them.
            var selectedHeaderPageIndex = selected.pageIndex
            var headerCommitRanges: [Range<UInt64>] = []
            let releasesHeaderCommitsAfterNextCommit: Bool
            func commitRanges(_ slice: FooterSlice?) -> [Range<UInt64>] {
                guard let slice, slice.footerOffset != footerSlice.footerOffset,
                      let ranges = Self.commitRanges(of: slice)
                else { return [] }
                return ranges
            }
            if !selectedHeaderWasStale {
                headerCommitRanges = commitRanges(otherPageFooter)
                releasesHeaderCommitsAfterNextCommit = true
            } else if repair {
                // Neither page names the recovered commit. Name it on the other page now, so
                // the pages again name the durable commit and the one before it.
                var recoveredHeader = header
                recoveredHeader.headerPageGeneration = max(
                    selected.page.headerPageGeneration,
                    otherHeaderPage?.headerPageGeneration ?? 0
                ) &+ 1
                recoveredHeader.walReplaySnapshot = nil
                try file.writeAll(
                    try recoveredHeader.encodeWithChecksum(),
                    at: UInt64(otherHeaderPageIndex) * Constants.headerPageSize
                )
                try file.fsync()
                header = recoveredHeader
                selectedHeaderPageIndex = otherHeaderPageIndex
                headerCommitRanges = commitRanges(fastFooter)
                releasesHeaderCommitsAfterNextCommit = true
            } else {
                // Without repair the pages stay as they are; keep both their commits until close.
                headerCommitRanges = commitRanges(fastFooter) + commitRanges(otherPageFooter)
                releasesHeaderCommitsAfterNextCommit = false
            }
            for range in headerCommitRanges {
                requiredEnd = max(requiredEnd, range.upperBound)
            }

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
                selectedHeaderPageIndex: selectedHeaderPageIndex,
                toc: toc,
                wal: wal,
                pendingMutations: pendingMutations,
                dataEnd: dataEnd,
                committedTocRange: footerSlice.tocOffset..<expectedEnd,
                headerCommitRanges: headerCommitRanges,
                releasesHeaderCommitsAfterNextCommit: releasesHeaderCommitsAfterNextCommit,
                generation: footerSlice.footer.generation,
                dirty: !pendingMutations.isEmpty,
                replaySnapshotUsed: usedReplaySnapshot,
                replayTruncated: replayTruncated,
                footerScanned: shouldScanForNewerFooter
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
            walReplayTruncationCount: opened.replayTruncated ? 1 : 0,
            walReplayFooterScanCount: opened.footerScanned ? 1 : 0,
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
        await wax.initializeDataSpace(
            committedTocRange: opened.committedTocRange,
            headerCommitRanges: opened.headerCommitRanges,
            releasesHeaderCommitsAfterNextCommit: opened.releasesHeaderCommitsAfterNextCommit,
            mayHoldUnreferencedFooter: true
        )
        do {
            try Self.applyDataProtectionIfSupported(at: url)
        } catch {
            try? await wax.close()
            throw error
        }
        return wax
    }

    /// Checks the data payload a pending (uncommitted) mutation refers to.
    ///
    /// A checksum-valid WAL record whose payload range overflows is structural corruption, not a
    /// torn write, and always fails closed.
    private static func pendingPayloadStatus(
        _ mutation: PendingMutation,
        file: FDFile,
        fileSize: UInt64
    ) throws -> PendingPayloadStatus {
        guard case .putFrame(let put) = mutation.entry else { return .notApplicable }
        guard put.payloadOffset <= UInt64.max - put.payloadLength else {
            throw WaxError.invalidToc(reason: "pending frame \(put.frameId) payload range overflows")
        }
        guard put.payloadOffset + put.payloadLength <= fileSize else { return .outOfBounds }
        guard put.payloadLength <= UInt64(Int.max) else {
            throw WaxError.io("pending frame \(put.frameId) payload too large: \(put.payloadLength)")
        }

        let payload = put.payloadLength == 0
            ? Data()
            : try file.readExactly(length: Int(put.payloadLength), at: put.payloadOffset)
        return SHA256Checksum.digest(payload) == put.storedChecksum ? .intact : .checksumMismatch
    }

    private static func pendingPayloadError(_ mutation: PendingMutation, status: PendingPayloadStatus) -> WaxError {
        guard case .putFrame(let put) = mutation.entry else {
            return .invalidToc(reason: "pending WAL mutation \(mutation.sequence) is damaged")
        }
        if status == .outOfBounds {
            return .invalidToc(reason: "pending WAL references bytes beyond file size")
        }
        return .checksumMismatch("pending frame \(put.frameId) stored_checksum mismatch")
    }
}
