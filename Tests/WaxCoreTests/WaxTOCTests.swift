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
