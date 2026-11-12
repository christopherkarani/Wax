import Foundation
import Testing
@testable import WaxCore

private func restampTocChecksum(_ bytes: inout Data) {
    let checksum = WaxTOC.computeChecksum(for: bytes)
    bytes.replaceSubrange((bytes.count - 32)..<bytes.count, with: checksum)
}

@Test func tocChecksumIsStampedAsFinal32Bytes() throws {
    var toc = WaxTOC.emptyV1()
    toc.frames = [
        FrameMeta(
            id: 0,
            timestamp: 123,
            payloadOffset: 9_216,
            payloadLength: 0,
            checksum: Data(repeating: 0xAA, count: 32),
            canonicalEncoding: .plain
        )
    ]

    let bytes = try toc.encode()
    #expect(bytes.count >= 32)

    let body = Data(bytes.dropLast(32))
    let stored = Data(bytes.suffix(32))

    var hasher = SHA256Checksum()
    hasher.update(body)
    hasher.update(Data(repeating: 0, count: 32))
    let computed = hasher.finalize()

    #expect(stored == computed)
}

@Test func tocEncodingIsDeterministic() throws {
    let toc = WaxTOC.emptyV1()
    let first = try toc.encode()
    let second = try toc.encode()
    #expect(first == second)
}

@Test func tocDecodeRejectsChecksumMismatch() throws {
    let toc = WaxTOC.emptyV1()
    var bytes = try toc.encode()
    bytes[0] ^= 0xFF

    do {
        _ = try WaxTOC.decode(from: bytes)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func tocEncodeRejectsUnsupportedTocVersion() throws {
    var toc = WaxTOC.emptyV1()
    toc.tocVersion = 2

    do {
        _ = try toc.encode()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func tocEncodeRejectsNonDenseFrameIds() throws {
    var toc = WaxTOC.emptyV1()
    toc.frames = [
        FrameMeta(
            id: 1,
            timestamp: 123,
            payloadOffset: 9_216,
            payloadLength: 0,
            checksum: Data(repeating: 0xAA, count: 32),
            canonicalEncoding: .plain
        )
    ]

    do {
        _ = try toc.encode()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func tocDecodeRejectsUnsupportedTocVersion() throws {
    var bytes = try WaxTOC.emptyV1().encode()
    bytes[0] = 2 // toc_version (UInt64, little-endian)
    restampTocChecksum(&bytes)

    do {
        _ = try WaxTOC.decode(from: bytes)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func tocDecodeRejectsNonDenseFrameIds() throws {
    var toc = WaxTOC.emptyV1()
    toc.frames = [
        FrameMeta(
            id: 0,
            timestamp: 123,
            payloadOffset: 9_216,
            payloadLength: 0,
            checksum: Data(repeating: 0xAA, count: 32),
            canonicalEncoding: .plain
        )
    ]
    var bytes = try toc.encode()
    bytes[12] = 1 // first frame id (UInt64, little-endian) starts at byte offset 12
    restampTocChecksum(&bytes)

    do {
        _ = try WaxTOC.decode(from: bytes)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func tocDecodeRejectsReservedTracksInV1() throws {
    var bytes = try WaxTOC.emptyV1().encode()
    bytes[16] = 1 // memories_track tag
    restampTocChecksum(&bytes)

    do {
        _ = try WaxTOC.decode(from: bytes)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .invalidToc = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test func ticketRefRoundtrip() throws {
    var ticket = TicketRef(
        issuer: "memvid.com",
        seqNo: 123,
        expiresInSecs: 456,
        capacityBytes: 789,
        verified: 1
    )

    var encoder = BinaryEncoder()
    try ticket.encode(to: &encoder)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try TicketRef.decode(from: &decoder)
    try decoder.finalize()

    #expect(decoded == ticket)
}

@Test func timeIndexManifestRoundtrip() throws {
    var manifest = TimeIndexManifest(
        bytesOffset: 100,
        bytesLength: 200,
        entryCount: 3,
        checksum: Data(repeating: 0xAB, count: 32)
    )

    var encoder = BinaryEncoder()
    try manifest.encode(to: &encoder)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try TimeIndexManifest.decode(from: &decoder)
    try decoder.finalize()

    #expect(decoded == manifest)
}

/// Readers reject a TOC above `maxTocBytes`, so a commit must not write one: the store would
/// then open on an older footer whose WAL was already checkpointed.
@Test func tocEncodeRejectsATocReadersWouldReject() throws {
    let toc = WaxTOC.emptyV1()
    let size = try toc.encode().count
    #expect(throws: WaxError.self) { try toc.encode(maxBytes: UInt64(size - 1)) }
    #expect(try toc.encode(maxBytes: UInt64(size)).count == size)
}

/// A commit writes the encoding in parts with the cached frames payload in the middle; joined,
/// they are the bytes `encode` returns, with or without the cache.
@Test func tocEncodedPartsJoinToTheEncodingWithTheCachedFramesPayloadUncopied() throws {
    var toc = WaxTOC.emptyV1()
    toc.frames = (0..<3).map { index in
        FrameMeta(
            id: UInt64(index),
            timestamp: 100 + Int64(index),
            payloadOffset: 9_216 + UInt64(index) * 8,
            payloadLength: 8,
            checksum: Data(repeating: 0xAA, count: 32),
            canonicalEncoding: .plain,
            storedChecksum: Data(repeating: 0xBB, count: 32)
        )
    }
    toc.merkleRoot = Data(repeating: 0x5A, count: 32)
    let fresh = try toc.encode()
    // toc_version, then the frame count.
    let framesStart = MemoryLayout<UInt64>.size + MemoryLayout<UInt32>.size

    var encoder = BinaryEncoder()
    for frame in toc.frames {
        var mutable = frame
        try mutable.encode(to: &encoder)
    }
    let framesPayload = encoder.data

    let parts = try toc.encodeParts(cachedFramesPayload: framesPayload)
    #expect(parts.head.count == framesStart)
    #expect(parts.frames == framesPayload)
    #expect(parts.parts.reduce(Data(), +) == fresh)
    #expect(parts.byteCount == fresh.count)
    #expect(parts.checksum == WaxTOC.computeChecksum(for: fresh))
    #expect(try toc.encode(cachedFramesPayload: framesPayload) == fresh)

    let uncached = try toc.encodeParts()
    #expect(uncached.frames.isEmpty)
    #expect(uncached.parts.reduce(Data(), +) == fresh)

    #expect(throws: WaxError.self) {
        try toc.encodeParts(cachedFramesPayload: framesPayload, maxBytes: UInt64(fresh.count - 1))
    }
}
