import Foundation
import Testing
@testable import WaxCore

// MARK: - Fixture

/// A pending WAL record appended directly to the ring, bypassing `Wax`, to model what a
/// crash can leave behind: WAL envelopes are durable while data payloads may be torn.
enum PendingRecordFixture: Sendable {
    case intactPut
    case corruptPut
    case putBeyondFileEnd
    case delete(frameId: UInt64)
}

private struct PendingRingLayout {
    var walOffset: UInt64
    var walSize: UInt64
    /// Ring-relative offset of each appended record.
    var recordOffsets: [UInt64]
    /// Ring-relative offset just past the last appended record.
    var chainEnd: UInt64
    var lastSequence: UInt64
}

private func makePut(frameId: UInt64, payload: Data, payloadOffset: UInt64, uri: String? = nil) -> PutFrame {
    let checksum = SHA256Checksum.digest(payload)
    return PutFrame(
        frameId: frameId,
        timestampMs: 1_234,
        options: FrameMetaSubset(uri: uri),
        payloadOffset: payloadOffset,
        payloadLength: UInt64(payload.count),
        canonicalEncoding: .plain,
        canonicalLength: UInt64(payload.count),
        canonicalChecksum: checksum,
        storedChecksum: checksum
    )
}

private func readHeaderPage(_ file: FDFile) throws -> WaxHeaderPage {
    let pageA = try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
    let pageB = try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
    return try #require(WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB)).page
}

private func openRingWriter(_ file: FDFile) throws -> WALRingWriter {
    let page = try readHeaderPage(file)
    return WALRingWriter(
        file: file,
        walOffset: page.walOffset,
        walSize: page.walSize,
        writePos: page.walWritePos,
        checkpointPos: page.walCheckpointPos,
        pendingBytes: 0,
        lastSequence: page.walCommittedSeq
    )
}

/// Appends uncommitted records straight to the ring (no commit). Put frame ids increase only
/// for puts; payload bytes are written at the end of the file.
private struct PendingRecordAppender {
    let file: FDFile
    let writer: WALRingWriter
    var nextFrameId: UInt64
    var offsets: [UInt64] = []

    init(file: FDFile, firstFrameId: UInt64) throws {
        self.file = file
        self.writer = try openRingWriter(file)
        self.nextFrameId = firstFrameId
    }

    var layout: PendingRingLayout {
        PendingRingLayout(
            walOffset: writer.walOffset,
            walSize: writer.walSize,
            recordOffsets: offsets,
            chainEnd: writer.writePos,
            lastSequence: writer.lastSequence
        )
    }

    mutating func append(_ record: PendingRecordFixture) throws {
        let entry: WALEntry
        switch record {
        case .delete(let frameId):
            entry = .deleteFrame(DeleteFrame(frameId: frameId))
        case .intactPut, .corruptPut, .putBeyondFileEnd:
            let frameId = nextFrameId
            nextFrameId += 1
            let payload = Data("pending-\(frameId)".utf8)
            var payloadOffset = try file.size()
            switch record {
            case .intactPut:
                try file.writeAll(payload, at: payloadOffset)
            case .corruptPut:
                try file.writeAll(Data(repeating: 0x58, count: payload.count), at: payloadOffset)
            default:
                payloadOffset += 4096
            }
            entry = .putFrame(makePut(frameId: frameId, payload: payload, payloadOffset: payloadOffset))
        }
        let encoded = try WALEntryCodec.encode(entry)
        _ = try writer.append(payload: encoded)
        // The record ends at the new write position; it may sit after padding at the ring start.
        let recordSize = UInt64(WALRecord.headerSize + encoded.count)
        offsets.append((writer.writePos + writer.walSize - recordSize) % writer.walSize)
    }
}

@discardableResult
private func appendPendingRecords(
    to url: URL,
    firstFrameId: UInt64,
    records: [PendingRecordFixture]
) throws -> PendingRingLayout {
    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    var appender = try PendingRecordAppender(file: file, firstFrameId: firstFrameId)
    for record in records {
        try appender.append(record)
    }
    try file.fsync()
    return appender.layout
}

