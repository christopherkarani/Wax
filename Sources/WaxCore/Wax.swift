import Foundation

/// Primary handle for interacting with a `.wax` memory file.
///
/// Holds the file descriptor, lock, header, TOC, and in-memory index state.
/// All mutable state is isolated within this actor for thread safety.
package actor Wax {
    /// Internal only because of the file split; immutable after init.
    let url: URL
    /// Internal only because of the file split; immutable after init.
    let io: BlockingIOExecutor
    private let opLock = AsyncReadWriteLock()
    /// Held by embedding writes and by vector-index stage/commit, so no embedding lands
    /// between the vector engine syncing pending embeddings and the commit that covers them.
    private let embeddingWriteGate = AsyncMutex()
    /// Internal only because of the file split; use only from the writer-lease methods (Wax+Lifecycle.swift).
    var writerLeaseId: UUID?
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var file: FDFile
    private var lock: FileLock

    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var header: WaxHeaderPage
    private var selectedHeaderPageIndex: Int

    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var toc: WaxTOC
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var surrogateIndex: [UInt64: UInt64]? = nil
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var wal: WALRingWriter
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var pendingMutations: [PendingMutation]
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var pendingMutationSummary: PendingMutationSummary
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var encodedCommittedFramePayloadCache: Data?
    /// What the commit in progress changed in place, for its rollback (Wax+Commit.swift).
    /// Internal only because of the file split; use only under `opLock` for writing.
    var commitUndo: CommitUndo?
    /// Payload ranges of the committed frames, built by the first commit that needs them and
    /// extended by each durable commit (Wax+PayloadRanges.swift).
    /// Internal only because of the file split; use only under `opLock` for writing.
    var committedFramePayloadRanges: FramePayloadRangeIndex?
    /// Built by the first remember dedup probe, then updated by every pending mutation and commit.
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var rememberDedupIndex: RememberDedupIndex?
    /// Frames the remember dedup probe has examined since open, for tests.
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var rememberDedupFramesExamined: UInt64 = 0
    /// Full frame-list timeline scans since open, for tests.
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var timelineScans: UInt64 = 0
    /// Verified reads of the committed vector segment since open, for tests.
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var committedVecIndexReads: UInt64 = 0
    private var stagedLexIndex: StagedLexIndex?
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var stagedVecIndex: StagedVecIndex?
    private var stagedLexIndexStamp: UInt64?
    private var stagedVecIndexStamp: UInt64?
    private var stagedLexIndexStampCounter: UInt64
    private var stagedVecIndexStampCounter: UInt64

    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var dataEnd: UInt64
    /// Free ranges below `dataEnd` and the durable TOC range (Wax+DataSpace.swift). Not part of
    /// commit rollback: ranges a failed commit wrote stay reserved until the next open.
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var dataSpace = DataSpaceState()
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    private(set) var generation: UInt64
    /// Internal only because of the file split; use only under `opLock` (`withReadLock` / `withWriteLock`).
    var dirty: Bool
    private var walAutoCommitCount: UInt64
    private var walReplaySnapshotHitCount: UInt64
    private let walReplayTruncationCount: UInt64
    private let walReplayFooterScanCount: UInt64
    private let walProactiveCommitThresholdBytes: UInt64?
    private let walProactiveCommitMaxWalSizeBytes: UInt64?
    private let walProactiveCommitMinPendingBytes: UInt64
    private let walReplayStateSnapshotEnabled: Bool

    /// Internal only because of the file split; use only from the writer-lease methods (Wax+Lifecycle.swift).
    var writerWaiters: [WriterWaiter] = []

    /// Internal only because of the file split; call only from `create` / `open` (Wax+Lifecycle.swift).
    init(
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
        walReplayTruncationCount: UInt64,
        walReplayFooterScanCount: UInt64,
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
        self.walReplayTruncationCount = walReplayTruncationCount
        self.walReplayFooterScanCount = walReplayFooterScanCount
        self.walProactiveCommitThresholdBytes = walProactiveCommitThresholdBytes
        self.walProactiveCommitMaxWalSizeBytes = walProactiveCommitMaxWalSizeBytes
        self.walProactiveCommitMinPendingBytes = walProactiveCommitMinPendingBytes
        self.walReplayStateSnapshotEnabled = walReplayStateSnapshotEnabled
    }

    /// Internal only because of the file split; takes the lock itself.
    func withWriteLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
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

    /// Embedding writes take the embedding write gate before the op lock, the same order as
    /// ``withEmbeddingWritesPaused(_:)`` holders, so they wait out an in-flight stage/commit.
    /// Internal only because of the file split; takes the locks itself.
    func withEmbeddingWriteLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
        await embeddingWriteGate.lock()
        do {
            let value = try await withWriteLock(body)
            await embeddingWriteGate.unlock()
            return value
        } catch {
            await embeddingWriteGate.unlock()
            throw error
        }
    }

    /// Runs `body` while embedding writes wait. A vector index synced, staged and committed
    /// inside `body` therefore covers exactly the embeddings the commit marks committed.
    /// `body` must not write embeddings itself: the gate is not reentrant.
    package func withEmbeddingWritesPaused<T: Sendable>(
        _ body: @Sendable () async throws -> T
    ) async rethrows -> T {
        try await embeddingWriteGate.withLock(body)
    }

    /// Internal only because of the file split; takes the lock itself.
    func withReadLock<T: Sendable>(_ body: () async throws -> T) async rethrows -> T {
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

    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func ensureWalCapacityLocked(payloadSize: Int) async throws {
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

    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func ensureWalCapacityLocked(payloadSizes: [Int]) async throws {
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

    /// Tasks (embedding writes, or other stage/commits) parked on the embedding write gate.
    package func embeddingWriteGateWaiterCount() async -> Int {
        await embeddingWriteGate.waiterCount
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
        similarity: VecSimilarity,
        coverage: StagedVecIndexCoverage
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
            try Self.validateVecIndexSegment(
                bytes,
                vectorCount: vectorCount,
                dimension: dimension,
                similarity: similarity
            )

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

            let pendingEmbeddingMaxSequence: UInt64?
            switch coverage {
            case .latestPending:
                pendingEmbeddingMaxSequence = pendingMutationSummary.latestPendingEmbeddingSequence
            case .syncedThrough(let sequence):
                pendingEmbeddingMaxSequence = sequence
            }
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

            if !pendingMutationSummary.hasPendingEmbedding,
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
                throw WaxError.vectorIndexNotStaged
            }
        } else if let stagedVecIndex {
            let latestPendingEmbeddingSequence = pendingMutationSummary.latestPendingEmbeddingSequence
            if latestPendingEmbeddingSequence != stagedVecIndex.pendingEmbeddingMaxSequence {
                throw WaxError.vectorIndexStale
            }
        }

        try await ensureRecoveryFenceLocked()
        let rollbackState = CommitRollbackState.capture(from: self)
        var commitSucceeded = false
        defer {
            if !commitSucceeded {
                rollbackState.restore(into: self)
            }
        }

        let applied = try applyPendingMutationsIntoTOC()
        let appliedWalSeq = applied.maxSequence
        let cachedFramesPayload = try encodedCommittedFramePayloadForCommit(
            appendedFrames: applied.appendedFrames,
            invalidated: applied.modifiedCommittedFrames
        )

        let file = self.file
        var supersededRanges: [Range<UInt64>] = []
        if let staged = stagedLexIndex {
            let byteCount = staged.bytes.count
            guard byteCount <= Constants.maxBlobBytes else {
                throw WaxError.capacityExceeded(
                    limit: UInt64(Constants.maxBlobBytes),
                    requested: UInt64(byteCount)
                )
            }
            let lexLength = UInt64(byteCount)
            let lexOffset = allocateDataLocked(length: lexLength)
            try await io.run {
                try file.writeAll(staged.bytes, at: lexOffset)
            }

            toc.indexes.lex = LexIndexManifest(
                docCount: staged.docCount,
                bytesOffset: lexOffset,
                bytesLength: lexLength,
                checksum: staged.checksum,
                version: staged.version
            )
            let segmentId = nextSegmentId()
            supersededRanges += removeSupersededSegmentsLocked(kind: .lex)
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

            let vecLength = UInt64(byteCount)
            let vecOffset = allocateDataLocked(length: vecLength)
            try await io.run {
                try file.writeAll(staged.bytes, at: vecOffset)
            }

            toc.indexes.vec = VecIndexManifest(
                vectorCount: staged.vectorCount,
                dimension: staged.dimension,
                bytesOffset: vecOffset,
                bytesLength: vecLength,
                checksum: staged.checksum,
                similarity: staged.similarity
            )
            let segmentId = nextSegmentId()
            supersededRanges += removeSupersededSegmentsLocked(kind: .vec)
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

        let tocLength = UInt64(tocBytes.count)
        let tocOffset = allocateDataLocked(
            length: tocLength + Constants.footerSize,
            notBelow: Self.referencedDataEnd(of: toc)
        )
        let footerOffset = tocOffset + tocLength
        let footer = WaxFooter(
            tocLen: tocLength,
            tocHash: Data(tocChecksum),
            generation: try nextFooterGenerationLocked(),
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
            try await persistReplaySnapshotOnNextHeaderPage(replaySnapshot)
        }

        try await io.run {
            try file.writeAll(tocBytes, at: tocOffset)
        }
        #if DEBUG
        Self.maybeCrashAfterCheckpoint(.afterTocWriteBeforeFooter)
        #endif

        try await io.run {
            try file.writeAll(try footer.encode(), at: footerOffset)
        }
        #if DEBUG
        Self.maybeCrashAfterCheckpoint(.afterFooterWriteBeforeFsync)
        #endif

        try await io.run {
            try file.fsync()
        }
        #if DEBUG
        Self.maybeCrashAfterCheckpoint(.afterFooterFsyncBeforeHeader)
        #endif

        header.footerOffset = footerOffset
        header.fileGeneration = footer.generation
        header.tocChecksum = Data(tocChecksum)
        header.walCommittedSeq = appliedWalSeq
        header.walReplaySnapshot = replaySnapshot
        header.walCheckpointPos = walState.writePos
        header.walWritePos = walState.writePos
        header.headerPageGeneration &+= 1

        try await writeHeaderPage(header)
        #if DEBUG
        Self.maybeCrashAfterCheckpoint(.afterHeaderWriteBeforeFinalFsync)
        #endif
        try await io.run {
            try file.fsync()
            wal.recordCheckpoint()
        }

        clearPendingMutations()
        rememberDedupIndex?.didCommit()
        stagedLexIndex = nil
        stagedVecIndex = nil
        stagedLexIndexStamp = nil
        stagedVecIndexStamp = nil
        surrogateIndex = nil
        dirty = false
        generation = footer.generation
        commitUndo = nil
        committedFramePayloadRanges?.append(applied.appendedFrames)
        commitSucceeded = true
        await reclaimAfterDurableCommitLocked(
            superseded: supersededRanges,
            committedTocRange: tocOffset..<(footerOffset + Constants.footerSize)
        )
    }

    /// The actor state a failed commit restores. It holds neither the frame list nor the
    /// encoded frame cache: a capture sharing them would make the commit's appends copy the
    /// whole array and cache. The restore truncates both to their captured lengths and puts
    /// back what `commitUndo` recorded: the committed frames the commit changed in place, and
    /// the cache if the commit replaced it.
    private struct CommitRollbackState {
        var header: WaxHeaderPage
        var selectedHeaderPageIndex: Int
        /// `toc` with an empty frame list.
        var tocWithoutFrames: WaxTOC
        var frameCount: Int
        var surrogateIndex: [UInt64: UInt64]?
        var pendingMutations: [PendingMutation]
        var pendingMutationSummary: PendingMutationSummary
        var encodedFrameCacheLength: Int?
        var stagedLexIndex: StagedLexIndex?
        var stagedVecIndex: StagedVecIndex?
        var stagedLexIndexStamp: UInt64?
        var stagedVecIndexStamp: UInt64?
        var stagedLexIndexStampCounter: UInt64
        var stagedVecIndexStampCounter: UInt64
        // No `dataEnd`: what a failed commit appended stays reserved, since a footer it synced
        // can still be recovered by a footer scan.
        var generation: UInt64
        var dirty: Bool

        static func capture(from wax: isolated Wax) -> CommitRollbackState {
            var tocWithoutFrames = wax.toc
            tocWithoutFrames.frames = []
            wax.commitUndo = CommitUndo()
            return CommitRollbackState(
                header: wax.header,
                selectedHeaderPageIndex: wax.selectedHeaderPageIndex,
                tocWithoutFrames: tocWithoutFrames,
                frameCount: wax.toc.frames.count,
                surrogateIndex: wax.surrogateIndex,
                pendingMutations: wax.pendingMutations,
                pendingMutationSummary: wax.pendingMutationSummary,
                encodedFrameCacheLength: wax.encodedCommittedFramePayloadCache?.count,
                stagedLexIndex: wax.stagedLexIndex,
                stagedVecIndex: wax.stagedVecIndex,
                stagedLexIndexStamp: wax.stagedLexIndexStamp,
                stagedVecIndexStamp: wax.stagedVecIndexStamp,
                stagedLexIndexStampCounter: wax.stagedLexIndexStampCounter,
                stagedVecIndexStampCounter: wax.stagedVecIndexStampCounter,
                generation: wax.generation,
                dirty: wax.dirty
            )
        }

        func restore(into wax: isolated Wax) {
            let undo = wax.commitUndo ?? CommitUndo()
            wax.commitUndo = nil

            var frames: [FrameMeta] = []
            swap(&frames, &wax.toc.frames)
            if frames.count > frameCount {
                frames.removeLast(frames.count - frameCount)
            }
            for (index, original) in undo.committedFrameOriginals {
                frames[index] = original
            }
            wax.toc = tocWithoutFrames
            wax.toc.frames = frames

            if undo.replacedFrameCache {
                wax.encodedCommittedFramePayloadCache = undo.frameCacheBeforeCommit
            } else if let encodedFrameCacheLength,
                      let cacheCount = wax.encodedCommittedFramePayloadCache?.count {
                if cacheCount > encodedFrameCacheLength {
                    wax.encodedCommittedFramePayloadCache?.removeSubrange(encodedFrameCacheLength..<cacheCount)
                }
            } else {
                // The commit built the cache from nothing; the next commit builds it again.
                wax.encodedCommittedFramePayloadCache = nil
            }

            wax.header = header
            wax.selectedHeaderPageIndex = selectedHeaderPageIndex
            wax.surrogateIndex = surrogateIndex
            wax.pendingMutations = pendingMutations
            wax.pendingMutationSummary = pendingMutationSummary
            wax.stagedLexIndex = stagedLexIndex
            wax.stagedVecIndex = stagedVecIndex
            wax.stagedLexIndexStamp = stagedLexIndexStamp
            wax.stagedVecIndexStamp = stagedVecIndexStamp
            wax.stagedLexIndexStampCounter = stagedLexIndexStampCounter
            wax.stagedVecIndexStampCounter = stagedVecIndexStampCounter
            wax.generation = generation
            wax.dirty = dirty
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

    package func stagedVecIndexStamp() async -> UInt64? {
        await withReadLock {
            stagedVecIndexStamp
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
                replaySnapshotHitCount: walReplaySnapshotHitCount,
                replayTruncationCount: walReplayTruncationCount,
                replayFooterScanCount: walReplayFooterScanCount
            )
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

    /// Writes the snapshot on the page this commit's header will overwrite, as the newest page.
    /// The selected page is never rewritten in place, so it names the durable commit until the
    /// next header is durable, and no older commit needs to stay intact for a torn page.
    private func persistReplaySnapshotOnNextHeaderPage(_ snapshot: WaxHeaderPage.WALReplaySnapshot) async throws {
        var snapshotPage = header
        snapshotPage.walReplaySnapshot = snapshot
        snapshotPage.headerPageGeneration &+= 1
        let nextIndex = selectedHeaderPageIndex == 0 ? 1 : 0
        let offset = UInt64(nextIndex) * Constants.headerPageSize
        let file = self.file
        let encoded = try snapshotPage.encodeWithChecksum()
        try await io.run {
            try file.writeAll(encoded, at: offset)
        }
    }

    /// Writes `page` to the page that is not selected and syncs it, returning that page's index.
    /// The caller selects it only after this returns. Internal only because of the file split.
    func writeOtherHeaderPageDurably(_ page: WaxHeaderPage) async throws -> Int {
        let index = selectedHeaderPageIndex == 0 ? 1 : 0
        let offset = UInt64(index) * Constants.headerPageSize
        let file = self.file
        let encoded = try page.encodeWithChecksum()
        try await io.run {
            try file.writeAll(encoded, at: offset)
            try file.fsync()
        }
        return index
    }

    /// Internal only because of the file split.
    func markHeaderPageSelected(_ index: Int) {
        selectedHeaderPageIndex = index
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

    private func nextSegmentId() -> UInt64 {
        if let maxId = toc.segmentCatalog.entries.map({ $0.segmentId }).max() {
            return maxId &+ 1
        }
        return 0
    }
}
