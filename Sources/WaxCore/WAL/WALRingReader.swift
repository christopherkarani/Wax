import Foundation

public struct WALRecordLocation: Equatable, Sendable {
    public var offset: UInt64
    public var record: WALRecord

    public init(offset: UInt64, record: WALRecord) {
        self.offset = offset
        self.record = record
    }
}

public struct WALScanState: Equatable, Sendable {
    public var lastSequence: UInt64
    public var writePos: UInt64
    public var pendingBytes: UInt64

    public init(lastSequence: UInt64, writePos: UInt64, pendingBytes: UInt64) {
        self.lastSequence = lastSequence
        self.writePos = writePos
        self.pendingBytes = pendingBytes
    }
}

public struct WALPendingScanResult: Equatable, Sendable {
    public var pendingMutations: [PendingMutation]
    public var state: WALScanState

    public init(pendingMutations: [PendingMutation], state: WALScanState) {
        self.pendingMutations = pendingMutations
        self.state = state
    }
}

public final class WALRingReader {
    private let file: FDFile
    public let walOffset: UInt64
    public let walSize: UInt64

    public init(file: FDFile, walOffset: UInt64, walSize: UInt64) {
        self.file = file
        self.walOffset = walOffset
        self.walSize = walSize
    }

    /// Checks whether the persisted cursor currently points at a terminal marker.
    ///
    /// A `true` result means open can safely treat WAL replay as empty from this cursor.
    public func isTerminalMarker(at cursor: UInt64) throws -> Bool {
        guard walSize > 0 else { return true }
        let normalized = cursor % walSize
        let remaining = walSize - normalized
        guard remaining >= UInt64(WALRecord.headerSize) else { return false }

        let headerData = try file.readExactly(length: WALRecord.headerSize, at: walOffset + normalized)
        let header: WALRecordHeader
        do {
            header = try WALRecordHeader.decode(from: headerData, offset: normalized)
        } catch let error as WaxError {
            if case .walCorruption = error { return false }
            throw error
        } catch {
            throw error
        }
        return header.isSentinel || header.sequence == 0
    }

    public func scanRecords(from checkpointPos: UInt64, committedSeq: UInt64) throws -> [WALRecordLocation] {
        return try scanInternal(from: checkpointPos, committedSeq: committedSeq) { offset, header, payload in
            let record = WALRecord.data(sequence: header.sequence, flags: header.flags, payload: payload)
            return WALRecordLocation(offset: offset, record: record)
        }
    }

    public func scanPendingMutations(from checkpointPos: UInt64, committedSeq: UInt64) throws -> [PendingMutation] {
        return try scanInternal(from: checkpointPos, committedSeq: committedSeq) { offset, header, payload in
            let entry = try WALEntryCodec.decode(payload, offset: offset)
            return PendingMutation(sequence: header.sequence, entry: entry)
        }
    }