private func createStoreWithOneCommittedFrame(at url: URL, walSize: UInt64 = 256 * 1024) async throws {
    let wax = try await Wax.create(at: url, walSize: walSize)
    _ = try await wax.put(Data("committed".utf8))
    try await wax.commit()
    try await wax.close()
}

private func withStoreURL(_ body: (URL) async throws -> Void) async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    try await body(url)
}

/// A store with a torn pending tail: an intact prefix, a corrupt put at `cutIndex`, then
/// intact puts and a delete that recovery must drop.
private struct TornTailStore {
    var layout: PendingRingLayout
    var cutIndex: Int
    var keptFrameIds: [UInt64]

    var cut: UInt64 { layout.recordOffsets[cutIndex] }
}

/// The delete directly follows the cut: a stale put there would be cut again as a damaged put
/// (its payload is gone), so only a stale delete in that slot shows whether it can chain.
private let droppedTail: [PendingRecordFixture] = [.corruptPut, .delete(frameId: 0), .intactPut, .intactPut]

/// With `wrapsRingEnd`, committed frames first move the checkpoint past the middle of a small
/// ring and intact pending puts fill it to near the end, so the dropped records wrap to the start.
private func makeTornTailStore(at url: URL, wrapsRingEnd: Bool) async throws -> TornTailStore {
    guard wrapsRingEnd else {
        try await createStoreWithOneCommittedFrame(at: url)
        let layout = try appendPendingRecords(to: url, firstFrameId: 1, records: [.intactPut] + droppedTail)
        return TornTailStore(layout: layout, cutIndex: 1, keptFrameIds: [0, 1])
    }

    let walSize: UInt64 = 4096
    var committed: UInt64 = 0
    do {
        let wax = try await Wax.create(at: url, walSize: walSize)
        while await wax.walStats().writePos < walSize / 2 {
            _ = try await wax.put(Data("committed-\(committed)".utf8))
            try await wax.commit()
            committed += 1
        }
        try await wax.close()
    }

    let file = try FDFile.open(at: url)
    defer { try? file.close() }
    var appender = try PendingRecordAppender(file: file, firstFrameId: committed)
    try appender.append(.intactPut)
    let recordSize = appender.writer.writePos - appender.offsets[0]
    while appender.writer.writePos + 3 * recordSize < walSize {
        try appender.append(.intactPut)
    }
    let cutIndex = appender.offsets.count
    for record in droppedTail {
        try appender.append(record)
    }
    try file.fsync()
    return TornTailStore(
        layout: appender.layout,
        cutIndex: cutIndex,
        keptFrameIds: Array(0..<(committed + UInt64(cutIndex)))
    )
}

/// Copies `[start, end)` in ring order (wrapping at the ring end) from `source` into `bytes`.
private func restoreRing(
    _ bytes: inout Data,
    from source: Data,
    layout: PendingRingLayout,
    start: UInt64,
    end: UInt64
) {
    let ringStart: UInt64 = 0
    let spans: [(UInt64, UInt64)] = start <= end ? [(start, end)] : [(start, layout.walSize), (ringStart, end)]
    for (lower, upper) in spans {
        let range = Int(layout.walOffset + lower)..<Int(layout.walOffset + upper)
        bytes.replaceSubrange(range, with: source[range])
    }
}

/// Reopens `bytes`, appends a record of the dropped cut record's length at the cut, then
/// simulates a crash that loses every write after it, so all dropped bytes after the new record
/// are back exactly as they were before recovery. None of them may be replayed.
private func expectDroppedRecordsStayUnreachable(
    from bytes: Data,
    original: Data,
    store: TornTailStore,
    context: String
) async throws {
    let url = TempFiles.uniqueURL()
    let crashURL = TempFiles.uniqueURL()
    defer {
        try? FileManager.default.removeItem(at: url)
        try? FileManager.default.removeItem(at: crashURL)
    }
    try bytes.write(to: url)
    let newFrameId = UInt64(store.keptFrameIds.count)
    let next = store.layout.recordOffsets[store.cutIndex + 1]

    let wax = try await Wax.open(at: url)
    #expect(await wax.frameMetasIncludingPending().map(\.id) == store.keptFrameIds, "\(context)")
    #expect(try await wax.put(Data("pending-\(newFrameId)".utf8), timestampMs: 1_234) == newFrameId)
    // Same length as the dropped cut record, so the next dropped record directly follows it.
    #expect(await wax.walStats().writePos == next, "\(context)")
    var crashed = try Data(contentsOf: url)
    restoreRing(&crashed, from: original, layout: store.layout, start: next, end: store.layout.chainEnd)
    try crashed.write(to: crashURL)
    try await wax.close()

    let recovered = try await Wax.open(at: crashURL)
    let frames = await recovered.frameMetasIncludingPending()
    #expect(frames.map(\.id) == store.keptFrameIds + [newFrameId], "\(context)")
    #expect(frames.first?.status == .active, "stale delete must not be replayed (\(context))")
    try await recovered.close()
}

