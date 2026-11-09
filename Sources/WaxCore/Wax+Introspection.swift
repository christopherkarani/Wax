import Foundation

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
    /// The writer's last sequence. Every open moves it about `walSize / 48` past `committedSeq`
    /// (the replay sequence floor), so `lastSeq - committedSeq` is not a pending-record count;
    /// `pendingBytes` is.
    package var lastSeq: UInt64
    package var wrapCount: UInt64
    package var checkpointCount: UInt64
    package var sentinelWriteCount: UInt64
    package var writeCallCount: UInt64
    package var autoCommitCount: UInt64
    package var replaySnapshotHitCount: UInt64
    /// Number of opens that stopped pending WAL replay early because an uncommitted
    /// record referenced a torn or missing payload (the longest valid prefix was kept).
    package var replayTruncationCount: UInt64
    /// Number of opens that scanned the file tail for a newer footer because neither the header
    /// nor the replay snapshot pinned a valid footer ending the file.
    package var replayFooterScanCount: UInt64

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
        replaySnapshotHitCount: UInt64,
        replayTruncationCount: UInt64,
        replayFooterScanCount: UInt64
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
        self.replayTruncationCount = replayTruncationCount
        self.replayFooterScanCount = replayFooterScanCount
    }
}

extension Wax {
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

    /// Replace the store's binding once every vector was re-embedded with the new identity.
    /// The binding lives in the TOC, so it becomes durable only in the same commit as the
    /// last re-embedded vectors; a crash before that commit keeps the old binding.
    package func replaceMemoryBinding(_ binding: MemoryBinding) async throws {
        await withWriteLock {
            guard !binding.isEmpty, toc.memoryBinding != binding else { return }
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

    /// Injects `pread`/`pwrite` faults into the store file. Tests only.
    func installFileFaultPlanForTesting(_ plan: FDFileFaultPlan?) {
        if let plan {
            file.installFaultPlan(plan)
        } else {
            file.clearFaultPlan()
        }
    }

    func recordedFileOperationsForTesting() -> [FDFileOperation] {
        file.recordedOperations()
    }

    package func fileURL() -> URL {
        url
    }

    /// Return whether a WAL payload can be appended without overflowing the
    /// current pending ring. Higher-level maintenance uses this preflight to
    /// commit a batch before writing the next frame record.
    package func canAppendWALPayload(payloadSize: Int) async -> Bool {
        await withReadLock {
            wal.canAppend(payloadSize: payloadSize)
        }
    }
}

extension Wax {
    /// The committed segment catalog. Tests only.
    func segmentCatalogEntriesForTesting() async -> [SegmentCatalogEntry] {
        await withReadLock { toc.segmentCatalog.entries }
    }

    /// Free ranges a commit may allocate from. Tests only.
    func freeDataRangesForTesting() async -> [Range<UInt64>] {
        await withReadLock { dataSpace.free.extents }
    }

    /// Whole committed lex images this handle hashed. Tests only.
    func lexFingerprintBuildsForTesting() async -> UInt64 {
        await withReadLock { lexFingerprintBuilds }
    }

    /// Stages that could not read the committed lex runs. Tests only.
    func committedLexReadFailuresForTesting() async -> UInt64 {
        await withReadLock { committedLexReadFailures }
    }
}
