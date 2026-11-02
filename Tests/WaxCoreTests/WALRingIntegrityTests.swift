import Foundation
import Testing
@testable import WaxCore

// MARK: - Helpers

private let headerSize = WALRecord.headerSize

private func withRing<T>(
    walSize: UInt64,
    _ body: (FDFile) throws -> T
) throws -> T {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        try file.truncate(to: walSize * 2)
        defer { try? file.close() }
        return try body(file)
    }
}

private func payload(entrySize: Int, fill: UInt8) -> Data {
    Data(repeating: fill, count: entrySize - headerSize)
}

private func replayedPayloads(file: FDFile, walSize: UInt64, from checkpointPos: UInt64) throws -> [Data] {
    let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
    return try reader.scanRecords(from: checkpointPos, committedSeq: 0).compactMap { location in
        if case .data(_, _, let payload) = location.record { return payload }
        return nil
    }
}

private func isCapacityExceeded(_ body: () throws -> Void) -> Bool {
    do {
        try body()
        return false
    } catch WaxError.capacityExceeded {
        return true
    } catch {
        return false
    }
}

// MARK: - Sentinel must never overrun the oldest pending record

/// Reproduces the reviewed layout: walSize 1000, checkpoint at 500, records
/// [500,900), [900,1000), then a record at 0 that leaves `leftover` free bytes
/// before the checkpoint. A 48-byte sentinel there would zero the record at 500.
@Test(arguments: 1...47)
func walAppendRefusesToLeaveLessThanHeaderOfFreeSpace(leftover: Int) throws {
    let walSize: UInt64 = 1000
    try withRing(walSize: walSize) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize, writePos: 500, checkpointPos: 500)
        let first = payload(entrySize: 400, fill: 0x11)
        let second = payload(entrySize: 100, fill: 0x22)
        _ = try writer.append(payload: first)
        _ = try writer.append(payload: second)
        #expect(writer.writePos == 0)
        #expect(writer.pendingBytes == 500)

        let thirdEntry = 500 - leftover
        let third = payload(entrySize: thirdEntry, fill: 0x33)
        #expect(writer.canAppend(payloadSize: third.count) == false)
        #expect(writer.canAppendBatch(payloadSizes: [third.count]) == false)
        #expect(isCapacityExceeded { _ = try writer.append(payload: third) })

        // Simulated crash without commit: everything appended must still replay.
        let replayed = try replayedPayloads(file: file, walSize: walSize, from: 500)
        #expect(replayed == [first, second])
    }
}

@Test(arguments: 1...47)
func walAppendBatchRefusesToLeaveLessThanHeaderOfFreeSpace(leftover: Int) throws {
    let walSize: UInt64 = 1000
    try withRing(walSize: walSize) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize, writePos: 500, checkpointPos: 500)
        let batch = [
            payload(entrySize: 400, fill: 0x11),
            payload(entrySize: 100, fill: 0x22),
            payload(entrySize: 500 - leftover, fill: 0x33)
        ]
        #expect(writer.canAppendBatch(payloadSizes: batch.map(\.count)) == false)
        #expect(isCapacityExceeded { _ = try writer.appendBatch(payloads: batch) })

        _ = try writer.appendBatch(payloads: Array(batch.prefix(2)))
        let replayed = try replayedPayloads(file: file, walSize: walSize, from: 500)
        #expect(replayed == Array(batch.prefix(2)))
    }
}

@Test(arguments: [0, 48, 60])
func walAppendFillingRingToBoundaryReplaysAllPendingRecords(leftover: Int) throws {
    let walSize: UInt64 = 1000
    try withRing(walSize: walSize) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize, writePos: 500, checkpointPos: 500)
        let payloads = [
            payload(entrySize: 400, fill: 0x11),
            payload(entrySize: 100, fill: 0x22),
            payload(entrySize: 500 - leftover, fill: 0x33)
        ]
        for item in payloads {
            #expect(writer.canAppend(payloadSize: item.count))
            _ = try writer.append(payload: item)
        }
        #expect(writer.pendingBytes == walSize - UInt64(leftover))

        let replayed = try replayedPayloads(file: file, walSize: walSize, from: 500)
        #expect(replayed == payloads)
    }
}

@Test func walAppendBatchFillingRingToExactCapacityReplaysAllPendingRecords() throws {
    let walSize: UInt64 = 1000
    try withRing(walSize: walSize) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize, writePos: 500, checkpointPos: 500)
        let batch = [
            payload(entrySize: 400, fill: 0x11),
            payload(entrySize: 100, fill: 0x22),
            payload(entrySize: 500, fill: 0x33)
        ]
        #expect(writer.canAppendBatch(payloadSizes: batch.map(\.count)))
        _ = try writer.appendBatch(payloads: batch)
        #expect(writer.pendingBytes == walSize)

        let replayed = try replayedPayloads(file: file, walSize: walSize, from: 500)
        #expect(replayed == batch)
    }
}

/// A trailing tail shorter than a header is zero-filled and counted as pending.
/// When that tail plus the record would leave 1...47 free bytes, the append must be refused.
@Test func walAppendCountsTrailingTailWhenReservingSentinelRoom() throws {
    let walSize: UInt64 = 1000
    try withRing(walSize: walSize) { file in
        // checkpoint at 100; a record [100, 980) leaves a 20-byte tail -> wraps to 0.
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize, writePos: 100, checkpointPos: 100)
        let first = payload(entrySize: 880, fill: 0x44)
        _ = try writer.append(payload: first)
        #expect(writer.writePos == 0)
        #expect(writer.pendingBytes == 900)

        // 60-byte record at [0, 60) would leave 40 free bytes before checkpoint 100.
        let second = payload(entrySize: 60, fill: 0x55)
        #expect(writer.canAppend(payloadSize: second.count) == false)
        #expect(isCapacityExceeded { _ = try writer.append(payload: second) })

        let replayed = try replayedPayloads(file: file, walSize: walSize, from: 100)
        #expect(replayed == [first])
    }
}

