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

/// Decides whether damaged pending payloads are a torn tail or corruption.
///
/// With `.onCommit` fsync a crash can persist WAL records whose data payloads never reached disk.
/// That only ever damages a suffix of the pending puts, so a damaged payload counts as a torn tail
/// when no later pending put has an intact payload. An intact put after a damaged one means the
/// damage is not explained by a crash, and open fails closed to keep the evidence.
enum PendingReplayPolicy {
    static func decide(_ statuses: [PendingPayloadStatus], allowsTruncation: Bool) -> PendingReplayDecision {
        guard let first = statuses.firstIndex(where: \.isDamaged) else { return .replayAll }
        let laterIntactPut = statuses[(first + 1)...].contains(.intact)
        guard allowsTruncation, !laterIntactPut else { return .failClosed(at: first) }
        return .truncateTornTail(at: first)
    }

    /// Drops the torn tail starting at pending mutation `index`.
    ///
    /// Every dropped record, `[cut, end of chain)` in ring order, is zeroed and fsynced before this
    /// returns, so neither the dropped records nor anything after them can be replayed later.
    ///
    /// - Returns: The ring state at the cut, where the writer resumes.
    static func truncateTornTail(
        _ scan: WALPendingScanResult,
        at index: Int,
        checkpointPos: UInt64,
        walOffset: UInt64,
        walSize: UInt64,
        file: FDFile
    ) throws -> WALScanState {
        let cut = scan.pendingOffsets[index]
        let start = checkpointPos % walSize
        let keptBytes = (cut + walSize - start) % walSize
        try zeroRing(
            file: file,
            walOffset: walOffset,
            walSize: walSize,
            from: cut,
            length: scan.state.pendingBytes - keptBytes
        )
        try file.fsync()
        let lastKeptSequence = index > 0 ? scan.pendingMutations[index - 1].sequence : 0
        return WALScanState(lastSequence: lastKeptSequence, writePos: cut, pendingBytes: keptBytes)
    }

    private static let zeroChunkLimit: UInt64 = 1 << 20

    private static func zeroRing(
        file: FDFile,
        walOffset: UInt64,
        walSize: UInt64,
        from start: UInt64,
        length: UInt64
    ) throws {
        var position = start
        var remaining = length
        while remaining > 0 {
            let count = min(remaining, walSize - position, zeroChunkLimit)
            try file.writeAll(Data(count: Int(count)), at: walOffset + position)
            remaining -= count
            position = (position + count) % walSize
        }
    }
}
