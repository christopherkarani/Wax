import Foundation

package enum WALFsyncPolicy: Sendable, Equatable {
    case always
    case onCommit
    case everyBytes(UInt64)
}

package final class WALRingWriter {
    private struct WriterStateSnapshot {
        let writePos: UInt64
        let checkpointPos: UInt64
        let pendingBytes: UInt64
        let lastSequence: UInt64
        let wrapCount: UInt64
        let checkpointCount: UInt64
        let sentinelWriteCount: UInt64
        let writeCallCount: UInt64
        let bytesSinceFsync: UInt64
    }

    private let file: FDFile
    package let walOffset: UInt64
    package let walSize: UInt64
    private let fsyncPolicy: WALFsyncPolicy
    private static let sentinelData = Data(repeating: 0, count: WALRecord.headerSize)

    package private(set) var writePos: UInt64
    package private(set) var checkpointPos: UInt64
    package private(set) var pendingBytes: UInt64
    package private(set) var lastSequence: UInt64
    package private(set) var wrapCount: UInt64
    package private(set) var checkpointCount: UInt64
    package private(set) var sentinelWriteCount: UInt64
    package private(set) var writeCallCount: UInt64
    package private(set) var bytesSinceFsync: UInt64
    package private(set) var fsyncCount: UInt64 = 0
    /// True until the first append of a writer resumed from disk. That append fsyncs the file,
    /// writes the first record (and any padding before it), and fsyncs again before writing
    /// anything after it, so the first new record can never be lost while a later one survives.
    /// `PendingReplayPolicy.resumeSequence(above:walSize:)` relies on this.
    package private(set) var needsDurableAnchor: Bool
    private var isFaulted = false

    package init(
        file: FDFile,
        walOffset: UInt64,
        walSize: UInt64,
        writePos: UInt64 = 0,
        checkpointPos: UInt64 = 0,
        pendingBytes: UInt64 = 0,
        lastSequence: UInt64 = 0,
        wrapCount: UInt64 = 0,
        checkpointCount: UInt64 = 0,
        sentinelWriteCount: UInt64 = 0,
        writeCallCount: UInt64 = 0,
        fsyncPolicy: WALFsyncPolicy = .onCommit,
        needsDurableAnchor: Bool = false
    ) {
        self.file = file
        self.walOffset = walOffset
        self.walSize = walSize
        self.fsyncPolicy = fsyncPolicy
        if walSize > 0 {
            self.writePos = writePos % walSize
            self.checkpointPos = checkpointPos % walSize
        } else {
            self.writePos = 0
            self.checkpointPos = 0
        }
        self.pendingBytes = pendingBytes
        self.lastSequence = lastSequence
        self.wrapCount = wrapCount
        self.checkpointCount = checkpointCount
        self.sentinelWriteCount = sentinelWriteCount
        self.writeCallCount = writeCallCount
        self.bytesSinceFsync = 0
        self.needsDurableAnchor = needsDurableAnchor
    }

    @discardableResult
    func append(payload: Data, flags: WALFlags = []) throws -> UInt64 {
        let sequences = try appendPlanned(payloads: [payload], flags: flags, fsyncAccounting: .ringBytesConsumed)
        guard let sequence = sequences.first else {
            throw WaxError.io("WAL append produced no record")
        }
        return sequence
    }

    /// Append multiple payloads in a single pass, coalescing contiguous writes.
    /// Returns the sequence numbers for the appended data records (padding records are excluded).
    func appendBatch(payloads: [Data], flags: WALFlags = []) throws -> [UInt64] {
        try appendPlanned(payloads: payloads, flags: flags, fsyncAccounting: .bytesWrittenBeforeTrailingTail)
    }

    /// How an append counts toward the `.everyBytes` fsync threshold. Both match the
    /// pre-planner writer: single appends counted ring bytes consumed (including padding
    /// skip and zero tails); batches counted bytes written, excluding the trailing zero tail.
    private enum FsyncAccounting {
        case ringBytesConsumed
        case bytesWrittenBeforeTrailingTail
    }

    private struct EncodedPlan {
        var writes = CoalescedWrites()
        /// Number of leading write operations that end with the first data record.
        var anchorOperationCount: Int?
        var lastSequence: UInt64
        var sequences: [UInt64] = []
        var bytesBeforeTrailingTail: UInt64 = 0
    }

    /// Encodes every planned step into coalesced writes without touching the file.
    private func encode(
        _ plan: WALAppendPlan,
        payloads: [Data],
        flags: WALFlags,
        splitAfterFirstRecord: Bool
    ) throws -> EncodedPlan {
        var encoded = EncodedPlan(lastSequence: lastSequence)
        encoded.sequences.reserveCapacity(payloads.count)
        for step in plan.steps {
            switch step {
            case .zeroTail(let position, let length):
                encoded.writes.append(Data(repeating: 0, count: Int(length)), at: walOffset + position)
                if encoded.sequences.count < payloads.count {
                    encoded.bytesBeforeTrailingTail = encoded.writes.totalBytes
                }
            case .padding(let position, let skipBytes):
                encoded.lastSequence &+= 1
                let padding = WALRecord.padding(sequence: encoded.lastSequence, skipBytes: skipBytes)
                encoded.writes.append(try padding.encode(), at: walOffset + position)
            case .record(let position, let entryIndex):
                encoded.lastSequence &+= 1
                let record = WALRecord.data(
                    sequence: encoded.lastSequence,
                    flags: flags,
                    payload: payloads[entryIndex]
                )
                encoded.writes.append(try record.encode(), at: walOffset + position)
                encoded.sequences.append(encoded.lastSequence)
                encoded.bytesBeforeTrailingTail = encoded.writes.totalBytes
                if splitAfterFirstRecord, encoded.anchorOperationCount == nil {
                    encoded.anchorOperationCount = encoded.writes.operations.count
                    encoded.writes.seal()
                }
            }
        }
        return encoded
    }

    private func appendPlanned(
        payloads: [Data],
        flags: WALFlags,
        fsyncAccounting: FsyncAccounting
    ) throws -> [UInt64] {
        guard !isFaulted else {
            throw WaxError.io("WAL writer is faulted after a partial write failure")
        }
        guard !payloads.isEmpty else { return [] }

        let plan = try makePlan(entrySizes: payloads.map(Self.validatedEntrySize(for:)))
        let encoded = try encode(plan, payloads: payloads, flags: flags, splitAfterFirstRecord: needsDurableAnchor)
        var writes = encoded.writes
        let sequence = encoded.lastSequence
        let sequences = encoded.sequences
        let fsyncBytes: UInt64
        switch fsyncAccounting {
        case .ringBytesConsumed:
            fsyncBytes = plan.pendingBytes - pendingBytes
        case .bytesWrittenBeforeTrailingTail:
            fsyncBytes = encoded.bytesBeforeTrailingTail
        }
        if plan.writesSentinel {
            writes.append(Self.sentinelData, at: walOffset + plan.writePos)
        }

        let snapshot = captureState()
        do {
            try perform(writes.operations, anchorOperationCount: encoded.anchorOperationCount)
            lastSequence = sequence
            pendingBytes = plan.pendingBytes
            writePos = plan.writePos
            wrapCount &+= plan.wraps
            if plan.writesSentinel {
                sentinelWriteCount &+= 1
            }
            bytesSinceFsync &+= fsyncBytes
            try maybeFsync()
            return sequences
        } catch {
            faultAndRestore(snapshot)
            throw error
        }
    }

    /// Issues the planned file writes. While `needsDurableAnchor` is set, everything already on
    /// disk is fsynced first, and the writes up to the first data record are fsynced before the rest.
    private func perform(_ operations: [(offset: UInt64, bytes: Data)], anchorOperationCount: Int?) throws {
        let anchorEnd = needsDurableAnchor ? (anchorOperationCount ?? operations.count) : 0
        if needsDurableAnchor {
            try fsyncCounted()
            for write in operations[..<anchorEnd] {
                try writeAllCounted(write.bytes, at: write.offset)
            }
            try fsyncCounted()
            needsDurableAnchor = false
        }
        for write in operations[anchorEnd...] {
            try writeAllCounted(write.bytes, at: write.offset)
        }
    }

    package func canAppend(payloadSize: Int) -> Bool {
        canAppendBatch(payloadSizes: [payloadSize])
    }

    package func canAppendBatch(payloadSizes: [Int]) -> Bool {
        guard !payloadSizes.isEmpty else { return false }
        guard payloadSizes.allSatisfy({ $0 > 0 && $0 <= Int(UInt32.max) }) else { return false }
        let entrySizes = payloadSizes.map { UInt64(WALRecord.headerSize) + UInt64($0) }
        return (try? makePlan(entrySizes: entrySizes)) != nil
    }

    package func recordCheckpoint() {
        checkpointPos = writePos
        pendingBytes = 0
        bytesSinceFsync = 0
        checkpointCount &+= 1
    }

    package func flush() throws {
        guard bytesSinceFsync > 0 else { return }
        try fsyncCounted()
        bytesSinceFsync = 0
    }

    private func fsyncCounted() throws {
        try file.fsync()
        fsyncCount &+= 1
    }

    private func maybeFsync() throws {
        switch fsyncPolicy {
        case .always:
            try flush()
        case .onCommit:
            return
        case .everyBytes(let threshold):
            guard threshold > 0 else { return }
            if bytesSinceFsync >= threshold {
                try flush()
            }
        }
    }

    private func makePlan(entrySizes: [UInt64]) throws -> WALAppendPlan {
        try WALAppendPlan.make(
            walSize: walSize,
            writePos: writePos,
            pendingBytes: pendingBytes,
            entrySizes: entrySizes
        )
    }

    private static func validatedEntrySize(for payload: Data) throws -> UInt64 {
        guard !payload.isEmpty else {
            throw WaxError.encodingError(reason: "wal payload must be non-empty")
        }
        guard payload.count <= Int(UInt32.max) else {
            throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: UInt64(payload.count))
        }
        return UInt64(WALRecord.headerSize) + UInt64(payload.count)
    }

    private func writeAllCounted(_ data: Data, at offset: UInt64) throws {
        try file.writeAll(data, at: offset)
        writeCallCount &+= 1
    }

    private func captureState() -> WriterStateSnapshot {
        WriterStateSnapshot(
            writePos: writePos,
            checkpointPos: checkpointPos,
            pendingBytes: pendingBytes,
            lastSequence: lastSequence,
            wrapCount: wrapCount,
            checkpointCount: checkpointCount,
            sentinelWriteCount: sentinelWriteCount,
            writeCallCount: writeCallCount,
            bytesSinceFsync: bytesSinceFsync
        )
    }

    private func restoreState(_ snapshot: WriterStateSnapshot) {
        writePos = snapshot.writePos
        checkpointPos = snapshot.checkpointPos
        pendingBytes = snapshot.pendingBytes
        lastSequence = snapshot.lastSequence
        wrapCount = snapshot.wrapCount
        checkpointCount = snapshot.checkpointCount
        sentinelWriteCount = snapshot.sentinelWriteCount
        writeCallCount = snapshot.writeCallCount
        bytesSinceFsync = snapshot.bytesSinceFsync
    }

    private func faultAndRestore(_ snapshot: WriterStateSnapshot) {
        restoreState(snapshot)
        isFaulted = true
        // Best-effort: overwrite any partially-written bytes at the restored writePos
        // with a zeroed sentinel so a subsequent package does not mistake stale on-disk
        // content (e.g., a sentinel written before the failure) for a valid record.
        // This is advisory — the package path must still handle corrupt content defensively.
        try? writeAllCounted(Self.sentinelData, at: walOffset + snapshot.writePos)
    }
}

extension WALRingWriter: @unchecked Sendable {}

/// File writes for one append, merged when each starts where the previous one ended.
private struct CoalescedWrites {
    private(set) var operations: [(offset: UInt64, bytes: Data)] = []
    private(set) var totalBytes: UInt64 = 0
    private var sealed = false

    /// Starts a new operation on the next append even if it is contiguous with the last one.
    mutating func seal() {
        sealed = true
    }

    mutating func append(_ bytes: Data, at offset: UInt64) {
        totalBytes &+= UInt64(bytes.count)
        defer { sealed = false }
        if !sealed, let last = operations.indices.last,
           operations[last].offset + UInt64(operations[last].bytes.count) == offset {
            operations[last].bytes.append(bytes)
        } else {
            operations.append((offset: offset, bytes: bytes))
        }
    }
}
