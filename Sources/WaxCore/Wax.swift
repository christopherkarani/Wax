import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@inline(__always)
private func posixGetPID() -> Int32 {
    #if canImport(Darwin)
    Darwin.getpid()
    #else
    Glibc.getpid()
    #endif
}

@inline(__always)
private func posixKill(_ pid: Int32, _ signal: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.kill(pid, signal)
    #else
    Glibc.kill(pid, signal)
    #endif
}

package struct WaxStats: Equatable, Sendable {
    package var frameCount: UInt64
    package var pendingFrames: UInt64
    package var generation: UInt64

    package init(frameCount: UInt64, pendingFrames: UInt64, generation: UInt64) {
        self.frameCount = frameCount
        self.pendingFrames = pendingFrames
        self.generation = generation
    }
}

package struct WaxWALStats: Equatable, Sendable {
    package var walSize: UInt64
    package var writePos: UInt64
    package var checkpointPos: UInt64
    package var pendingBytes: UInt64
    package var committedSeq: UInt64
    package var lastSeq: UInt64
    package var wrapCount: UInt64
    package var checkpointCount: UInt64
    package var sentinelWriteCount: UInt64
    package var writeCallCount: UInt64
    package var autoCommitCount: UInt64
    package var replaySnapshotHitCount: UInt64

    package init(
        walSize: UInt64,
        writePos: UInt64,
        checkpointPos: UInt64,
        pendingBytes: UInt64,
        committedSeq: UInt64,
        lastSeq: UInt64,
        wrapCount: UInt64,
        checkpointCount: UInt64,
        sentinelWriteCount: UInt64,
        writeCallCount: UInt64,
        autoCommitCount: UInt64,
        replaySnapshotHitCount: UInt64
    ) {
        self.walSize = walSize
        self.writePos = writePos
        self.checkpointPos = checkpointPos
        self.pendingBytes = pendingBytes
        self.committedSeq = committedSeq
        self.lastSeq = lastSeq
        self.wrapCount = wrapCount
        self.checkpointCount = checkpointCount
        self.sentinelWriteCount = sentinelWriteCount
        self.writeCallCount = writeCallCount
        self.autoCommitCount = autoCommitCount
        self.replaySnapshotHitCount = replaySnapshotHitCount
    }
}

package struct PendingEmbeddingSnapshot: Equatable, Sendable {
    package let embeddings: [PutEmbedding]
    package let latestSequence: UInt64?

    package init(embeddings: [PutEmbedding], latestSequence: UInt64?) {
        self.embeddings = embeddings
        self.latestSequence = latestSequence
    }
}

package struct RememberDedupEmbeddingIdentity: Equatable, Sendable {
    package var provider: String?
    package var model: String?
    package var dimensions: Int?
    package var normalized: Bool?

    package init(
        provider: String? = nil,
        model: String? = nil,
        dimensions: Int? = nil,
        normalized: Bool? = nil
    ) {
        self.provider = provider
        self.model = model
        self.dimensions = dimensions
        self.normalized = normalized
    }

    fileprivate func matches(metadataEntries: [String: String]) -> Bool {
        if let provider, metadataEntries["wax.embedding.provider"] != provider {
            return false
        }
        if let model, metadataEntries["wax.embedding.model"] != model {
            return false
        }
        if let dimensions, metadataEntries["wax.embedding.dimension"] != String(dimensions) {
            return false
        }
        if let normalized, metadataEntries["wax.embedding.normalized"] != String(normalized) {
            return false
        }
        return true
    }
}

package struct RememberDedupProbe: Equatable, Sendable {
    package var documentId: UInt64
    package var isComplete: Bool

    package init(documentId: UInt64, isComplete: Bool) {
        self.documentId = documentId
        self.isComplete = isComplete
    }
}

package struct SurrogateSourceFrame: Equatable, Sendable {
    package var id: UInt64
    package var searchText: String

    package init(id: UInt64, searchText: String) {
        self.id = id
        self.searchText = searchText
    }
}

