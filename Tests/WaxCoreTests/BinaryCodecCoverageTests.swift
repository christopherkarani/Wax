import Foundation
import Testing
@testable import WaxCore

@Test
func binaryEncoderAndDecoderCoverOptionalAndArrayOverloads() throws {
    var encoder = BinaryEncoder()

    encoder.encode(UInt16?.some(42))
    encoder.encode(UInt16?.none)
    encoder.encode(UInt64?.some(9))
    encoder.encode(UInt64?.none)
    encoder.encode(Int64?.some(-7))
    encoder.encode(Int64?.none)

    try encoder.encode([UInt16(1), UInt16(2)])
    try encoder.encode([UInt32(3), UInt32(4)])
    try encoder.encode([UInt64(5), UInt64(6)])
    try encoder.encode([Int64(-1), Int64(2)])
    try encoder.encode(["a", "bb"])

    try encoder.encode(UInt8?.some(11)) { enc, value in
        enc.encode(value)
    }
    try encoder.encode(UInt8?.none) { enc, value in
        enc.encode(value)
    }

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decodeOptional(UInt16.self) == 42)
    #expect(try decoder.decodeOptional(UInt16.self) == nil)
    #expect(try decoder.decodeOptional(UInt64.self) == 9)
    #expect(try decoder.decodeOptional(UInt64.self) == nil)
    #expect(try decoder.decodeOptional(Int64.self) == -7)
    #expect(try decoder.decodeOptional(Int64.self) == nil)

    #expect(try decoder.decodeArray(UInt16.self) == [1, 2])
    #expect(try decoder.decodeArray(UInt32.self) == [3, 4])
    #expect(try decoder.decodeArray(UInt64.self) == [5, 6])
    #expect(try decoder.decodeArray(Int64.self) == [-1, 2])
    #expect(try decoder.decodeArray(String.self) == ["a", "bb"])

    #expect(try decoder.decodeOptional(UInt8.self) == 11)
    #expect(try decoder.decodeOptional(UInt8.self) == nil)
    try decoder.finalize()
}

@Test
func binaryEncoderHonorsLimitsAndPadding() throws {
    var limits = BinaryEncoder.Limits()
    limits.maxBlobBytes = 2
    limits.maxStringBytes = 2
    limits.maxArrayCount = 1

    do {
        var encoder = BinaryEncoder(limits: limits)
        try encoder.encodeBytes(Data([1, 2, 3]))
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("exceeds limit"))
    }

    do {
        var encoder = BinaryEncoder(limits: limits)
        try encoder.encode("toolong")
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("string byte length"))
    }

    do {
        var encoder = BinaryEncoder(limits: limits)
        try encoder.encode([UInt16(1), UInt16(2)])
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .encodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("array count"))
    }

    var padded = BinaryEncoder()
    padded.encode(UInt8(0xAB))
    padded.pad(to: 4)
    #expect(padded.data == Data([0xAB, 0x00, 0x00, 0x00]))
    padded.pad(to: 2)
    #expect(padded.data == Data([0xAB, 0x00, 0x00, 0x00]))
}

@Test
func binaryEncoderAndDecoderUInt8AndUInt32RoundTrip() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(255))
    encoder.encode(UInt8(0))
    encoder.encode(UInt32(0))
    encoder.encode(UInt32.max)
    encoder.encode(UInt16(0xBEEF))

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(UInt8.self) == 255)
    #expect(try decoder.decode(UInt8.self) == 0)
    #expect(try decoder.decode(UInt32.self) == 0)
    #expect(try decoder.decode(UInt32.self) == UInt32.max)
    #expect(try decoder.decode(UInt16.self) == 0xBEEF)
    try decoder.finalize()
}

@Test
func binaryEncoderStringRoundtrip() throws {
    var encoder = BinaryEncoder()
    try encoder.encode("")
    try encoder.encode("hello")
    try encoder.encode("swift 6.2")

    var decoder = try BinaryDecoder(data: encoder.data)
    #expect(try decoder.decode(String.self) == "")
    #expect(try decoder.decode(String.self) == "hello")
    #expect(try decoder.decode(String.self) == "swift 6.2")
    try decoder.finalize()
}

