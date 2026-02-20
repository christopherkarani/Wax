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
