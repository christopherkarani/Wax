import Foundation
import Testing
@testable import WaxCore

@Test func uint8Roundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(42))
    encoder.encode(UInt8(255))

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(UInt8.self) == 42)
    #expect(try decoder.decode(UInt8.self) == 255)
    try decoder.finalize()
}

@Test func uint16LittleEndian() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt16(0x1234))
    #expect(encoder.data == Data([0x34, 0x12]))

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(UInt16.self) == 0x1234)
    try decoder.finalize()
}

@Test func uint32Roundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt32(0xDEADBEEF))

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(UInt32.self) == 0xDEADBEEF)
    try decoder.finalize()
}

@Test func uint64Roundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt64.max)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(UInt64.self) == UInt64.max)
    try decoder.finalize()
}

@Test func int64Roundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Int64(-1_000_000))

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(Int64.self) == -1_000_000)
    try decoder.finalize()
}

@Test func stringRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode("Hello, 世界!")

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(String.self) == "Hello, 世界!")
    try decoder.finalize()
}

@Test func emptyStringRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode("")
    #expect(encoder.data.count == 4)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(String.self) == "")
    try decoder.finalize()
}

@Test func arrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt8(1), UInt8(2), UInt8(3)])

    var decoder = try BinaryDecoder(data: encoder.data)
    let result = try decoder.decodeArray(UInt8.self)
    #expect(result == [1, 2, 3])
    try decoder.finalize()
}

@Test func emptyArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt64]())

    var decoder = try BinaryDecoder(data: encoder.data)
    let result = try decoder.decodeArray(UInt64.self)
    #expect(result == [])
    try decoder.finalize()
}

@Test func optionalPresentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt32>.some(42))

    #expect(encoder.data.count == 5)
    #expect(encoder.data[0] == 1)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt32.self) == 42)
    try decoder.finalize()
}

@Test func optionalAbsentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt32>.none)

    #expect(encoder.data.count == 1)
    #expect(encoder.data[0] == 0)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt32.self) == nil)
    try decoder.finalize()
}

@Test func fixedBytesRoundtrip() throws {
    let hash = Data(repeating: 0xAB, count: 32)
    var encoder = BinaryEncoder()
    encoder.encodeFixedBytes(hash)
    #expect(encoder.data.count == 32)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeFixedBytes(count: 32) == hash)
    try decoder.finalize()
}

@Test func truncatedBufferThrows() throws {
    let bytes = Data([0x01, 0x02, 0x03]) // too short for UInt64
    var decoder = try BinaryDecoder(data: bytes)
    do {
        _ = try decoder.decode(UInt64.self)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("truncated"))
    }
}

@Test func excessBytesThrowsOnFinalize() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(1))
    encoder.encode(UInt8(2))

    var decoder = try BinaryDecoder(data: encoder.data)
    _ = try decoder.decode(UInt8.self)
    do {
        try decoder.finalize()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("excess"))
    }
}

// MARK: - Optional UInt16

@Test func optionalUInt16PresentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt16>.some(0x1234))
    #expect(encoder.data.count == 3) // 1 tag + 2 payload
    #expect(encoder.data[0] == 1)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt16.self) == 0x1234)
    try decoder.finalize()
}

@Test func optionalUInt16AbsentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt16>.none)
    #expect(encoder.data.count == 1)
    #expect(encoder.data[0] == 0)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt16.self) == nil)
    try decoder.finalize()
}

@Test func optionalStringPresentRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode(Optional<String>.some("hello"))
    #expect(encoder.data[0] == 1)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(String.self) == "hello")
    try decoder.finalize()
}

@Test func optionalStringAbsentRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode(Optional<String>.none)
    #expect(encoder.data.count == 1)
    #expect(encoder.data[0] == 0)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(String.self) == nil)
    try decoder.finalize()
}

@Test func optionalUInt8PresentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt8>.some(7))
    #expect(encoder.data.count == 2)
    #expect(encoder.data[0] == 1)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt8.self) == 7)
    try decoder.finalize()
}

@Test func optionalUInt8AbsentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt8>.none)
    #expect(encoder.data.count == 1)
    #expect(encoder.data[0] == 0)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt8.self) == nil)
    try decoder.finalize()
}

@Test func optionalUInt64PresentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt64>.some(UInt64.max))
    #expect(encoder.data.count == 9)
    #expect(encoder.data[0] == 1)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt64.self) == UInt64.max)
    try decoder.finalize()
}

@Test func optionalUInt64AbsentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<UInt64>.none)
    #expect(encoder.data.count == 1)
    #expect(encoder.data[0] == 0)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt64.self) == nil)
    try decoder.finalize()
}

@Test func optionalInt64PresentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<Int64>.some(-42))
    #expect(encoder.data.count == 9)
    #expect(encoder.data[0] == 1)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(Int64.self) == -42)
    try decoder.finalize()
}

@Test func optionalInt64AbsentRoundtrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(Optional<Int64>.none)
    #expect(encoder.data.count == 1)
    #expect(encoder.data[0] == 0)

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(Int64.self) == nil)
    try decoder.finalize()
}

// MARK: - Typed array encoders

@Test func stringArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode(["alpha", "", "世界"])

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeArray(String.self) == ["alpha", "", "世界"])
    try decoder.finalize()
}

@Test func uint16ArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt16(100), UInt16(200), UInt16(300)])

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeArray(UInt16.self) == [100, 200, 300])
    try decoder.finalize()
}

