import Foundation
import Testing
@testable import WaxCore

// MARK: - Helpers

/// Creates a writable WAL file, runs `body`, returns the result.
private func withWritableWalFile<T>(
    walSize: UInt64,
    fileSize: UInt64? = nil,
    body: (FDFile, WALRingWriter, WALRingReader) throws -> T
) throws -> T {
    try TempFiles.withTempFile { url in
        let actual = fileSize ?? walSize * 2
        let file = try FDFile.create(at: url)
        try file.truncate(to: actual)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        return try body(file, writer, reader)
    }
}

/// Encodes a minimal valid WALEntry payload.
private func deletePayload(frameId: UInt64) throws -> Data {
    try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: frameId)))
}

// MARK: - isTerminalMarker

@Test func walRingReaderIsTerminalMarkerWalSizeZeroAlwaysTrue() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        // walSize == 0: every cursor is considered terminal.
        #expect(try reader.isTerminalMarker(at: 0) == true)
        #expect(try reader.isTerminalMarker(at: 100) == true)
    }
}

@Test func walRingReaderIsTerminalMarkerRemainingTooSmall() throws {
    // When (walSize - cursor % walSize) < headerSize, returns false.
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize)
        defer { try? file.close() }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        // Put cursor at walSize - (headerSize - 1): remaining < headerSize.
        let headerSize = UInt64(WALRecord.headerSize)
        let tinyRemaining = headerSize - 1
        let cursor = walSize - tinyRemaining
        #expect(try reader.isTerminalMarker(at: cursor) == false)
    }
}

@Test func walRingReaderIsTerminalMarkerAtSentinelIsTrue() throws {
    try withWritableWalFile(walSize: 512) { _, writer, reader in
        let payload = try deletePayload(frameId: 1)
        _ = try writer.append(payload: payload)
        // writePos points at the sentinel the writer left behind.
        #expect(try reader.isTerminalMarker(at: writer.writePos) == true)
    }
}

@Test func walRingReaderIsTerminalMarkerAtDataRecordIsFalse() throws {
    try withWritableWalFile(walSize: 512) { _, writer, reader in
        let payload = try deletePayload(frameId: 2)
        _ = try writer.append(payload: payload)
        // Offset 0 is where the first record starts – not a terminal marker.
        #expect(try reader.isTerminalMarker(at: 0) == false)
    }
}

@Test func walRingReaderIsTerminalMarkerAtZeroedBytesIsTrue() throws {
    // An all-zero header is treated as a sentinel (sequence == 0).
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize)
        defer { try? file.close() }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        // The file is all zeroes; the header at offset 0 has sequence == 0 → terminal.
        #expect(try reader.isTerminalMarker(at: 0) == true)
    }
}

@Test func walRingReaderIsTerminalMarkerNormalizesLargeCursor() throws {
    // cursor > walSize: it should be normalised to cursor % walSize.
    try withWritableWalFile(walSize: 512) { _, writer, reader in
        let payload = try deletePayload(frameId: 5)
        _ = try writer.append(payload: payload)
        let wp = writer.writePos
        // cursor = writePos + walSize resolves to the same position via %.
        #expect(try reader.isTerminalMarker(at: wp + 512) == true)
    }
}

// MARK: - scanState

@Test func walRingReaderScanStateEmptyWal() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 0)
        #expect(state.writePos == 0)
        #expect(state.pendingBytes == 0)
    }
}

@Test func walRingReaderScanStateSingleRecord() throws {
    try withWritableWalFile(walSize: 512) { _, writer, reader in
        let payload = try deletePayload(frameId: 10)
        _ = try writer.append(payload: payload)
        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 1)
        #expect(state.writePos == writer.writePos)
    }
}

@Test func walRingReaderScanStateStopsAtSentinel() throws {
    try withWritableWalFile(walSize: 1024) { _, writer, reader in
        for i in 1...3 {
            _ = try writer.append(payload: try deletePayload(frameId: UInt64(i)))
        }
        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 3)
        // writePos should equal what the writer reports.
        #expect(state.writePos == writer.writePos)
    }
}

