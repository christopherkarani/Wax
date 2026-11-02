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
    private var bytesSinceFsync: UInt64
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
        fsyncPolicy: WALFsyncPolicy = .onCommit
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
    }

    @discardableResult
    func append(payload: Data, flags: WALFlags = []) throws -> UInt64 {
        let sequences = try appendBatch(payloads: [payload], flags: flags)
        guard let sequence = sequences.first else {
            throw WaxError.io("WAL append produced no record")
        }
        return sequence
    }

    /// Append multiple payloads in a single pass, coalescing contiguous writes.
    /// Returns the sequence numbers for the appended data records (padding records are excluded).
    func appendBatch(payloads: [Data], flags: WALFlags = []) throws -> [UInt64] {
        guard !isFaulted else {
            throw WaxError.io("WAL writer is faulted after a partial write failure")
        }
        guard !payloads.isEmpty else { return [] }

        let plan = try makePlan(entrySizes: payloads.map(Self.validatedEntrySize(for:)))

        var writes = CoalescedWrites()
        var sequence = lastSequence
        var sequences: [UInt64] = []
        sequences.reserveCapacity(payloads.count)
        for step in plan.steps {
            switch step {
            case .zeroTail(let position, let length):
                writes.append(Data(repeating: 0, count: Int(length)), at: walOffset + position)
            case .padding(let position, let skipBytes):
                sequence &+= 1
                let padding = WALRecord.padding(sequence: sequence, skipBytes: skipBytes)
                writes.append(try padding.encode(), at: walOffset + position)
            case .record(let position, let entryIndex):
                sequence &+= 1
                let record = WALRecord.data(sequence: sequence, flags: flags, payload: payloads[entryIndex])
                writes.append(try record.encode(), at: walOffset + position)
                sequences.append(sequence)
            }
        }
        let recordBytes = writes.totalBytes
        if plan.writesSentinel {
            writes.append(Self.sentinelData, at: walOffset + plan.writePos)
        }

        let snapshot = captureState()
        do {
            for write in writes.operations {
                try writeAllCounted(write.bytes, at: write.offset)
            }

            lastSequence = sequence
            pendingBytes = plan.pendingBytes
            writePos = plan.writePos
            wrapCount &+= plan.wraps
            if plan.writesSentinel {
                sentinelWriteCount &+= 1
            }
            bytesSinceFsync &+= recordBytes
            try maybeFsync()
            return sequences
        } catch {
            faultAndRestore(snapshot)
            throw error
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
        try file.fsync()
        bytesSinceFsync = 0
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

    mutating func append(_ bytes: Data, at offset: UInt64) {
        totalBytes &+= UInt64(bytes.count)
        if let last = operations.indices.last,
           operations[last].offset + UInt64(operations[last].bytes.count) == offset {
            operations[last].bytes.append(bytes)
        } else {
            operations.append((offset: offset, bytes: bytes))
        }
    }
}
