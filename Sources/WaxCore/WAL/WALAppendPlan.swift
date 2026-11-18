import Foundation

/// Pure placement plan for appending one or more entries to the WAL ring.
///
/// This is the single source of truth for ring capacity math: `WALRingWriter.append`,
/// `appendBatch`, `canAppend`, and `canAppendBatch` all derive their answers from it.
///
/// Invariant enforced by every successful plan: after the append, the free ring space
/// (`walSize - pendingBytes`) is either zero — the ring is exactly full and replay stops
/// when it reaches the checkpoint again — or at least one record header, so the
/// terminating sentinel always fits and never overwrites the oldest pending record.
struct WALAppendPlan: Equatable, Sendable {
    enum Step: Equatable, Sendable {
        /// Zero-fill a tail shorter than a record header, then wrap to offset 0.
        case zeroTail(position: UInt64, length: UInt64)
        /// Padding record whose skip ends exactly at the ring end, then wrap to offset 0.
        case padding(position: UInt64, skipBytes: UInt32)
        /// Data record for the entry at `entryIndex` of the planned batch.
        case record(position: UInt64, entryIndex: Int)
    }

    /// Ring writes in order. Each `.padding` and `.record` consumes one WAL sequence number.
    var steps: [Step]
    /// Ring-relative write cursor after the batch; always leaves room for a header or is 0.
    var writePos: UInt64
    /// Pending (uncheckpointed) ring bytes after the batch, including padding and zero tails.
    var pendingBytes: UInt64
    /// Number of times the cursor wrapped from a non-zero position through padding or a zero tail.
    var wraps: UInt64
    /// Whether a zeroed sentinel header must be written at `writePos`.
    var writesSentinel: Bool

    /// Plans appending `entrySizes` (header + payload bytes each) at `writePos`.
    ///
    /// - Throws: `WaxError.capacityExceeded` when an entry can never fit or the ring lacks room.
    static func make(
        walSize: UInt64,
        writePos: UInt64,
        pendingBytes: UInt64,
        entrySizes: [UInt64]
    ) throws -> WALAppendPlan {
        guard walSize > 0 else {
            throw WaxError.capacityExceeded(limit: 0, requested: entrySizes.first ?? 0)
        }
        var builder = Builder(walSize: walSize, writePos: writePos % walSize, pendingBytes: pendingBytes)
        for (index, entrySize) in entrySizes.enumerated() {
            try builder.placeRecord(entrySize: entrySize, entryIndex: index)
        }
        try builder.wrapIfTailCannotHoldHeader()
        return try builder.finish()
    }

    private struct Builder {
        let walSize: UInt64
        var position: UInt64
        var pendingBytes: UInt64
        var wraps: UInt64 = 0
        var steps: [Step] = []

        private static let headerSize = UInt64(WALRecord.headerSize)

        init(walSize: UInt64, writePos: UInt64, pendingBytes: UInt64) {
            self.walSize = walSize
            self.position = writePos
            self.pendingBytes = pendingBytes
        }

        mutating func placeRecord(entrySize: UInt64, entryIndex: Int) throws {
            guard entrySize <= walSize else {
                throw WaxError.capacityExceeded(limit: walSize, requested: entrySize)
            }
            try wrapIfTailCannotHoldHeader()

            let remaining = walSize - position
            if remaining < entrySize {
                let skipBytes = remaining - Self.headerSize
                guard skipBytes <= UInt64(UInt32.max) else {
                    throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: skipBytes)
                }
                try consume(remaining)
                steps.append(.padding(position: position, skipBytes: UInt32(skipBytes)))
                wrapToStart()
            }

            try consume(entrySize)
            steps.append(.record(position: position, entryIndex: entryIndex))
            position += entrySize
            if position == walSize {
                position = 0
            }
        }

        /// A tail shorter than a header can hold neither a record nor a sentinel,
        /// so it is zero-filled, counted as pending, and the cursor wraps.
        mutating func wrapIfTailCannotHoldHeader() throws {
            let remaining = walSize - position
            guard remaining < Self.headerSize else { return }
            try consume(remaining)
            steps.append(.zeroTail(position: position, length: remaining))
            wrapToStart()
        }

        func finish() throws -> WALAppendPlan {
            let freeBytes = walSize - pendingBytes
            guard freeBytes == 0 || freeBytes >= Self.headerSize else {
                throw WaxError.capacityExceeded(limit: walSize, requested: pendingBytes + Self.headerSize)
            }
            return WALAppendPlan(
                steps: steps,
                writePos: position,
                pendingBytes: pendingBytes,
                wraps: wraps,
                writesSentinel: freeBytes > 0
            )
        }

        private mutating func consume(_ bytes: UInt64) throws {
            let (total, overflow) = pendingBytes.addingReportingOverflow(bytes)
            guard !overflow, total <= walSize else {
                throw WaxError.capacityExceeded(limit: walSize, requested: overflow ? .max : total)
            }
            pendingBytes = total
        }

        private mutating func wrapToStart() {
            if position != 0 {
                wraps &+= 1
            }
            position = 0
        }
    }
}
