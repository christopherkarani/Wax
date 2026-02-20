import Foundation

public enum WALFsyncPolicy: Sendable, Equatable {
    case always
    case onCommit
    case everyBytes(UInt64)
}

public final class WALRingWriter {
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
    public let walOffset: UInt64
    public let walSize: UInt64
    private let fsyncPolicy: WALFsyncPolicy
    private static let sentinelData = Data(repeating: 0, count: WALRecord.headerSize)

    public private(set) var writePos: UInt64
    public private(set) var checkpointPos: UInt64
    public private(set) var pendingBytes: UInt64
    public private(set) var lastSequence: UInt64
    public private(set) var wrapCount: UInt64
    public private(set) var checkpointCount: UInt64
    public private(set) var sentinelWriteCount: UInt64
    public private(set) var writeCallCount: UInt64
    private var bytesSinceFsync: UInt64
    private var isFaulted = false

    public init(
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
    public func append(payload: Data, flags: WALFlags = []) throws -> UInt64 {
        guard !isFaulted else {
            throw WaxError.io("WAL writer is faulted after a partial write failure")
        }
        guard !payload.isEmpty else {
            throw WaxError.encodingError(reason: "wal payload must be non-empty")
        }
        guard walSize > 0 else {
            throw WaxError.capacityExceeded(limit: 0, requested: UInt64(payload.count))
        }
        guard payload.count <= Int(UInt32.max) else {
            throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: UInt64(payload.count))
        }

        let headerSize = UInt64(WALRecord.headerSize)
        let entrySize = headerSize + UInt64(payload.count)
        if entrySize > walSize {
            throw WaxError.capacityExceeded(limit: walSize, requested: entrySize)
        }

        var extraPadding: UInt64 = 0
        var probeWritePos = writePos
        var remaining = walSize - probeWritePos

        if remaining < headerSize {
            extraPadding += remaining
            probeWritePos = 0
            remaining = walSize
        }

        if remaining < entrySize {
            extraPadding += remaining
            probeWritePos = 0
            remaining = walSize
        }

        let predictedWritePos = probeWritePos + entrySize
        if walSize - predictedWritePos < headerSize {
            extraPadding += walSize - predictedWritePos
        }

        let totalNeeded = entrySize + extraPadding
        if pendingBytes + totalNeeded > walSize {
            throw WaxError.capacityExceeded(limit: walSize, requested: pendingBytes + totalNeeded)
        }

        let snapshot = captureState()

        do {
            remaining = walSize - writePos
            if remaining < headerSize {
                if remaining > 0 {
                    let zeroTail = Data(repeating: 0, count: Int(remaining))
                    try writeAllCounted(zeroTail, at: walOffset + writePos)
                    pendingBytes += remaining
                }
                if writePos != 0 {
                    wrapCount &+= 1
                }
                writePos = 0
                remaining = walSize
            }

            let needsPadding = remaining < entrySize && remaining >= headerSize
            if needsPadding {
                let skipBytes64 = remaining - headerSize
                guard skipBytes64 <= UInt64(UInt32.max) else {
                    throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: skipBytes64)
                }
                let skipBytes = UInt32(skipBytes64)
                let paddingSequence = lastSequence &+ 1
                let paddingRecord = WALRecord.padding(sequence: paddingSequence, skipBytes: skipBytes)
                let paddingData = try paddingRecord.encode()
                try writeAllCounted(paddingData, at: walOffset + writePos)
                lastSequence = paddingSequence
                pendingBytes += remaining
                if writePos != 0 {
                    wrapCount &+= 1
                }
                writePos = 0
            }

            let sequence = lastSequence &+ 1
            let record = WALRecord.data(sequence: sequence, flags: flags, payload: payload)
            let recordData = try record.encode()
            let recordStart = writePos
            let recordEnd = recordStart + entrySize
            let canInlineSentinel =
                recordEnd < walSize &&
                (walSize - recordEnd) >= headerSize &&
                (pendingBytes + entrySize) < walSize

            if canInlineSentinel {
                var combined = Data()
                combined.reserveCapacity(recordData.count + WALRecord.headerSize)
                combined.append(recordData)
                combined.append(Self.sentinelData)
                try writeAllCounted(combined, at: walOffset + recordStart)
                sentinelWriteCount &+= 1
            } else {
                try writeAllCounted(recordData, at: walOffset + recordStart)
            }

            lastSequence = sequence
            pendingBytes += entrySize
            writePos = recordEnd == walSize ? 0 : recordEnd

            if !canInlineSentinel {
                try writeSentinel()
            }
            bytesSinceFsync &+= totalNeeded
            try maybeFsync()
            return sequence
        } catch {
            faultAndRestore(snapshot)
            throw error
        }
    }

    /// Append multiple payloads in a single pass, reusing padding and wrap calculations.
    /// Returns the sequence numbers for the appended data records (padding records are excluded).
    public func appendBatch(payloads: [Data], flags: WALFlags = []) throws -> [UInt64] {
        guard !isFaulted else {
            throw WaxError.io("WAL writer is faulted after a partial write failure")
        }
        guard !payloads.isEmpty else { return [] }
        guard walSize > 0 else {
            throw WaxError.capacityExceeded(limit: 0, requested: 0)
        }

        let headerSize = UInt64(WALRecord.headerSize)
        var operations: [(offset: UInt64, bytes: Data)] = []
        var sequences: [UInt64] = []

        var localWritePos = writePos
        var localPendingBytes = pendingBytes
        var localLastSequence = lastSequence
        var localWrapCount = wrapCount
        var totalWritten: UInt64 = 0

        func appendOperation(offset: UInt64, data: Data) {
            operations.append((offset: offset, bytes: data))
            totalWritten &+= UInt64(data.count)
        }

        for payload in payloads {
            guard !payload.isEmpty else {
                throw WaxError.encodingError(reason: "wal payload must be non-empty")
            }
            guard payload.count <= Int(UInt32.max) else {
                throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: UInt64(payload.count))
            }

            let entrySize = headerSize + UInt64(payload.count)
            if entrySize > walSize {
                throw WaxError.capacityExceeded(limit: walSize, requested: entrySize)
            }

            var remaining = walSize - localWritePos
            if remaining < headerSize {
                if remaining > 0 {
                    let zeroTail = Data(repeating: 0, count: Int(remaining))
                    appendOperation(offset: walOffset + localWritePos, data: zeroTail)
                    localPendingBytes &+= remaining
                }
                if localWritePos != 0 {
                    localWrapCount &+= 1
                }
                localWritePos = 0
                remaining = walSize
            }

            if remaining < entrySize {
                let skipBytes = remaining - headerSize
                guard skipBytes <= UInt64(UInt32.max) else {
                    throw WaxError.capacityExceeded(limit: UInt64(UInt32.max), requested: skipBytes)
                }
                let paddingSeq = localLastSequence &+ 1
                let paddingRecord = WALRecord.padding(sequence: paddingSeq, skipBytes: UInt32(skipBytes))
                let paddingData = try paddingRecord.encode()
                appendOperation(offset: walOffset + localWritePos, data: paddingData)
                localLastSequence = paddingSeq
                localPendingBytes &+= remaining
                if localWritePos != 0 {
                    localWrapCount &+= 1
                }
                localWritePos = 0
            }

            if localPendingBytes + entrySize > walSize {
                throw WaxError.capacityExceeded(limit: walSize, requested: localPendingBytes + entrySize)
            }

            let sequence = localLastSequence &+ 1
            let record = WALRecord.data(sequence: sequence, flags: flags, payload: payload)
            let recordData = try record.encode()
            appendOperation(offset: walOffset + localWritePos, data: recordData)

            sequences.append(sequence)
            localLastSequence = sequence
            localPendingBytes &+= entrySize
            localWritePos = (localWritePos + entrySize) % walSize
        }

        var coalesced: [(offset: UInt64, bytes: Data)] = []
        coalesced.reserveCapacity(operations.count)
        for op in operations {
            if let lastIndex = coalesced.indices.last {
                let lastEnd = coalesced[lastIndex].offset + UInt64(coalesced[lastIndex].bytes.count)
                if lastEnd == op.offset {
                    coalesced[lastIndex].bytes.append(op.bytes)
                    continue
                }
            }
            coalesced.append(op)
        }

        var inlinedSentinel = false
        if localPendingBytes < walSize,
           localWritePos <= walSize - headerSize,
           let lastIndex = coalesced.indices.last {
            let sentinelOffset = walOffset + localWritePos
            let lastEnd = coalesced[lastIndex].offset + UInt64(coalesced[lastIndex].bytes.count)
            if lastEnd == sentinelOffset {
                coalesced[lastIndex].bytes.append(Self.sentinelData)
                inlinedSentinel = true
            }
        }

        let snapshot = captureState()

        do {
            for op in coalesced {
                try writeAllCounted(op.bytes, at: op.offset)
            }

            lastSequence = localLastSequence
            pendingBytes = localPendingBytes
            writePos = localWritePos
            wrapCount = localWrapCount
            bytesSinceFsync &+= totalWritten

            if inlinedSentinel {
                sentinelWriteCount &+= 1
            } else {
                try writeSentinel()
            }
            try maybeFsync()
            return sequences
        } catch {
            faultAndRestore(snapshot)
            throw error
        }
    }

    public func canAppend(payloadSize: Int) -> Bool {
        guard payloadSize > 0 else { return false }
        guard walSize > 0 else { return false }
        guard payloadSize <= Int(UInt32.max) else { return false }

        let headerSize = UInt64(WALRecord.headerSize)
        let entrySize = headerSize + UInt64(payloadSize)
        if entrySize > walSize { return false }

        var extraPadding: UInt64 = 0
        var probeWritePos = writePos
        var remaining = walSize - probeWritePos

        if remaining < headerSize {
            extraPadding += remaining
            probeWritePos = 0
            remaining = walSize
        }

        if remaining < entrySize {
            extraPadding += remaining
            probeWritePos = 0
            remaining = walSize
        }

        let predictedWritePos = probeWritePos + entrySize
        if walSize - predictedWritePos < headerSize {
            extraPadding += walSize - predictedWritePos
        }

        let totalNeeded = entrySize + extraPadding
        return pendingBytes + totalNeeded <= walSize
    }

    public func canAppendBatch(payloadSizes: [Int]) -> Bool {
        guard !payloadSizes.isEmpty else { return false }
        guard walSize > 0 else { return false }

        let headerSize = UInt64(WALRecord.headerSize)
        var localWritePos = writePos
        var localPendingBytes = pendingBytes

        for payloadSize in payloadSizes {
            guard payloadSize > 0 else { return false }
            guard payloadSize <= Int(UInt32.max) else { return false }

            let entrySize = headerSize + UInt64(payloadSize)
            if entrySize > walSize { return false }

            var remaining = walSize - localWritePos
            if remaining < headerSize {
                if remaining > 0 {
                    localPendingBytes &+= remaining
                    if localPendingBytes > walSize { return false }
                }
                localWritePos = 0
                remaining = walSize
            }

            if remaining < entrySize {
                localPendingBytes &+= remaining
                if localPendingBytes > walSize { return false }
                localWritePos = 0
            }

            if localPendingBytes + entrySize > walSize {
                return false
            }

            localPendingBytes &+= entrySize
            localWritePos = (localWritePos + entrySize) % walSize
        }

        if walSize >= headerSize {
            let remaining = walSize - localWritePos
            if remaining < headerSize {
                if remaining > 0 {
                    localPendingBytes &+= remaining
                    if localPendingBytes > walSize { return false }
                }
            }
        }

        return localPendingBytes <= walSize
    }

    public func recordCheckpoint() {
        checkpointPos = writePos
        pendingBytes = 0
        bytesSinceFsync = 0
        checkpointCount &+= 1
    }

    public func flush() throws {
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

    private func writeSentinel() throws {
        let headerSize = UInt64(WALRecord.headerSize)
        guard walSize >= headerSize else { return }

        var remaining = walSize - writePos
        if remaining < headerSize {
            if remaining > 0 {
                let zeroTail = Data(repeating: 0, count: Int(remaining))
                try writeAllCounted(zeroTail, at: walOffset + writePos)
                pendingBytes += remaining
            }
            if writePos != 0 {
                wrapCount &+= 1
            }
            writePos = 0
            remaining = walSize
        }

        if pendingBytes >= walSize {
            return
        }

        try writeAllCounted(Self.sentinelData, at: walOffset + writePos)
        sentinelWriteCount &+= 1
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
        // with a zeroed sentinel so a subsequent open does not mistake stale on-disk
        // content (e.g., a sentinel written before the failure) for a valid record.
        // This is advisory — the open path must still handle corrupt content defensively.
        try? writeAllCounted(Self.sentinelData, at: walOffset + snapshot.writePos)
    }
}

extension WALRingWriter: @unchecked Sendable {}
