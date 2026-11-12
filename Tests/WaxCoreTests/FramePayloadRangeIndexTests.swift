import Foundation
import Testing
@testable import WaxCore

// A commit validates only its new frames against the committed frames' range index. That must
// accept and reject exactly what validating the whole TOC accepts and rejects.

private struct SplitMix64: RandomNumberGenerator {
    var state: UInt64
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private let dataStart: UInt64 = 1_000
private let dataEnd: UInt64 = 1_000_000

private func frame(_ id: UInt64, offset: UInt64, length: UInt64) -> FrameMeta {
    FrameMeta(
        id: id,
        timestamp: 123,
        payloadOffset: offset,
        payloadLength: length,
        checksum: Data(repeating: 0xAA, count: 32),
        canonicalEncoding: .plain,
        canonicalLength: nil,
        storedChecksum: length > 0 ? Data(repeating: 0xBB, count: 32) : nil
    )
}

private func segment(_ id: UInt64, offset: UInt64, length: UInt64) -> SegmentCatalogEntry {
    SegmentCatalogEntry(
        segmentId: id,
        bytesOffset: offset,
        bytesLength: length,
        checksum: Data(repeating: 0xCC, count: 32),
        compression: .none,
        kind: .vec
    )
}

/// Disjoint ranges in shuffled order, so payloads land both above and in holes below the
/// committed ones, as space reuse places them.
private func disjointRanges(count: Int, using rng: inout SplitMix64) -> [(offset: UInt64, length: UInt64)] {
    var cursor = dataStart
    var ranges: [(UInt64, UInt64)] = []
    for _ in 0..<count {
        cursor += UInt64.random(in: 0...40, using: &rng)
        let length = UInt64.random(in: 0...30, using: &rng)
        ranges.append((cursor, length))
        cursor += length
    }
    return ranges.shuffled(using: &rng)
}

private func expectInvalidToc(
    _ expected: String,
    sourceLocation: SourceLocation = #_sourceLocation,
    _ body: () throws -> Void
) {
    do {
        try body()
        Issue.record("expected invalidToc(\(expected))", sourceLocation: sourceLocation)
    } catch WaxError.invalidToc(let reason) {
        #expect(reason == expected, sourceLocation: sourceLocation)
    } catch {
        Issue.record("unexpected error \(error)", sourceLocation: sourceLocation)
    }
}

private func fullValidationError(frames: [FrameMeta], segments: [SegmentCatalogEntry]) -> String? {
    var toc = WaxTOC.emptyV1()
    toc.frames = frames
    toc.segmentCatalog = SegmentCatalog(entries: segments)
    do {
        try Wax.validateTocRanges(toc, dataStart: dataStart, dataEnd: dataEnd)
        return nil
    } catch {
        return "\(error)"
    }
}

private func incrementalValidationError(
    committed: [FrameMeta],
    added: [FrameMeta],
    segments: [SegmentCatalogEntry]
) throws -> String? {
    let index = try Wax.FramePayloadRangeIndex(frames: committed[...], dataStart: dataStart, dataEnd: dataEnd)
    do {
        try index.validateAppending(added, segments: segments, dataStart: dataStart, dataEnd: dataEnd)
        return nil
    } catch {
        return "\(error)"
    }
}

/// Frames with disjoint payloads plus two segments, the last `total - committedCount` frames
/// new, with at most one overlap planted: a new frame or a segment over part of another range.
private func randomLayout(seed: UInt64) -> (committed: [FrameMeta], added: [FrameMeta], segments: [SegmentCatalogEntry]) {
    var rng = SplitMix64(state: seed)
    let total = Int.random(in: 1...60, using: &rng)
    let ranges = disjointRanges(count: total + 2, using: &rng)
    var frames = (0..<total).map { index in
        frame(UInt64(index), offset: ranges[index].offset, length: ranges[index].length)
    }
    var segments = [
        segment(0, offset: ranges[total].offset, length: ranges[total].length),
        segment(1, offset: ranges[total + 1].offset, length: ranges[total + 1].length),
    ]
    let committedCount = Int.random(in: 0...total, using: &rng)
    let victim = Int.random(in: 0..<total, using: &rng)
    switch Int.random(in: 0..<3, using: &rng) {
    case 1 where committedCount < total && frames[victim].payloadLength > 0:
        let target = Int.random(in: committedCount..<total, using: &rng)
        let start = frames[victim].payloadOffset + UInt64.random(in: 0..<frames[victim].payloadLength, using: &rng)
        frames[target] = frame(UInt64(target), offset: start, length: max(1, frames[target].payloadLength))
    case 2 where frames[victim].payloadLength > 0:
        let start = frames[victim].payloadOffset + UInt64.random(in: 0..<frames[victim].payloadLength, using: &rng)
        segments[1] = segment(1, offset: start, length: 4)
    default:
        break
    }
    return (Array(frames[..<committedCount]), Array(frames[committedCount...]), segments)
}

@Test func incrementalRangeValidationMatchesFullValidation() throws {
    var rejected = 0
    for seed in UInt64(0)..<2_000 {
        let layout = randomLayout(seed: seed)
        let full = fullValidationError(frames: layout.committed + layout.added, segments: layout.segments)
        let incremental = try incrementalValidationError(
            committed: layout.committed,
            added: layout.added,
            segments: layout.segments
        )
        // With one planted overlap the two checks can still name different pairs (a range
        // can overlap two others), so compare only whether each rejects the layout.
        #expect((full == nil) == (incremental == nil), "seed \(seed): full \(full ?? "ok"), incremental \(incremental ?? "ok")")
        if full != nil { rejected += 1 }
    }
    // Both outcomes are exercised.
    #expect(rejected > 300)
    #expect(rejected < 1_700)
}

@Test func rangeIndexRejectsANewFrameInsideACommittedOne() throws {
    let committed = [frame(0, offset: 2_000, length: 100), frame(1, offset: 1_000, length: 100)]
    let index = try Wax.FramePayloadRangeIndex(frames: committed[...], dataStart: dataStart, dataEnd: dataEnd)
    expectInvalidToc("data overlap between frame 1 and frame 2") {
        try index.validateAppending(
            [frame(2, offset: 1_050, length: 10)],
            segments: [],
            dataStart: dataStart,
            dataEnd: dataEnd
        )
    }
    expectInvalidToc("data overlap between frame 2 and frame 0") {
        try index.validateAppending(
            [frame(2, offset: 1_990, length: 20)],
            segments: [],
            dataStart: dataStart,
            dataEnd: dataEnd
        )
    }
    // Touching ranges do not overlap.
    try index.validateAppending(
        [frame(2, offset: 1_100, length: 900), frame(3, offset: 2_100, length: 1)],
        segments: [segment(0, offset: 2_101, length: 5)],
        dataStart: dataStart,
        dataEnd: dataEnd
    )
}

@Test func rangeIndexRejectsOverlapsAmongNewFramesAndSegments() throws {
    let index = try Wax.FramePayloadRangeIndex(frames: [][...], dataStart: dataStart, dataEnd: dataEnd)
    expectInvalidToc("data overlap between frame 0 and frame 1") {
        try index.validateAppending(
            [frame(0, offset: 1_000, length: 10), frame(1, offset: 1_005, length: 10)],
            segments: [],
            dataStart: dataStart,
            dataEnd: dataEnd
        )
    }
    expectInvalidToc("data overlap between frame 0 and segment 7") {
        try index.validateAppending(
            [frame(0, offset: 1_000, length: 10)],
            segments: [segment(7, offset: 1_009, length: 10)],
            dataStart: dataStart,
            dataEnd: dataEnd
        )
    }
}

@Test func rangeIndexChecksEachNewFrame() throws {
    let index = try Wax.FramePayloadRangeIndex(
        frames: [frame(0, offset: 1_000, length: 10)][...],
        dataStart: dataStart,
        dataEnd: dataEnd
    )
    expectInvalidToc("frame id not dense: found 2, expected 1") {
        try index.validateAppending([frame(2, offset: 2_000, length: 1)], segments: [], dataStart: dataStart, dataEnd: dataEnd)
    }
    expectInvalidToc("frame 1 payload exceeds data end") {
        try index.validateAppending([frame(1, offset: dataEnd, length: 1)], segments: [], dataStart: dataStart, dataEnd: dataEnd)
    }
    expectInvalidToc("frame 1 payload below data region") {
        try index.validateAppending([frame(1, offset: 10, length: 1)], segments: [], dataStart: dataStart, dataEnd: dataEnd)
    }
}

@Test func rangeIndexAppendKeepsRangesSortedAndTracksTheEnd() throws {
    var index = try Wax.FramePayloadRangeIndex(
        frames: [frame(0, offset: 5_000, length: 10), frame(1, offset: 1_000, length: 10)][...],
        dataStart: dataStart,
        dataEnd: dataEnd
    )
    #expect(index.end == 5_010)
    #expect(index.frameCount == 2)

    // Into a hole below the highest range, then above it.
    index.append([frame(2, offset: 3_000, length: 10), frame(3, offset: 0, length: 0)])
    #expect(index.end == 5_010)
    #expect(index.frameCount == 4)
    index.append([frame(4, offset: 9_000, length: 50)])
    #expect(index.end == 9_050)

    expectInvalidToc("data overlap between frame 2 and frame 5") {
        try index.validateAppending([frame(5, offset: 3_005, length: 1)], segments: [], dataStart: dataStart, dataEnd: dataEnd)
    }
    try index.validateAppending([frame(5, offset: 3_010, length: 1_990)], segments: [], dataStart: dataStart, dataEnd: dataEnd)
}

/// End of the highest range `toc` references, by a pass over every frame and segment.
private func scannedReferencedDataEnd(_ toc: WaxTOC) -> UInt64 {
    let frameEnds = toc.frames.filter { $0.payloadLength > 0 }.map { $0.payloadOffset + $0.payloadLength }
    let segmentEnds = toc.segmentCatalog.entries.filter { $0.bytesLength > 0 }.map { $0.bytesOffset + $0.bytesLength }
    return (frameEnds + segmentEnds).max() ?? 0
}

@Test func referencedDataEndTracksFramesPlacedInReusedSpace() async throws {
    let url = TempFiles.uniqueURL()
    defer { try? FileManager.default.removeItem(at: url) }
    let wax = try await Wax.create(at: url, walSize: 256 * 1024)
    var frameCount = 0
    for round in 0..<6 {
        // A shrinking lex segment frees space each commit; later payloads reuse it.
        let lex = Data(repeating: UInt8(round), count: 40_000 - round * 5_000)
        for _ in 0..<(3 + round) {
            _ = try await wax.put(Data(repeating: UInt8(frameCount % 251), count: 700 + frameCount * 37))
            frameCount += 1
        }
        try await wax.stageLexIndexForNextCommit(bytes: lex, docCount: UInt64(frameCount))
        try await wax.commit()
        let toc = await wax.toc
        #expect(try await wax.referencedDataEndLocked(appendedFrames: []) == scannedReferencedDataEnd(toc), "round \(round)")
    }
    let toc = await wax.toc
    let committedRange = await wax.dataSpace.committedTocRange
    #expect(committedRange.lowerBound >= scannedReferencedDataEnd(toc))
    // Some payload went below an earlier one, into freed space.
    let offsets = toc.frames.map(\.payloadOffset)
    #expect(offsets != offsets.sorted())
    try await wax.close()

    let reopened = try await Wax.open(at: url)
    try await reopened.verify(deep: true)
    try await reopened.close()
}
