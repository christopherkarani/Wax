import Foundation
import Testing
@testable import WaxCore

/// A frame whose optional fields, collections, roles and encodings vary with `index`.
private func variedFrame(_ index: Int) -> FrameMeta {
    let full = index % 3 == 0
    let compressed = index % 5 == 0
    let empty = index % 7 == 0
    return FrameMeta(
        id: UInt64(index),
        timestamp: 1_700_000_000_000 + Int64(index),
        anchorTs: full ? Int64(index) : nil,
        kind: index % 2 == 0 ? "text" : nil,
        track: full ? "track-\(index % 4)" : nil,
        payloadOffset: 9_216 + UInt64(index) * 64,
        payloadLength: empty ? 0 : 64,
        checksum: Data(repeating: UInt8(index % 251), count: 32),
        uri: full ? "wax://doc/\(index)" : nil,
        title: index % 4 == 0 ? "Título \(index) 🐝" : nil,
        canonicalEncoding: compressed ? .lzfse : .plain,
        canonicalLength: compressed || full ? 128 : nil,
        storedChecksum: empty ? nil : Data(repeating: 0xBB, count: 32),
        metadata: index % 2 == 1
            ? Metadata(["doc_id": "\(index)", "source": "msmarco"])
            : (full ? Metadata([:]) : nil),
        searchText: index % 6 == 5 ? nil : String(repeating: "passage \(index) text ", count: index % 9 + 1),
        tags: full ? [TagPair(key: "k\(index % 3)", value: "v"), TagPair(key: "lang", value: "日本語")] : [],
        labels: index % 3 == 1 ? ["l1", "l\(index)"] : [],
        contentDates: full ? ["2026-11-12"] : [],
        role: FrameRole(rawValue: UInt8(index % 4))!,
        parentId: index % 4 == 1 ? UInt64(index - 1) : nil,
        chunkIndex: index % 4 == 1 ? UInt32(index % 3) : nil,
        chunkCount: index % 4 == 1 ? 3 : nil,
        chunkManifest: index % 10 == 0 ? Data([0x01, 0x02, 0x03]) : nil,
        status: index % 11 == 0 ? .deleted : .active,
        supersedes: index % 13 == 0 ? 1 : nil,
        supersededBy: index % 17 == 0 ? 2 : nil
    )
}

/// The frames' records back to back, and the offset where each record ends.
private func encodedFrames(_ frames: [FrameMeta]) throws -> (bytes: Data, ends: [Int]) {
    var encoder = BinaryEncoder()
    var ends: [Int] = []
    for frame in frames {
        var mutable = frame
        try mutable.encode(to: &encoder)
        ends.append(encoder.data.count)
    }
    return (encoder.data, ends)
}

/// The frames a decode returned, or its error's description, and where the decoder stopped.
private struct DecodeOutcome {
    var frames: [FrameMeta]?
    var error: String?
    var position: Int
}

/// Decodes `count` records from `bytes` in `chunkCount` chunks.
private func decode(_ bytes: Data, count: Int, chunkCount: Int) throws -> DecodeOutcome {
    var decoder = try BinaryDecoder(data: bytes)
    do {
        let frames = try WaxTOC.decodeFrames(count: count, chunkCount: chunkCount, from: &decoder)
        return DecodeOutcome(frames: frames, position: decoder.position)
    } catch {
        return DecodeOutcome(error: String(describing: error), position: decoder.position)
    }
}

@Test func frameSkipConsumesExactlyTheBytesDecodeReads() throws {
    let frames = (0..<240).map(variedFrame)
    let (bytes, ends) = try encodedFrames(frames)
    var skipping = try BinaryDecoder(data: bytes)
    var decoding = try BinaryDecoder(data: bytes)
    for (frame, end) in zip(frames, ends) {
        try FrameMeta.skip(in: &skipping)
        #expect(try FrameMeta.decode(from: &decoding) == frame)
        #expect(skipping.position == end)
        #expect(decoding.position == end)
    }
}

@Test(arguments: [2, 3, 7, 16])
func chunkedFrameDecodeMatchesTheSequentialDecode(chunkCount: Int) throws {
    let frames = (0..<241).map(variedFrame)
    var (bytes, _) = try encodedFrames(frames)
    let framesEnd = bytes.count
    bytes.append(contentsOf: [0xEE, 0xEE, 0xEE]) // what follows the frames in a TOC
    let sequential = try decode(bytes, count: frames.count, chunkCount: 1)
    let chunked = try decode(bytes, count: frames.count, chunkCount: chunkCount)
    #expect(sequential.frames == frames)
    #expect(chunked.frames == frames)
    #expect(sequential.position == framesEnd)
    #expect(chunked.position == framesEnd)
}