private func expectOpenFailsClosedWithoutWriting(
    _ url: URL,
    repair: Bool = true,
    options: WaxOptions = .init(),
    expected: (Error) -> Bool
) async throws {
    let before = try Data(contentsOf: url)
    do {
        let wax = try await Wax.open(at: url, repair: repair, options: options)
        try await wax.close()
        Issue.record("Expected open to fail closed")
    } catch {
        #expect(expected(error), "unexpected error: \(error)")
    }
    let after = try Data(contentsOf: url)
    #expect(after == before, "fail-closed open must keep the evidence untouched")
}

private func isChecksumMismatch(_ error: Error) -> Bool {
    if case WaxError.checksumMismatch = error { return true }
    return false
}

private func isInvalidToc(_ error: Error) -> Bool {
    if case WaxError.invalidToc = error { return true }
    return false
}

// MARK: - Genuine torn tail: truncate

@Test func openDropsTornPendingPutFrameInsteadOfFailing() async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        try appendPendingRecords(to: url, firstFrameId: 1, records: [.corruptPut])

        let reopened = try await Wax.open(at: url)
        #expect(await reopened.frameMetasIncludingPending().map(\.id) == [0])
        #expect(try await reopened.frameContent(frameId: 0) == Data("committed".utf8))
        let stats = await reopened.walStats()
        #expect(stats.replayTruncationCount == 1)
        #expect(stats.pendingBytes == 0)
        try await reopened.close()
    }
}

@Test(arguments: [PendingRecordFixture.corruptPut, .putBeyondFileEnd])
func openTruncatesGenuineTornTail(fault: PendingRecordFixture) async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        try appendPendingRecords(to: url, firstFrameId: 1, records: [.intactPut, fault, .putBeyondFileEnd])

        do {
            let reopened = try await Wax.open(at: url)
            #expect(await reopened.frameMetasIncludingPending().map(\.id) == [0, 1])
            #expect(try await reopened.frameContentIncludingPending(frameId: 1) == Data("pending-1".utf8))
            #expect(await reopened.walStats().replayTruncationCount == 1)

            let newId = try await reopened.put(Data("after-recovery".utf8))
            #expect(newId == 2)
            try await reopened.commit()
            try await reopened.close()
        }

        let verified = try await Wax.open(at: url)
        #expect(await verified.frameMetas().map(\.id) == [0, 1, 2])
        #expect(try await verified.frameContent(frameId: 1) == Data("pending-1".utf8))
        #expect(try await verified.frameContent(frameId: 2) == Data("after-recovery".utf8))
        #expect(await verified.walStats().replayTruncationCount == 0)
        try await verified.close()
    }
}

@Test func openDropsNonPutRecordsAfterTornTail() async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        try appendPendingRecords(
            to: url,
            firstFrameId: 1,
            records: [.intactPut, .corruptPut, .delete(frameId: 0)]
        )

        let reopened = try await Wax.open(at: url)
        let frames = await reopened.frameMetasIncludingPending()
        #expect(frames.map(\.id) == [0, 1])
        #expect(frames.first?.status == .active)
        #expect(await reopened.walStats().replayTruncationCount == 1)
        try await reopened.close()
    }
}