@Test func walRingReaderScanStateStopsOnBadPaddingChecksum() throws {
    // A padding record with an invalid checksum should halt scanning.
    try withWritableWalFile(walSize: 512) { file, writer, reader in
        let payload = try deletePayload(frameId: 20)
        _ = try writer.append(payload: payload)
        let afterRecord = writer.writePos

        // Write a fake padding header with a bad checksum at afterRecord.
        let badChecksum = Data(repeating: 0xFF, count: WALRecord.checksumSize)
        let paddingHeader = WALRecordHeader(
            sequence: 2,
            length: 0,
            flags: .isPadding,
            checksum: badChecksum
        )
        try file.writeAll(try paddingHeader.encode(), at: afterRecord)

        let state = try reader.scanState(from: 0)
        // Must stop before the corrupt padding; lastSequence is still 1.
        #expect(state.lastSequence == 1)
    }
}

@Test func walRingReaderScanStateStopsOnPaddingExceedingWalSize() throws {
    // A padding record whose advance would exceed walSize should halt scanning.
    try withWritableWalFile(walSize: 512) { file, writer, reader in
        _ = try writer.append(payload: try deletePayload(frameId: 30))
        let afterRecord = writer.writePos

        // Create a padding record claiming to skip more bytes than the WAL.
        let paddingRecord = WALRecord.padding(sequence: 2, skipBytes: UInt32(600))
        try file.writeAll(try paddingRecord.encode(), at: afterRecord)

        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 1)
    }
}

@Test func walRingReaderScanStateWrapsAroundRing() throws {
    // Write enough records to wrap the ring, then verify scanState reflects them all.
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize * 2)
        defer { try? file.close() }

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        _ = try writer.append(payload: try deletePayload(frameId: 1))
        _ = try writer.append(payload: try deletePayload(frameId: 2))
        writer.recordCheckpoint()
        // These may force a wrap-around.
        _ = try writer.append(payload: try deletePayload(frameId: 3))
        _ = try writer.append(payload: try deletePayload(frameId: 4))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let state = try reader.scanState(from: writer.checkpointPos)
        #expect(state.lastSequence >= 3)
        #expect(state.writePos == writer.writePos)
    }
}

@Test func walRingReaderScanStateStopsOnZeroPayloadLength() throws {
    // A data record with length == 0 should stop scanning.
    try withWritableWalFile(walSize: 512) { file, writer, reader in
        _ = try writer.append(payload: try deletePayload(frameId: 40))
        let afterRecord = writer.writePos

        // Write a header claiming sequence=2, length=0 (invalid data record).
        let zeroLenChecksum = SHA256Checksum.digest(Data()) // some checksum
        let header = WALRecordHeader(
            sequence: 2,
            length: 0,
            flags: [],
            checksum: zeroLenChecksum
        )
        try file.writeAll(try header.encode(), at: afterRecord)

        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 1)
    }
}

@Test func walRingReaderScanStateStopsOnChecksumMismatch() throws {
    // A data record with a mismatched payload checksum should stop scanning.
    try withWritableWalFile(walSize: 512) { file, writer, reader in
        _ = try writer.append(payload: try deletePayload(frameId: 50))
        let afterRecord = writer.writePos

        // Build a record whose checksum does not match its payload.
        let payload = Data(repeating: 0x42, count: 10)
        let wrongChecksum = Data(repeating: 0x00, count: WALRecord.checksumSize)
        let header = WALRecordHeader(
            sequence: 2,
            length: UInt32(payload.count),
            flags: [],
            checksum: wrongChecksum
        )
        var rawRecord = try header.encode()
        rawRecord.append(payload)
        try file.writeAll(rawRecord, at: afterRecord)

        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 1)
    }
}

// MARK: - scanRecords

@Test func walRingReaderScanRecordsEmptyWal() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.isEmpty)
    }
}

@Test func walRingReaderScanRecordsSkipsCommittedSequences() throws {
    try withWritableWalFile(walSize: 512) { _, writer, reader in
        _ = try writer.append(payload: try deletePayload(frameId: 1))
        _ = try writer.append(payload: try deletePayload(frameId: 2))
        _ = try writer.append(payload: try deletePayload(frameId: 3))

        // committedSeq=2: only record with sequence 3 is "pending".
        let records = try reader.scanRecords(from: 0, committedSeq: 2)
        #expect(records.count == 1)
        #expect(records[0].record.sequence == 3)
    }
}

