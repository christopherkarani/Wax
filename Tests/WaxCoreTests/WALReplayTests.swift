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

@Test func walPendingScanWithStateThrowsOnChecksumValidUndecodableEntry() throws {
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

        // scanPendingMutations re-throws decode failures (by design — see scanInternal comment).
        #expect(throws: WaxError.self) {
            _ = try reader.scanPendingMutations(from: 0, committedSeq: 0)
        }

        // scanState never decodes WAL entry payloads, so it succeeds.
        let legacyState = try reader.scanState(from: 0)
        #expect(legacyState.lastSequence == 2)

        // scanPendingMutationsWithState must fail closed on checksum-valid but
        // undecodable payloads so open cannot advance past dropped mutations.
        #expect(throws: WaxError.self) {
            _ = try reader.scanPendingMutationsWithState(from: 0, committedSeq: 0)
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

enum PendingPayloadFault: Sendable {
    case intact
    case corrupt
    case beyondFileEnd
}

/// Appends pending `putFrame` WAL records (no commit) whose payload bytes are written
/// at the end of the file according to `faults`, simulating a crash after the WAL record
/// became durable but before (or while) the data payload was written.
private func appendPendingPuts(
    to url: URL,
    firstFrameId: UInt64,
    faults: [PendingPayloadFault]
) throws {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }

    let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
    let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
    let selected = try #require(WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB))
    let writer = WALRingWriter(
        file: file,
        walOffset: selected.page.walOffset,
        walSize: selected.page.walSize,
        writePos: selected.page.walWritePos,
        checkpointPos: selected.page.walCheckpointPos,
        pendingBytes: 0,
        lastSequence: selected.page.walCommittedSeq
    )

    for (index, fault) in faults.enumerated() {
        let frameId = firstFrameId + UInt64(index)
        let payload = Data("pending-\(frameId)".utf8)
        let checksum = SHA256Checksum.digest(payload)
        let payloadOffset: UInt64
        switch fault {
        case .intact:
            payloadOffset = try file.size()
            try file.writeAll(payload, at: payloadOffset)
        case .corrupt:
            payloadOffset = try file.size()
            try file.writeAll(Data(repeating: 0x58, count: payload.count), at: payloadOffset)
        case .beyondFileEnd:
            payloadOffset = try file.size() + 4096
        }
        let put = PutFrame(
            frameId: frameId,
            timestampMs: 1_234,
            options: FrameMetaSubset(),
            payloadOffset: payloadOffset,
            payloadLength: UInt64(payload.count),
            canonicalEncoding: .plain,
            canonicalLength: UInt64(payload.count),
            canonicalChecksum: checksum,
            storedChecksum: checksum
        )
        _ = try writer.append(payload: try WALEntryCodec.encode(.putFrame(put)))
    }
    try file.fsync()
}

private func createStoreWithOneCommittedFrame(at url: URL) async throws {
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    _ = try await wax.put(Data("committed".utf8))
    try await wax.commit()
    try await wax.close()
}

@Test func openDropsTornPendingPutFrameInsteadOfFailing() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try await createStoreWithOneCommittedFrame(at: url)
    try appendPendingPuts(to: url, firstFrameId: 1, faults: [.corrupt])

    // Uncommitted WAL records are not a durability promise: a torn payload is dropped
    // and the committed state stays readable.
    let reopened = try await Wax.open(at: url)
    let frames = await reopened.frameMetasIncludingPending()
    #expect(frames.map(\.id) == [0])
    #expect(try await reopened.frameContent(frameId: 0) == Data("committed".utf8))
    let stats = await reopened.walStats()
    #expect(stats.replayTruncationCount == 1)
    #expect(stats.pendingBytes == 0)
    try await reopened.close()
}

@Test(arguments: [PendingPayloadFault.corrupt, .beyondFileEnd])
func openReplaysLongestValidPendingPrefix(fault: PendingPayloadFault) async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try await createStoreWithOneCommittedFrame(at: url)
    try appendPendingPuts(to: url, firstFrameId: 1, faults: [.intact, fault, .intact])

    do {
        let reopened = try await Wax.open(at: url)
        let frames = await reopened.frameMetasIncludingPending()
        #expect(frames.map(\.id) == [0, 1])
        #expect(try await reopened.frameContentIncludingPending(frameId: 1) == Data("pending-1".utf8))
        #expect(await reopened.walStats().replayTruncationCount == 1)

        // The writer resumes at the first dropped record, so new work is durable after commit.
        let newId = try await reopened.put(Data("after-recovery".utf8))
        #expect(newId == 2)
        try await reopened.commit()
        try await reopened.close()
    }

    let verified = try await Wax.open(at: url)
    let frames = await verified.frameMetas()
    #expect(frames.map(\.id) == [0, 1, 2])
    #expect(try await verified.frameContent(frameId: 1) == Data("pending-1".utf8))
    #expect(try await verified.frameContent(frameId: 2) == Data("after-recovery".utf8))
    #expect(await verified.walStats().replayTruncationCount == 0)
    try await verified.close()
}

@Test func openReplaysAllPendingRecordsWhenPayloadsAreIntact() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }

    try await createStoreWithOneCommittedFrame(at: url)
    try appendPendingPuts(to: url, firstFrameId: 1, faults: [.intact, .intact])

    let reopened = try await Wax.open(at: url)
    let frames = await reopened.frameMetasIncludingPending()
    #expect(frames.map(\.id) == [0, 1, 2])
    #expect(await reopened.walStats().replayTruncationCount == 0)
    try await reopened.close()
}
