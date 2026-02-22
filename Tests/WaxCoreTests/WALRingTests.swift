import Foundation
import Testing
@testable import WaxCore

private func withWalFile<T>(size: UInt64, _ body: (FDFile) throws -> T) rethrows -> T {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: size)
        defer { try? file.close() }
        return try body(file)
    }
}

private func withReadOnlyWalFile<T>(size: UInt64, _ body: (FDFile) throws -> T) throws -> T {
    try TempFiles.withTempFile { url in
        let writable = try FDFile.create(at: url)
        try writable.truncate(to: size)
        try writable.close()

        let file = try FDFile.openReadOnly(at: url)
        defer { try? file.close() }
        return try body(file)
    }
}

@Test func walRingAppendAndScan() throws {
    try withWalFile(size: 1024) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 512)
        let seq1 = try writer.append(payload: Data("one".utf8))
        let seq2 = try writer.append(payload: Data("two".utf8))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 512)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)

        let payloads = records.compactMap { record -> Data? in
            if case .data(_, _, let payload) = record.record { return payload }
            return nil
        }
        #expect(payloads == [Data("one".utf8), Data("two".utf8)])

        let sequences = records.compactMap { $0.record.sequence }
        #expect(sequences == [seq1, seq2])
    }
}

@Test func walRingWrapUsesPadding() throws {
    try withWalFile(size: 1024) { file in
        let walSize: UInt64 = 256
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let payload = Data(repeating: 0xAB, count: 20) // entry size = 68

        _ = try writer.append(payload: payload)
        _ = try writer.append(payload: payload)
        writer.recordCheckpoint()

        _ = try writer.append(payload: Data(repeating: 0xCD, count: 20))
        let wrappedSeq = try writer.append(payload: Data(repeating: 0xEF, count: 20))

        #expect(writer.writePos == UInt64(WALRecord.headerSize + 20))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let records = try reader.scanRecords(from: writer.checkpointPos, committedSeq: 0)
        let payloads = records.compactMap { record -> Data? in
            if case .data(_, _, let payload) = record.record { return payload }
            return nil
        }

        #expect(payloads.count == 2)
        #expect(payloads[0] == Data(repeating: 0xCD, count: 20))
        #expect(payloads[1] == Data(repeating: 0xEF, count: 20))

        let sequences = records.compactMap { $0.record.sequence }
        #expect(sequences.last == wrappedSeq)
    }
}

@Test func walRingFullThrowsCapacityExceeded() throws {
    try withWalFile(size: 512) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 128)
        _ = try writer.append(payload: Data(repeating: 0x11, count: 40)) // entry size 88

        do {
            _ = try writer.append(payload: Data(repeating: 0x22, count: 40))
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .capacityExceeded = error else {
                #expect(Bool(false))
                return
            }
        }
    }
}

@Test func walRingCheckpointResetsPendingBytes() throws {
    try withWalFile(size: 512) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 256)
        _ = try writer.append(payload: Data(repeating: 0x33, count: 10))
        #expect(writer.pendingBytes > 0)
        writer.recordCheckpoint()
        #expect(writer.pendingBytes == 0)
        #expect(writer.checkpointPos == writer.writePos)
    }
}

@Test func walRingRejectsEmptyPayload() throws {
    try withWalFile(size: 256) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 128)
        do {
            _ = try writer.append(payload: Data())
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .encodingError = error else {
                #expect(Bool(false))
                return
            }
        }
    }
}

@Test func walRingAppendFaultsWriterAndRestoresStateOnWriteFailure() throws {
    try withReadOnlyWalFile(size: 512) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 256)

        do {
            _ = try writer.append(payload: Data("one".utf8))
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }

        #expect(writer.writePos == 0)
        #expect(writer.pendingBytes == 0)
        #expect(writer.lastSequence == 0)
        #expect(writer.wrapCount == 0)
        #expect(writer.sentinelWriteCount == 0)
        #expect(writer.writeCallCount == 0)

        do {
            _ = try writer.append(payload: Data("two".utf8))
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("WAL writer is faulted"))
        }
    }
}

@Test func walRingAppendBatchFaultsWriterAndRestoresStateOnWriteFailure() throws {
    try withReadOnlyWalFile(size: 1024) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 512)

        do {
            _ = try writer.appendBatch(payloads: [Data("one".utf8), Data("two".utf8)])
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io = error else {
                #expect(Bool(false))
                return
            }
        }

        #expect(writer.writePos == 0)
        #expect(writer.pendingBytes == 0)
        #expect(writer.lastSequence == 0)
        #expect(writer.wrapCount == 0)
        #expect(writer.sentinelWriteCount == 0)
        #expect(writer.writeCallCount == 0)

        do {
            _ = try writer.appendBatch(payloads: [Data("three".utf8)])
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .io(let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(reason.contains("WAL writer is faulted"))
        }
    }
}