    public func scanPendingMutationsWithState(from checkpointPos: UInt64, committedSeq: UInt64) throws -> WALPendingScanResult {
        guard walSize > 0 else {
            return WALPendingScanResult(
                pendingMutations: [],
                state: WALScanState(lastSequence: 0, writePos: 0, pendingBytes: 0)
            )
        }

        let start = checkpointPos % walSize
        var cursor = start
        var lastSequence: UInt64 = 0
        var pendingBytes: UInt64 = 0
        var wrapped = false
        var pendingMutations: [PendingMutation] = []
        // When a pending-entry decode error occurs we stop collecting pending mutations
        // but continue advancing the cursor so writePos/pendingBytes remain accurate
        // for WAL recovery position tracking. This preserves the old open behavior:
        // a corrupt pending entry does not prevent the state-position scan from reaching
        // the true end of the ring.
        var stopDecodingPendingMutations = false

        while true {
            let remaining = walSize - cursor
            if remaining < UInt64(WALRecord.headerSize) {
                if wrapped { break }
                pendingBytes += remaining
                cursor = 0
                wrapped = true
                if cursor == start { break }
                continue
            }

            let headerData = try file.readExactly(length: WALRecord.headerSize, at: walOffset + cursor)
            let header: WALRecordHeader
            do {
                header = try WALRecordHeader.decode(from: headerData, offset: cursor)
            } catch let error as WaxError {
                if case .walCorruption = error { break }
                throw error
            } catch {
                throw error
            }

            if header.isSentinel || header.sequence == 0 {
                break
            }

            if lastSequence != 0 && header.sequence <= lastSequence {
                break
            }

            if header.flags.contains(.isPadding) {
                if header.checksum != WALRecord.paddingChecksum {
                    break
                }
                let skipBytes = UInt64(header.length)
                let advance = UInt64(WALRecord.headerSize) + skipBytes
                if cursor + advance > walSize {
                    break
                }
                cursor = (cursor + advance) % walSize
                pendingBytes += advance
                lastSequence = header.sequence
                if cursor == 0 { wrapped = true }
                if cursor == start { break }
                continue
            }

            let payloadLen = UInt64(header.length)
            if payloadLen == 0 { break }

            let maxPayload = walSize >= UInt64(WALRecord.headerSize) ? walSize - UInt64(WALRecord.headerSize) : 0
            if payloadLen > maxPayload { break }
            if payloadLen > remaining - UInt64(WALRecord.headerSize) { break }
            if payloadLen > UInt64(Int.max) { break }

            let payloadOffset = cursor + UInt64(WALRecord.headerSize)
            let payload = try file.readExactly(length: Int(payloadLen), at: walOffset + payloadOffset)
            let computed = SHA256Checksum.digest(payload)
            if computed != header.checksum {
                break
            }

            if header.sequence > committedSeq && !stopDecodingPendingMutations {
                do {
                    let entry = try WALEntryCodec.decode(payload, offset: cursor)
                    pendingMutations.append(PendingMutation(sequence: header.sequence, entry: entry))
                } catch {
                    // Treat decode failure as corruption for this pending entry: stop collecting
                    // mutations but continue the state-position scan so writePos/pendingBytes
                    // remain accurate. A mid-ring corrupt pending entry is non-fatal for
                    // position tracking.
                    stopDecodingPendingMutations = true
                }
            }

            let advance = UInt64(WALRecord.headerSize) + payloadLen
            cursor = cursor + advance
            if cursor == walSize {
                cursor = 0
                wrapped = true
            }
            pendingBytes += advance
            lastSequence = header.sequence
            if cursor == start { break }
        }

        let state = WALScanState(lastSequence: lastSequence, writePos: cursor, pendingBytes: pendingBytes)
        return WALPendingScanResult(pendingMutations: pendingMutations, state: state)
    }

