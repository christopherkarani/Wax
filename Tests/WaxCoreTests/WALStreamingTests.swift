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

@Test
func walAppendBatchWritesAllRecords() throws {
    try withWalFile(size: 2048) { file in
        let walSize: UInt64 = 512
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)

        let payloads = [
            Data("alpha".utf8),
            Data("bravo".utf8),
            Data("charlie".utf8)
        ]

        let sequences = try writer.appendBatch(payloads: payloads)
        #expect(sequences.count == payloads.count)
        #expect(sequences == Array(1...UInt64(payloads.count)))

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let records = try reader.scanRecords(from: 0, committedSeq: 0)
        let decodedPayloads = records.compactMap { record -> Data? in
            if case .data(_, _, let payload) = record.record { return payload }
            return nil
        }

        #expect(decodedPayloads == payloads)
        let decodedSeqs = records.compactMap { $0.record.sequence }
        #expect(decodedSeqs == sequences)
    }
}

@Test
func walAppendBatchWrapsAcrossBoundary() throws {
    try withWalFile(size: 1024) { file in
        let walSize: UInt64 = 256
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)

        // Fill most of the WAL with individual appends to force wrap on batch.
        _ = try writer.append(payload: Data(repeating: 0xAB, count: 40)) // ~88 bytes
        _ = try writer.append(payload: Data(repeating: 0xCD, count: 40)) // ~88 bytes
        writer.recordCheckpoint()

        let payloads = [
            Data(repeating: 0x01, count: 20), // ~68 bytes
            Data(repeating: 0x02, count: 20)  // ~68 bytes (forces wrap)
        ]

        let sequences = try writer.appendBatch(payloads: payloads)
        #expect(sequences.count == payloads.count)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let records = try reader.scanRecords(from: writer.checkpointPos, committedSeq: 0)
        let decodedPayloads = records.compactMap { record -> Data? in
            if case .data(_, _, let payload) = record.record { return payload }
            return nil
        }

        #expect(decodedPayloads == payloads)
        #expect(records.last?.record.sequence == sequences.last)
    }
}

@Test
func mmapWritableRegionPersistsBytes() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }

        let payload = Data("streaming-write".utf8)
        let targetOffset: UInt64 = 4096 // align away from start to exercise offset math
        let region = try file.mapWritable(length: payload.count, at: targetOffset)
        defer { region.close() }

        // Write via mapped buffer
        region.buffer.copyBytes(from: payload)

        // Read back via FDFile APIs
        let readBack = try file.readExactly(length: payload.count, at: targetOffset)
        #expect(readBack == payload)
    }
}
