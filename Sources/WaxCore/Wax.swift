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
    enum CrashInjectionCheckpoint: String {
        case afterTocWriteBeforeFooter = "after_toc_write_before_footer"
        case afterFooterWriteBeforeFsync = "after_footer_write_before_fsync"
        case afterFooterFsyncBeforeHeader = "after_footer_fsync_before_header"
        case afterHeaderWriteBeforeFinalFsync = "after_header_write_before_final_fsync"

        static let envKey = "WAX_CRASH_INJECT_CHECKPOINT"
    }

    let url: URL
    let io: BlockingIOExecutor
    private let opLock = AsyncReadWriteLock()
    private var writerLeaseId: UUID?
    var file: FDFile
    var lock: FileLock

    var header: WaxHeaderPage
    var selectedHeaderPageIndex: Int

    var toc: WaxTOC
    var surrogateIndex: [UInt64: UInt64]? = nil
    var wal: WALRingWriter
    var pendingMutations: [PendingMutation]
    var pendingMutationSummary: PendingMutationSummary
    var encodedCommittedFramePayloadCache: Data?
    var stagedLexIndex: StagedLexIndex?
    var stagedVecIndex: StagedVecIndex?
    var stagedLexIndexStamp: UInt64?
    var stagedVecIndexStamp: UInt64?
    var stagedLexIndexStampCounter: UInt64
    var stagedVecIndexStampCounter: UInt64

    var dataEnd: UInt64
    var generation: UInt64
    var dirty: Bool
    var walAutoCommitCount: UInt64
    var walReplaySnapshotHitCount: UInt64
    let walProactiveCommitThresholdBytes: UInt64?
    let walProactiveCommitMaxWalSizeBytes: UInt64?
    let walProactiveCommitMinPendingBytes: UInt64
    let walReplayStateSnapshotEnabled: Bool

    private struct WriterWaiter {
        let id: UUID
        let continuation: CheckedContinuation<UUID, Error>
    }

    private var writerWaiters: [WriterWaiter] = []

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


    // MARK: - Internal helpers

    static func maybeCrashAfterCheckpoint(_ checkpoint: CrashInjectionCheckpoint) {
        let env = ProcessInfo.processInfo.environment
        guard env[CrashInjectionCheckpoint.envKey] == checkpoint.rawValue else { return }
        // SIGKILL is delivered asynchronously and may be delayed or masked in sandboxed
        // environments (containers, test harnesses). The fatalError below is a safety net
        // for those cases; it should never be reached in normal crash-injection runs but
        // produces a clear diagnostic if SIGKILL did not terminate the process in time.
        _ = posixKill(posixGetPID(), SIGKILL)
        fatalError("crash injection did not terminate process at \(checkpoint.rawValue)")
    }

    func persistReplaySnapshotOnSelectedHeaderPage(_ snapshot: WaxHeaderPage.WALReplaySnapshot) async throws {
        var snapshotPage = header
        snapshotPage.walReplaySnapshot = snapshot
        let offset = UInt64(selectedHeaderPageIndex) * Constants.headerPageSize
        let file = self.file
        let encoded = try snapshotPage.encodeWithChecksum()
        try await io.run {
            try file.writeAll(encoded, at: offset)
        }
    }

    func writeHeaderPage(_ page: WaxHeaderPage) async throws {
        let nextIndex = selectedHeaderPageIndex == 0 ? 1 : 0
        let offset = UInt64(nextIndex) * Constants.headerPageSize
        let file = self.file
        try await io.run {
            try file.writeAll(try page.encodeWithChecksum(), at: offset)
        }
        selectedHeaderPageIndex = nextIndex
    }

    struct AppliedPendingMutations {
        var maxSequence: UInt64
        var appendedFrames: [FrameMeta]
        var modifiedCommittedFrames: Bool
    }

    func applyPendingMutationsIntoTOC() throws -> AppliedPendingMutations {
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

    struct StagedLexIndex {
        var bytes: Data
        var docCount: UInt64
        var version: UInt32
        var checksum: Data
    }

    struct StagedVecIndex {
        var bytes: Data
        var vectorCount: UInt64
        var dimension: UInt32
        var similarity: VecSimilarity
        var pendingEmbeddingMaxSequence: UInt64?
        var checksum: Data
    }

    struct PendingMutationSummary {
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

    func nextSegmentId() -> UInt64 {
        if let maxId = toc.segmentCatalog.entries.map({ $0.segmentId }).max() {
            return maxId &+ 1
        }
        return 0
    }

    func encodedCommittedFramePayloadForCommit(
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

    static func validateTocRanges(_ toc: WaxTOC, dataStart: UInt64, dataEnd: UInt64) throws {
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

    func sha256(file: FDFile, offset: UInt64, length: UInt64) async throws -> Data {
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