    public func scanState(from checkpointPos: UInt64) throws -> WALScanState {
        guard walSize > 0 else { return WALScanState(lastSequence: 0, writePos: 0, pendingBytes: 0) }

        let start = checkpointPos % walSize
        var cursor = start
        var lastSequence: UInt64 = 0
        var pendingBytes: UInt64 = 0
        var wrapped = false

        while true {
            let remaining = walSize - cursor
            if remaining < UInt64(WALRecord.headerSize) {
                if wrapped { break }
                pendingBytes += remaining
                cursor = 0
                wrapped = true
                if cursor == start { break }
                continue
            }

            let headerData = try file.readExactly(length: WALRecord.headerSize, at: walOffset + cursor)
            let header: WALRecordHeader
            do {
                header = try WALRecordHeader.decode(from: headerData, offset: cursor)
            } catch let error as WaxError {
                if case .walCorruption = error { break }
                throw error
            } catch {
                throw error
            }

            if header.isSentinel || header.sequence == 0 {
                break
            }

            if lastSequence != 0 && header.sequence <= lastSequence {
                break
            }

            if header.flags.contains(.isPadding) {
                if header.checksum != WALRecord.paddingChecksum {
                    break
                }
                let skipBytes = UInt64(header.length)
                let advance = UInt64(WALRecord.headerSize) + skipBytes
                if cursor + advance > walSize {
                    break
                }
                cursor = (cursor + advance) % walSize
                pendingBytes += advance
                lastSequence = header.sequence
                if cursor == 0 { wrapped = true }
                if cursor == start { break }
                continue
            }

            let payloadLen = UInt64(header.length)
            if payloadLen == 0 { break }

            let maxPayload = walSize >= UInt64(WALRecord.headerSize) ? walSize - UInt64(WALRecord.headerSize) : 0
            if payloadLen > maxPayload { break }
            if payloadLen > remaining - UInt64(WALRecord.headerSize) { break }
            if payloadLen > UInt64(Int.max) { break }

            let payload = try file.readExactly(length: Int(payloadLen), at: walOffset + cursor + UInt64(WALRecord.headerSize))
            let computed = SHA256Checksum.digest(payload)
            if computed != header.checksum { break }

            let advance = UInt64(WALRecord.headerSize) + payloadLen
            cursor = cursor + advance
            if cursor == walSize {
                cursor = 0
                wrapped = true
            }
            pendingBytes += advance
            lastSequence = header.sequence
            if cursor == start { break }
        }

        return WALScanState(lastSequence: lastSequence, writePos: cursor, pendingBytes: pendingBytes)
    }

    private func scanInternal<T>(
        from checkpointPos: UInt64,
        committedSeq: UInt64,
        decode: (UInt64, WALRecordHeader, Data) throws -> T
    ) throws -> [T] {
        guard walSize > 0 else { return [] }

        let start = checkpointPos % walSize
        var cursor = start
        var results: [T] = []
        var wrapped = false
        var lastSequence: UInt64 = 0

        while true {
            let remaining = walSize - cursor
            if remaining < UInt64(WALRecord.headerSize) {
                if wrapped { break }
                cursor = 0
                wrapped = true
                if cursor == start { break }
                continue
            }

            let headerData = try file.readExactly(length: WALRecord.headerSize, at: walOffset + cursor)
            let header: WALRecordHeader
            do {
                header = try WALRecordHeader.decode(from: headerData, offset: cursor)
            } catch let error as WaxError {
                if case .walCorruption = error { break }
                throw error
            } catch {
                throw error
            }

            if header.isSentinel {
                break
            }

            if header.sequence == 0 {
                break
            }

            if lastSequence != 0 && header.sequence <= lastSequence {
                break
            }

            if header.flags.contains(.isPadding) {
                if header.checksum != WALRecord.paddingChecksum {
                    break
                }
                let skipBytes = UInt64(header.length)
                let advance = UInt64(WALRecord.headerSize) + skipBytes
                if cursor + advance > walSize {
                    break
                }
                cursor = (cursor + advance) % walSize
                lastSequence = header.sequence
                if cursor == 0 { wrapped = true }
                if cursor == start { break }
                continue
            }

            let payloadLen = UInt64(header.length)
            if payloadLen == 0 { break }

            let maxPayload = walSize >= UInt64(WALRecord.headerSize) ? walSize - UInt64(WALRecord.headerSize) : 0
            if payloadLen > maxPayload { break }
            if payloadLen > remaining - UInt64(WALRecord.headerSize) { break }
            if payloadLen > UInt64(Int.max) { break }

            let payload = try file.readExactly(length: Int(payloadLen), at: walOffset + cursor + UInt64(WALRecord.headerSize))
            let computed = SHA256Checksum.digest(payload)
            if computed != header.checksum {
                break
            }

            if header.sequence > committedSeq {
                do {
                    results.append(try decode(cursor, header, payload))
                } catch {
                    break
                }
            }

            cursor = cursor + UInt64(WALRecord.headerSize) + payloadLen
            if cursor == walSize {
                cursor = 0
                wrapped = true
            }
            lastSequence = header.sequence
            if cursor == start { break }
        }

        return results
    }
}