@Test func openZeroesTheWholeDroppedWALRangeOnTruncation() async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        let layout = try appendPendingRecords(
            to: url,
            firstFrameId: 1,
            records: [.intactPut, .corruptPut, .delete(frameId: 0), .putBeyondFileEnd]
        )

        let reopened = try await Wax.open(at: url)
        let start = layout.recordOffsets[1]
        #expect(layout.chainEnd > start)
        let file = try FDFile.openReadOnly(at: url)
        let dropped = try file.readExactly(length: Int(layout.chainEnd - start), at: layout.walOffset + start)
        try file.close()
        #expect(dropped.allSatisfy { $0 == 0 }, "dropped WAL records must be invalidated before open returns")
        #expect(await reopened.walStats().writePos == start)
        try await reopened.close()
    }
}

/// Regression for the resurrection probe: after truncation the writer reuses the dropped
/// record's offset. If the new record has the same length and a crash loses everything after it
/// (sentinel and zeroing alike), a stale higher-sequence record must still be unreachable.
@Test func truncatedTailCannotBeResurrectedBehindANewRecord() async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        let layout = try appendPendingRecords(
            to: url,
            firstFrameId: 1,
            records: [.intactPut, .corruptPut, .delete(frameId: 0)]
        )
        let beforeRepair = try Data(contentsOf: url)
        let crashURL = TempFiles.uniqueURL()
        defer { try? FileManager.default.removeItem(at: crashURL) }

        let reopened = try await Wax.open(at: url)
        #expect(await reopened.walStats().lastSeq >= layout.lastSequence)
        let newId = try await reopened.put(Data("pending-2".utf8), timestampMs: 1_234)
        #expect(newId == 2)
        // Same-length record at the reused offset: the stale delete would follow directly.
        #expect(await reopened.walStats().writePos == layout.recordOffsets[2])

        // Crash before commit, losing every write after the new record.
        var crashed = try Data(contentsOf: url)
        let staleStart = Int(layout.walOffset + layout.recordOffsets[2])
        let staleEnd = Int(layout.walOffset + layout.chainEnd)
        crashed.replaceSubrange(staleStart..<staleEnd, with: beforeRepair[staleStart..<staleEnd])
        try crashed.write(to: crashURL)
        try await reopened.close()

        let recovered = try await Wax.open(at: crashURL)
        let frames = await recovered.frameMetasIncludingPending()
        #expect(frames.map(\.id) == [0, 1, 2])
        #expect(frames.first?.status == .active, "stale delete must not be replayed")
        try await recovered.close()
    }
}

@Test func openTruncatesATornTailThatWrapsAcrossTheRingEnd() async throws {
    try await withStoreURL { url in
        let store = try await makeTornTailStore(at: url, wrapsRingEnd: true)
        let ring = store.layout
        #expect(ring.chainEnd < store.cut, "fixture must wrap the dropped records across the ring end")
        let newFrameId = UInt64(store.keptFrameIds.count)

        do {
            let reopened = try await Wax.open(at: url)
            #expect(await reopened.frameMetasIncludingPending().map(\.id) == store.keptFrameIds)
            #expect(await reopened.walStats().writePos == store.cut)
            let bytes = try Data(contentsOf: url)
            let tail = bytes[Int(ring.walOffset + store.cut)..<Int(ring.walOffset + ring.walSize)]
            let head = bytes[Int(ring.walOffset)..<Int(ring.walOffset + ring.chainEnd)]
            #expect(tail.allSatisfy { $0 == 0 }, "dropped records before the ring end must be zeroed")
            #expect(head.allSatisfy { $0 == 0 }, "dropped records after the wrap must be zeroed")

            #expect(try await reopened.put(Data("after-wrap".utf8)) == newFrameId)
            try await reopened.commit()
            try await reopened.close()
        }

        let verified = try await Wax.open(at: url)
        #expect(await verified.frameMetas().map(\.id) == store.keptFrameIds + [newFrameId])
        #expect(try await verified.frameContent(frameId: newFrameId) == Data("after-wrap".utf8))
        try await verified.close()
    }
}

