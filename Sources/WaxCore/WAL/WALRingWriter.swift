import Foundation

public enum WALFsyncPolicy: Sendable, Equatable {
    case always
    case onCommit
    case everyBytes(UInt64)
}

public final class WALRingWriter {
    private let file: FDFile
    public let walOffset: UInt64
    public let walSize: UInt64
    private let fsyncPolicy: WALFsyncPolicy

    public private(set) var writePos: UInt64
    public private(set) var checkpointPos: UInt64
    public private(set) var pendingBytes: UInt64
    public private(set) var lastSequence: UInt64
    private var bytesSinceFsync: UInt64

    public init(
        file: FDFile,
        walOffset: UInt64,
        walSize: UInt64,
        writePos: UInt64 = 0,
        checkpointPos: UInt64 = 0,
        pendingBytes: UInt64 = 0,
        lastSequence: UInt64 = 0,
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
        self.bytesSinceFsync = 0
    }

    @discardableResult
    public func append(payload: Data, flags: WALFlags = []) throws -> UInt64 {
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

        remaining = walSize - writePos
        if remaining < headerSize {
            if remaining > 0 {
                let zeroTail = Data(repeating: 0, count: Int(remaining))
                try file.writeAll(zeroTail, at: walOffset + writePos)
                pendingBytes += remaining
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
            try file.writeAll(paddingData, at: walOffset + writePos)
            lastSequence = paddingSequence
            pendingBytes += remaining
            writePos = 0
        }

        let sequence = lastSequence &+ 1
        let record = WALRecord.data(sequence: sequence, flags: flags, payload: payload)
        let recordData = try record.encode()
        try file.writeAll(recordData, at: walOffset + writePos)

        lastSequence = sequence
        pendingBytes += entrySize
        writePos = (writePos + entrySize) % walSize

        try writeSentinel()
        bytesSinceFsync &+= totalNeeded
        try maybeFsync()
        return sequence
    }

    /// Append multiple payloads in a single pass, reusing padding and wrap calculations.
    /// Returns the sequence numbers for the appended data records (padding records are excluded).
    public func appendBatch(payloads: [Data], flags: WALFlags = []) throws -> [UInt64] {
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

        for op in operations {
            try file.writeAll(op.bytes, at: op.offset)
        }

        lastSequence = localLastSequence
        pendingBytes = localPendingBytes
        writePos = localWritePos
        bytesSinceFsync &+= totalWritten

        try writeSentinel()
        try maybeFsync()
        return sequences
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

    public func recordCheckpoint() {
        checkpointPos = writePos
        pendingBytes = 0
        bytesSinceFsync = 0
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
                try file.writeAll(zeroTail, at: walOffset + writePos)
                pendingBytes += remaining
            }
            writePos = 0
            remaining = walSize
        }

        if pendingBytes >= walSize {
            return
        }

        let sentinel = Data(repeating: 0, count: WALRecord.headerSize)
        try file.writeAll(sentinel, at: walOffset + writePos)
    }
}

extension WALRingWriter: @unchecked Sendable {}
