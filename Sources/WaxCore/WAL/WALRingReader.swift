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
    /// Ring-relative offset of each entry in `pendingMutations`.
    package var pendingOffsets: [UInt64]
    /// Ring-relative offset of every record in the valid chain (data and padding), in chain order.
    package var recordOffsets: [UInt64]

    package init(
        pendingMutations: [PendingMutation],
        state: WALScanState,
        pendingOffsets: [UInt64] = [],
        recordOffsets: [UInt64] = []
    ) {
        self.pendingMutations = pendingMutations
        self.state = state
        self.pendingOffsets = pendingOffsets
        self.recordOffsets = recordOffsets
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
            guard header.sequence > committedSeq else { return }
            let record = WALRecord.data(sequence: header.sequence, flags: header.flags, payload: payload)
            locations.append(WALRecordLocation(offset: offset, record: record))
        }
        return locations
    }

    package func scanPendingMutations(from checkpointPos: UInt64, committedSeq: UInt64) throws -> [PendingMutation] {
        try scanPendingMutationsWithState(from: checkpointPos, committedSeq: committedSeq).pendingMutations
    }

    /// Scans pending (`sequence > committedSeq`) mutations, their ring offsets, and the ring
    /// state after the whole valid chain.
    func scanPendingMutationsWithState(
        from checkpointPos: UInt64,
        committedSeq: UInt64
    ) throws -> WALPendingScanResult {
        var pendingMutations: [PendingMutation] = []
        var pendingOffsets: [UInt64] = []
        var recordOffsets: [UInt64] = []
        let state = try walk(
            from: checkpointPos,
            onRecord: { recordOffsets.append($0) },
            visit: { offset, header, payload in
                guard header.sequence > committedSeq else { return }
                // Do not silently skip checksum-valid but undecodable payloads: a decode failure is a
                // codec invariant violation, not a torn write (torn writes fail the checksum and end the
                // scan earlier), and advancing past it would permanently drop committed mutations.
                let entry = try WALEntryCodec.decode(payload, offset: offset)
                pendingMutations.append(PendingMutation(sequence: header.sequence, entry: entry))
                pendingOffsets.append(offset)
            }
        )
        return WALPendingScanResult(
            pendingMutations: pendingMutations,
            state: state,
            pendingOffsets: pendingOffsets,
            recordOffsets: recordOffsets
        )
    }

    func scanState(from checkpointPos: UInt64) throws -> WALScanState {
        try walk(from: checkpointPos) { _, _, _ in }
    }

    /// Walks the ring from `checkpointPos`, validating each record envelope, and hands every
    /// checksum-valid data record to `visit`. The walk ends at the first sentinel, zero or
    /// non-increasing sequence, torn header/payload/padding, or on returning to the start.
    /// `onRecord` receives the offset of every accepted record, padding included.
    ///
    /// - Returns: The ring state immediately after the last record the walk advanced past.
    private func walk(
        from checkpointPos: UInt64,
        onRecord: (_ offset: UInt64) -> Void = { _ in },
        visit: (_ offset: UInt64, _ header: WALRecordHeader, _ payload: Data) throws -> Void
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

            onRecord(cursor)
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

    /// Validates the record at `offset`, hands data records to `visit`, and returns the ring
    /// bytes the record occupies, or `nil` when it is torn (the walk ends there).
    private func acceptedRecordLength(
        header: WALRecordHeader,
        at offset: UInt64,
        remaining: UInt64,
        visit: (_ offset: UInt64, _ header: WALRecordHeader, _ payload: Data) throws -> Void
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
        try visit(offset, header, payload)
        return headerSize + payloadLen
    }
}
