import Foundation
import Testing
@testable import WaxCore

// MARK: - Helpers

private func makeWalFile(walSize: UInt64, fileSize: UInt64? = nil, body: (FDFile, WALRingWriter) throws -> Void) throws {
    try TempFiles.withTempFile { url in
        let actualFileSize = fileSize ?? walSize * 2
        let file = try FDFile.create(at: url)
        try file.truncate(to: actualFileSize)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        try body(file, writer)
    }
}

private func makeReadOnlyWalFile(walSize: UInt64, fileSize: UInt64? = nil, body: (FDFile, WALRingWriter) throws -> Void) throws {
    try TempFiles.withTempFile { url in
        let actualFileSize = fileSize ?? walSize * 2
        let writable = try FDFile.create(at: url)
        try writable.truncate(to: actualFileSize)
        try writable.close()
        let file = try FDFile.openReadOnly(at: url)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        try body(file, writer)
    }
}

// MARK: - WALRingWriter: append edge cases

@Test func walRingWriterZeroSizeThrowsOnAppend() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 0)
        #expect(throws: WaxError.self) {
            _ = try writer.append(payload: Data("x".utf8))
        }
    }
}

@Test func walRingWriterZeroSizeInitNormalizesPositions() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 0,
            writePos: 999,
            checkpointPos: 888
        )
        // When walSize == 0 both positions must be clamped to 0.
        #expect(writer.writePos == 0)
        #expect(writer.checkpointPos == 0)
    }
}

@Test func walRingWriterEntryLargerThanWalThrows() throws {
    try makeWalFile(walSize: 64) { _, writer in
        // header(48) + payload(64) = 112 > walSize(64)
        let hugePayload = Data(repeating: 0xAA, count: 64)
        #expect(throws: WaxError.self) {
            _ = try writer.append(payload: hugePayload)
        }
    }
}

@Test func walRingWriterFaultedAfterPartialWriteBlocksFurtherAppends() throws {
    try makeReadOnlyWalFile(walSize: 256) { _, writer in
        // First attempt writes to a read-only file – triggers fault.
        do { _ = try writer.append(payload: Data("fail".utf8)) } catch {}

        // Subsequent append must throw "faulted" error.
        do {
            _ = try writer.append(payload: Data("also-fail".utf8))
            #expect(Bool(false))
        } catch let error as WaxError {
            if case .io(let reason) = error {
                #expect(reason.contains("faulted"))
            } else {
                #expect(Bool(false))
            }
        }
    }
}

// MARK: - WALRingWriter: appendBatch edge cases

@Test func walRingWriterAppendBatchEmptyPayloadsReturnsEmpty() throws {
    try makeWalFile(walSize: 512) { _, writer in
        let seqs = try writer.appendBatch(payloads: [])
        #expect(seqs.isEmpty)
    }
}

@Test func walRingWriterAppendBatchZeroSizeWalThrows() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 0)
        #expect(throws: WaxError.self) {
            _ = try writer.appendBatch(payloads: [Data("x".utf8)])
        }
    }
}

@Test func walRingWriterAppendBatchRejectsEmptyElementPayload() throws {
    try makeWalFile(walSize: 512) { _, writer in
        #expect(throws: WaxError.self) {
            _ = try writer.appendBatch(payloads: [Data("ok".utf8), Data(), Data("also-ok".utf8)])
        }
    }
}

@Test func walRingWriterAppendBatchEntryExceedsWalThrows() throws {
    try makeWalFile(walSize: 64) { _, writer in
        let hugePayload = Data(repeating: 0xBB, count: 64)
        #expect(throws: WaxError.self) {
            _ = try writer.appendBatch(payloads: [hugePayload])
        }
    }
}

@Test func walRingWriterAppendBatchFaultedBlocksFurtherBatchAppends() throws {
    try makeReadOnlyWalFile(walSize: 512) { _, writer in
        do { _ = try writer.appendBatch(payloads: [Data("fail".utf8)]) } catch {}

        do {
            _ = try writer.appendBatch(payloads: [Data("also-fail".utf8)])
            #expect(Bool(false))
        } catch let error as WaxError {
            if case .io(let reason) = error {
                #expect(reason.contains("faulted"))
            } else {
                #expect(Bool(false))
            }
        }
    }
}