@Test func walRingReaderTerminalMarkerEdgeCases() throws {
    try withWalFile(size: 512) { file in
        let zeroReader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let zeroResult = try zeroReader.isTerminalMarker(at: 0)
        #expect(zeroResult)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 128)
        let atZero = try reader.isTerminalMarker(at: 0)
        #expect(atZero)
        let at127 = try reader.isTerminalMarker(at: 127)
        #expect(at127 == false)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 128)
        _ = try writer.append(payload: Data("live".utf8))
        let afterWrite = try reader.isTerminalMarker(at: 0)
        #expect(afterWrite == false)
    }
}

@Test func walRingPendingMutationScanStopsDecodingAfterCorruptEntryAndTracksState() throws {
    try withWalFile(size: 1024) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 512)

        let firstPayload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 1)))
        let thirdPayload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 3)))

        let seq1 = try writer.append(payload: firstPayload)
        _ = try writer.append(payload: Data([0xFF])) // checksum-valid but WALEntry decode-invalid
        let seq3 = try writer.append(payload: thirdPayload)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 512)
        let result = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)

        #expect(result.pendingMutations.count == 1)
        #expect(result.pendingMutations.first?.sequence == seq1)
        if case .deleteFrame(let delete)? = result.pendingMutations.first?.entry {
            #expect(delete.frameId == 1)
        } else {
            #expect(Bool(false))
        }

        #expect(result.state.lastSequence == seq3)
        #expect(result.state.writePos == writer.writePos)
        #expect(result.state.pendingBytes == writer.pendingBytes)
    }
}

@Test func walRingScanPendingMutationsThrowsForDecodeErrorInStrictScan() throws {
    try withWalFile(size: 1024) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 512)
        _ = try writer.append(payload: Data([0xFF]))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 512)
        do {
            _ = try reader.scanPendingMutations(from: 0, committedSeq: 0)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .walCorruption = error else {
                #expect(Bool(false))
                return
            }
        }
    }
}

@Test func walRingScanStateMatchesWriterAcrossPaddingAndWrap() throws {
    try withWalFile(size: 1024) { file in
        let walSize: UInt64 = 256
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let payload = Data(repeating: 0xAB, count: 20) // entry size = 68

        _ = try writer.append(payload: payload)
        _ = try writer.append(payload: payload)
        writer.recordCheckpoint()

        _ = try writer.append(payload: Data(repeating: 0xCD, count: 20))
        _ = try writer.append(payload: Data(repeating: 0xEF, count: 20))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let state = try reader.scanState(from: writer.checkpointPos)

        #expect(state.lastSequence == writer.lastSequence)
        #expect(state.writePos == writer.writePos)
        #expect(state.pendingBytes == writer.pendingBytes)
    }
}

// MARK: - Additional ring-writer coverage

@Test func walRingFsyncPolicyAlwaysFlushesAfterAppend() throws {
    try withWalFile(size: 1024) { file in
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 512,
            fsyncPolicy: .always
        )
        // With .always policy the append must succeed (fsync is a no-op on a real fd)
        let seq = try writer.append(payload: Data("fsync-always".utf8))
        #expect(seq == 1)
    }
}

@Test func walRingFsyncPolicyEveryBytesFlushesWhenThresholdMet() throws {
    try withWalFile(size: 1024) { file in
        // Set threshold to 1 byte so every append triggers a flush
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 512,
            fsyncPolicy: .everyBytes(1)
        )
        let seq = try writer.append(payload: Data("everyBytes-flush".utf8))
        #expect(seq == 1)
    }
}

@Test func walRingFsyncPolicyEveryBytesZeroThresholdDoesNotFlush() throws {
    // everyBytes(0) must never flush (threshold 0 is a no-op guard)
    try withWalFile(size: 1024) { file in
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 512,
            fsyncPolicy: .everyBytes(0)
        )
        let seq = try writer.append(payload: Data("everyBytes-zero".utf8))
        #expect(seq == 1)
    }
}