/// Truncation zeroes the dropped records in one pass, so a crash can persist any part of that,
/// including only the cut record's header. For every subset of dropped record headers zeroed,
/// the records left behind must stay unreachable once a new record reuses the cut's slot.
@Test(arguments: [false, true])
func droppedRecordsStayUnreachableAfterAnyPartialZeroing(wrapsRingEnd: Bool) async throws {
    try await withStoreURL { url in
        let store = try await makeTornTailStore(at: url, wrapsRingEnd: wrapsRingEnd)
        let original = try Data(contentsOf: url)
        let dropped = Array(store.layout.recordOffsets[store.cutIndex...])

        for mask in 0..<(1 << dropped.count) {
            var crashed = original
            for (bit, offset) in dropped.enumerated() where mask & (1 << bit) != 0 {
                let start = Int(store.layout.walOffset + offset)
                crashed.replaceSubrange(start..<start + WALRecord.headerSize, with: Data(count: WALRecord.headerSize))
            }
            try await expectDroppedRecordsStayUnreachable(
                from: crashed,
                original: original,
                store: store,
                context: "zeroed headers mask \(mask)"
            )
        }
    }
}

enum TornEnvelope: Sendable {
    case header
    case payload
}

/// Under `.onCommit` a pending WAL record can be torn while later ones reached disk. The chain
/// ends at the tear, so open never sees or zeroes the later records; they must stay unreachable
/// once a new record of the same length takes the torn record's slot.
@Test(arguments: [TornEnvelope.header, .payload])
func recordsBehindATornEnvelopeStayUnreachable(tear: TornEnvelope) async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        let layout = try appendPendingRecords(
            to: url,
            firstFrameId: 1,
            records: [.intactPut, .delete(frameId: 0), .intactPut]
        )
        var torn = try Data(contentsOf: url)
        let first = Int(layout.walOffset + layout.recordOffsets[0])
        switch tear {
        case .header:
            torn.replaceSubrange(first..<first + WALRecord.headerSize, with: Data(count: WALRecord.headerSize))
        case .payload:
            torn[first + WALRecord.headerSize] ^= 0xFF
        }
        try torn.write(to: url)
        let crashURL = TempFiles.uniqueURL()
        defer { try? FileManager.default.removeItem(at: crashURL) }

        let reopened = try await Wax.open(at: url)
        #expect(await reopened.frameMetasIncludingPending().map(\.id) == [0])
        #expect(try await reopened.put(Data("pending-1".utf8), timestampMs: 1_234) == 1)
        #expect(await reopened.walStats().writePos == layout.recordOffsets[1])
        var crashed = try Data(contentsOf: url)
        restoreRing(&crashed, from: torn, layout: layout, start: layout.recordOffsets[1], end: layout.chainEnd)
        try crashed.write(to: crashURL)
        try await reopened.close()

        let recovered = try await Wax.open(at: crashURL)
        let frames = await recovered.frameMetasIncludingPending()
        #expect(frames.map(\.id) == [0, 1])
        #expect(frames.first?.status == .active, "the stale delete behind the tear must not be replayed")
        try await recovered.close()
    }
}

/// Under `.onCommit` a crash can persist a later payload but lose an earlier one, so an intact
/// put after the damaged one is no sign of corruption: recovery still cuts at the first damage.
@Test(arguments: [PendingRecordFixture.corruptPut, .putBeyondFileEnd])
func openCutsAtTheFirstDamagedPutEvenWhenAnIntactPutFollows(fault: PendingRecordFixture) async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        try appendPendingRecords(to: url, firstFrameId: 1, records: [.intactPut, fault, .intactPut])

        let reopened = try await Wax.open(at: url)
        #expect(await reopened.frameMetasIncludingPending().map(\.id) == [0, 1])
        #expect(await reopened.walStats().replayTruncationCount == 1)
        try await reopened.close()
    }
}

// MARK: - Fail closed and keep the evidence

@Test(arguments: [[PendingRecordFixture.corruptPut], [.intactPut, .corruptPut, .intactPut]])
func openFailsClosedOnDamagedPendingPayloadWhenFsyncPolicyIsAlways(records: [PendingRecordFixture]) async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        try appendPendingRecords(to: url, firstFrameId: 1, records: records)

        try await expectOpenFailsClosedWithoutWriting(
            url,
            options: WaxOptions(walFsyncPolicy: .always),
            expected: isChecksumMismatch
        )
    }
}