@Test func walRingWriterAppendBatchOverfullThrows() throws {
    try makeWalFile(walSize: 256) { _, writer in
        let smallPayload = Data(repeating: 0x11, count: 10)
        while writer.canAppend(payloadSize: smallPayload.count) {
            _ = try writer.append(payload: smallPayload)
        }
        #expect(throws: WaxError.self) {
            _ = try writer.appendBatch(payloads: [smallPayload])
        }
    }
}

@Test func walRingWriterAppendBatchCoalescesAdjacentWrites() throws {
    try makeWalFile(walSize: 1024) { file, writer in
        let payloads = (1...5).map { Data("payload-\($0)".utf8) }
        let sequences = try writer.appendBatch(payloads: payloads)
        #expect(sequences.count == 5)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 1024)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.count == 5)
        let decodedPayloads = records.compactMap { r -> Data? in
            if case .data(_, _, let p) = r.record { return p }
            return nil
        }
        #expect(decodedPayloads == payloads)
    }
}

// MARK: - WALRingWriter: canAppend

@Test func walRingWriterCanAppendReturnsFalseForZeroPayloadSize() throws {
    try makeWalFile(walSize: 256) { _, writer in
        #expect(writer.canAppend(payloadSize: 0) == false)
    }
}

@Test func walRingWriterCanAppendReturnsFalseForZeroWalSize() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 0)
        #expect(writer.canAppend(payloadSize: 1) == false)
    }
}

@Test func walRingWriterCanAppendReturnsTrueWhenSpaceAvailable() throws {
    try makeWalFile(walSize: 256) { _, writer in
        // Fresh WAL: a small payload must fit.
        #expect(writer.canAppend(payloadSize: 10) == true)
    }
}

@Test func walRingWriterCanAppendReturnsFalseWhenFull() throws {
    try makeWalFile(walSize: 256) { _, writer in
        let payload = Data(repeating: 0x22, count: 10)
        while writer.canAppend(payloadSize: payload.count) {
            _ = try writer.append(payload: payload)
        }
        #expect(writer.canAppend(payloadSize: payload.count) == false)
    }
}

@Test func walRingWriterCanAppendReturnsFalseWhenPayloadExceedsWal() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 128)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 64)
        // header(48) + payload(64) = 112 > walSize(64): can never fit.
        #expect(writer.canAppend(payloadSize: 64) == false)
    }
}

// MARK: - WALRingWriter: canAppendBatch

@Test func walRingWriterCanAppendBatchEmptyReturnsFalse() throws {
    try makeWalFile(walSize: 256) { _, writer in
        #expect(writer.canAppendBatch(payloadSizes: []) == false)
    }
}

@Test func walRingWriterCanAppendBatchZeroWalSizeReturnsFalse() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 64)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 0)
        #expect(writer.canAppendBatch(payloadSizes: [10]) == false)
    }
}

@Test func walRingWriterCanAppendBatchZeroElementReturnsFalse() throws {
    try makeWalFile(walSize: 256) { _, writer in
        #expect(writer.canAppendBatch(payloadSizes: [10, 0, 5]) == false)
    }
}

@Test func walRingWriterCanAppendBatchReturnsTrueWhenFits() throws {
    try makeWalFile(walSize: 1024) { _, writer in
        #expect(writer.canAppendBatch(payloadSizes: [10, 20, 30]) == true)
    }
}

@Test func walRingWriterCanAppendBatchReturnsFalseWhenBatchExceedsCapacity() throws {
    try makeWalFile(walSize: 256) { _, writer in
        let payload = Data(repeating: 0x33, count: 10)
        while writer.canAppend(payloadSize: payload.count) {
            _ = try writer.append(payload: payload)
        }
        #expect(writer.canAppendBatch(payloadSizes: [10, 10, 10]) == false)
    }
}

@Test func walRingWriterCanAppendBatchElementExceedsWalReturnsFalse() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 128)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 64)
        // Individual element larger than entire WAL.
        #expect(writer.canAppendBatch(payloadSizes: [64]) == false)
    }
}