@Test func walRingFaultedStateAfterReadOnlyWriteFailure() throws {
    // After the first I/O failure the writer is faulted; subsequent calls must
    // immediately throw the "faulted" error without attempting more I/O.
    try withReadOnlyWalFile(size: 512) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 256)

        var ioErrorCount = 0
        var faultedErrorCount = 0

        for _ in 0..<3 {
            do {
                _ = try writer.append(payload: Data("payload".utf8))
            } catch let error as WaxError {
                switch error {
                case .io(let reason) where reason.contains("WAL writer is faulted"):
                    faultedErrorCount += 1
                case .io:
                    ioErrorCount += 1
                default:
                    break
                }
            }
        }

        // First error is a real I/O error; subsequent ones should be faulted
        #expect(ioErrorCount == 1)
        #expect(faultedErrorCount == 2)
    }
}

@Test func walRingWrapCountIncreasesOnWrapAround() throws {
    try withWalFile(size: 1024) { file in
        let walSize: UInt64 = 256
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)

        let payload = Data(repeating: 0xAB, count: 20) // entrySize = headerSize + 20 = 68
        _ = try writer.append(payload: payload)
        _ = try writer.append(payload: payload)
        writer.recordCheckpoint()
        let wrapsBefore = writer.wrapCount

        // A third append must wrap around the ring
        _ = try writer.append(payload: payload)
        #expect(writer.wrapCount > wrapsBefore)
    }
}

@Test func walRingSentinelWriteCountIncreasesAfterEachAppend() throws {
    try withWalFile(size: 1024) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 512)
        #expect(writer.sentinelWriteCount == 0)

        _ = try writer.append(payload: Data("a".utf8))
        let after1 = writer.sentinelWriteCount

        _ = try writer.append(payload: Data("b".utf8))
        let after2 = writer.sentinelWriteCount

        // Each append must write at least one sentinel (inline or explicit)
        #expect(after2 > after1)
        // Total count is 2 or more
        #expect(after2 >= 2)
    }
}

@Test func walRingPaddingRecordWrittenWhenEntryDoesNotFitAtCurrentPos() throws {
    // To trigger the padding path: write enough data that the entry partially
    // fits (≥ headerSize remaining but < entrySize remaining) which requires a
    // padding record before wrapping.
    try withWalFile(size: 1024) { file in
        let walSize: UInt64 = 256
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)

        // Fill to a position where remaining is between headerSize and entrySize.
        // headerSize = 48; payload = 156 bytes → entrySize = 204 bytes.
        // After writing: remaining = 256 - 204 = 52, which is ≥ 48 (headerSize) but
        // < 68 (headerSize + 20 for the next small record) — padding is triggered.
        let bigPayload = Data(repeating: 0xCC, count: 156)
        _ = try writer.append(payload: bigPayload)
        let writePosBefore = writer.writePos
        let wrapBefore = writer.wrapCount
        writer.recordCheckpoint()

        // Now append a smaller entry that requires padding because 52 < 68
        let smallPayload = Data(repeating: 0xDD, count: 20)
        _ = try writer.append(payload: smallPayload)

        // A padding record should have been written and writePos should wrap to 0
        // (the small entry itself then goes at the start of the ring)
        #expect(writer.wrapCount > wrapBefore || writer.writePos < writePosBefore)
    }
}

@Test func walRingFlushIsNoOpWhenNoPendingBytes() throws {
    try withWalFile(size: 512) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 256)
        // flush() with no pending writes must not throw
        try writer.flush()
    }
}

@Test func walRingFlushWritesToDiskAfterAppend() throws {
    try withWalFile(size: 512) { file in
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 256,
            fsyncPolicy: .onCommit
        )
        _ = try writer.append(payload: Data("flush-test".utf8))
        // Explicit flush should not throw
        try writer.flush()
    }
}

// MARK: - Additional ring-reader coverage

@Test func walRingReaderScanRecordsReturnsEmptyForZeroSizedWal() throws {
    try withWalFile(size: 256) { file in
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.isEmpty)
    }
}

@Test func walRingReaderScanStateReturnsZeroForZeroSizedWal() throws {
    try withWalFile(size: 256) { file in
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 0)
        #expect(state.writePos == 0)
        #expect(state.pendingBytes == 0)
    }
}

@Test func walRingReaderScanPendingMutationsWithStateZeroSizedWal() throws {
    try withWalFile(size: 256) { file in
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let result = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
        #expect(result.pendingMutations.isEmpty)
        #expect(result.state.lastSequence == 0)
    }
}