/// A frame that fails to decode in the middle of a chunk, or bytes that end early, give the
/// sequential decode's error.
@Test func chunkedFrameDecodeThrowsTheSequentialError() throws {
    var frames = (0..<200).map(variedFrame)
    // No optional fields before the encoding byte: id, timestamp, three absent optionals,
    // payload offset and length, checksum, two absent optionals.
    frames[150] = FrameMeta(
        id: 150, timestamp: 1, payloadOffset: 9_216, payloadLength: 0,
        checksum: Data(repeating: 0xAA, count: 32), canonicalEncoding: .plain
    )
    var (bytes, ends) = try encodedFrames(frames)
    bytes[ends[149] + 8 + 8 + 3 + 16 + 32 + 2] = 9 // canonical encoding
    let sequential = try decode(bytes, count: frames.count, chunkCount: 1)
    let chunked = try decode(bytes, count: frames.count, chunkCount: 7)
    #expect(sequential.error?.contains("invalid canonical_encoding 9") == true)
    #expect(chunked.error == sequential.error)

    let truncated = Data(bytes.prefix(ends[198] + 5))
    let sequentialTruncated = try decode(truncated, count: frames.count, chunkCount: 1)
    let chunkedTruncated = try decode(truncated, count: frames.count, chunkCount: 7)
    #expect(sequentialTruncated.error != nil)
    #expect(chunkedTruncated.error == sequentialTruncated.error)
}

/// Where each record starts: 0, then where the one before it ends.
private func recordStarts(_ ends: [Int]) -> [Int] {
    [0] + ends.dropLast()
}

@Test(arguments: [2, 7, 16])
func chunkStartsAreFoundWithoutSkippingTheRecordsBeforeThem(chunkCount: Int) throws {
    let frames = (0..<241).map(variedFrame)
    var (bytes, ends) = try encodedFrames(frames)
    bytes.append(contentsOf: [0xEE, 0xEE, 0xEE])
    let starts = WaxTOC.speculativeChunkStarts(
        count: frames.count,
        chunkCount: chunkCount,
        in: try BinaryDecoder(data: bytes)
    )
    #expect(starts.count == chunkCount)
    #expect(starts.first == WaxTOC.FrameRecordStart(frame: 0, offset: 0))
    #expect(zip(starts, starts.dropFirst()).allSatisfy { $0.frame < $1.frame && $0.offset < $1.offset })
    let truth = recordStarts(ends)
    for start in starts {
        #expect(truth[start.frame] == start.offset)
    }
}

/// A frame record with only its fixed fields, whose encoding is all ASCII when `id` is
/// below 128.
private func asciiFrame(_ id: Int) -> FrameMeta {
    FrameMeta(
        id: UInt64(id), timestamp: 1, payloadOffset: 1, payloadLength: 0,
        checksum: Data(repeating: 0x41, count: 32), canonicalEncoding: .plain
    )
}

/// A string that holds encoded frame records, so a search for where records start can land
/// on records that are not there. The decode still returns exactly the sequential result.
@Test func recordsInsideAStringDoNotChangeTheChunkedDecode() throws {
    let fakes = try encodedFrames((100..<110).map(asciiFrame)).bytes
    var fakeText = Data()
    for _ in 0..<300 { fakeText.append(fakes) }
    var frames = (0..<200).map(variedFrame)
    frames[50].searchText = String(decoding: fakeText, as: UTF8.self)
    #expect(frames[50].searchText?.utf8.count == fakeText.count)
    var (bytes, ends) = try encodedFrames(frames)
    let framesEnd = bytes.count
    bytes.append(contentsOf: [0xEE, 0xEE, 0xEE])

    let starts = WaxTOC.speculativeChunkStarts(
        count: frames.count,
        chunkCount: 8,
        in: try BinaryDecoder(data: bytes)
    )
    let truth = recordStarts(ends)
    #expect(starts.contains { truth[$0.frame] != $0.offset }, "the search lands inside frame 50's text")

    let chunked = try decode(bytes, count: frames.count, chunkCount: 8)
    #expect(chunked.frames == frames)
    #expect(chunked.position == framesEnd)
}

@Test func tocAboveTheParallelThresholdDecodesTheFramesItEncoded() throws {
    var toc = WaxTOC.emptyV1()
    toc.frames = (0..<(WaxTOC.parallelFrameDecodeThreshold + 1_001)).map(variedFrame)
    let decoded = try WaxTOC.decode(from: try toc.encode())
    #expect(decoded.frames == toc.frames)
}
