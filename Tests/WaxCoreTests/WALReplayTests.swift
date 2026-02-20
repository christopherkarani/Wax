import Foundation
import Testing
@testable import WaxCore

@Test func walReplayFiltersByCommittedSeq() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 1024)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 512)
        let payload1 = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 1)))
        let payload2 = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 2)))
        let payload3 = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 3)))

        _ = try writer.append(payload: payload1)
        _ = try writer.append(payload: payload2)
        _ = try writer.append(payload: payload3)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 512)
        let mutations = try reader.scanPendingMutations(from: 0, committedSeq: 1)
        #expect(mutations.count == 2)
        #expect(mutations.map { $0.sequence } == [2, 3])
    }
}

@Test func walReplayStopsOnCorruption() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 1024)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 512)
        let payload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 10)))
        _ = try writer.append(payload: payload)

        // Scribble an invalid header where the next record would start.
        let corruptHeader = WALRecordHeader(
            sequence: 99,
            length: 0,
            flags: [],
            checksum: Data(repeating: 0, count: WALRecord.checksumSize)
        )
        let corruptData = try corruptHeader.encode()
        try file.writeAll(corruptData, at: writer.writePos)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 512)
        let mutations = try reader.scanPendingMutations(from: 0, committedSeq: 0)
        #expect(mutations.count == 1)
    }
}

@Test func walReplayOpcodeDecodeSmoke() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 2048)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 1024)

        let options = FrameMetaSubset(uri: "mv2://doc/1", title: "Doc", tags: [TagPair(key: "k", value: "v")])
        let put = PutFrame(
            frameId: 42,
            timestampMs: 123456789,
            options: options,
            payloadOffset: 8192,
            payloadLength: 1024,
            canonicalEncoding: .plain,
            canonicalLength: 1024,
            canonicalChecksum: Data(repeating: 0xAA, count: 32),
            storedChecksum: Data(repeating: 0xBB, count: 32)
        )

        let putPayload = try WALEntryCodec.encode(.putFrame(put))
        let delPayload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 7)))

        _ = try writer.append(payload: putPayload)
        _ = try writer.append(payload: delPayload)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 1024)
        let mutations = try reader.scanPendingMutations(from: 0, committedSeq: 0)
        #expect(mutations.count == 2)

        if case .putFrame(let decodedPut) = mutations[0].entry {
            #expect(decodedPut.frameId == 42)
            #expect(decodedPut.payloadOffset == 8192)
            #expect(decodedPut.options.uri == "mv2://doc/1")
        } else {
            #expect(Bool(false))
        }

        if case .deleteFrame(let decodedDelete) = mutations[1].entry {
            #expect(decodedDelete.frameId == 7)
        } else {
            #expect(Bool(false))
        }
    }
}

@Test func walPendingScanWithStateMatchesLegacyTwoPassScan() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 2048)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 1024)
        let payload1 = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 1)))
        let payload2 = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 2)))
        _ = try writer.append(payload: payload1)
        _ = try writer.append(payload: payload2)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 1024)
        let legacyPending = try reader.scanPendingMutations(from: 0, committedSeq: 1)
        let legacyState = try reader.scanState(from: 0)

        let combined = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 1)
        #expect(combined.pendingMutations == legacyPending)
        #expect(combined.state == legacyState)
    }
}

@Test func walPendingScanWithStateThrowsOnPendingDecodeFailure() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 4096)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 2048)

        // Valid WAL record envelope but invalid WALEntry opcode payload.
        _ = try writer.append(payload: Data([0xFF]))
        let validPayload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 42)))
        _ = try writer.append(payload: validPayload)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 2048)
        let legacyPending = try reader.scanPendingMutations(from: 0, committedSeq: 0)
        let legacyState = try reader.scanState(from: 0)
        #expect(legacyPending.isEmpty)
        #expect(legacyState.lastSequence == 2)

        do {
            _ = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
            #expect(Bool(false))
        } catch let error as WaxError {
            guard case .walCorruption(let offset, let reason) = error else {
                #expect(Bool(false))
                return
            }
            #expect(offset == 0)
            #expect(reason.contains("failed to decode pending WAL mutation"))
        }
    }
}

@Test func walReplayTerminalMarkerDetectionMatchesWriteCursor() throws {
    try TempFiles.withTempFile { url in
        let file = try FDFile.create(at: url)
        defer { try? file.close() }
        try file.truncate(to: 4096)

        let writer = WALRingWriter(file: file, walOffset: 0, walSize: 2048)
        let payload = try WALEntryCodec.encode(.deleteFrame(DeleteFrame(frameId: 1)))
        _ = try writer.append(payload: payload)

        let reader = WALRingReader(file: file, walOffset: 0, walSize: 2048)
        #expect(try reader.isTerminalMarker(at: writer.writePos))
        #expect((try reader.isTerminalMarker(at: 0)) == false)
    }
}
