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
    let result: [UInt8] = try decoder.decodeArray()
    #expect(result == [1, 2, 3])
    try decoder.finalize()
}

@Test func emptyArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt64]())

    var decoder = try BinaryDecoder(data: encoder.data)
    let result: [UInt64] = try decoder.decodeArray()
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

// MARK: - Typed array encoders

@Test func uint16ArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt16(100), UInt16(200), UInt16(300)])

    var decoder = try BinaryDecoder(data: encoder.data)
    let count = try decoder.decode(UInt32.self)
    #expect(count == 3)
    #expect(try decoder.decode(UInt16.self) == 100)
    #expect(try decoder.decode(UInt16.self) == 200)
    #expect(try decoder.decode(UInt16.self) == 300)
    try decoder.finalize()
}

@Test func uint32ArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([UInt32(0xDEAD), UInt32(0xBEEF)])

    var decoder = try BinaryDecoder(data: encoder.data)
    let count = try decoder.decode(UInt32.self)
    #expect(count == 2)
    #expect(try decoder.decode(UInt32.self) == 0xDEAD)
    #expect(try decoder.decode(UInt32.self) == 0xBEEF)
    try decoder.finalize()
}

@Test func int64ArrayRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode([Int64(-1), Int64(0), Int64(Int64.max)])

    var decoder = try BinaryDecoder(data: encoder.data)
    let count = try decoder.decode(UInt32.self)
    #expect(count == 3)
    #expect(try decoder.decode(Int64.self) == -1)
    #expect(try decoder.decode(Int64.self) == 0)
    #expect(try decoder.decode(Int64.self) == Int64.max)
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
