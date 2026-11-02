import Foundation

/// Integrity of the out-of-band data payload a pending WAL mutation refers to.
enum PendingPayloadStatus: Equatable, Sendable {
    /// The mutation carries no out-of-band payload (delete, supersede, embedding).
    case notApplicable
    case intact
    case outOfBounds
    case checksumMismatch

    var isDamaged: Bool {
        self == .outOfBounds || self == .checksumMismatch
    }
}

/// What open does with the pending WAL mutations it scanned.
enum PendingReplayDecision: Equatable, Sendable {
    case replayAll
    /// Drop the mutation at this index and everything after it.
    case truncateTornTail(at: Int)
    /// Refuse to open; the mutation at this index is damaged.
    case failClosed(at: Int)
}

/// A contiguous span of the WAL ring, `length` bytes from `start`, possibly wrapping past the end.
struct WALRingRange: Equatable, Sendable {
    var start: UInt64
    var length: UInt64
}

/// Decides what to do with damaged pending payloads and drops a torn tail durably.
///
/// Pending (uncommitted) mutations are not a durability promise. Unless every payload is synced
/// before its WAL record (`.always`), a crash can persist any subset of pending payload bytes,
/// including a later payload but not an earlier one. So the first damaged pending put is where
/// recovery cuts, whatever follows it.
enum PendingReplayPolicy {
    static func decide(_ statuses: [PendingPayloadStatus], allowsTruncation: Bool) -> PendingReplayDecision {
        guard let first = statuses.firstIndex(where: \.isDamaged) else { return .replayAll }
        return allowsTruncation ? .truncateTornTail(at: first) : .failClosed(at: first)
    }

    /// Drops the torn tail starting at pending mutation `index`.
    ///
    /// Every dropped record, `[cut, end of chain)` in ring order, is zeroed before this returns.
    /// Records are zeroed last-first with an fsync after each, so a crash part-way leaves only
    /// a prefix of the dropped records live, still reachable from the cut. The next open sees the
    /// same damaged record and finishes the job, and no stale record is ever left beyond the end
    /// of the chain, where a later append could make it replayable again.
    ///
    /// - Returns: The ring state at the cut, where the writer resumes.
    static func truncateTornTail(
        _ scan: WALPendingScanResult,
        at index: Int,
        checkpointPos: UInt64,
        ring: (offset: UInt64, size: UInt64),
        file: FDFile
    ) throws -> WALScanState {
        let cut = scan.pendingOffsets[index]
        let dropped = droppedRecordRanges(scan, at: index, checkpointPos: checkpointPos, walSize: ring.size)
        for range in dropped {
            try zeroRing(file: file, ring: ring, range: range)
            try file.fsync()
        }
        let lastKeptSequence = index > 0 ? scan.pendingMutations[index - 1].sequence : 0
        return WALScanState(
            lastSequence: lastKeptSequence,
            writePos: cut,
            pendingBytes: keptBytes(cut: cut, checkpointPos: checkpointPos, walSize: ring.size)
        )
    }

    /// The ring span of each record dropped when cutting at pending mutation `index`, padding and
    /// any zero tail included, in the order they must be zeroed: last record first, cut last.
    static func droppedRecordRanges(
        _ scan: WALPendingScanResult,
        at index: Int,
        checkpointPos: UInt64,
        walSize: UInt64
    ) -> [WALRingRange] {
        let cut = scan.pendingOffsets[index]
        let kept = keptBytes(cut: cut, checkpointPos: checkpointPos, walSize: walSize)
        let droppedBytes = scan.state.pendingBytes - kept
        // `cut` comes from `pendingOffsets`, a subset of `recordOffsets`; zeroing it as one span
        // is the conservative fallback should that ever not hold.
        guard let first = scan.recordOffsets.firstIndex(of: cut) else {
            return [WALRingRange(start: cut, length: droppedBytes)]
        }
        let starts = scan.recordOffsets[first...]
        var ranges: [WALRingRange] = []
        var consumed: UInt64 = 0
        for (start, next) in zip(starts, starts.dropFirst()) {
            let length = (next + walSize - start) % walSize
            ranges.append(WALRingRange(start: start, length: length))
            consumed += length
        }
        if let last = starts.last {
            ranges.append(WALRingRange(start: last, length: droppedBytes - consumed))
        }
        return ranges.reversed()
    }

    /// Ring bytes from the checkpoint up to `cut`.
    private static func keptBytes(cut: UInt64, checkpointPos: UInt64, walSize: UInt64) -> UInt64 {
        (cut + walSize - checkpointPos % walSize) % walSize
    }

    private static let zeroChunkLimit: UInt64 = 1 << 20

    private static func zeroRing(file: FDFile, ring: (offset: UInt64, size: UInt64), range: WALRingRange) throws {
        var position = range.start
        var remaining = range.length
        while remaining > 0 {
            let count = min(remaining, ring.size - position, zeroChunkLimit)
            try file.writeAll(Data(count: Int(count)), at: ring.offset + position)
            remaining -= count
            position = (position + count) % ring.size
        }
    }
}
