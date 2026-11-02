import Foundation
struct WALRecordLocation: Equatable, Sendable {
    package var offset: UInt64
    package var record: WALRecord

    package init(offset: UInt64, record: WALRecord) {
        self.offset = offset
        self.record = record
    }
}

struct WALScanState: Equatable, Sendable {
    package var lastSequence: UInt64
    package var writePos: UInt64
    package var pendingBytes: UInt64

    package init(lastSequence: UInt64, writePos: UInt64, pendingBytes: UInt64) {
        self.lastSequence = lastSequence
        self.writePos = writePos
        self.pendingBytes = pendingBytes
    }
}

struct WALPendingScanResult: Equatable, Sendable {
    package var pendingMutations: [PendingMutation]
    package var state: WALScanState
    /// True when replay stopped before a pending record the caller declined to replay.
    package var truncated: Bool

    package init(pendingMutations: [PendingMutation], state: WALScanState, truncated: Bool = false) {
        self.pendingMutations = pendingMutations
        self.state = state
        self.truncated = truncated
    }
}

package final class WALRingReader {
    private let file: FDFile
    package let walOffset: UInt64
    package let walSize: UInt64

    package init(file: FDFile, walOffset: UInt64, walSize: UInt64) {
        self.file = file
        self.walOffset = walOffset
        self.walSize = walSize
    }

    /// Checks whether the persisted cursor currently points at a terminal marker.
    ///
    /// A `true` result means package can safely treat WAL replay as empty from this cursor.
    package func isTerminalMarker(at cursor: UInt64) throws -> Bool {
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

    func scanRecords(from checkpointPos: UInt64, committedSeq: UInt64) throws -> [WALRecordLocation] {
        var locations: [WALRecordLocation] = []
        _ = try walk(from: checkpointPos) { offset, header, payload in
            if header.sequence > committedSeq {
                let record = WALRecord.data(sequence: header.sequence, flags: header.flags, payload: payload)
                locations.append(WALRecordLocation(offset: offset, record: record))
            }
            return .replay
        }
        return locations
    }

    package func scanPendingMutations(from checkpointPos: UInt64, committedSeq: UInt64) throws -> [PendingMutation] {
        try scanPendingMutationsWithState(from: checkpointPos, committedSeq: committedSeq).pendingMutations
    }

    /// Scans pending mutations and the ring state that follows them.
    ///
    /// `shouldReplay` is consulted for every pending (`sequence > committedSeq`) mutation in order.
    /// Returning `false` ends replay *before* that record: the returned state points at its offset
    /// so the writer resumes there, and `truncated` is set. Committed records are never offered.
    func scanPendingMutationsWithState(
        from checkpointPos: UInt64,
        committedSeq: UInt64,
        shouldReplay: (PendingMutation) throws -> Bool = { _ in true }
    ) throws -> WALPendingScanResult {
        var pendingMutations: [PendingMutation] = []
        var truncated = false
        let state = try walk(from: checkpointPos) { offset, header, payload in
            guard header.sequence > committedSeq else { return .replay }
            // Do not silently skip checksum-valid but undecodable payloads: a decode failure is a
            // codec invariant violation, not a torn write (torn writes fail the checksum and end the
            // scan earlier), and advancing past it would permanently drop committed mutations.
            let entry = try WALEntryCodec.decode(payload, offset: offset)
            let mutation = PendingMutation(sequence: header.sequence, entry: entry)
            guard try shouldReplay(mutation) else {
                truncated = true
                return .stop
            }
            pendingMutations.append(mutation)
            return .replay
        }
        return WALPendingScanResult(pendingMutations: pendingMutations, state: state, truncated: truncated)
    }

    func scanState(from checkpointPos: UInt64) throws -> WALScanState {
        try walk(from: checkpointPos) { _, _, _ in .replay }
    }

    private enum RecordDecision {
        case replay
        case stop
    }

    /// Walks the ring from `checkpointPos`, validating each record envelope, and hands every
    /// checksum-valid data record to `visit`. The walk ends at the first sentinel, zero or
    /// non-increasing sequence, torn header/payload/padding, or on returning to the start.
    ///
    /// - Returns: The ring state immediately after the last record the walk advanced past.
    private func walk(
        from checkpointPos: UInt64,
        visit: (_ offset: UInt64, _ header: WALRecordHeader, _ payload: Data) throws -> RecordDecision
    ) throws -> WALScanState {
        guard walSize > 0 else { return WALScanState(lastSequence: 0, writePos: 0, pendingBytes: 0) }

        let headerSize = UInt64(WALRecord.headerSize)
        let start = checkpointPos % walSize
        var cursor = start
        var lastSequence: UInt64 = 0
        var pendingBytes: UInt64 = 0
        var wrapped = false

        while true {
            let remaining = walSize - cursor
            if remaining < headerSize {
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
            } catch WaxError.walCorruption {
                break
            }

            if header.isSentinel || header.sequence == 0 { break }
            if lastSequence != 0 && header.sequence <= lastSequence { break }
            guard let advance = try acceptedRecordLength(
                header: header,
                at: cursor,
                remaining: remaining,
                visit: visit
            ) else { break }

            cursor += advance
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

    /// Validates the record at `offset` and returns the ring bytes it occupies,
    /// or `nil` when the record is torn or `visit` declines it (the walk ends there).
    private func acceptedRecordLength(
        header: WALRecordHeader,
        at offset: UInt64,
        remaining: UInt64,
        visit: (_ offset: UInt64, _ header: WALRecordHeader, _ payload: Data) throws -> RecordDecision
    ) throws -> UInt64? {
        let headerSize = UInt64(WALRecord.headerSize)
        if header.flags.contains(.isPadding) {
            // Padding headers carry no payload checksum, so a torn `length` is only detectable by
            // position: the writer always pads exactly to the ring end. Anything else is a torn tail.
            guard header.checksum == WALRecord.paddingChecksum,
                  headerSize + UInt64(header.length) == remaining else { return nil }
            return remaining
        }

        let payloadLen = UInt64(header.length)
        guard payloadLen > 0, payloadLen <= remaining - headerSize, payloadLen <= UInt64(Int.max) else { return nil }
        let payload = try file.readExactly(length: Int(payloadLen), at: walOffset + offset + headerSize)
        guard SHA256Checksum.digest(payload) == header.checksum else { return nil }
        guard try visit(offset, header, payload) == .replay else { return nil }
        return headerSize + payloadLen
    }
}