@Test
func binaryEncoderFixedBytesRoundtrip() throws {
    let fixed = Data([0xDE, 0xAD, 0xBE, 0xEF])
    var encoder = BinaryEncoder()
    encoder.encodeFixedBytes(fixed)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try decoder.decodeFixedBytes(count: 4)
    #expect(decoded == fixed)
    try decoder.finalize()
}

@Test
func binaryEncoderBytesRoundtrip() throws {
    let bytes = Data([0x01, 0x02, 0x03, 0x04, 0x05])
    var encoder = BinaryEncoder()
    try encoder.encodeBytes(bytes)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded = try decoder.decodeBytes()
    #expect(decoded == bytes)
    try decoder.finalize()
}

@Test
func binaryDecoderThrowsOnTruncatedData() throws {
    // Write a UInt64 header but provide only 4 bytes of data
    var encoder = BinaryEncoder()
    encoder.encode(UInt64(9_999))
    let truncated = encoder.data.prefix(4)

    do {
        var decoder = try BinaryDecoder(data: Data(truncated))
        _ = try decoder.decode(UInt64.self)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test
func binaryDecoderFinalizationThrowsWhenBytesRemain() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt8(1))
    encoder.encode(UInt8(2)) // Extra byte not consumed

    var decoder = try BinaryDecoder(data: encoder.data)
    _ = try decoder.decode(UInt8.self)
    // finalize must throw because one byte remains
    do {
        try decoder.finalize()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError = error else {
            #expect(Bool(false))
            return
        }
    }
}

@Test
func binaryDecoderArrayOf_UInt8_Roundtrip() throws {
    let values: [UInt8] = [10, 20, 30, 40]
    var encoder = BinaryEncoder()
    try encoder.encode(values)

    var decoder = try BinaryDecoder(data: encoder.data)
    let decoded: [UInt8] = try decoder.decodeArray()
    #expect(decoded == values)
    try decoder.finalize()
}

@Test
func binaryEncoderPadAlreadyAligned() throws {
    var encoder = BinaryEncoder()
    encoder.encode(UInt32(0xDEAD_BEEF))
    let sizeBefore = encoder.data.count // 4 bytes
    // pad(to: 4) should not add anything since already aligned
    encoder.pad(to: 4)
    #expect(encoder.data.count == sizeBefore)
}

@Test
func binaryEncoderLimitsDefaultValues() {
    let limits = BinaryEncoder.Limits()
    // Defaults must be positive and sane
    #expect(limits.maxBlobBytes > 0)
    #expect(limits.maxStringBytes > 0)
    #expect(limits.maxArrayCount > 0)
}

@Test
func binaryDecoderLimitsDefaultValues() {
    let limits = BinaryDecoder.Limits()
    #expect(limits.maxBlobBytes > 0)
    #expect(limits.maxArrayCount > 0)
}

@Test
func binaryDecoderRejectsBlobArrayOptionalAndUnsupportedTypeEdges() throws {
    var blobBytes = Data()
    blobBytes.append(contentsOf: [0x03, 0x00, 0x00, 0x00])
    blobBytes.append(contentsOf: [0xAA, 0xBB, 0xCC])

    do {
        var limits = BinaryDecoder.Limits()
        limits.maxBlobBytes = 2
        var decoder = try BinaryDecoder(data: blobBytes, limits: limits)
        _ = try decoder.decodeBytes()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("exceeds limit"))
    }

    do {
        var encoder = BinaryEncoder()
        encoder.encode(UInt32(2))
        encoder.encode(UInt8(1))
        encoder.encode(UInt8(2))

        var limits = BinaryDecoder.Limits()
        limits.maxArrayCount = 1
        var decoder = try BinaryDecoder(data: encoder.data, limits: limits)
        let _: [UInt8] = try decoder.decodeArray()
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("array count"))
    }

    do {
        var decoder = try BinaryDecoder(data: Data([0x02]))
        _ = try decoder.decodeOptional(UInt8.self)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("invalid optional tag"))
    }

    do {
        var decoder = try BinaryDecoder(data: Data())
        _ = try decoder.decode(Double.self)
        #expect(Bool(false))
    } catch let error as WaxError {
        guard case .decodingError(let reason) = error else {
            #expect(Bool(false))
            return
        }
        #expect(reason.contains("unsupported decode type"))
    }
}