/// Primary handle for interacting with a `.wax` memory file.
///
/// Holds the file descriptor, lock, header, TOC, and in-memory index state.
/// All mutable state is isolated within this actor for thread safety.
package actor Wax {
    private enum CrashInjectionCheckpoint: String {
        case afterTocWriteBeforeFooter = "after_toc_write_before_footer"
        case afterFooterWriteBeforeFsync = "after_footer_write_before_fsync"
        case afterFooterFsyncBeforeHeader = "after_footer_fsync_before_header"
        case afterHeaderWriteBeforeFinalFsync = "after_header_write_before_final_fsync"

        static let envKey = "WAX_CRASH_INJECT_CHECKPOINT"
    }

    private let url: URL
    private let io: BlockingIOExecutor
    private let opLock = AsyncReadWriteLock()
    private var writerLeaseId: UUID?
    private var file: FDFile
    private var lock: FileLock

    private var header: WaxHeaderPage
    private var selectedHeaderPageIndex: Int

    private var toc: WaxTOC
    private var surrogateIndex: [UInt64: UInt64]? = nil
    private var wal: WALRingWriter
    private var pendingMutations: [PendingMutation]
    private var pendingMutationSummary: PendingMutationSummary
    private var encodedCommittedFramePayloadCache: Data?
    private var stagedLexIndex: StagedLexIndex?
    private var stagedVecIndex: StagedVecIndex?
    private var stagedLexIndexStamp: UInt64?
    private var stagedVecIndexStamp: UInt64?
    private var stagedLexIndexStampCounter: UInt64
    private var stagedVecIndexStampCounter: UInt64

    private var dataEnd: UInt64
    private var generation: UInt64
    private var dirty: Bool
    private var walAutoCommitCount: UInt64
    private var walReplaySnapshotHitCount: UInt64
    private let walProactiveCommitThresholdBytes: UInt64?
    private let walProactiveCommitMaxWalSizeBytes: UInt64?
    private let walProactiveCommitMinPendingBytes: UInt64
    private let walReplayStateSnapshotEnabled: Bool

    private struct WriterWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var writerWaiters: [WriterWaiter] = []

    private init(
        url: URL,
        io: BlockingIOExecutor,
        file: FDFile,
        lock: FileLock,
        header: WaxHeaderPage,
        selectedHeaderPageIndex: Int,
        toc: WaxTOC,
        wal: WALRingWriter,
        pendingMutations: [PendingMutation],
        encodedCommittedFramePayloadCache: Data?,
        stagedLexIndex: StagedLexIndex?,
        stagedVecIndex: StagedVecIndex?,
        stagedLexIndexStamp: UInt64?,
        stagedVecIndexStamp: UInt64?,
        stagedLexIndexStampCounter: UInt64,
        stagedVecIndexStampCounter: UInt64,
        dataEnd: UInt64,
        generation: UInt64,
        dirty: Bool,
        walAutoCommitCount: UInt64,
        walReplaySnapshotHitCount: UInt64,
        walProactiveCommitThresholdBytes: UInt64?,
        walProactiveCommitMaxWalSizeBytes: UInt64?,
        walProactiveCommitMinPendingBytes: UInt64,
        walReplayStateSnapshotEnabled: Bool
    ) {
        self.url = url
        self.io = io
        self.file = file
        self.lock = lock
        self.header = header
        self.selectedHeaderPageIndex = selectedHeaderPageIndex
        self.toc = toc
        self.wal = wal
        self.pendingMutations = pendingMutations
        self.pendingMutationSummary = PendingMutationSummary.from(pendingMutations)
        self.encodedCommittedFramePayloadCache = encodedCommittedFramePayloadCache
        self.stagedLexIndex = stagedLexIndex
        self.stagedVecIndex = stagedVecIndex
        self.stagedLexIndexStamp = stagedLexIndexStamp
        self.stagedVecIndexStamp = stagedVecIndexStamp
        self.stagedLexIndexStampCounter = stagedLexIndexStampCounter
        self.stagedVecIndexStampCounter = stagedVecIndexStampCounter
        self.dataEnd = dataEnd
        self.generation = generation
        self.dirty = dirty
        self.walAutoCommitCount = walAutoCommitCount
        self.walReplaySnapshotHitCount = walReplaySnapshotHitCount
        self.walProactiveCommitThresholdBytes = walProactiveCommitThresholdBytes
        self.walProactiveCommitMaxWalSizeBytes = walProactiveCommitMaxWalSizeBytes
        self.walProactiveCommitMinPendingBytes = walProactiveCommitMinPendingBytes
        self.walReplayStateSnapshotEnabled = walReplayStateSnapshotEnabled
    }

    private func withWriteLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.writeLock()
        do {
            let value = try await body()
            await opLock.writeUnlock()
            return value
        } catch {
            await opLock.writeUnlock()
            throw error
        }
    }

    private func withReadLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await opLock.readLock()
        do {
            let value = try await body()
            await opLock.readUnlock()
            return value
        } catch {
            await opLock.readUnlock()
            throw error
        }
    }

    private func canAutoCommitForWalPressureLocked() -> Bool {
        !(pendingMutationSummary.hasPendingEmbedding && stagedVecIndex == nil)
    }

    private func estimatedWalBytesForAppend(payloadSize: Int) -> UInt64? {
        guard payloadSize > 0 else { return nil }
        guard payloadSize <= Int(UInt32.max) else { return nil }
        return UInt64(WALRecord.headerSize) + UInt64(payloadSize)
    }

    private func estimatedWalBytesForAppendBatch(payloadSizes: [Int]) -> UInt64? {
        guard !payloadSizes.isEmpty else { return nil }

        let headerSize = UInt64(WALRecord.headerSize)
        var total: UInt64 = 0
        for payloadSize in payloadSizes {
            guard payloadSize > 0 else { return nil }
            guard payloadSize <= Int(UInt32.max) else { return nil }
            let bytes = headerSize + UInt64(payloadSize)
            let (next, overflowed) = total.addingReportingOverflow(bytes)
            if overflowed { return nil }
            total = next
        }
        return total
    }

    private func maybeProactiveAutoCommitLocked(estimatedIncomingWalBytes: UInt64) async throws {
        guard let thresholdBytes = walProactiveCommitThresholdBytes else { return }
        guard estimatedIncomingWalBytes > 0 else { return }
        guard canAutoCommitForWalPressureLocked() else { return }
        if let maxWalSizeBytes = walProactiveCommitMaxWalSizeBytes,
           wal.walSize > maxWalSizeBytes {
            return
        }

        let pendingBytes = wal.pendingBytes
        guard pendingBytes >= walProactiveCommitMinPendingBytes else { return }

        let (projectedPendingBytes, overflowed) = pendingBytes.addingReportingOverflow(estimatedIncomingWalBytes)
        let projected = overflowed ? UInt64.max : projectedPendingBytes
        guard projected >= thresholdBytes else { return }

        try await commitLocked()
        walAutoCommitCount &+= 1
    }

    private func ensureWalCapacityLocked(payloadSize: Int) async throws {
        if walProactiveCommitThresholdBytes != nil,
           let estimated = estimatedWalBytesForAppend(payloadSize: payloadSize) {
            try await maybeProactiveAutoCommitLocked(estimatedIncomingWalBytes: estimated)
        }
        if wal.canAppend(payloadSize: payloadSize) {
            return
        }

        if !canAutoCommitForWalPressureLocked() {
            throw WaxError.io("WAL capacity exceeded before vector index staged; stageForCommit() and commit() earlier or increase wal_size.")
        }

        try await commitLocked()
        walAutoCommitCount &+= 1
        guard wal.canAppend(payloadSize: payloadSize) else {
            throw WaxError.capacityExceeded(limit: wal.walSize, requested: UInt64(payloadSize))
        }
    }

    private func ensureWalCapacityLocked(payloadSizes: [Int]) async throws {
        guard !payloadSizes.isEmpty else { return }
        if walProactiveCommitThresholdBytes != nil,
           let estimated = estimatedWalBytesForAppendBatch(payloadSizes: payloadSizes) {
            try await maybeProactiveAutoCommitLocked(estimatedIncomingWalBytes: estimated)
        }
        if wal.canAppendBatch(payloadSizes: payloadSizes) {
            return
        }

        if !canAutoCommitForWalPressureLocked() {
            throw WaxError.io("WAL capacity exceeded before vector index staged; stageForCommit() and commit() earlier or increase wal_size.")
        }

        try await commitLocked()
        walAutoCommitCount &+= 1
        guard wal.canAppendBatch(payloadSizes: payloadSizes) else {
            let requested = UInt64(payloadSizes.reduce(0, +))
            throw WaxError.capacityExceeded(limit: wal.walSize, requested: requested)
        }
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
            let file = try FDFile.create(at: url)
            let lock: FileLock
            do {
                lock = try FileLock.acquire(
                    at: url,
                    mode: .exclusive,
                    timeout: options.lockWaitTimeout
                )
            } catch {
                try? file.close()
                throw error
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
            if repair, fileSize > requiredEnd {
                try file.truncate(to: requiredEnd)
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

    // MARK: - Mutations

    private func currentTimestampMs() -> Int64 {
        Int64(Date().timeIntervalSince1970 * 1000)
    }

    private func appendPendingMutation(sequence: UInt64, entry: WALEntry) {
        let mutation = PendingMutation(sequence: sequence, entry: entry)
        pendingMutations.append(mutation)
        pendingMutationSummary.record(mutation)
    }

    private func clearPendingMutations() {
        pendingMutations.removeAll(keepingCapacity: true)
        pendingMutationSummary = PendingMutationSummary()
    }

    private func orderedPendingMutationsLocked() -> [PendingMutation] {
        if pendingMutationSummary.isOrderedBySequence {
            return pendingMutations
        }
        return pendingMutations.sorted { $0.sequence < $1.sequence }
    }

    private func putLocked(
        _ content: Data,
        options: FrameMetaSubset,
        timestampMs: Int64?,
        compression: CanonicalEncoding
    ) async throws -> UInt64 {
        let committedCount = UInt64(toc.frames.count)
        let pendingPutCount = pendingMutationSummary.putFrameCount
        let frameId = committedCount + UInt64(pendingPutCount)

        let canonicalChecksum = SHA256Checksum.digest(content)

        var storedBytes = content
        var canonicalEncoding: CanonicalEncoding = .plain
        if compression != .plain {
            do {
                let compressed = try PayloadCompressor.compress(content, algorithm: CompressionKind(canonicalEncoding: compression))
                if compressed.count < content.count {
                    storedBytes = compressed
                    canonicalEncoding = compression
                }
            } catch {
                storedBytes = content
                canonicalEncoding = .plain
            }
        }

        let storedChecksum = SHA256Checksum.digest(storedBytes)

        let payloadOffset = dataEnd
        let entry = WALEntry.putFrame(
            PutFrame(
                frameId: frameId,
                timestampMs: timestampMs ?? currentTimestampMs(),
                options: options,
                payloadOffset: payloadOffset,
                payloadLength: UInt64(storedBytes.count),
                canonicalEncoding: canonicalEncoding,
                canonicalLength: UInt64(content.count),
                canonicalChecksum: canonicalChecksum,
                storedChecksum: storedChecksum
            )
        )
        let payload = try WALEntryCodec.encode(entry)
        try await ensureWalCapacityLocked(payloadSize: payload.count)
        let file = self.file
        let wal = self.wal
        let bytesToStore = storedBytes
        let seq = try await io.run {
            try file.writeAll(bytesToStore, at: payloadOffset)
            return try wal.append(payload: payload)
        }

        dataEnd += UInt64(storedBytes.count)
        appendPendingMutation(sequence: seq, entry: entry)
        dirty = true
        return frameId
    }

    package func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain
    ) async throws -> UInt64 {
        try await withWriteLock {
            try await putLocked(content, options: options, timestampMs: nil, compression: compression)
        }
    }

    package func put(
        _ content: Data,
        options: FrameMetaSubset = .init(),
        compression: CanonicalEncoding = .plain,
        timestampMs: Int64
    ) async throws -> UInt64 {
        try await withWriteLock {
            try await putLocked(content, options: options, timestampMs: timestampMs, compression: compression)
        }
    }

    private func putBatchLocked(
        _ contents: [Data],
        options: [FrameMetaSubset],
        timestampsMs: [Int64]?,
        compression: CanonicalEncoding
    ) async throws -> [UInt64] {
        let committedCount = UInt64(toc.frames.count)
        let pendingPutCount = pendingMutationSummary.putFrameCount
        let baseFrameId = committedCount + UInt64(pendingPutCount)
        let defaultTimestampMs = Int64(Date().timeIntervalSince1970 * 1000)

        // Pre-compute all frame data outside I/O
        struct PreparedFrame {
            let storedBytes: Data
            let putFrame: PutFrame
        }

        var prepared: [PreparedFrame] = []
        prepared.reserveCapacity(contents.count)
        var totalPayloadSize = 0
        var walPayloadSizes: [Int] = []
        walPayloadSizes.reserveCapacity(contents.count)

        for (index, content) in contents.enumerated() {
            let frameId = baseFrameId + UInt64(index)
            let canonicalChecksum = SHA256Checksum.digest(content)

            var storedBytes = content
            var canonicalEncoding: CanonicalEncoding = .plain
            if compression != .plain {
                do {
                    let compressed = try PayloadCompressor.compress(content, algorithm: CompressionKind(canonicalEncoding: compression))
                    if compressed.count < content.count {
                        storedBytes = compressed
                        canonicalEncoding = compression
                    }
                } catch {
                    storedBytes = content
                    canonicalEncoding = .plain
                }
            }

            let storedChecksum = SHA256Checksum.digest(storedBytes)
            let timestampMsForFrame = timestampsMs?[index] ?? defaultTimestampMs

            let putFrame = PutFrame(
                frameId: frameId,
                timestampMs: timestampMsForFrame,
                options: options[index],
                payloadOffset: 0,
                payloadLength: UInt64(storedBytes.count),
                canonicalEncoding: canonicalEncoding,
                canonicalLength: UInt64(content.count),
                canonicalChecksum: canonicalChecksum,
                storedChecksum: storedChecksum
            )
            let walPayloadSize = try WALEntryCodec.encode(.putFrame(putFrame)).count

            prepared.append(PreparedFrame(
                storedBytes: storedBytes,
                putFrame: putFrame
            ))
            walPayloadSizes.append(walPayloadSize)
            totalPayloadSize += storedBytes.count
        }

        func appendSequentially() async throws -> [UInt64] {
            var frameIds: [UInt64] = []
            frameIds.reserveCapacity(prepared.count)
            let file = self.file
            let wal = self.wal

            for (index, frame) in prepared.enumerated() {
                try await ensureWalCapacityLocked(payloadSize: walPayloadSizes[index])
                var putFrame = frame.putFrame
                putFrame.payloadOffset = dataEnd
                let entry = WALEntry.putFrame(putFrame)
                let walPayload = try WALEntryCodec.encode(entry)

                let payloadOffset = putFrame.payloadOffset
                let storedBytes = frame.storedBytes
                let seq = try await io.run {
                    try file.writeAll(storedBytes, at: payloadOffset)
                    return try wal.append(payload: walPayload)
                }
                dataEnd += UInt64(frame.storedBytes.count)
                appendPendingMutation(sequence: seq, entry: entry)
                frameIds.append(putFrame.frameId)
            }
            dirty = true
            return frameIds
        }

        // Check WAL capacity for entire batch. If the batch cannot fit as a unit,
        // fall back to per-entry appends (allows mid-batch commits).
        do {
            try await ensureWalCapacityLocked(payloadSizes: walPayloadSizes)
        } catch WaxError.capacityExceeded {
            return try await appendSequentially()
        }

        // Capture values for Sendable closure
        let file = self.file
        let wal = self.wal
        let startOffset = dataEnd
        let storedBytesArray = prepared.map { $0.storedBytes }

        var walPayloadsArray: [Data] = []
        walPayloadsArray.reserveCapacity(prepared.count)
        var entries: [WALEntry] = []
        entries.reserveCapacity(prepared.count)
        var currentOffset = dataEnd

        for frame in prepared {
            var putFrame = frame.putFrame
            putFrame.payloadOffset = currentOffset
            let entry = WALEntry.putFrame(putFrame)
            let walPayload = try WALEntryCodec.encode(entry)
            walPayloadsArray.append(walPayload)
            entries.append(entry)
            currentOffset += UInt64(frame.storedBytes.count)
        }

        // Single mapped write for payloads
        let payloadLength = totalPayloadSize
        if payloadLength > 0 {
            try await io.run {
                try file.ensureSize(atLeast: startOffset + UInt64(payloadLength))
                let region = try file.mapWritable(length: payloadLength, at: startOffset)
                defer { region.close() }

                var cursor = 0
                guard let base = region.buffer.baseAddress else {
                    throw WaxError.io("mapped region baseAddress is nil")
                }
                for storedBytes in storedBytesArray {
                    storedBytes.withUnsafeBytes { src in
                        guard let srcBase = src.baseAddress else { return }
                        base.advanced(by: cursor).copyMemory(from: srcBase, byteCount: storedBytes.count)
                    }
                    cursor += storedBytes.count
                }
            }
        }

        // Batch append WAL entries
        let walPayloads = walPayloadsArray
        let sequences = try await io.run {
            try wal.appendBatch(payloads: walPayloads)
        }

        // Update state
        dataEnd = currentOffset
        for (index, entry) in entries.enumerated() {
            appendPendingMutation(sequence: sequences[index], entry: entry)
        }
        dirty = true

        return prepared.map { $0.putFrame.frameId }
    }

    /// Batch put multiple frames in a single operation.
    /// This amortizes actor and I/O overhead across all frames.
    /// Returns frame IDs in the same order as the input contents.
    package func putBatch(
        _ contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain
    ) async throws -> [UInt64] {
        guard !contents.isEmpty else { return [] }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count (\(contents.count)) != options.count (\(options.count))")
        }

        return try await withWriteLock {
            try await putBatchLocked(contents, options: options, timestampsMs: nil, compression: compression)
        }
    }

    /// Batch put multiple frames with caller-provided timestamps.
    /// The `timestampsMs` array must match `contents` order and length.
    package func putBatch(
        _ contents: [Data],
        options: [FrameMetaSubset],
        compression: CanonicalEncoding = .plain,
        timestampsMs: [Int64]
    ) async throws -> [UInt64] {
        guard !contents.isEmpty else { return [] }
        guard contents.count == options.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count (\(contents.count)) != options.count (\(options.count))")
        }
        guard contents.count == timestampsMs.count else {
            throw WaxError.encodingError(reason: "putBatch: contents.count (\(contents.count)) != timestampsMs.count (\(timestampsMs.count))")
        }

        return try await withWriteLock {
            try await putBatchLocked(contents, options: options, timestampsMs: timestampsMs, compression: compression)
        }
    }

    /// Batch put embeddings for multiple frames in a single operation.
    package func putEmbeddingBatch(frameIds: [UInt64], vectors: [[Float]]) async throws {
        guard !frameIds.isEmpty else { return }
        guard frameIds.count == vectors.count else {
            throw WaxError.encodingError(reason: "putEmbeddingBatch: frameIds.count != vectors.count")
        }

        try await withWriteLock {
            // Validate all vectors first
            var dimension: UInt32?
            for vector in vectors {
                guard !vector.isEmpty else {
                    throw WaxError.encodingError(reason: "embedding vector must be non-empty")
                }
                guard vector.count <= Constants.maxEmbeddingDimensions else {
                    throw WaxError.capacityExceeded(
                        limit: UInt64(Constants.maxEmbeddingDimensions),
                        requested: UInt64(vector.count)
                    )
                }
                let dim = UInt32(vector.count)
                if let existing = dimension {
                    guard existing == dim else {
                        throw WaxError.encodingError(reason: "all embeddings in batch must have same dimension")
                    }
                } else {
                    dimension = dim
                }
            }

            guard let dimension else { return }

            // Check dimension consistency with committed/staged indexes
            if let committed = toc.indexes.vec {
                guard committed.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs committed vec index: expected \(committed.dimension), got \(dimension)"
                    )
                }
            }
            if let staged = stagedVecIndex {
                guard staged.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs staged vec index: expected \(staged.dimension), got \(dimension)"
                    )
                }
            }

            // Pre-encode all WAL entries
            var walPayloads: [Data] = []
            walPayloads.reserveCapacity(frameIds.count)
            var entries: [WALEntry] = []
            entries.reserveCapacity(frameIds.count)
            var walPayloadSizes: [Int] = []
            walPayloadSizes.reserveCapacity(frameIds.count)

            for (frameId, vector) in zip(frameIds, vectors) {
                let entry = WALEntry.putEmbedding(
                    PutEmbedding(frameId: frameId, dimension: dimension, vector: vector)
                )
                let payload = try WALEntryCodec.encode(entry)
                walPayloads.append(payload)
                entries.append(entry)
                walPayloadSizes.append(payload.count)
            }

            try await ensureWalCapacityLocked(payloadSizes: walPayloadSizes)

            // Capture for Sendable closure
            let wal = self.wal
            let walPayloadsArray = walPayloads  // Copy to let binding

            let sequences = try await io.run {
                try wal.appendBatch(payloads: walPayloadsArray)
            }

            // Update state
            for (index, entry) in entries.enumerated() {
                appendPendingMutation(sequence: sequences[index], entry: entry)
            }
            dirty = true
        }
    }

    package func putEmbedding(frameId: UInt64, vector: [Float]) async throws {
        try await withWriteLock {
            guard !vector.isEmpty else {
                throw WaxError.encodingError(reason: "embedding vector must be non-empty")
            }
            guard vector.count <= Constants.maxEmbeddingDimensions else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxEmbeddingDimensions),
                    requested: UInt64(vector.count)
                )
            }
            guard vector.count <= Int(UInt32.max) else {
                throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: UInt64(vector.count))
            }

            let dimension = UInt32(vector.count)

            if let committed = toc.indexes.vec {
                guard committed.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs committed vec index: expected \(committed.dimension), got \(dimension)"
                    )
                }
            }
            if let staged = stagedVecIndex {
                guard staged.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "embedding dimension mismatch vs staged vec index: expected \(staged.dimension), got \(dimension)"
                    )
                }
            }
            let entry = WALEntry.putEmbedding(
                PutEmbedding(frameId: frameId, dimension: dimension, vector: vector)
            )
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            appendPendingMutation(sequence: seq, entry: entry)
            dirty = true
        }
    }

    package func pendingEmbeddingMutations() async -> [PutEmbedding] {
        let snapshot = await pendingEmbeddingMutations(since: nil)
        return snapshot.embeddings
    }

    package func pendingEmbeddingMutations(since sequence: UInt64?) async -> PendingEmbeddingSnapshot {
        await withReadLock {
            guard pendingMutationSummary.hasPendingEmbedding else {
                return PendingEmbeddingSnapshot(embeddings: [], latestSequence: nil)
            }
            var embeddings: [PutEmbedding] = []
            embeddings.reserveCapacity(pendingMutations.count)
            var latestSequence: UInt64?
            for mutation in pendingMutations {
                guard case .putEmbedding(let embedding) = mutation.entry else { continue }
                latestSequence = mutation.sequence
                if let sequence, mutation.sequence <= sequence { continue }
                embeddings.append(embedding)
            }
            return PendingEmbeddingSnapshot(embeddings: embeddings, latestSequence: latestSequence)
        }
    }

    package func delete(frameId: UInt64) async throws {
        try await withWriteLock {
            let entry = WALEntry.deleteFrame(DeleteFrame(frameId: frameId))
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            appendPendingMutation(sequence: seq, entry: entry)
            dirty = true
        }
    }

    package func supersede(supersededId: UInt64, supersedingId: UInt64) async throws {
        try await withWriteLock {
            // Check committed state for reverse relationship
            if supersededId < UInt64(toc.frames.count) {
                let supersededMeta = toc.frames[Int(supersededId)]
                if supersededMeta.supersedes == supersedingId {
                    throw WaxError.invalidToc(reason: "supersede cycle detected: frame \(supersededId) already supersedes frame \(supersedingId)")
                }
            }
            if supersedingId < UInt64(toc.frames.count) {
                let supersedingMeta = toc.frames[Int(supersedingId)]
                if supersedingMeta.supersededBy == supersededId {
                    throw WaxError.invalidToc(reason: "supersede cycle detected: frame \(supersedingId) is already superseded by frame \(supersededId)")
                }
            }
            // Check pending mutations for reverse relationship
            for pending in pendingMutations {
                if case .supersedeFrame(let s) = pending.entry,
                   s.supersededId == supersedingId, s.supersedingId == supersededId {
                    throw WaxError.invalidToc(reason: "supersede cycle detected: reverse supersede already pending for frames \(supersededId) and \(supersedingId)")
                }
            }

            let entry = WALEntry.supersedeFrame(
                SupersedeFrame(supersededId: supersededId, supersedingId: supersedingId)
            )
            let payload = try WALEntryCodec.encode(entry)
            try await ensureWalCapacityLocked(payloadSize: payload.count)
            let wal = self.wal
            let seq = try await io.run {
                try wal.append(payload: payload)
            }
            appendPendingMutation(sequence: seq, entry: entry)
            dirty = true
        }
    }

    package func pendingFrameMeta(frameId: UInt64) async -> FrameMeta? {
        await withReadLock {
            let maxCommittedId = UInt64(toc.frames.count)
            guard frameId >= maxCommittedId else { return nil }
            return frameMetasIncludingPendingUnlocked(frameIds: [frameId])[frameId]
        }
    }

    package func stageLexIndexForNextCommit(bytes: Data, docCount: UInt64, version: UInt32 = 1) async throws {
        try await withWriteLock {
            guard version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported lex index version \(version)")
            }
            guard !bytes.isEmpty else {
                throw WaxError.io("lex index bytes must be non-empty (expected sqlite3_serialize output)")
            }
            let byteCount = bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }

            let checksum = SHA256Checksum.digest(bytes)
            let bytesLength = UInt64(byteCount)

            if let stagedLexIndex {
                if stagedLexIndex.docCount == docCount,
                   stagedLexIndex.version == version,
                   UInt64(stagedLexIndex.bytes.count) == bytesLength,
                   stagedLexIndex.checksum == checksum {
                    return
                }
            }

            if let committed = toc.indexes.lex,
               committed.docCount == docCount,
               committed.version == version,
               committed.bytesLength == bytesLength,
               committed.checksum == checksum {
                stagedLexIndex = nil
                stagedLexIndexStamp = nil
                return
            }

            stagedLexIndex = StagedLexIndex(
                bytes: bytes,
                docCount: docCount,
                version: version,
                checksum: checksum
            )
            stagedLexIndexStampCounter &+= 1
            stagedLexIndexStamp = stagedLexIndexStampCounter
            dirty = true
        }
    }

    package func stageVecIndexForNextCommit(
        bytes: Data,
        vectorCount: UInt64,
        dimension: UInt32,
        similarity: VecSimilarity
    ) async throws {
        try await withWriteLock {
            guard !bytes.isEmpty else {
                throw WaxError.io("vec index bytes must be non-empty")
            }
            let byteCount = bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }
            guard dimension > 0 else {
                throw WaxError.io("vec index dimension must be > 0")
            }
            guard dimension <= UInt32(Constants.maxEmbeddingDimensions) else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxEmbeddingDimensions),
                    requested: UInt64(dimension)
                )
            }

            if let committed = toc.indexes.vec {
                guard committed.dimension == dimension else {
                    throw WaxError.invalidToc(
                        reason: "staged vec dimension mismatch vs committed vec index: expected \(committed.dimension), got \(dimension)"
                    )
                }
                guard committed.similarity == similarity else {
                    throw WaxError.invalidToc(
                        reason: "staged vec similarity mismatch vs committed vec index: expected \(committed.similarity), got \(similarity)"
                    )
                }
            }

            let pendingEmbeddingMaxSequence = pendingMutationSummary.latestPendingEmbeddingSequence
            if pendingMutationSummary.hasPendingEmbedding {
                let matchesDimension = !pendingMutationSummary.pendingEmbeddingHasMixedDimensions
                    && pendingMutationSummary.pendingEmbeddingDimension == dimension
                guard matchesDimension else {
                    let actualDimension: String
                    if pendingMutationSummary.pendingEmbeddingHasMixedDimensions {
                        actualDimension = "mixed"
                    } else if let pendingDimension = pendingMutationSummary.pendingEmbeddingDimension {
                        actualDimension = String(pendingDimension)
                    } else {
                        actualDimension = "none"
                    }
                    throw WaxError.invalidToc(
                        reason: "pending embedding dimension mismatch vs staged vec index: expected \(dimension), got \(actualDimension)"
                    )
                }
            }

            let checksum = SHA256Checksum.digest(bytes)
            let bytesLength = UInt64(byteCount)

            if let stagedVecIndex {
                if stagedVecIndex.vectorCount == vectorCount,
                   stagedVecIndex.dimension == dimension,
                   stagedVecIndex.similarity == similarity,
                   stagedVecIndex.pendingEmbeddingMaxSequence == pendingEmbeddingMaxSequence,
                   UInt64(stagedVecIndex.bytes.count) == bytesLength,
                   stagedVecIndex.checksum == checksum {
                    return
                }
            }

            if pendingEmbeddingMaxSequence == nil,
               let committed = toc.indexes.vec,
               committed.vectorCount == vectorCount,
               committed.dimension == dimension,
               committed.similarity == similarity,
               committed.bytesLength == bytesLength,
               committed.checksum == checksum {
                stagedVecIndex = nil
                stagedVecIndexStamp = nil
                return
            }

            stagedVecIndex = StagedVecIndex(
                bytes: bytes,
                vectorCount: vectorCount,
                dimension: dimension,
                similarity: similarity,
                pendingEmbeddingMaxSequence: pendingEmbeddingMaxSequence,
                checksum: checksum
            )
            stagedVecIndexStampCounter &+= 1
            stagedVecIndexStamp = stagedVecIndexStampCounter
            dirty = true
        }
    }

    package func commit() async throws {
        try await withWriteLock {
            try await commitLocked()
        }
    }

    private func commitLocked() async throws {
        guard dirty || stagedLexIndex != nil || stagedVecIndex != nil else { return }

        if stagedVecIndex == nil {
            if pendingMutationSummary.hasPendingEmbedding {
                throw WaxError.io("vector index must be staged before committing embeddings")
            }
        } else if let stagedVecIndex {
            let latestPendingEmbeddingSequence = pendingMutationSummary.latestPendingEmbeddingSequence
            if latestPendingEmbeddingSequence != stagedVecIndex.pendingEmbeddingMaxSequence {
                throw WaxError.io(
                    "vector index is stale relative to pending embeddings; restage vector index before commit"
                )
            }
        }

        let applied = try applyPendingMutationsIntoTOC()
        let appliedWalSeq = applied.maxSequence
        let cachedFramesPayload = try encodedCommittedFramePayloadForCommit(
            appendedFrames: applied.appendedFrames,
            invalidated: applied.modifiedCommittedFrames
        )

        let file = self.file
        if let staged = stagedLexIndex {
            let byteCount = staged.bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }
            let lexOffset = dataEnd
            try await io.run {
                try file.writeAll(staged.bytes, at: lexOffset)
            }
            let lexLength = UInt64(byteCount)
            dataEnd += lexLength

            toc.indexes.lex = LexIndexManifest(
                docCount: staged.docCount,
                bytesOffset: lexOffset,
                bytesLength: lexLength,
                checksum: staged.checksum,
                version: staged.version
            )
            let segmentId = nextSegmentId()
            let entry = SegmentCatalogEntry(
                segmentId: segmentId,
                bytesOffset: lexOffset,
                bytesLength: lexLength,
                checksum: staged.checksum,
                compression: .none,
                kind: .lex
            )
            toc.segmentCatalog.entries.append(entry)
        }

        if let staged = stagedVecIndex {
            let byteCount = staged.bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }

            let vecOffset = dataEnd
            try await io.run {
                try file.writeAll(staged.bytes, at: vecOffset)
            }
            let vecLength = UInt64(byteCount)
            dataEnd += vecLength

            toc.indexes.vec = VecIndexManifest(
                vectorCount: staged.vectorCount,
                dimension: staged.dimension,
                bytesOffset: vecOffset,
                bytesLength: vecLength,
                checksum: staged.checksum,
                similarity: staged.similarity
            )
            let segmentId = nextSegmentId()
            let entry = SegmentCatalogEntry(
                segmentId: segmentId,
                bytesOffset: vecOffset,
                bytesLength: vecLength,
                checksum: staged.checksum,
                compression: .none,
                kind: .vec
            )
            toc.segmentCatalog.entries.append(entry)
        }

        let tocBytes = try toc.encode(cachedFramesPayload: cachedFramesPayload)
        let tocChecksum = tocBytes.suffix(32)
        toc.tocChecksum = Data(tocChecksum)

        let tocOffset = dataEnd
        let footerOffset = tocOffset + UInt64(tocBytes.count)
        let footer = WaxFooter(
            tocLen: UInt64(tocBytes.count),
            tocHash: Data(tocChecksum),
            generation: generation &+ 1,
            walCommittedSeq: appliedWalSeq
        )
        let wal = self.wal
        let walState = await io.run {
            (
                writePos: wal.writePos,
                lastSequence: wal.lastSequence
            )
        }
        let replaySnapshot = WaxHeaderPage.WALReplaySnapshot(
            fileGeneration: footer.generation,
            walCommittedSeq: appliedWalSeq,
            footerOffset: footerOffset,
            walWritePos: walState.writePos,
            walCheckpointPos: walState.writePos,
            walPendingBytes: 0,
            walLastSequence: max(appliedWalSeq, walState.lastSequence)
        )

        if walReplayStateSnapshotEnabled {
            try await persistReplaySnapshotOnSelectedHeaderPage(replaySnapshot)
        }

        try await io.run {
            try file.writeAll(tocBytes, at: tocOffset)
        }
        Self.maybeCrashAfterCheckpoint(.afterTocWriteBeforeFooter)

        try await io.run {
            try file.writeAll(try footer.encode(), at: footerOffset)
        }
        Self.maybeCrashAfterCheckpoint(.afterFooterWriteBeforeFsync)

        try await io.run {
            try file.fsync()
        }
        Self.maybeCrashAfterCheckpoint(.afterFooterFsyncBeforeHeader)

        header.footerOffset = footerOffset
        header.fileGeneration = footer.generation
        header.tocChecksum = Data(tocChecksum)
        header.walCommittedSeq = appliedWalSeq
        header.walReplaySnapshot = replaySnapshot
        header.walCheckpointPos = walState.writePos
        header.walWritePos = walState.writePos
        header.headerPageGeneration &+= 1

        try await writeHeaderPage(header)
        Self.maybeCrashAfterCheckpoint(.afterHeaderWriteBeforeFinalFsync)
        try await io.run {
            try file.fsync()
            wal.recordCheckpoint()
        }

        clearPendingMutations()
        stagedLexIndex = nil
        stagedVecIndex = nil
        stagedLexIndexStamp = nil
        stagedVecIndexStamp = nil
        surrogateIndex = nil
        dirty = false
        generation = footer.generation
        dataEnd = footerOffset + Constants.footerSize
    }

    // MARK: - Reads

    package func frameMetas() async -> [FrameMeta] {
        await withReadLock {
            toc.frames
        }
    }

    package func activeFrameIDs(
        matchingMetadataKey key: String,
        value: String
    ) async -> [UInt64] {
        await withReadLock {
            var frameIDs: [UInt64] = []
            frameIDs.reserveCapacity(toc.frames.count)

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }
                guard frame.metadata?.entries[key] == value else { continue }
                frameIDs.append(frame.id)
            }

            return frameIDs
        }
    }

    package func latestCommittedActiveSystemFrameMeta(
        kind: String,
        fallbackMetadataKey: String,
        fallbackMetadataValue: String
    ) async -> FrameMeta? {
        await withReadLock {
            var latest: FrameMeta?

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil, frame.role == .system else {
                    continue
                }
                guard frame.kind == kind
                    || frame.metadata?.entries[fallbackMetadataKey] == fallbackMetadataValue else {
                    continue
                }
                guard latest?.timestamp ?? .min < frame.timestamp else { continue }
                latest = frame
            }

            return latest
        }
    }

    package func latestCommittedActiveHandoffMeta(project: String? = nil) async -> FrameMeta? {
        await withReadLock {
            var latest: FrameMeta?

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }

                let hasHandoffKind = frame.kind == "handoff" || frame.metadata?.entries["kind"] == "handoff"
                let hasHandoffLabel = frame.labels.contains("handoff")
                guard hasHandoffKind || hasHandoffLabel else { continue }

                if let project, !project.isEmpty, frame.metadata?.entries["project"] != project {
                    continue
                }

                guard let current = latest else {
                    latest = frame
                    continue
                }

                if frame.timestamp > current.timestamp
                    || (frame.timestamp == current.timestamp && frame.id > current.id) {
                    latest = frame
                }
            }

            return latest
        }
    }

    package func committedPayloadLivenessBytes() async -> (
        totalPayloadBytes: UInt64,
        deadPayloadBytes: UInt64
    ) {
        await withReadLock {
            var totalPayloadBytes: UInt64 = 0
            var deadPayloadBytes: UInt64 = 0

            for frame in toc.frames where frame.payloadLength > 0 {
                totalPayloadBytes &+= frame.payloadLength
                let isLive = frame.status == .active && frame.supersededBy == nil
                if !isLive {
                    deadPayloadBytes &+= frame.payloadLength
                }
            }

            return (totalPayloadBytes, deadPayloadBytes)
        }
    }

    package func activeSurrogateSourceFrames() async -> [SurrogateSourceFrame] {
        await withReadLock {
            var sources: [SurrogateSourceFrame] = []
            sources.reserveCapacity(toc.frames.count)

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }
                guard frame.role == .chunk else { continue }
                guard frame.kind != "surrogate" else { continue }
                guard let searchText = frame.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !searchText.isEmpty else {
                    continue
                }
                sources.append(.init(id: frame.id, searchText: searchText))
            }

            return sources
        }
    }

    package func rememberDedupProbe(
        contentHash: String,
        metadata: [String: String],
        expectedChunkCount: Int,
        embeddingIdentity: RememberDedupEmbeddingIdentity?
    ) async -> RememberDedupProbe? {
        await withReadLock {
            struct ChunkCoverage {
                var count = 0
                var indices: Set<Int> = []
                var indicesAreValid = true
                var chunkCountsMatch = true
                var embeddingIdentityMatches = true

                mutating func record(
                    _ chunk: FrameMeta,
                    expectedChunkCount: Int,
                    embeddingIdentity: RememberDedupEmbeddingIdentity?
                ) {
                    count += 1
                    guard expectedChunkCount > 0 else { return }

                    guard let chunkCount = chunk.chunkCount, Int(chunkCount) == expectedChunkCount else {
                        chunkCountsMatch = false
                        return
                    }
                    guard let chunkIndex = chunk.chunkIndex else {
                        indicesAreValid = false
                        return
                    }

                    let index = Int(chunkIndex)
                    guard (0..<expectedChunkCount).contains(index) else {
                        indicesAreValid = false
                        return
                    }
                    guard indices.insert(index).inserted else {
                        indicesAreValid = false
                        return
                    }

                    if let embeddingIdentity,
                       embeddingIdentity.matches(metadataEntries: chunk.metadata?.entries ?? [:]) == false {
                        embeddingIdentityMatches = false
                    }
                }

                func isComplete(expectedChunkCount: Int) -> Bool {
                    guard expectedChunkCount > 0 else { return true }
                    guard count == expectedChunkCount else { return false }
                    guard indices.count == expectedChunkCount else { return false }
                    return indicesAreValid && chunkCountsMatch && embeddingIdentityMatches
                }
            }

            var chunkCoverageByDocument: [UInt64: ChunkCoverage] = [:]

            for meta in toc.frames.reversed() {
                guard meta.status == .active, meta.supersededBy == nil else { continue }

                if meta.role == .chunk, let parentId = meta.parentId {
                    var coverage = chunkCoverageByDocument[parentId] ?? ChunkCoverage()
                    coverage.record(
                        meta,
                        expectedChunkCount: expectedChunkCount,
                        embeddingIdentity: embeddingIdentity
                    )
                    chunkCoverageByDocument[parentId] = coverage
                    continue
                }

                guard meta.role == .document else { continue }
                guard let entries = meta.metadata?.entries else { continue }
                guard entries["wax.content.hash"] == contentHash else { continue }
                guard entries == metadata else { continue }

                let coverage = chunkCoverageByDocument[meta.id] ?? ChunkCoverage()
                return RememberDedupProbe(
                    documentId: meta.id,
                    isComplete: coverage.isComplete(expectedChunkCount: expectedChunkCount)
                )
            }

            return nil
        }
    }

    package func frameMetas(frameIds: [UInt64]) async -> [UInt64: FrameMeta] {
        await withReadLock {
            var metas: [UInt64: FrameMeta] = [:]
            metas.reserveCapacity(frameIds.count)
            let maxId = UInt64(toc.frames.count)
            for frameId in frameIds where frameId < maxId {
                metas[frameId] = toc.frames[Int(frameId)]
            }
            return metas
        }
    }

    package func frameMetasIncludingPending(frameIds: [UInt64]) async -> [UInt64: FrameMeta] {
        await withReadLock {
            frameMetasIncludingPendingUnlocked(frameIds: frameIds)
        }
    }

    package func surrogateFrameId(sourceFrameId: UInt64) async -> UInt64? {
        await withReadLock {
            if surrogateIndex == nil {
                surrogateIndex = buildSurrogateIndexUnlocked()
            }
            return surrogateIndex?[sourceFrameId]
        }
    }

    /// Batch lookup of surrogate frame ids to avoid repeated actor hops.
    package func surrogateFrameIds(for sourceFrameIds: [UInt64]) async -> [UInt64: UInt64] {
        await withReadLock {
            if surrogateIndex == nil {
                surrogateIndex = buildSurrogateIndexUnlocked()
            }
            guard let surrogateIndex else { return [:] }
            var result: [UInt64: UInt64] = [:]
            result.reserveCapacity(sourceFrameIds.count)
            for frameId in sourceFrameIds {
                if let surrogate = surrogateIndex[frameId] {
                    result[frameId] = surrogate
                }
            }
            return result
        }
    }

    package func frameMeta(frameId: UInt64) async throws -> FrameMeta {
        try await withReadLock {
            try frameMetaUnlocked(frameId: frameId)
        }
    }

    package func frameMetaIncludingPending(frameId: UInt64) async throws -> FrameMeta {
        try await withReadLock {
            let metas = frameMetasIncludingPendingUnlocked(frameIds: [frameId])
            guard let meta = metas[frameId] else {
                throw WaxError.frameNotFound(frameId: frameId)
            }
            return meta
        }
    }

    package func frameContent(frameId: UInt64) async throws -> Data {
        try await withReadLock {
            try await frameContentUnlocked(frameId: frameId)
        }
    }

    package func frameContentIncludingPending(frameId: UInt64) async throws -> Data {
        try await withReadLock {
            let metas = frameMetasIncludingPendingUnlocked(frameIds: [frameId])
            guard let meta = metas[frameId] else {
                throw WaxError.frameNotFound(frameId: frameId)
            }
            return try await frameContentFromMetaUnlocked(meta)
        }
    }

    package func framePreview(frameId: UInt64, maxBytes: Int) async throws -> Data {
        try await withReadLock {
            let clampedMax = max(0, maxBytes)
            if clampedMax == 0 { return Data() }

            let frame = try frameMetaUnlocked(frameId: frameId)
            if frame.payloadLength == 0 { return Data() }

            if frame.canonicalEncoding == .plain {
                let available = min(frame.payloadLength, UInt64(clampedMax))
                guard available <= UInt64(Int.max) else {
                    throw WaxError.io("payload preview too large: \(available)")
                }
                let file = self.file
                return try await io.run {
                    try file.readExactly(length: Int(available), at: frame.payloadOffset)
                }
            }

            let canonical = try await frameContentUnlocked(frameId: frameId)
            return Data(canonical.prefix(clampedMax))
        }
    }

    package func framePreviews(frameIds: [UInt64], maxBytes: Int) async throws -> [UInt64: Data] {
        struct PlainPreviewPlan: Sendable {
            let frameId: UInt64
            let offset: UInt64
            let length: Int
        }

        let clampedMax = max(0, maxBytes)
        guard clampedMax > 0 else { return [:] }

        let file = self.file

        let (emptyIds, plainPlans, compressedFrames): ([UInt64], [PlainPreviewPlan], [FrameMeta]) = try await withReadLock {
            var emptyIds: [UInt64] = []
            var plainPlans: [PlainPreviewPlan] = []
            var compressedFrames: [FrameMeta] = []

            let maxId = UInt64(toc.frames.count)
            emptyIds.reserveCapacity(frameIds.count)
            plainPlans.reserveCapacity(frameIds.count)
            compressedFrames.reserveCapacity(frameIds.count)

            for frameId in frameIds where frameId < maxId {
                let frame = toc.frames[Int(frameId)]
                if frame.payloadLength == 0 {
                    emptyIds.append(frameId)
                    continue
                }

                if frame.canonicalEncoding == .plain {
                    let available = min(frame.payloadLength, UInt64(clampedMax))
                    if available == 0 {
                        emptyIds.append(frameId)
                        continue
                    }
                    if available > UInt64(Int.max) {
                        throw WaxError.io("payload preview too large: \(available)")
                    }
                    plainPlans.append(
                        PlainPreviewPlan(
                            frameId: frameId,
                            offset: frame.payloadOffset,
                            length: Int(available)
                        )
                    )
                    continue
                }

                compressedFrames.append(frame)
            }

            return (emptyIds, plainPlans, compressedFrames)
        }

        var previews: [UInt64: Data] = [:]
        previews.reserveCapacity(emptyIds.count + plainPlans.count + compressedFrames.count)

        for frameId in emptyIds {
            previews[frameId] = Data()
        }

        if !plainPlans.isEmpty {
            let plainPreviewBytes = try await io.run {
                var bytesByFrameId: [UInt64: Data] = [:]
                bytesByFrameId.reserveCapacity(plainPlans.count)
                for plan in plainPlans {
                    bytesByFrameId[plan.frameId] = try file.readExactly(length: plan.length, at: plan.offset)
                }
                return bytesByFrameId
            }
            previews.merge(plainPreviewBytes, uniquingKeysWith: { _, new in new })
        }

        for frame in compressedFrames {
            let canonical = try await frameContentFromMeta(frame)
            previews[frame.id] = Data(canonical.prefix(clampedMax))
        }

        return previews
    }

    /// Batch read full frame contents (committed only) in a single actor hop.
    package func frameContents(frameIds: [UInt64]) async throws -> [UInt64: Data] {
        try await withReadLock {
            var contents: [UInt64: Data] = [:]
            contents.reserveCapacity(frameIds.count)
            let maxId = UInt64(toc.frames.count)

            for frameId in frameIds where frameId < maxId {
                let frame = toc.frames[Int(frameId)]
                guard frame.payloadLength > 0 else {
                    contents[frameId] = Data()
                    continue
                }
                let data = try await frameContentFromMetaUnlocked(frame)
                contents[frameId] = data
            }

            return contents
        }
    }

    package func frameStoredContent(frameId: UInt64) async throws -> Data {
        try await withReadLock {
            try await frameStoredContentUnlocked(frameId: frameId)
        }
    }

    package func frameStoredPreview(frameId: UInt64, maxBytes: Int) async throws -> Data {
        try await withReadLock {
            let frame = try frameMetaUnlocked(frameId: frameId)
            if frame.payloadLength == 0 { return Data() }
            let clampedMax = max(0, maxBytes)
            if clampedMax == 0 { return Data() }
            let available = min(frame.payloadLength, UInt64(clampedMax))
            guard available <= UInt64(Int.max) else {
                throw WaxError.io("payload preview too large: \(available)")
            }
            let file = self.file
            return try await io.run {
                try file.readExactly(length: Int(available), at: frame.payloadOffset)
            }
        }
    }

    private func frameStoredContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        let stored = try await readStoredPayloadFromMeta(frame)
        _ = try Self.validateStoredPayloadChecksum(stored, frame: frame)
        return stored
    }

    private func frameContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        return try await frameContentFromMeta(frame)
    }

    private func frameContentFromMeta(_ frame: FrameMeta) async throws -> Data {
        let stored = try await readStoredPayloadFromMeta(frame)
        if frame.payloadLength == 0 { return stored }

        let storedChecksum = try Self.validateStoredPayloadChecksum(stored, frame: frame)
        guard frame.canonicalEncoding != .plain else {
            guard storedChecksum == frame.checksum else {
                throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
            }
            return stored
        }

        guard let canonicalLength = frame.canonicalLength else {
            throw WaxError.invalidToc(reason: "missing canonical_length for frame \(frame.id)")
        }
        guard canonicalLength <= UInt64(Int.max) else {
            throw WaxError.io("canonical payload too large: \(canonicalLength)")
        }
        let canonical = try PayloadCompressor.decompress(
            stored,
            algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
            uncompressedLength: Int(canonicalLength)
        )
        let canonicalChecksum = SHA256Checksum.digest(canonical)
        guard canonicalChecksum == frame.checksum else {
            throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
        }
        return canonical
    }

    private func frameContentFromMetaUnlocked(_ frame: FrameMeta) async throws -> Data {
        try await frameContentFromMeta(frame)
    }

    private func readStoredPayloadFromMeta(_ frame: FrameMeta) async throws -> Data {
        if frame.payloadLength == 0 { return Data() }
        guard frame.payloadLength <= UInt64(Int.max) else {
            throw WaxError.io("payload too large: \(frame.payloadLength)")
        }
        let file = self.file
        return try await io.run {
            try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
        }
    }

    private static func validateStoredPayloadChecksum(_ stored: Data, frame: FrameMeta) throws -> Data {
        if frame.payloadLength == 0 { return Data() }
        guard let expectedStoredChecksum = frame.storedChecksum else {
            throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
        }
        let storedChecksum = SHA256Checksum.digest(stored)
        guard storedChecksum == expectedStoredChecksum else {
            throw WaxError.checksumMismatch("frame \(frame.id) stored_checksum mismatch")
        }
        return storedChecksum
    }

    private func frameMetaUnlocked(frameId: UInt64) throws -> FrameMeta {
        guard frameId < UInt64(toc.frames.count) else {
            throw WaxError.frameNotFound(frameId: frameId)
        }
        return toc.frames[Int(frameId)]
    }

    private func frameMetasIncludingPendingUnlocked(frameIds: [UInt64]) -> [UInt64: FrameMeta] {
        let trackedFrameIds = Set(frameIds)
        guard !trackedFrameIds.isEmpty else { return [:] }

        var metas: [UInt64: FrameMeta] = [:]
        metas.reserveCapacity(trackedFrameIds.count)

        let maxCommittedId = UInt64(toc.frames.count)
        for frameId in trackedFrameIds where frameId < maxCommittedId {
            metas[frameId] = toc.frames[Int(frameId)]
        }

        guard !pendingMutations.isEmpty else { return metas }

        let ordered = pendingMutations.sorted { $0.sequence < $1.sequence }
        for mutation in ordered {
            switch mutation.entry {
            case .putFrame(let put):
                guard trackedFrameIds.contains(put.frameId) else { continue }
                guard let pendingMeta = try? FrameMeta.fromPut(put) else { continue }
                metas[put.frameId] = pendingMeta

            case .deleteFrame(let delete):
                guard trackedFrameIds.contains(delete.frameId),
                      var meta = metas[delete.frameId]
                else { continue }
                meta.status = .deleted
                metas[delete.frameId] = meta

            case .supersedeFrame(let supersede):
                guard supersede.supersededId != supersede.supersedingId else { continue }

                if trackedFrameIds.contains(supersede.supersededId) {
                    guard let supersededMeta = metas[supersede.supersededId] else { continue }
                    if let existing = supersededMeta.supersededBy,
                       existing != supersede.supersedingId {
                        continue
                    }
                }

                if trackedFrameIds.contains(supersede.supersedingId) {
                    guard let supersedingMeta = metas[supersede.supersedingId] else { continue }
                    if let existing = supersedingMeta.supersedes,
                       existing != supersede.supersededId {
                        continue
                    }
                }

                if trackedFrameIds.contains(supersede.supersededId),
                   var supersededMeta = metas[supersede.supersededId] {
                    supersededMeta.supersededBy = supersede.supersedingId
                    metas[supersede.supersededId] = supersededMeta
                }
                if trackedFrameIds.contains(supersede.supersedingId),
                   var supersedingMeta = metas[supersede.supersedingId] {
                    supersedingMeta.supersedes = supersede.supersededId
                    metas[supersede.supersedingId] = supersedingMeta
                }

            case .putEmbedding:
                continue
            }
        }

        return metas
    }

    package func readCommittedLexIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let manifest = toc.indexes.lex else { return nil }
            guard manifest.version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported lex index version \(manifest.version)")
            }
            guard manifest.bytesLength > 0 else { return nil }
            let maxBlob = UInt64(Constants.maxBlobBytes)
            guard manifest.bytesLength <= maxBlob else {
                throw WaxError.capacityExceeded(limit: maxBlob, requested: manifest.bytesLength)
            }
            guard manifest.bytesLength <= UInt64(Int.max) else {
                throw WaxError.io("lex index size exceeds Int.max: \(manifest.bytesLength)")
            }

            let dataStart = header.walOffset + header.walSize
            guard manifest.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "lex index below data region")
            }
            guard manifest.bytesOffset <= UInt64.max - manifest.bytesLength else {
                throw WaxError.invalidToc(reason: "lex index range overflows")
            }
            let end = manifest.bytesOffset + manifest.bytesLength
            guard end <= header.footerOffset else {
                throw WaxError.invalidToc(reason: "lex index exceeds footer offset")
            }

            let file = self.file
            let bytes = try await io.run {
                try file.readExactly(length: Int(manifest.bytesLength), at: manifest.bytesOffset)
            }
            let computed = SHA256Checksum.digest(bytes)
            guard computed == manifest.checksum else {
                throw WaxError.checksumMismatch("lex index checksum mismatch")
            }
            return bytes
        }
    }

    private func buildSurrogateIndexUnlocked() -> [UInt64: UInt64] {
        var index: [UInt64: UInt64] = [:]
        for frame in toc.frames {
            guard frame.status == .active else { continue }
            guard frame.supersededBy == nil else { continue }
            guard frame.kind == "surrogate" else { continue }
            guard let source = frame.metadata?.entries["source_frame_id"],
                  let sourceFrameId = UInt64(source) else {
                continue
            }
            guard sourceFrameId < UInt64(toc.frames.count) else { continue }
            let sourceMeta = toc.frames[Int(sourceFrameId)]
            guard sourceMeta.status == .active else { continue }
            guard sourceMeta.supersededBy == nil else { continue }
            guard sourceMeta.kind != "surrogate" else { continue }
            index[sourceFrameId] = frame.id
        }
        return index
    }

    package func committedLexIndexManifest() async -> LexIndexManifest? {
        await withReadLock {
            toc.indexes.lex
        }
    }

    package func readStagedLexIndexBytes() async -> Data? {
        await withReadLock {
            stagedLexIndex?.bytes
        }
    }

    package func stagedLexIndexStamp() async -> UInt64? {
        await withReadLock {
            stagedLexIndexStamp
        }
    }

    package func readCommittedVecIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let manifest = toc.indexes.vec else { return nil }
            guard manifest.bytesLength > 0 else { return nil }
            let maxBlob = UInt64(Constants.maxBlobBytes)
            guard manifest.bytesLength <= maxBlob else {
                throw WaxError.capacityExceeded(limit: maxBlob, requested: manifest.bytesLength)
            }
            guard manifest.bytesLength <= UInt64(Int.max) else {
                throw WaxError.io("vec index size exceeds Int.max: \(manifest.bytesLength)")
            }

            let dataStart = header.walOffset + header.walSize
            guard manifest.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "vec index below data region")
            }
            guard manifest.bytesOffset <= UInt64.max - manifest.bytesLength else {
                throw WaxError.invalidToc(reason: "vec index range overflows")
            }
            let end = manifest.bytesOffset + manifest.bytesLength
            guard end <= header.footerOffset else {
                throw WaxError.invalidToc(reason: "vec index exceeds footer offset")
            }

            let file = self.file
            let bytes = try await io.run {
                try file.readExactly(length: Int(manifest.bytesLength), at: manifest.bytesOffset)
            }
            let computed = SHA256Checksum.digest(bytes)
            guard computed == manifest.checksum else {
                throw WaxError.checksumMismatch("vec index checksum mismatch")
            }
            return bytes
        }
    }

    package func readStagedVecIndexBytes() async -> (bytes: Data, dimension: UInt32, similarity: VecSimilarity)? {
        await withReadLock {
            guard let staged = stagedVecIndex else { return nil }
            return (bytes: staged.bytes, dimension: staged.dimension, similarity: staged.similarity)
        }
    }

    package func stagedVecIndexStamp() async -> UInt64? {
        await withReadLock {
            stagedVecIndexStamp
        }
    }

    package func committedVecIndexManifest() async -> VecIndexManifest? {
        await withReadLock {
            toc.indexes.vec
        }
    }

    package func memoryBinding() async -> MemoryBinding? {
        await withReadLock {
            toc.memoryBinding
        }
    }

    package func setMemoryBindingIfMissing(_ binding: MemoryBinding) async throws {
        await withWriteLock {
            guard !binding.isEmpty else { return }
            guard toc.memoryBinding == nil else { return }
            toc.memoryBinding = binding
            dirty = true
        }
    }

    package func overwriteMemoryBindingForTesting(_ binding: MemoryBinding?) async throws {
        await withWriteLock {
            guard toc.memoryBinding != binding else { return }
            toc.memoryBinding = binding
            dirty = true
        }
    }

    // MARK: - Introspection

    package func stats() async -> WaxStats {
        await withReadLock {
            let pending = pendingMutations.reduce(0) { count, mutation in
                if case .putFrame = mutation.entry { return count + 1 }
                return count
            }
            return WaxStats(
                frameCount: UInt64(toc.frames.count),
                pendingFrames: UInt64(pending),
                generation: generation
            )
        }
    }

    package func fileURL() -> URL {
        url
    }

    package func walStats() async -> WaxWALStats {
        await withReadLock {
            WaxWALStats(
                walSize: wal.walSize,
                writePos: wal.writePos,
                checkpointPos: wal.checkpointPos,
                pendingBytes: wal.pendingBytes,
                committedSeq: header.walCommittedSeq,
                lastSeq: wal.lastSequence,
                wrapCount: wal.wrapCount,
                checkpointCount: wal.checkpointCount,
                sentinelWriteCount: wal.sentinelWriteCount,
                writeCallCount: wal.writeCallCount,
                autoCommitCount: walAutoCommitCount,
                replaySnapshotHitCount: walReplaySnapshotHitCount
            )
        }
    }

    package func timeline(_ query: TimelineQuery) async -> [FrameMeta] {
        await withReadLock {
            TimelineQuery.filter(frames: toc.frames, query: query)
        }
    }

    // MARK: - Verification hook

    /// Verify the file on disk.
    ///
    /// This is equivalent to `verify(deep: true)`. Use `verify(deep: false)` for a structural-only check.
    package func verify() async throws {
        try await verify(deep: true)
    }

    package func verify(deep: Bool) async throws {
        try await withReadLock {
            let file = self.file
            let pageA = try await io.run {
                try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
            }
            let pageB = try await io.run {
                try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
            }
            guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
                throw WaxError.invalidHeader(reason: "no valid header pages")
            }
            let header = selected.page
            let url = self.url

            let footerSlice: FooterSlice
            if let fastFooter = try await io.run({
                try FooterScanner.findFooter(at: header.footerOffset, in: url)
            }) {
                footerSlice = fastFooter
            } else {
                guard let scanned = try await io.run({
                    try FooterScanner.findLastValidFooter(in: url)
                }) else {
                    throw WaxError.invalidFooter(reason: "no valid footer found within max_footer_scan_bytes")
                }
                footerSlice = scanned
            }
            let toc = try WaxTOC.decode(from: footerSlice.tocBytes)

            let dataStart = header.walOffset + header.walSize
            try Self.validateTocRanges(toc, dataStart: dataStart, dataEnd: footerSlice.footerOffset)

            guard deep else { return }

            var frameIndex = 0
            for frame in toc.frames {
                guard frame.payloadLength > 0 else {
                    frameIndex += 1
                    continue
                }
                guard let storedChecksum = frame.storedChecksum else {
                    throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
                }
                let stored = try await sha256(
                    file: file,
                    offset: frame.payloadOffset,
                    length: frame.payloadLength
                )
                guard stored == storedChecksum else {
                    throw WaxError.checksumMismatch("frame \(frame.id) stored_checksum mismatch")
                }
                if frame.canonicalEncoding == .plain {
                    guard stored == frame.checksum else {
                        throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
                    }
                } else {
                    guard let canonicalLength = frame.canonicalLength else {
                        throw WaxError.invalidToc(reason: "frame \(frame.id) missing canonical_length")
                    }
                    guard canonicalLength <= UInt64(Int.max) else {
                        throw WaxError.io("canonical payload too large: \(canonicalLength)")
                    }
                    guard frame.payloadLength <= UInt64(Int.max) else {
                        throw WaxError.io("payload too large: \(frame.payloadLength)")
                    }
                    let storedBytes = try await io.run {
                        try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
                    }
                    let canonicalBytes = try PayloadCompressor.decompress(
                        storedBytes,
                        algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
                        uncompressedLength: Int(canonicalLength)
                    )
                    let canonicalChecksum = SHA256Checksum.digest(canonicalBytes)
                    guard canonicalChecksum == frame.checksum else {
                        throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
                    }
                }

                frameIndex += 1
                if frameIndex % 32 == 0 {
                    await Task.yield()
                }
            }

            var segmentIndex = 0
            for entry in toc.segmentCatalog.entries {
                guard entry.bytesLength > 0 else {
                    segmentIndex += 1
                    continue
                }
                let computed = try await sha256(
                    file: file,
                    offset: entry.bytesOffset,
                    length: entry.bytesLength
                )
                guard computed == entry.checksum else {
                    throw WaxError.checksumMismatch("segment \(entry.segmentId) checksum mismatch")
                }

                segmentIndex += 1
                if segmentIndex % 16 == 0 {
                    await Task.yield()
                }
            }
        }
    }

    package func close() async throws {
        try await withWriteLock {
            var commitError: Error?
            if dirty || stagedLexIndex != nil || stagedVecIndex != nil {
                do {
                    try await commitLocked()
                } catch {
                    commitError = error
                }
            }

            let file = self.file
            let lock = self.lock
            var closeError: Error?
            do {
                try await io.run {
                    try file.close()
                    try lock.release()
                }
            } catch {
                closeError = error
            }

            if let commitError {
                // Commit error indicates potential data loss; prioritize it over close errors.
                throw commitError
            }
            if let closeError {
                throw closeError
            }
        }
    }

    // MARK: - Internal helpers

    private static func maybeCrashAfterCheckpoint(_ checkpoint: CrashInjectionCheckpoint) {
        let env = ProcessInfo.processInfo.environment
        guard env[CrashInjectionCheckpoint.envKey] == checkpoint.rawValue else { return }
        // SIGKILL is delivered asynchronously and may be delayed or masked in sandboxed
        // environments (containers, test harnesses). The fatalError below is a safety net
        // for those cases; it should never be reached in normal crash-injection runs but
        // produces a clear diagnostic if SIGKILL did not terminate the process in time.
        _ = posixKill(posixGetPID(), SIGKILL)
        fatalError("crash injection did not terminate process at \(checkpoint.rawValue)")
    }

    private func persistReplaySnapshotOnSelectedHeaderPage(_ snapshot: WaxHeaderPage.WALReplaySnapshot) async throws {
        var snapshotPage = header
        snapshotPage.walReplaySnapshot = snapshot
        let offset = UInt64(selectedHeaderPageIndex) * Constants.headerPageSize
        let file = self.file
        let encoded = try snapshotPage.encodeWithChecksum()
        try await io.run {
            try file.writeAll(encoded, at: offset)
        }
    }

    private func writeHeaderPage(_ page: WaxHeaderPage) async throws {
        let nextIndex = selectedHeaderPageIndex == 0 ? 1 : 0
        let offset = UInt64(nextIndex) * Constants.headerPageSize
        let file = self.file
        try await io.run {
            try file.writeAll(try page.encodeWithChecksum(), at: offset)
        }
        selectedHeaderPageIndex = nextIndex
    }

    private struct AppliedPendingMutations {
        var maxSequence: UInt64
        var appendedFrames: [FrameMeta]
        var modifiedCommittedFrames: Bool
    }

    private func applyPendingMutationsIntoTOC() throws -> AppliedPendingMutations {
        let committedSeq = header.walCommittedSeq
        var maxSeq = committedSeq

        let stagedVecDimension = stagedVecIndex?.dimension
        let ordered = orderedPendingMutationsLocked()
        var newFrames: [FrameMeta] = []
        var modifiedCommittedFrames = false

        func withFrame(_ frameId: UInt64, _ update: (inout FrameMeta) throws -> Void) throws {
            let committedCount = toc.frames.count
            let maxKnown = committedCount + newFrames.count
            guard frameId < UInt64(maxKnown) else {
                throw WaxError.invalidToc(reason: "mutation references unknown frameId \(frameId) (known < \(maxKnown))")
            }
            if frameId < UInt64(committedCount) {
                modifiedCommittedFrames = true
                try update(&toc.frames[Int(frameId)])
            } else {
                let index = Int(frameId - UInt64(committedCount))
                try update(&newFrames[index])
            }
        }

        for mutation in ordered {
            guard mutation.sequence > committedSeq else {
                throw WaxError.invalidToc(reason: "mutation sequence \(mutation.sequence) not > committed \(committedSeq)")
            }
            if mutation.sequence > maxSeq { maxSeq = mutation.sequence }

            switch mutation.entry {
            case .putFrame(let put):
                let expectedId = UInt64(toc.frames.count + newFrames.count)
                guard put.frameId == expectedId else {
                    throw WaxError.invalidToc(reason: "non-dense frame id \(put.frameId), expected \(expectedId)")
                }
                let frame = try FrameMeta.fromPut(put)
                newFrames.append(frame)
            case .deleteFrame(let delete):
                try withFrame(delete.frameId) { frame in
                    frame.status = .deleted
                }
            case .supersedeFrame(let supersede):
                guard supersede.supersededId != supersede.supersedingId else {
                    throw WaxError.invalidToc(reason: "supersedeFrame requires distinct ids")
                }
                try withFrame(supersede.supersededId) { frame in
                    if let existing = frame.supersededBy, existing != supersede.supersedingId {
                        throw WaxError.invalidToc(
                            reason: "frame \(supersede.supersededId) already superseded by \(existing)"
                        )
                    }
                    frame.supersededBy = supersede.supersedingId
                }
                try withFrame(supersede.supersedingId) { frame in
                    if let existing = frame.supersedes, existing != supersede.supersededId {
                        throw WaxError.invalidToc(
                            reason: "frame \(supersede.supersedingId) already supersedes \(existing)"
                        )
                    }
                    frame.supersedes = supersede.supersededId
                }
            case .putEmbedding(let embedding):
                guard let stagedVecDimension else {
                    throw WaxError.invalidToc(reason: "putEmbedding pending without staged vec index")
                }
                guard embedding.dimension == stagedVecDimension else {
                    throw WaxError.invalidToc(
                        reason: "putEmbedding dimension \(embedding.dimension) != staged vec dimension \(stagedVecDimension)"
                    )
                }

                let maxKnownFrameIdExclusive = UInt64(toc.frames.count + newFrames.count)
                guard embedding.frameId < maxKnownFrameIdExclusive else {
                    throw WaxError.invalidToc(
                        reason: "putEmbedding references unknown frameId \(embedding.frameId) (known < \(maxKnownFrameIdExclusive))"
                    )
                }
                continue
            }
        }

        if !newFrames.isEmpty {
            let originalCount = toc.frames.count
            // Validate after appending in place so commit does not clone the full frame array first.
            toc.frames.append(contentsOf: newFrames)
            let dataStart = header.walOffset + header.walSize
            do {
                try Self.validateTocRanges(toc, dataStart: dataStart, dataEnd: dataEnd)
            } catch {
                toc.frames.removeLast(toc.frames.count - originalCount)
                throw error
            }
        }

        return AppliedPendingMutations(
            maxSequence: maxSeq,
            appendedFrames: newFrames,
            modifiedCommittedFrames: modifiedCommittedFrames
        )
    }

    private struct DataRange {
        var start: UInt64
        var end: UInt64
        var label: String
    }

    private struct StagedLexIndex {
        var bytes: Data
        var docCount: UInt64
        var version: UInt32
        var checksum: Data
    }

    private struct StagedVecIndex {
        var bytes: Data
        var vectorCount: UInt64
        var dimension: UInt32
        var similarity: VecSimilarity
        var pendingEmbeddingMaxSequence: UInt64?
        var checksum: Data
    }

    private struct PendingMutationSummary {
        var putFrameCount: UInt64 = 0
        var hasPendingEmbedding = false
        var latestPendingEmbeddingSequence: UInt64?
        var pendingEmbeddingDimension: UInt32?
        var pendingEmbeddingHasMixedDimensions = false
        var isOrderedBySequence = true

        private var lastSequence: UInt64?

        mutating func record(_ mutation: PendingMutation) {
            if let lastSequence, mutation.sequence <= lastSequence {
                isOrderedBySequence = false
            }
            self.lastSequence = mutation.sequence

            switch mutation.entry {
            case .putFrame:
                putFrameCount &+= 1
            case .putEmbedding(let embedding):
                hasPendingEmbedding = true
                latestPendingEmbeddingSequence = mutation.sequence
                if let pendingEmbeddingDimension, pendingEmbeddingDimension != embedding.dimension {
                    pendingEmbeddingHasMixedDimensions = true
                } else {
                    pendingEmbeddingDimension = embedding.dimension
                }
            case .deleteFrame, .supersedeFrame:
                break
            }
        }

        static func from(_ mutations: [PendingMutation]) -> PendingMutationSummary {
            var summary = PendingMutationSummary()
            summary.putFrameCount = 0
            for mutation in mutations {
                summary.record(mutation)
            }
            return summary
        }
    }

    private func nextSegmentId() -> UInt64 {
        if let maxId = toc.segmentCatalog.entries.map({ $0.segmentId }).max() {
            return maxId &+ 1
        }
        return 0
    }

    private func encodedCommittedFramePayloadForCommit(
        appendedFrames: [FrameMeta],
        invalidated: Bool
    ) throws -> Data {
        if invalidated {
            encodedCommittedFramePayloadCache = nil
        }

        if encodedCommittedFramePayloadCache == nil {
            encodedCommittedFramePayloadCache = try Self.encodeFramePayloads(toc.frames)
            return encodedCommittedFramePayloadCache ?? Data()
        }

        if !appendedFrames.isEmpty {
            encodedCommittedFramePayloadCache?.append(try Self.encodeFramePayloads(appendedFrames))
        }

        return encodedCommittedFramePayloadCache ?? Data()
    }

    private static func encodeFramePayloads(_ frames: [FrameMeta]) throws -> Data {
        guard !frames.isEmpty else { return Data() }

        var encoder = BinaryEncoder()
        for frame in frames {
            var mutable = frame
            try mutable.encode(to: &encoder)
        }
        return encoder.data
    }

    private static func validateTocRanges(_ toc: WaxTOC, dataStart: UInt64, dataEnd: UInt64) throws {
        let frameRanges = try collectFramePayloadRanges(toc.frames, dataStart: dataStart, dataEnd: dataEnd)
        let segmentRanges = try collectSegmentRanges(toc.segmentCatalog.entries, dataStart: dataStart, dataEnd: dataEnd)

        try validateNoOverlap(frameRanges + segmentRanges)
        try validateSegmentCatalogMatchesManifests(
            segmentCatalog: toc.segmentCatalog,
            indexes: toc.indexes,
            timeIndex: toc.timeIndex
        )
    }

    private static func collectFramePayloadRanges(
        _ frames: [FrameMeta],
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> [DataRange] {
        guard dataEnd >= dataStart else {
            throw WaxError.invalidToc(reason: "data region invalid: start \(dataStart), end \(dataEnd)")
        }

        var ranges: [DataRange] = []
        ranges.reserveCapacity(frames.count)

        for (index, frame) in frames.enumerated() {
            guard frame.id == UInt64(index) else {
                throw WaxError.invalidToc(reason: "frame id not dense: found \(frame.id), expected \(index)")
            }
            if frame.checksum.count != 32 {
                throw WaxError.invalidToc(reason: "frame \(frame.id) checksum must be 32 bytes")
            }
            if frame.canonicalEncoding != .plain && frame.canonicalLength == nil {
                throw WaxError.invalidToc(reason: "frame \(frame.id) missing canonical_length")
            }
            if frame.payloadLength > 0 && frame.storedChecksum == nil {
                throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
            }
            if frame.payloadLength == 0 { continue }
            guard frame.payloadOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload below data region")
            }
            guard frame.payloadOffset <= UInt64.max - frame.payloadLength else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload range overflows")
            }
            let end = frame.payloadOffset + frame.payloadLength
            guard end <= dataEnd else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload exceeds data end")
            }
            ranges.append(DataRange(start: frame.payloadOffset, end: end, label: "frame \(frame.id)"))
        }

        return ranges
    }

    private static func collectSegmentRanges(
        _ entries: [SegmentCatalogEntry],
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> [DataRange] {
        var ranges: [DataRange] = []
        ranges.reserveCapacity(entries.count)

        for entry in entries {
            if entry.bytesLength == 0 { continue }
            guard entry.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) below data region")
            }
            guard entry.bytesOffset <= UInt64.max - entry.bytesLength else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) range overflows")
            }
            let end = entry.bytesOffset + entry.bytesLength
            guard end <= dataEnd else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) exceeds data end")
            }
            ranges.append(DataRange(start: entry.bytesOffset, end: end, label: "segment \(entry.segmentId)"))
        }

        return ranges
    }

    private static func validateNoOverlap(_ ranges: [DataRange]) throws {
        let sorted = ranges.sorted { $0.start < $1.start }
        for idx in sorted.indices.dropFirst() {
            let prev = sorted[idx - 1]
            let next = sorted[idx]
            if prev.end > next.start {
                throw WaxError.invalidToc(reason: "data overlap between \(prev.label) and \(next.label)")
            }
        }
    }

    private static func validateSegmentCatalogMatchesManifests(
        segmentCatalog: SegmentCatalog,
        indexes: IndexManifests,
        timeIndex: TimeIndexManifest?
    ) throws {
        if let lex = indexes.lex {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .lex
                    && entry.bytesOffset == lex.bytesOffset
                    && entry.bytesLength == lex.bytesLength
                    && entry.checksum == lex.checksum
            }) else {
                throw WaxError.invalidToc(reason: "lex index manifest missing matching segment catalog entry")
            }
        }
        if let vec = indexes.vec {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .vec
                    && entry.bytesOffset == vec.bytesOffset
                    && entry.bytesLength == vec.bytesLength
                    && entry.checksum == vec.checksum
            }) else {
                throw WaxError.invalidToc(reason: "vec index manifest missing matching segment catalog entry")
            }
        }
        if let timeIndex {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .time
                    && entry.bytesOffset == timeIndex.bytesOffset
                    && entry.bytesLength == timeIndex.bytesLength
                    && entry.checksum == timeIndex.checksum
            }) else {
                throw WaxError.invalidToc(reason: "time index manifest missing matching segment catalog entry")
            }
        }
    }

    private func sha256(file: FDFile, offset: UInt64, length: UInt64) async throws -> Data {
        guard length > 0 else { return SHA256Checksum.digest(Data()) }
        var hasher = SHA256Checksum()
        let chunkSize: UInt64 = 1 * 1024 * 1024

        var cursor: UInt64 = 0
	        var chunkIndex = 0
	        while cursor < length {
	            let remaining = length - cursor
	            let thisChunkLen64 = min(chunkSize, remaining)
	            guard thisChunkLen64 <= UInt64(Int.max) else {
	                throw WaxError.io("verify chunk exceeds Int.max: \(thisChunkLen64)")
	            }
	            let readOffset = offset + cursor
	            let bytes = try await io.run {
	                try file.readExactly(length: Int(thisChunkLen64), at: readOffset)
	            }
	            bytes.withUnsafeBytes { raw in
	                hasher.update(raw)
	            }
            cursor += thisChunkLen64
            chunkIndex += 1
            if chunkIndex % 8 == 0 {
                await Task.yield()
            }
        }

        return hasher.finalize()
    }
}
