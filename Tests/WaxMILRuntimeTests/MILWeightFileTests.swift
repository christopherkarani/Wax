import Foundation
import Testing
import WaxMILRuntime

/// Writes MILBlob v2 files: a 64-byte header, then for each blob a 64-byte metadata record
/// followed by its 64-byte-aligned payload.
struct BlobFileBuilder {
    private(set) var bytes = [UInt8](repeating: 0, count: 64)
    private var count: UInt32 = 0

    /// Appends a blob and returns the offset of its metadata record (what BLOBFILE names).
    mutating func append(code: UInt32, payload: [UInt8], sentinel: UInt32 = 0xDEAD_BEEF, claimedSize: UInt64? = nil) -> UInt64 {
        let metadataOffset = bytes.count
        let dataOffset = metadataOffset + 64
        var metadata = [UInt8](repeating: 0, count: 64)
        func put<T: FixedWidthInteger>(_ value: T, at position: Int) {
            withUnsafeBytes(of: value.littleEndian) { raw in
                for (i, byte) in raw.enumerated() { metadata[position + i] = byte }
            }
        }
        put(sentinel, at: 0)
        put(code, at: 4)
        put(claimedSize ?? UInt64(payload.count), at: 8)
        put(UInt64(dataOffset), at: 16)
        bytes += metadata
        bytes += payload
        let padding = (64 - bytes.count % 64) % 64
        bytes += [UInt8](repeating: 0, count: padding)
        count += 1
        return UInt64(metadataOffset)
    }

    func write(to directory: URL) throws -> URL {
        var header = bytes
        withUnsafeBytes(of: count.littleEndian) { for (i, b) in $0.enumerated() { header[i] = b } }
        withUnsafeBytes(of: UInt32(2).littleEndian) { for (i, b) in $0.enumerated() { header[4 + i] = b } }
        let weights = directory.appendingPathComponent("weights", isDirectory: true)
        try FileManager.default.createDirectory(at: weights, withIntermediateDirectories: true)
        let url = weights.appendingPathComponent("weight.bin")
        try Data(header).write(to: url)
        return url
    }
}

func bytes<T: FixedWidthInteger>(_ values: [T]) -> [UInt8] {
    values.flatMap { value in withUnsafeBytes(of: value.littleEndian) { Array($0) } }
}

func bytes(_ values: [Float]) -> [UInt8] {
    bytes(values.map(\.bitPattern))
}

func temporaryDirectory() throws -> URL {
    let url = FileManager.default.temporaryDirectory
        .appendingPathComponent("WaxMILRuntimeTests-\(UUID().uuidString)", isDirectory: true)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: true)
    return url
}

struct MILWeightFileTests {
    @Test func decodesEachPayloadTypeAtItsMetadataOffset() throws {
        var builder = BlobFileBuilder()
        let fp32 = builder.append(code: 2, payload: bytes([Float(1.5), -0.25, 3e38]))
        // 1, -2, 65504 (max), smallest subnormal, +inf, -0, 0x3555 (~0.33325)
        let fp16 = builder.append(code: 1, payload: bytes([UInt16(0x3C00), 0xC000, 0x7BFF, 0x0001, 0x7C00, 0x8000, 0x3555]))
        let int8 = builder.append(code: 4, payload: bytes([Int8(-128), 127, 0, 5]))
        let int32 = builder.append(code: 14, payload: bytes([Int32(-7), 0, 511, .max]))
        let uint16 = builder.append(code: 7, payload: bytes([UInt16(0), 65535]))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try MILWeightFile(contentsOf: builder.write(to: directory))
        #expect(file.blobCount == 5)

        #expect(try file.tensor(at: fp32, dataType: .fp32, shape: [3]).floats == [1.5, -0.25, 3e38])
        let halves = try file.tensor(at: fp16, dataType: .fp16, shape: [7]).floats
        #expect(halves[0] == 1 && halves[1] == -2 && halves[2] == 65504)
        #expect(halves[3] == Float(sign: .plus, exponent: -24, significand: 1))
        #expect(halves[4] == .infinity)
        #expect(halves[5] == 0 && halves[5].sign == .minus)
        #expect(halves[6] == 0x1.554p-2)
        #expect(try file.tensor(at: int8, dataType: .int8, shape: [2, 2]).floats == [-128, 127, 0, 5])
        let ints = try file.tensor(at: int32, dataType: .int32, shape: [4])
        #expect(ints.int32s == [-7, 0, 511, .max])
        #expect(ints.shape == [4])
        #expect(try file.tensor(at: uint16, dataType: .uint16, shape: [2]).int32s == [0, 65535])
    }

