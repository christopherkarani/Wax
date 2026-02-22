import Foundation
import Testing
@testable import WaxCore

private func encodeFrameMetaBytes(
    id: UInt64 = 0,
    timestamp: Int64 = 123,
    anchorTs: Int64? = 456,
    kind: String? = "text",
    track: String? = "main",
    payloadOffset: UInt64 = 9_216,
    payloadLength: UInt64 = 10,
    checksum: Data = Data(repeating: 0xAA, count: 32),
    uri: String? = "mv2://doc/1",
    title: String? = "Doc",
    canonicalEncoding: UInt8 = 1,
    canonicalLength: UInt64? = 999,
    storedChecksum: Data? = Data(repeating: 0xBB, count: 32),
    metadata: Metadata? = Metadata(["a": "1"]),
    searchText: String? = "hello",
    tags: [TagPair] = [TagPair(key: "k", value: "v")],
    labels: [String] = ["l1"],
    contentDates: [String] = ["2024-01-01"],
    role: UInt8 = 3,
    parentId: UInt64? = 42,
    chunkIndex: UInt32? = 1,
    chunkCount: UInt32? = 2,
    chunkManifest: Data? = Data([0x01, 0x02, 0x03]),
    status: UInt8 = 1,
    supersedes: UInt64? = 7,
    supersededBy: UInt64? = 8
) throws -> Data {
    var encoder = BinaryEncoder()
    encoder.encode(id)
    encoder.encode(timestamp)
    encoder.encode(anchorTs)
    try encoder.encode(kind)
    try encoder.encode(track)
    encoder.encode(payloadOffset)
    encoder.encode(payloadLength)
    encoder.encodeFixedBytes(checksum)
    try encoder.encode(uri)
    try encoder.encode(title)
    encoder.encode(canonicalEncoding)
    encoder.encode(canonicalLength)

    if let storedChecksum {
        encoder.encode(UInt8(1))
        encoder.encodeFixedBytes(storedChecksum)
    } else {
        encoder.encode(UInt8(0))
    }

    try encoder.encode(metadata) { encoder, value in
        var mutable = value
        try mutable.encode(to: &encoder)
    }

    try encoder.encode(searchText)

    try encoder.encode(tags) { encoder, pair in
        try encoder.encode(pair.key)
        try encoder.encode(pair.value)
    }
    try encoder.encode(labels)
    try encoder.encode(contentDates)

    encoder.encode(role)
    encoder.encode(parentId)
    encoder.encode(chunkIndex)
    encoder.encode(chunkCount)

    try encoder.encode(chunkManifest) { encoder, value in
        try encoder.encodeBytes(value)
    }

    encoder.encode(status)
    encoder.encode(supersedes)
    encoder.encode(supersededBy)

    return encoder.data
}

@Test func frameMetaRoundtripFullFieldCoverage() throws {
    let frame = FrameMeta(
        id: 0,
        timestamp: 123,
        anchorTs: 456,
        kind: "text",
        track: "main",
        payloadOffset: 9_216,
        payloadLength: 10,
        checksum: Data(repeating: 0xAA, count: 32),
        uri: "mv2://doc/1",
        title: "Doc",
        canonicalEncoding: .lzfse,
        canonicalLength: 999,
        storedChecksum: Data(repeating: 0xBB, count: 32),
        metadata: Metadata(["a": "1"]),
        searchText: "hello",
        tags: [TagPair(key: "k", value: "v")],
        labels: ["l1"],
        contentDates: ["2024-01-01"],
        role: .system,
        parentId: 42,
        chunkIndex: 1,
        chunkCount: 2,
        chunkManifest: Data([0x01, 0x02, 0x03]),
        status: .deleted,
        supersedes: 7,
        supersededBy: 8
    )

    var encoder = BinaryEncoder()
    var mutable = frame
    try mutable.encode(to: &encoder)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try FrameMeta.decode(from: &decoder)
    try decoder.finalize()

    #expect(decoded == frame)
}

@Test func frameMetaRejectsMissingStoredChecksumWhenPayloadLengthPositive() throws {
    let bytes = try encodeFrameMetaBytes(
        payloadLength: 1,
        canonicalEncoding: 0,
        canonicalLength: nil,
        storedChecksum: nil,
        role: 0,
        status: 0
    )

    do {
        var decoder = try BinaryDecoder(data: bytes)
        _ = try FrameMeta.decode(from: &decoder)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func frameMetaRejectsMissingCanonicalLengthWhenCompressed() throws {
    let bytes = try encodeFrameMetaBytes(
        payloadLength: 1,
        canonicalEncoding: 1,
        canonicalLength: nil,
        storedChecksum: Data(repeating: 0xBB, count: 32)
    )

    do {
        var decoder = try BinaryDecoder(data: bytes)
        _ = try FrameMeta.decode(from: &decoder)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func frameMetaRejectsInvalidEnums() throws {
    let bytes = try encodeFrameMetaBytes(
        payloadLength: 1,
        canonicalEncoding: 9,
        canonicalLength: 123,
        storedChecksum: Data(repeating: 0xBB, count: 32),
        role: 255,
        status: 2
    )

    do {
        var decoder = try BinaryDecoder(data: bytes)
        _ = try FrameMeta.decode(from: &decoder)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func frameMetaRejectsOversizedPayloadLength() throws {
    let bytes = try encodeFrameMetaBytes(
        payloadLength: Constants.maxFramePayloadBytes + 1,
        canonicalEncoding: 0,
        canonicalLength: nil,
        storedChecksum: Data(repeating: 0xBB, count: 32),
        role: 0,
        status: 0
    )

    do {
        var decoder = try BinaryDecoder(data: bytes)
        _ = try FrameMeta.decode(from: &decoder)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("payload_length"))
    }
}

@Test func frameMetaRejectsOversizedCanonicalLength() throws {
    let bytes = try encodeFrameMetaBytes(
        payloadLength: 64,
        canonicalEncoding: 1,
        canonicalLength: Constants.maxFramePayloadBytes + 1,
        storedChecksum: Data(repeating: 0xBB, count: 32)
    )

    do {
        var decoder = try BinaryDecoder(data: bytes)
        _ = try FrameMeta.decode(from: &decoder)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("canonical_length"))
    }
}