// MARK: - WALRingWriter: flush / fsync policies

@Test func walRingWriterFlushNoOpsWhenNoBytesWritten() throws {
    try makeWalFile(walSize: 256) { _, writer in
        // flush() must be a no-op (no fsync call) when bytesSinceFsync == 0.
        // We can only observe that it doesn't throw.
        try writer.flush()
    }
}

@Test func walRingWriterFlushForcesAfterWrite() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 512)
        defer { try? file.close() }
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 256)
        _ = try writer.append(payload: Data("flush-me".utf8))
        // After a write, flush() calls fsync on the file; must not throw.
        try writer.flush()
    }
}

@Test func walRingWriterFsyncPolicyAlwaysFlushesAfterEachAppend() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 512)
        defer { try? file.close() }
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 256,
            fsyncPolicy: .always
        )
        _ = try writer.append(payload: Data("always-sync".utf8))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 256)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.count == 1)
    }
}

@Test func walRingWriterFsyncPolicyEveryBytesFlushesAtThreshold() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 2048)
        defer { try? file.close() }
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 1024,
            fsyncPolicy: .everyBytes(200)
        )
        for i in 0..<5 {
            _ = try writer.append(payload: Data("payload-\(i)".utf8))
        }
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 1024)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.count == 5)
    }
}

@Test func walRingWriterFsyncPolicyEveryBytesZeroThresholdIsNoOp() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: 512)
        defer { try? file.close() }
        let writer = WALRingWriter(
            file: file,
            walOffset: 0,
            walSize: 256,
            fsyncPolicy: .everyBytes(0)
        )
        // threshold == 0: guard fires and returns without fsync.
        _ = try writer.append(payload: Data("no-threshold".utf8))
        let reader = WALRingReader(file: file, walOffset: 0, walSize: 256)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.count == 1)
    }
}

// MARK: - WALRingWriter: writeSentinel when WAL nearly full

@Test func walRingWriterSentinelSkippedWhenWalFull() throws {
    // When pendingBytes == walSize after the last record, writeSentinel must not
    // attempt an additional write (no space). Verify the WAL is still readable.
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize * 2)
        defer { try? file.close() }

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let payloadSize = 10
        var appendedCount = 0
        while writer.canAppend(payloadSize: payloadSize) {
            _ = try writer.append(payload: Data(repeating: UInt8(appendedCount & 0xFF), count: payloadSize))
            appendedCount += 1
        }
        #expect(appendedCount > 0)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        #expect(records.count == appendedCount)
    }
}

// MARK: - WALRingWriter: recordCheckpoint

@Test func walRingWriterCheckpointResetsStateCorrectly() throws {
    try makeWalFile(walSize: 512) { _, writer in
        _ = try writer.append(payload: Data(repeating: 0x55, count: 20))
        _ = try writer.append(payload: Data(repeating: 0x66, count: 20))
        let posBeforeCheckpoint = writer.writePos
        writer.recordCheckpoint()
        #expect(writer.pendingBytes == 0)
        #expect(writer.checkpointPos == posBeforeCheckpoint)
        #expect(writer.checkpointCount == 1)
    }
}

@Test func walRingWriterMultipleCheckpointsIncrementCount() throws {
    try makeWalFile(walSize: 1024) { _, writer in
        for i in 0..<4 {
            _ = try writer.append(payload: Data("item-\(i)".utf8))
            writer.recordCheckpoint()
        }
        #expect(writer.checkpointCount == 4)
    }
}

// MARK: - WALRingWriter: wrapCount increments

@Test func walRingWriterWrapCountIncreasesOnRingWrap() throws {
    try TempFiles.withTempFile { url in
        let walSize: UInt64 = 256
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize * 2)
        defer { try? file.close() }

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        _ = try writer.append(payload: Data(repeating: 0xAA, count: 40))
        _ = try writer.append(payload: Data(repeating: 0xBB, count: 40))
        writer.recordCheckpoint()

        let wrapsBefore = writer.wrapCount
        // This append should force a padding record + wrap-around.
        _ = try writer.append(payload: Data(repeating: 0xCC, count: 40))
        #expect(writer.wrapCount > wrapsBefore)
    }
}
