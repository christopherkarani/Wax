import Foundation
import Testing
@testable import WaxCore

// Decoded element counts come from disk. A crafted count under `maxArrayCount` must be
// rejected against the bytes actually left before it can drive `reserveCapacity`.

private func countPrefixed(_ count: UInt32, trailing: Int = 0) -> Data {
    var encoder = BinaryEncoder()
    encoder.encode(count)
    return encoder.data + Data(repeating: 0, count: trailing)
}

private func decodingReason(_ body: () throws -> Void) -> String? {
    do {
        try body()
        return nil
    } catch let WaxError.decodingError(reason) {
        return reason
    } catch let WaxError.invalidToc(reason) {
        return reason
    } catch {
        return "unexpected error: \(error)"
    }
}

@Test func binaryDecoderRejectsArrayCountLargerThanRemainingBytes() throws {
    var decoder = try BinaryDecoder(data: countPrefixed(5_000_000, trailing: 16))
    let reason = decodingReason { _ = try decoder.decodeArray(UInt64.self) }
    #expect(reason?.contains("exceeds remaining bytes") ?? false, "got: \(String(describing: reason))")
}

@Test func binaryDecoderRejectsStringArrayCountLargerThanRemainingBytes() throws {
    // Each string needs at least its 4-byte length prefix.
    var decoder = try BinaryDecoder(data: countPrefixed(5, trailing: 16))
    let reason = decodingReason { _ = try decoder.decodeArray(String.self) }
    #expect(reason?.contains("exceeds remaining bytes") ?? false, "got: \(String(describing: reason))")
}

@Test func binaryDecoderStillDecodesArrayThatFitsExactly() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt64(1), 2, 3])
    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeArray(UInt64.self) == [1, 2, 3])
    try decoder.finalize()
}

@Test func metadataDecodeRejectsCountLargerThanRemainingBytes() throws {
    var decoder = try BinaryDecoder(data: countPrefixed(9_000_000, trailing: 8))
    let reason = decodingReason { _ = try Metadata.decode(from: &decoder) }
    #expect(reason?.contains("exceeds remaining bytes") ?? false, "got: \(String(describing: reason))")
}

@Test func segmentCatalogDecodeRejectsCountLargerThanRemainingBytes() throws {
    var decoder = try BinaryDecoder(data: countPrefixed(9_000_000, trailing: 64))
    let reason = decodingReason { _ = try SegmentCatalog.decode(from: &decoder) }
    #expect(reason?.contains("exceeds remaining bytes") ?? false, "got: \(String(describing: reason))")
}

@Test func tocDecodeRejectsCraftedHugeFrameCount() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt64(1)) // toc_version
    encoder.encode(UInt32(Constants.maxArrayCount)) // frame count at the cap
    var toc = encoder.data + Data(repeating: 0, count: 32) // checksum slot
    let checksum = WaxTOC.computeChecksum(for: toc)
    toc.replaceSubrange((toc.count - 32)..<toc.count, with: checksum)

    let reason = decodingReason { _ = try WaxTOC.decode(from: toc) }
    #expect(reason?.contains("exceeds remaining bytes") ?? false, "got: \(String(describing: reason))")
}