@Test func walRingReaderScanRecordsHandlesPaddingRecord() throws {
    // Force a padding record by writing to a small WAL that requires wrap-padding,
    // then verify scanRecords does not include the padding in results.
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize * 2)
        defer { try? file.close() }

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        // Fill enough to approach the boundary.
        _ = try writer.append(payload: Data(repeating: 0xAA, count: 40))
        _ = try writer.append(payload: Data(repeating: 0xBB, count: 40))
        writer.recordCheckpoint()
        // A third append forces padding + wrap if there is not enough room.
        _ = try writer.append(payload: Data(repeating: 0xCC, count: 40))
        _ = try writer.append(payload: Data(repeating: 0xDD, count: 40))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let records = try reader.scanRecords(from: writer.checkpointPos, committedSeq: 0)
        // Padding records must not appear in results; only data records.
        for loc in records {
            if case .padding = loc.record {
                #expect(Bool(false))
            }
        }
        #expect(records.count >= 1)
    }
}

@Test func walRingReaderScanRecordsStopsOnOutOfOrderSequence() throws {
    // When a record's sequence <= lastSequence, scanning stops.
    try withWritableWalFile(walSize: 512) { file, writer, reader in
        _ = try writer.append(payload: try deletePayload(frameId: 1))
        let afterRecord1 = writer.writePos

        // Write a record with a lower sequence number (out of order).
        let payload2 = try deletePayload(frameId: 2)
        let checksum2 = SHA256Checksum.digest(payload2)
        let header2 = WALRecordHeader(
            sequence: 1, // same as first record → out of order
            length: UInt32(payload2.count),
            flags: [],
            checksum: checksum2
        )
        var raw2 = try header2.encode()
        raw2.append(payload2)
        try file.writeAll(raw2, at: afterRecord1)

        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.count == 1)
    }
}

// MARK: - scanPendingMutations

@Test func walRingReaderScanPendingMutationsEmptyWal() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let mutations = try reader.scanPendingMutations(from: 0, committedSeq: 0)
        #expect(mutations.isEmpty)
    }
}

@Test func walRingReaderScanPendingMutationsFiltersCommitted() throws {
    try withWritableWalFile(walSize: 1024) { _, writer, reader in
        for i in 1...5 {
            _ = try writer.append(payload: try deletePayload(frameId: UInt64(i)))
        }
        // Sequences 1..3 are committed; only 4 and 5 are pending.
        let mutations = try reader.scanPendingMutations(from: 0, committedSeq: 3)
        #expect(mutations.count == 2)
        #expect(mutations.map(\.sequence) == [4, 5])
    }
}

@Test func walRingReaderScanPendingMutationsRethrowsDecodeError() throws {
    try withWritableWalFile(walSize: 1024) { _, writer, reader in
        // Append a record with an invalid WALEntry opcode (scanPendingMutations re-throws).
        _ = try writer.append(payload: Data([0xFF]))
        #expect(throws: WaxError.self) {
            _ = try reader.scanPendingMutations(from: 0, committedSeq: 0)
        }
    }
}

// MARK: - scanPendingMutationsWithState

@Test func walRingReaderScanPendingMutationsWithStateEmptyWal() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let result = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
        #expect(result.pendingMutations.isEmpty)
        #expect(result.state.lastSequence == 0)
        #expect(result.state.writePos == 0)
        #expect(result.state.pendingBytes == 0)
    }
}

@Test func walRingReaderScanPendingMutationsWithStateMatchesIndividualScans() throws {
    try withWritableWalFile(walSize: 1024) { _, writer, reader in
        for i in 1...4 {
            _ = try writer.append(payload: try deletePayload(frameId: UInt64(i)))
        }
        let committed: UInt64 = 2
        let legacyPending = try reader.scanPendingMutations(from: 0, committedSeq: committed)
        let legacyState = try reader.scanState(from: 0)
        let combined = try reader.scanPendingMutationsWithState(from: 0, committedSeq: committed)

        #expect(combined.pendingMutations == legacyPending)
        #expect(combined.state == legacyState)
    }
}