@Test func uint32ArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt32(0xDEAD), UInt32(0xBEEF)])

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeArray(UInt32.self) == [0xDEAD, 0xBEEF])
    try decoder.finalize()
}

@Test func int64ArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([Int64(-1), Int64(0), Int64(Int64.max)])

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeArray(Int64.self) == [-1, 0, Int64.max])
    try decoder.finalize()
}

// MARK: - Pad

@Test func padToSizeAppendsZeros() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(0xFF))
    encoder.pad(to: 8)
    #expect(encoder.data.count == 8)
    #expect(encoder.data[0] == 0xFF)
    for i in 1..<8 {
        #expect(encoder.data[i] == 0)
    }
}

@Test func padToSmallerSizeIsNoOp() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt64(42))
    encoder.pad(to: 4) // already 8 bytes, pad to 4 is a no-op
    #expect(encoder.data.count == 8)
}

@Test func invalidUTF8Throws() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt32(3))
    var bytes = encoder.data
    bytes.append(contentsOf: [0xFF, 0xFE, 0x80])

    var decoder = try BinaryDecoder(data: bytes)
    do {
        _ = try decoder.decode(String.self)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("UTF-8"))
    }
}

/// A repairing UTF-8 decode turns a truncated 4-byte sequence into one U+FFFD, which is
/// also 3 bytes, so a byte-count check alone would accept it. The decoder must reject it.
@Test func truncatedMultibyteSequenceThrowsAsInvalidUTF8() throws {
    let bytes: [UInt8] = [0xF0, 0x9F, 0x98, 0x41]
    var encoder = BinaryEncoder()
    encoder.encode(UInt32(bytes.count))
    var data = encoder.data
    data.append(contentsOf: bytes)

    var decoder = try BinaryDecoder(data: data)
    #expect(throws: WaxError.self) { _ = try decoder.decode(String.self) }
}

/// ASCII strings take a fast path. Its edges are NUL, 0x7F and the empty string, and a
/// non-ASCII byte anywhere, the last byte included, must still reach UTF-8 validation.
@Test func asciiStringsRoundtripAndATrailingInvalidByteThrows() throws {
    let values = ["", "a", "\u{0}nul", "del\u{7F}", "source", String(repeating: "x", count: 1_000)]
    var encoder = BinaryEncoder()
    for value in values {
        try encoder.encode(value)
    }
    var decoder = try BinaryDecoder(data: encoder.data)
    for value in values {
        #expect(try decoder.decode(String.self) == value)
    }
    try decoder.finalize()

    for prefixLength in [0, 1, 15, 16, 63] {
        let bytes = [UInt8](repeating: 0x61, count: prefixLength) + [0xFF]
        var invalid = BinaryEncoder()
        invalid.encode(UInt32(bytes.count))
        var data = invalid.data
        data.append(contentsOf: bytes)
        var invalidDecoder = try BinaryDecoder(data: data)
        #expect(throws: WaxError.self, "prefix \(prefixLength)") { _ = try invalidDecoder.decode(String.self) }
    }
}

@Test func multibyteAndReplacementCharacterStringsRoundtrip() throws {
    let values = ["naïve café ☕️ 日本語 🧠", "literal \u{FFFD} replacement", "\u{FEFF}leading BOM"]
    var encoder = BinaryEncoder()
    for value in values {
        try encoder.encode(value)
    }

    var decoder = try BinaryDecoder(data: encoder.data)
    for value in values {
        let decoded = try decoder.decode(String.self)
        #expect(Array(decoded.utf8) == Array(value.utf8))
    }
    try decoder.finalize()
}

@Test func stringLongerThanTheBufferThrows() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt32(10))
    var data = encoder.data
    data.append(contentsOf: Array("abc".utf8))

    var decoder = try BinaryDecoder(data: data)
    #expect(throws: WaxError.self) { _ = try decoder.decode(String.self) }
}

/// A `Data` slice keeps its parent's indices; decoding must read from the
/// slice's first byte, not from absolute index 0.
@Test func decodesFromDataSliceWithNonzeroStartIndex() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(7))
    encoder.encode(UInt16(0xBEEF))
    encoder.encode(UInt32(0xDEADBEEF))
    encoder.encode(UInt64(0x0102_0304_0506_0708))
    encoder.encode(Int64(-42))
    try encoder.encode("slice")

    let padded = Data([0xFF, 0xFF, 0xFF]) + encoder.data
    let slice = padded.dropFirst(3)
    #expect(slice.startIndex == 3)

    var decoder = try BinaryDecoder(data: slice)
    #expect(try decoder.decode(UInt8.self) == 7)
    #expect(try decoder.decode(UInt16.self) == 0xBEEF)
    #expect(try decoder.decode(UInt32.self) == 0xDEADBEEF)
    #expect(try decoder.decode(UInt64.self) == 0x0102_0304_0506_0708)
    #expect(try decoder.decode(Int64.self) == -42)
    #expect(try decoder.decode(String.self) == "slice")
    try decoder.finalize()
}

/// Integers sit at odd offsets in the format; reads must not assume alignment.
@Test func decodesUnalignedIntegers() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(1))
    encoder.encode(UInt64.max - 1)
    encoder.encode(UInt8(2))
    encoder.encode(UInt32(0x0A0B_0C0D))

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(UInt8.self) == 1)
    #expect(try decoder.decode(UInt64.self) == UInt64.max - 1)
    #expect(try decoder.decode(UInt8.self) == 2)
    #expect(try decoder.decode(UInt32.self) == 0x0A0B_0C0D)
    try decoder.finalize()
}