@Test func openWithoutRepairFailsClosedOnTornTail() async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        try appendPendingRecords(to: url, firstFrameId: 1, records: [.intactPut, .corruptPut, .intactPut])

        try await expectOpenFailsClosedWithoutWriting(url, repair: false, expected: isChecksumMismatch)
    }
}

@Test func openReplaysAllPendingRecordsWhenPayloadsAreIntact() async throws {
    try await withStoreURL { url in
        try await createStoreWithOneCommittedFrame(at: url)
        try appendPendingRecords(to: url, firstFrameId: 1, records: [.intactPut, .intactPut])

        let reopened = try await Wax.open(at: url)
        #expect(await reopened.frameMetasIncludingPending().map(\.id) == [0, 1, 2])
        #expect(await reopened.walStats().replayTruncationCount == 0)
        try await reopened.close()
    }
}

// MARK: - Exactly full ring

/// Fills the ring with pending puts that end exactly where the checkpoint is, so no sentinel
/// is written and replay must stop by returning to the checkpoint.
@Test func openReplaysAnExactlyFullRing() async throws {
    try await withStoreURL { url in
        let walSize: UInt64 = 4096
        do {
            let wax = try await Wax.create(at: url, walSize: walSize)
            try await wax.close()
        }

        let file = try FDFile.open(at: url)
        let writer = try openRingWriter(file)
        #expect(writer.writePos == writer.checkpointPos)
        var frameId: UInt64 = 0
        func appendPut(uri: String?) throws {
            let payload = Data("full-\(frameId)".utf8)
            let offset = try file.size()
            try file.writeAll(payload, at: offset)
            let put = makePut(frameId: frameId, payload: payload, payloadOffset: offset, uri: uri)
            _ = try writer.append(payload: try WALEntryCodec.encode(.putFrame(put)))
            frameId += 1
        }
        func entrySize(uri: String?) throws -> UInt64 {
            let put = makePut(frameId: frameId, payload: Data("full-\(frameId)".utf8), payloadOffset: 0, uri: uri)
            return UInt64(WALRecord.headerSize) + UInt64(try WALEntryCodec.encode(.putFrame(put)).count)
        }

        let base = try entrySize(uri: nil)
        while walSize - writer.pendingBytes >= 2 * base + 64 {
            try appendPut(uri: nil)
        }
        let remaining = walSize - writer.pendingBytes
        var exactURI: String?
        for length in 0..<Int(remaining) {
            let candidate = String(repeating: "u", count: length)
            if try entrySize(uri: candidate) == remaining {
                exactURI = candidate
                break
            }
        }
        try appendPut(uri: try #require(exactURI))
        #expect(writer.pendingBytes == walSize)
        #expect(writer.writePos == writer.checkpointPos)
        try file.fsync()
        try file.close()

        let appended = frameId
        do {
            let reopened = try await Wax.open(at: url)
            let stats = await reopened.walStats()
            #expect(stats.pendingBytes == walSize)
            #expect(stats.replayTruncationCount == 0)
            #expect(await reopened.frameMetasIncludingPending().count == Int(appended))
            try await reopened.close()
        }

        let verified = try await Wax.open(at: url)
        #expect(await verified.frameMetas().count == Int(appended))
        #expect(try await verified.frameContent(frameId: appended - 1) == Data("full-\(appended - 1)".utf8))
        try await verified.close()
    }
}

// MARK: - Policy

@Test func pendingReplayPolicyCutsAtTheFirstDamagedPayload() {
    #expect(PendingReplayPolicy.decide([], allowsTruncation: true) == .replayAll)
    #expect(PendingReplayPolicy.decide([.intact, .notApplicable], allowsTruncation: true) == .replayAll)
    #expect(
        PendingReplayPolicy.decide([.intact, .checksumMismatch, .notApplicable, .outOfBounds], allowsTruncation: true)
            == .truncateTornTail(at: 1)
    )
    #expect(
        PendingReplayPolicy.decide([.notApplicable, .outOfBounds, .intact], allowsTruncation: true)
            == .truncateTornTail(at: 1)
    )
    #expect(
        PendingReplayPolicy.decide([.intact, .checksumMismatch, .intact], allowsTruncation: false)
            == .failClosed(at: 1)
    )
}
