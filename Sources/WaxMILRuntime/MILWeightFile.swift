import Foundation
import WaxMILKernelsC

#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#elseif canImport(Musl)
import Musl
#endif

/// A read-only, memory-mapped MIL blob file (`weights/weight.bin`, MILBlob storage v2).
///
/// Layout, little-endian: a 64-byte file header `{ uint32 count; uint32 version = 2; ... }`
/// followed by blobs. A MIL `BLOBFILE(offset = N)` points at a 64-byte blob metadata record
/// `{ uint32 sentinel = 0xDEADBEEF; uint32 dataType; uint64 sizeInBytes; uint64 dataOffset;
/// ... }`, whose `dataOffset` is the absolute, 64-byte-aligned position of the payload.
///
/// `@unchecked Sendable`: the mapping is read-only (`PROT_READ`, `MAP_PRIVATE`) and immutable
/// for the object's lifetime; it is unmapped only in `deinit`.
package final class MILWeightFile: @unchecked Sendable {
    package struct BlobMetadata: Sendable, Equatable {
        package var dataType: MILDataType
        package var sizeInBytes: Int
        package var dataOffset: Int

        package init(dataType: MILDataType, sizeInBytes: Int, dataOffset: Int) {
            self.dataType = dataType
            self.sizeInBytes = sizeInBytes
            self.dataOffset = dataOffset
        }
    }

    static let headerSize = 64
    static let metadataSize = 64
    static let sentinel: UInt32 = 0xDEAD_BEEF

    package let url: URL
    package let blobCount: Int
    private let base: UnsafeRawPointer
    private let length: Int
    private let release: @Sendable (UnsafeRawPointer, Int) -> Void

    package init(contentsOf url: URL) throws {
        self.url = url
        let (base, length, release) = try Self.map(url)
        self.base = base
        self.length = length
        self.release = release
        guard length >= Self.headerSize else {
            release(base, length)
            throw MILRuntimeError.blob("\(url.lastPathComponent) is \(length) bytes, shorter than the 64-byte header")
        }
        let count = base.loadUnaligned(fromByteOffset: 0, as: UInt32.self).littleEndian
        let version = base.loadUnaligned(fromByteOffset: 4, as: UInt32.self).littleEndian
        guard version == 2 else {
            release(base, length)
            throw MILRuntimeError.blob("\(url.lastPathComponent) has storage version \(version); only version 2 is supported")
        }
        self.blobCount = Int(count)
    }

    deinit {
        release(base, length)
    }

    /// MILBlob `BlobDataType` codes.
    static func dataType(code: UInt32) -> MILDataType? {
        switch code {
        case 1: .fp16
        case 2: .fp32
        case 3: .uint8
        case 4: .int8
        case 6: .int16
        case 7: .uint16
        case 14: .int32
        case 15: .uint32
        default: nil // bfloat16, sub-byte and fp8 types are not used by the bundled models
        }
    }

    static func byteWidth(of dataType: MILDataType) -> Int? {
        switch dataType {
        case .int8, .uint8: 1
        case .fp16, .int16, .uint16: 2
        case .fp32, .int32, .uint32: 4
        case .bool, .string: nil
        }
    }

    package func metadata(at offset: UInt64) throws -> BlobMetadata {
        guard offset % 64 == 0, offset <= UInt64(length - Self.metadataSize) else {
            throw MILRuntimeError.blob("metadata offset \(offset) is misaligned or outside the \(length)-byte file")
        }
        let position = Int(offset)
        let sentinel = base.loadUnaligned(fromByteOffset: position, as: UInt32.self).littleEndian
        guard sentinel == Self.sentinel else {
            throw MILRuntimeError.blob("no blob metadata at offset \(offset) (sentinel 0x\(String(sentinel, radix: 16)))")
        }
        let code = base.loadUnaligned(fromByteOffset: position + 4, as: UInt32.self).littleEndian
        let size = base.loadUnaligned(fromByteOffset: position + 8, as: UInt64.self).littleEndian
        let dataOffset = base.loadUnaligned(fromByteOffset: position + 16, as: UInt64.self).littleEndian
        guard let dataType = Self.dataType(code: code) else {
            throw MILRuntimeError.blob("blob at offset \(offset) has unsupported data type code \(code)")
        }
        guard dataOffset % 64 == 0, size <= UInt64(length), dataOffset <= UInt64(length) - size else {
            throw MILRuntimeError.blob("blob at offset \(offset) claims \(size) bytes at \(dataOffset), outside the \(length)-byte file")
        }
        return BlobMetadata(dataType: dataType, sizeInBytes: Int(size), dataOffset: Int(dataOffset))
    }

    /// Decodes the blob whose metadata is at `offset` as a tensor of the declared type and
    /// shape. fp32 payloads are borrowed from the mapping without copying; fp16 and 8-bit
    /// payloads are widened to Float32; integer payloads to Int32.
    package func tensor(at offset: UInt64, dataType declared: MILDataType, shape: [Int]) throws -> MILTensor {
        let meta = try metadata(at: offset)
        guard meta.dataType == declared else {
            throw MILRuntimeError.blob("blob at offset \(offset) holds \(meta.dataType.rawValue) but the program declares \(declared.rawValue)")
        }
        let count = shape.reduce(1, *)
        guard let width = Self.byteWidth(of: declared), meta.sizeInBytes == count * width else {
            throw MILRuntimeError.blob("blob at offset \(offset) has \(meta.sizeInBytes) bytes, not \(count) \(declared.rawValue) values for shape \(shape)")
        }
        let payload = base + meta.dataOffset
        switch declared {
        case .fp32:
            let floats = payload.assumingMemoryBound(to: Float.self)
            return MILTensor(dataType: .fp32, shape: shape, storage: .float(MILFloatStorage(borrowing: floats, count: count, owner: self)))
        case .fp16:
            let storage = MILFloatStorage.make(count: count) { out in
                wax_mil_f16_to_f32(payload.assumingMemoryBound(to: UInt16.self), out.baseAddress, count)
            }
            return MILTensor(dataType: .fp16, shape: shape, storage: .float(storage))
        case .int8:
            let storage = MILFloatStorage.make(count: count) { out in
                wax_mil_i8_to_f32(payload.assumingMemoryBound(to: Int8.self), out.baseAddress, count)
            }
            return MILTensor(dataType: .int8, shape: shape, storage: .float(storage))
        case .uint8:
            let storage = MILFloatStorage.make(count: count) { out in
                wax_mil_u8_to_f32(payload.assumingMemoryBound(to: UInt8.self), out.baseAddress, count)
            }
            return MILTensor(dataType: .uint8, shape: shape, storage: .float(storage))
        case .int16:
            return MILTensor(dataType: .int16, shape: shape, storage: .int((0..<count).map {
                Int32(Int16(littleEndian: payload.loadUnaligned(fromByteOffset: $0 * 2, as: Int16.self)))
            }))
        case .uint16:
            return MILTensor(dataType: .uint16, shape: shape, storage: .int((0..<count).map {
                Int32(UInt16(littleEndian: payload.loadUnaligned(fromByteOffset: $0 * 2, as: UInt16.self)))
            }))
        case .int32:
            let values = [Int32](unsafeUninitializedCapacity: count) { buffer, initialized in
                if let destination = buffer.baseAddress {
                    UnsafeMutableRawPointer(destination).copyMemory(from: payload, byteCount: count * 4)
                }
                initialized = count
            }
            return MILTensor(dataType: .int32, shape: shape, storage: .int(values.map { Int32(littleEndian: $0) }))
        case .uint32:
            var values: [Int32] = []
            values.reserveCapacity(count)
            for index in 0..<count {
                let value = UInt32(littleEndian: payload.loadUnaligned(fromByteOffset: index * 4, as: UInt32.self))
                guard let narrowed = Int32(exactly: value) else {
                    throw MILRuntimeError.blob("uint32 value \(value) at offset \(offset) does not fit in Int32")
                }
                values.append(narrowed)
            }
            return MILTensor(dataType: .uint32, shape: shape, storage: .int(values))
        case .bool, .string:
            throw MILRuntimeError.blob("\(declared.rawValue) blobs are not supported")
        }
    }

    // MARK: - Mapping

    private static func map(_ url: URL) throws -> (UnsafeRawPointer, Int, @Sendable (UnsafeRawPointer, Int) -> Void) {
        #if canImport(Darwin) || canImport(Glibc) || canImport(Musl)
        let descriptor = open(url.path, O_RDONLY)
        guard descriptor >= 0 else {
            throw MILRuntimeError.blob("cannot open \(url.path) (errno \(errno))")
        }
        defer { close(descriptor) }
        var info = stat()
        guard fstat(descriptor, &info) == 0 else {
            throw MILRuntimeError.blob("cannot stat \(url.path) (errno \(errno))")
        }
        let length = Int(info.st_size)
        guard length > 0 else {
            throw MILRuntimeError.blob("\(url.path) is empty")
        }
        let mapped = mmap(nil, length, PROT_READ, MAP_PRIVATE, descriptor, 0)
        guard let mapped, mapped != MAP_FAILED else {
            throw MILRuntimeError.blob("cannot map \(url.path) (errno \(errno))")
        }
        return (UnsafeRawPointer(mapped), length, { pointer, length in
            _ = munmap(UnsafeMutableRawPointer(mutating: pointer), length)
        })
        #else
        let data = try Data(contentsOf: url)
        let memory = UnsafeMutableRawPointer.allocate(byteCount: max(data.count, 1), alignment: 64)
        data.copyBytes(to: memory.assumingMemoryBound(to: UInt8.self), count: data.count)
        return (UnsafeRawPointer(memory), data.count, { pointer, _ in
            UnsafeMutableRawPointer(mutating: pointer).deallocate()
        })
        #endif
    }
}
