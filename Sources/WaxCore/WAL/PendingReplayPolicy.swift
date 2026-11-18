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

/// Decides what to do with damaged pending payloads, drops a torn tail, and picks the sequence
/// the WAL writer resumes at.
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

    /// The WAL writer's last sequence on open (its next record is one higher): strictly above any
    /// sequence a record physically left anywhere in the ring can carry, so no stale record can
    /// ever chain after a new one (the reader only follows strictly increasing sequences).
    ///
    /// The bound: every record still in the ring was written either before the last commit
    /// (sequence at most the committed sequence) or after a point whose sequence open can see.
    /// That point is the last commit, or the first record a session appended after open. The
    /// writer makes that first record durable, together with everything before it, before
    /// writing anything after it, so it stays in the chain that `base` covers. Records written
    /// after that point all fit in the ring at once, and each takes at least one header, so
    /// there are at most `walSize / headerSize` of them and their sequences stay at or below
    /// `base + walSize / headerSize`.
    ///
    /// - Parameter base: The highest sequence open knows of: the committed sequence, the
    ///   persisted replay snapshot, and every record in the scanned chain, dropped ones included.
    static func resumeSequence(above base: UInt64, walSize: UInt64) throws -> UInt64 {
        let maxRecordsInRing = walSize / UInt64(WALRecord.headerSize)
        let (resume, overflow) = base.addingReportingOverflow(maxRecordsInRing &+ 1)
        guard !overflow, resume < UInt64.max - maxRecordsInRing else {
            throw WaxError.io("WAL sequence space exhausted (base \(base))")
        }
        return resume
    }

    /// Drops the torn tail starting at pending mutation `index`: zeroes `[cut, end of chain)` in
    /// one pass and fsyncs before returning.
    ///
    /// The zeroing is hygiene, not what keeps dropped records out of replay: a crash can persist
    /// any part of it, and `resumeSequence(above:walSize:)` keeps whatever survives unreachable.
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
        let keptBytes = (cut + ring.size - checkpointPos % ring.size) % ring.size
        try zeroRing(file: file, ring: ring, from: cut, length: scan.state.pendingBytes - keptBytes)
        try file.fsync()
        let lastKeptSequence = index > 0 ? scan.pendingMutations[index - 1].sequence : 0
        return WALScanState(lastSequence: lastKeptSequence, writePos: cut, pendingBytes: keptBytes)
    }

    private static let zeroChunkLimit: UInt64 = 1 << 20

    private static func zeroRing(
        file: FDFile,
        ring: (offset: UInt64, size: UInt64),
        from start: UInt64,
        length: UInt64
    ) throws {
        var position = start
        var remaining = length
        while remaining > 0 {
            let count = min(remaining, ring.size - position, zeroChunkLimit)
            try file.writeAll(Data(count: Int(count)), at: ring.offset + position)
            remaining -= count
            position = (position + count) % ring.size
        }
    }
}