@Test func walRingReaderScanPendingMutationsWithStateStopsCollectingOnDecodeFailure() throws {
    // A valid WAL envelope carrying an invalid WALEntry opcode:
    // - Collection of pending mutations stops at the bad record.
    // - The state scan continues to the end of the ring.
    try withWritableWalFile(walSize: 2048) { _, writer, reader in
        _ = try writer.append(payload: Data([0xFF])) // invalid opcode
        _ = try writer.append(payload: try deletePayload(frameId: 1))
        _ = try writer.append(payload: try deletePayload(frameId: 2))

        let result = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
        // No pending mutations because decoding stops at the first invalid entry.
        #expect(result.pendingMutations.isEmpty)
        // But state scan advances past all three records.
        #expect(result.state.lastSequence == 3)
    }
}

@Test func walRingReaderScanPendingMutationsWithStateHandlesWrappedRing() throws {
    // Write records that cross the ring boundary; verify the combined scan handles wrap.
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize * 2)
        defer { try? file.close() }

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        _ = try writer.append(payload: try deletePayload(frameId: 1))
        _ = try writer.append(payload: try deletePayload(frameId: 2))
        writer.recordCheckpoint()
        _ = try writer.append(payload: try deletePayload(frameId: 3))
        _ = try writer.append(payload: try deletePayload(frameId: 4))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let result = try reader.scanPendingMutationsWithState(
            from: writer.checkpointPos,
            committedSeq: 0
        )

        // Both pending records (after checkpoint) should be collected.
        let seqs = result.pendingMutations.map(\.sequence)
        #expect(seqs.contains(3) || seqs.contains(4))
        #expect(result.state.writePos == writer.writePos)
    }
}

@Test func walRingReaderScanPendingMutationsWithStatePaddingAccountedInPendingBytes() throws {
    // Padding records should advance pendingBytes even in the combined scan.
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize * 2)
        defer { try? file.close() }

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        _ = try writer.append(payload: Data(repeating: 0xAA, count: 40))
        _ = try writer.append(payload: Data(repeating: 0xBB, count: 40))
        writer.recordCheckpoint()
        _ = try writer.append(payload: Data(repeating: 0xCC, count: 40))
        _ = try writer.append(payload: Data(repeating: 0xDD, count: 40))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let legacyState = try reader.scanState(from: writer.checkpointPos)
        let result = try reader.scanPendingMutationsWithState(
            from: writer.checkpointPos,
            committedSeq: 0
        )
        // pendingBytes should match the legacy scanState result.
        #expect(result.state.pendingBytes == legacyState.pendingBytes)
    }
}

@Test func walRingReaderScanPendingMutationsWithStateStopsOnBadPaddingChecksum() throws {
    // A padding record with the wrong checksum must halt the scan.
    try withWritableWalFile(walSize: 512) { file, writer, reader in
        _ = try writer.append(payload: try deletePayload(frameId: 60))
        let afterRecord = writer.writePos

        let badChecksum = Data(repeating: 0xFF, count: WALRecord.checksumSize)
        let paddingHeader = WALRecordHeader(
            sequence: 2,
            length: 0,
            flags: .isPadding,
            checksum: badChecksum
        )
        try file.writeAll(try paddingHeader.encode(), at: afterRecord)

        let result = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
        // Scan must not include the corrupt padding or anything after it.
        #expect(result.state.lastSequence == 1)
    }
}

@Test func walRingReaderScanPendingMutationsWithStateStopsOnPaddingOverflow() throws {
    // Padding record claiming to skip past the end of the WAL halts scanning.
    try withWritableWalFile(walSize: 512) { file, writer, reader in
        _ = try writer.append(payload: try deletePayload(frameId: 70))
        let afterRecord = writer.writePos

        let paddingRecord = WALRecord.padding(sequence: 2, skipBytes: UInt32(600))
        try file.writeAll(try paddingRecord.encode(), at: afterRecord)

        let result = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
        #expect(result.state.lastSequence == 1)
    }
}