    @Test func rejectsMismatchedTypesSizesSentinelsAndOffsets() throws {
        var builder = BlobFileBuilder()
        let good = builder.append(code: 2, payload: bytes([Float(1), 2]))
        let badSentinel = builder.append(code: 2, payload: bytes([Float(1)]), sentinel: 0x1234_5678)
        let overlong = builder.append(code: 2, payload: bytes([Float(1)]), claimedSize: 1 << 40)
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let file = try MILWeightFile(contentsOf: builder.write(to: directory))

        #expect(throws: MILRuntimeError.self) { try file.tensor(at: good, dataType: .fp16, shape: [4]) }
        #expect(throws: MILRuntimeError.self) { try file.tensor(at: good, dataType: .fp32, shape: [3]) }
        #expect(throws: MILRuntimeError.self) { try file.tensor(at: badSentinel, dataType: .fp32, shape: [1]) }
        #expect(throws: MILRuntimeError.self) { try file.tensor(at: overlong, dataType: .fp32, shape: [1]) }
        #expect(throws: MILRuntimeError.self) { try file.tensor(at: good + 8, dataType: .fp32, shape: [2]) }
        #expect(throws: MILRuntimeError.self) { try file.tensor(at: 1 << 30, dataType: .fp32, shape: [2]) }
    }

    @Test func rejectsAnUnsupportedStorageVersion() throws {
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        var header = [UInt8](repeating: 0, count: 64)
        header[4] = 3
        let url = directory.appendingPathComponent("weight.bin")
        try Data(header).write(to: url)
        #expect(throws: MILRuntimeError.self) { try MILWeightFile(contentsOf: url) }
    }

    @Test func readsTheBundledPositionIdsBlob() throws {
        let file = try MILWeightFile(contentsOf: BundledModel.miniLM.url.appendingPathComponent("weights/weight.bin"))
        #expect(file.blobCount == 103)
        let meta = try file.metadata(at: 2176)
        #expect(meta == MILWeightFile.BlobMetadata(dataType: .int32, sizeInBytes: 2048, dataOffset: 2240))
        let positions = try file.tensor(at: 2176, dataType: .int32, shape: [1, 512])
        #expect(positions.int32s == (0..<512).map { Int32($0) })
    }

    @Test func dequantisesBlockwiseShiftScaleFromABlobFile() throws {
        var builder = BlobFileBuilder()
        // data [2, 4] int8; scale and offset [2, 2]: one entry per row and per pair of columns.
        let data = builder.append(code: 4, payload: bytes([Int8(1), 2, 3, 4, -1, -2, 10, 20]))
        let scale = builder.append(code: 1, payload: bytes([UInt16(0x3C00), 0x4000, 0x3800, 0xBC00])) // 1, 2, 0.5, -1
        let offset = builder.append(code: 4, payload: bytes([Int8(0), 1, -1, 10]))
        let directory = try temporaryDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        _ = try builder.write(to: directory)
        let path = #"string("@model_path/weights/weight.bin")"#
        let text = program(outputs: "w", """
                tensor<fp16, [2, 4]> w = constexpr_blockwise_shift_scale(data = tensor<int8, [2, 4]>(BLOBFILE(path = \(path), offset = uint64(\(data)))), scale = tensor<fp16, [2, 2]>(BLOBFILE(path = \(path), offset = uint64(\(scale)))), offset = tensor<int8, [2, 2]>(BLOBFILE(path = \(path), offset = uint64(\(offset)))))[name = string("w")];
        """)
        let model = try MILModel(programText: text, modelDirectory: directory)
        let w = try #require(try model.predict([:])["w"])
        #expect(w.dataType == .fp16)
        // (data - offset) * scale
        #expect(w.floats == [1, 2, 4, 6, 0, -0.5, 0, -10])
    }
}