// MARK: - Planner parity

@Test func walRingCapacityPlanMatchesWriterOutcomeAcrossLayouts() throws {
    let walSize: UInt64 = 512
    let sizes = [1, 7, 20, 52, 100, 200, 300, 416, 463]
    for start in stride(from: UInt64(0), to: walSize, by: 37) {
        for size in sizes {
            try withRing(walSize: walSize) { file in
                let writer = WALRingWriter(
                    file: file, walOffset: 0, walSize: walSize, writePos: start, checkpointPos: start
                )
                let predicted = writer.canAppend(payloadSize: size)
                let predictedBatch = writer.canAppendBatch(payloadSizes: [size, size])
                var appended: [Data] = []
                do {
                    let item = Data(repeating: 0x5A, count: size)
                    _ = try writer.append(payload: item)
                    appended.append(item)
                    #expect(predicted, "canAppend mismatch start=\(start) size=\(size)")
                } catch WaxError.capacityExceeded {
                    #expect(!predicted, "canAppend mismatch start=\(start) size=\(size)")
                }
                let freeBytes = walSize - writer.pendingBytes
                #expect(freeBytes == 0 || freeBytes >= UInt64(headerSize))

                if predicted {
                    let fresh = WALRingWriter(
                        file: file, walOffset: 0, walSize: walSize, writePos: start, checkpointPos: start
                    )
                    let pair = [Data(repeating: 0x6B, count: size), Data(repeating: 0x6C, count: size)]
                    do {
                        _ = try fresh.appendBatch(payloads: pair)
                        #expect(predictedBatch, "canAppendBatch mismatch start=\(start) size=\(size)")
                        let replayed = try replayedPayloads(file: file, walSize: walSize, from: start)
                        #expect(replayed == pair, "batch replay mismatch start=\(start) size=\(size)")
                    } catch WaxError.capacityExceeded {
                        #expect(!predictedBatch, "canAppendBatch mismatch start=\(start) size=\(size)")
                    }
                } else {
                    let replayed = try replayedPayloads(file: file, walSize: walSize, from: start)
                    #expect(replayed == appended)
                }
            }
        }
    }
}

// MARK: - Padding must land exactly at ring end

@Test func walReplayStopsWhenPaddingSkipDoesNotLandAtRingEnd() throws {
    let walSize: UInt64 = 512
    try withRing(walSize: walSize) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let first = Data(repeating: 0x01, count: 16)
        _ = try writer.append(payload: first)
        let afterFirst = writer.writePos // 64

        // A torn padding length that skips into the middle of the ring.
        let tornPadding = WALRecord.padding(sequence: 2, skipBytes: 16)
        try file.writeAll(try tornPadding.encode(), at: afterFirst)

        // A checksum-valid record exactly where the bogus skip lands.
        let landing = afterFirst + UInt64(headerSize) + 16
        let bogus = WALRecord.data(sequence: 3, flags: [], payload: Data(repeating: 0x03, count: 8))
        try file.writeAll(try bogus.encode(), at: landing)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let replayed = try replayedPayloads(file: file, walSize: walSize, from: 0)
        #expect(replayed == [first])
        let state = try reader.scanState(from: 0)
        #expect(state.lastSequence == 1)
        #expect(state.writePos == afterFirst)
    }
}

@Test func walReplayFollowsPaddingThatLandsAtRingEnd() throws {
    let walSize: UInt64 = 256
    try withRing(walSize: walSize) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        let entry = Data(repeating: 0xAB, count: 20) // entry size 68
        _ = try writer.append(payload: entry)
        _ = try writer.append(payload: entry)
        writer.recordCheckpoint()
        let third = Data(repeating: 0xCD, count: 20)
        let fourth = Data(repeating: 0xEF, count: 20)
        _ = try writer.append(payload: third)
        _ = try writer.append(payload: fourth) // forces padding at 204 -> wrap

        let replayed = try replayedPayloads(file: file, walSize: walSize, from: writer.checkpointPos)
        #expect(replayed == [third, fourth])
    }
}

// MARK: - Pending replay prefix

@Test func walPendingScanStopsBeforeFirstRejectedMutation() throws {
    let walSize: UInt64 = 1024
    try withRing(walSize: walSize) { file in
        let writer = WALRingWriter(file: file, walOffset: 0, walSize: walSize)
        var offsets: [UInt64] = []
        for frameId in UInt64(1)...3 {
            offsets.append(writer.writePos)
            _ = try writer.append(payload: try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: frameId))))
        }

        let reader = WALRingReader(file: file, walOffset: 0, walSize: walSize)
        let result = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0) { mutation in
            mutation.sequence != 2
        }
        #expect(result.truncated)
        #expect(result.pendingMutations.map(\.sequence) == [1])
        #expect(result.state.lastSequence == 1)
        #expect(result.state.writePos == offsets[1])
        #expect(result.state.pendingBytes == offsets[1])

        let full = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
        #expect(!full.truncated)
        #expect(full.pendingMutations.map(\.sequence) == [1, 2, 3])
        #expect(full.state.writePos == writer.writePos)
    }
}