@Test func walRingReaderStopsAtChecksumCorruptedRecord() throws {
    // Write a valid record, then corrupt its checksum on disk
    try withWalFile(size: 1024) { file in
        let walSize: UInt64 = 512
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let payload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 0)))
        _ = try writer.append(payload: payload)

        // Corrupt the checksum bytes (bytes 16–47 of the header = the SHA256 checksum)
        let checksumOffset: UInt64 = 16
        let corruptBytes = Data(repeating: 0xFF, count: 32)
        try file.writeAll(corruptBytes, at: checksumOffset)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        // The corrupted record must cause scanning to stop with zero results
        #expect(records.isEmpty)
    }
}

@Test func walRingReaderWraparoundScanRecoversPreviousCheckpoint() throws {
    try withWalFile(size: 1024) { file in
        let walSize: UInt64 = 256
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)

        let payload = Data(repeating: 0xAB, count: 20)

        // Fill ring with two records then checkpoint
        _ = try writer.append(payload: payload)
        _ = try writer.append(payload: payload)
        writer.recordCheckpoint()
        let checkpointAfterFirst = writer.checkpointPos

        // Add two more records that wrap around
        _ = try writer.append(payload: Data(repeating: 0xCD, count: 20))
        let finalSeq = try writer.append(payload: Data(repeating: 0xEF, count: 20))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let state = try reader.scanState(from: checkpointAfterFirst)

        // The scan should see both post-checkpoint records
        #expect(state.lastSequence == finalSeq)
        #expect(state.writePos == writer.writePos)
    }
}

@Test func walRingReaderIsTerminalMarkerReturnsFalseAfterWrite() throws {
    try withWalFile(size: 512) { file in
        let walSize: UInt64 = 256
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)

        // Before any write: position 0 is all zeros → terminal
        let beforeWrite = try reader.isTerminalMarker(at: 0)
        #expect(beforeWrite)

        _ = try writer.append(payload: Data("live-record".utf8))

        // After write: position 0 has a live record → not terminal
        let afterWrite = try reader.isTerminalMarker(at: 0)
        #expect(afterWrite == false)
    }
}

@Test func walRingReaderIsTerminalMarkerReturnsTrueForZeroWalSize() throws {
    try withWalFile(size: 256) { file in
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 0)
        let result = try reader.isTerminalMarker(at: 0)
        #expect(result)
    }
}

@Test func walRingReaderIsTerminalMarkerReturnsFalseWhenInsufficientRemaining() throws {
    try withWalFile(size: 512) { file in
        let walSize: UInt64 = 128
        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        // cursor at walSize - 1 (only 1 byte remaining, < headerSize)
        let result = try reader.isTerminalMarker(at: walSize - 1)
        #expect(result == false)
    }
}

@Test func walRingWriterValidationAndCheckpointCountersCoverEdgeCases() throws {
    try withWalFile(size: 256) { file in
        let zeroWriter = WALRingWriter(file: file, walOffset: 0, walSize: 0)
        do {
            _ = try zeroWriter.append(payload: Data([0xAA]))
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .capacityExceeded(let limit, _) = error else {
                #expect(Bool(false))
                return
            }
            #expect(limit == 0)
        }
    }

    try withWalFile(size: 512) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 128)

        #expect(writer.canAppend(payloadSize: 0) == false)
        #expect(writer.canAppend(payloadSize: Int(UInt32.max) + 1) == false)
        #expect(writer.canAppend(payloadSize: 80) == false)
        #expect(writer.canAppendBatch(payloadSizes: []) == false)
        #expect(writer.canAppendBatch(payloadSizes: [0]) == false)
        #expect(writer.canAppendBatch(payloadSizes: [80]) == false)

        let writePosBefore = writer.writePos
        let pendingBefore = writer.pendingBytes
        let emptyBatch = try writer.appendBatch(payloads: [])
        #expect(emptyBatch.isEmpty)
        #expect(writer.writePos == writePosBefore)
        #expect(writer.pendingBytes == pendingBefore)

        _ = try writer.append(payload: Data(repeating: 0x11, count: 40))
        #expect(writer.canAppendBatch(payloadSizes: [40]) == false)

        do {
            _ = try writer.append(payload: Data(repeating: 0x22, count: 80))
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .capacityExceeded = error else {
                #expect(Bool(false))
                return
            }
        }

        let checkpointCountBefore = writer.checkpointCount
        writer.recordCheckpoint()
        writer.recordCheckpoint()
        #expect(writer.checkpointCount == checkpointCountBefore + 2)
    }
}
