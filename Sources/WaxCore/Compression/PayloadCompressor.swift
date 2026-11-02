import Foundation
#if canImport(Compression)
import Compression
#endif
#if os(Linux)
import WaxCoreCompressionC
#endif

/// Payload compression backend selected per platform.
enum PayloadCompressor {
    package static func compress(_ data: Data, algorithm: CompressionKind) throws -> Data {
        guard algorithm != .none else { return data }
        if data.isEmpty { return Data() }

        #if canImport(Compression)
        return try compressWithAppleCompression(data, algorithm: algorithm)
        #elseif os(Linux)
        return try compressWithLinuxCodecs(data, algorithm: algorithm)
        #else
        throw WaxError.io("compression unsupported on this platform")
        #endif
    }

    package static func decompress(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int
    ) throws -> Data {
        guard algorithm != .none else { return data }

        guard uncompressedLength >= 0 else {
            throw WaxError.io("uncompressedLength must be >= 0")
        }
        if uncompressedLength == 0 { return Data() }

        #if canImport(Compression)
        return try decompressWithAppleCompression(
            data,
            algorithm: algorithm,
            uncompressedLength: uncompressedLength
        )
        #elseif os(Linux)
        return try decompressWithLinuxCodecs(
            data,
            algorithm: algorithm,
            uncompressedLength: uncompressedLength
        )
        #else
        throw WaxError.io("decompression unsupported on this platform")
        #endif
    }

    private static func maxCompressedCapacity(forInputSize inputSize: Int) -> Int {
        let plus128 = inputSize > Int.max - 128 ? Int.max : inputSize + 128
        let quadruple: Int
        if inputSize > Int.max / 4 {
            quadruple = Int.max
        } else {
            quadruple = inputSize * 4
        }
        return max(plus128, quadruple)
    }

    /// `.lz4` payloads are stored as one raw LZ4 block on every platform. Older Apple
    /// builds stored `COMPRESSION_LZ4` output instead: LZ4 blocks wrapped in `bv41` /
    /// `bv4-` frames and terminated by `bv4$`. Readers try that framing first when the
    /// magic is present and fall back to a raw block.
    static func hasAppleLZ4FrameMagic(_ data: Data) -> Bool {
        data.starts(with: [0x62, 0x76, 0x34]) // "bv4"
    }
}

#if canImport(Compression)
private extension PayloadCompressor {
    static func compressWithAppleCompression(_ data: Data, algorithm: CompressionKind) throws -> Data {
        let maxCapacity = maxCompressedCapacity(forInputSize: data.count)
        var dstCapacity = max(64, min(maxCapacity, max(1, data.count)))

        while dstCapacity <= maxCapacity {
            var dst = [UInt8](repeating: 0, count: dstCapacity)
            let written = data.withUnsafeBytes { raw -> Int in
                guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return dst.withUnsafeMutableBytes { dstRaw -> Int in
                    guard let out = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                    return compression_encode_buffer(
                        out,
                        dstRaw.count,
                        src,
                        raw.count,
                        nil,
                        algorithm.appleAlgorithm
                    )
                }
            }

            if written > 0 {
                dst.removeSubrange(written..<dst.count)
                return Data(dst)
            }

            let doubled = dstCapacity &* 2
            if doubled <= dstCapacity { break }
            dstCapacity = doubled
        }

        throw WaxError.io("compression failed: output did not fit within cap \(maxCapacity) bytes")
    }

    static func decompressWithAppleCompression(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int
    ) throws -> Data {
        if algorithm == .lz4, hasAppleLZ4FrameMagic(data),
           let legacy = try? appleDecode(data, algorithm: COMPRESSION_LZ4, uncompressedLength: uncompressedLength) {
            return legacy
        }
        return try appleDecode(data, algorithm: algorithm.appleAlgorithm, uncompressedLength: uncompressedLength)
    }

    static func appleDecode(
        _ data: Data,
        algorithm: compression_algorithm,
        uncompressedLength: Int
    ) throws -> Data {
        var dst = [UInt8](repeating: 0, count: uncompressedLength)
        let written = data.withUnsafeBytes { raw -> Int in
            guard let src = raw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
            return dst.withUnsafeMutableBytes { dstRaw -> Int in
                guard let out = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return 0 }
                return compression_decode_buffer(
                    out,
                    dstRaw.count,
                    src,
                    raw.count,
                    nil,
                    algorithm
                )
            }
        }

        guard written == uncompressedLength else {
            throw WaxError.io("decompress truncated or failed: wrote \(written), expected \(uncompressedLength)")
        }
        return Data(dst)
    }
}

private extension CompressionKind {
    var appleAlgorithm: compression_algorithm {
        switch self {
        case .none:
            return COMPRESSION_LZFSE
        case .lzfse:
            return COMPRESSION_LZFSE
        case .lz4:
            // Raw block, byte-compatible with liblz4 on Linux (not the `bv41` framing).
            return COMPRESSION_LZ4_RAW
        case .deflate:
            return COMPRESSION_ZLIB
        }
    }
}
#endif

#if os(Linux)
private extension PayloadCompressor {
    static func compressWithLinuxCodecs(_ data: Data, algorithm: CompressionKind) throws -> Data {
        switch algorithm {
        case .none:
            return data
        case .lzfse:
            throw WaxError.io("compression algorithm lzfse is unavailable in this Linux build")
        case .lz4:
            return try linuxLZ4Compress(data)
        case .deflate:
            return try linuxDeflateCompress(data)
        }
    }

    static func decompressWithLinuxCodecs(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int
    ) throws -> Data {
        switch algorithm {
        case .none:
            return data
        case .lzfse:
            throw WaxError.io("compression algorithm lzfse is unavailable in this Linux build")
        case .lz4:
            return try linuxLZ4Decompress(data, uncompressedLength: uncompressedLength)
        case .deflate:
            return try linuxDeflateDecompress(data, uncompressedLength: uncompressedLength)
        }
    }

    static func linuxDeflateCompress(_ data: Data) throws -> Data {
        let maxCapacity = maxCompressedCapacity(forInputSize: data.count)
        var dstCapacity = max(64, min(maxCapacity, max(1, data.count)))

        while dstCapacity <= maxCapacity {
            var dst = [UInt8](repeating: 0, count: dstCapacity)
            var written: size_t = dst.count
            let rc = data.withUnsafeBytes { srcRaw -> Int32 in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return dst.withUnsafeMutableBytes { dstRaw -> Int32 in
                    guard let out = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return wax_deflate_compress(src, srcRaw.count, out, &written)
                }
            }

            if rc == 0, written > 0 {
                dst.removeSubrange(Int(written)..<dst.count)
                return Data(dst)
            }

            let doubled = dstCapacity &* 2
            if doubled <= dstCapacity { break }
            dstCapacity = doubled
        }

        throw WaxError.io("deflate compression failed to fit within cap \(maxCapacity) bytes")
    }

    static func linuxDeflateDecompress(_ data: Data, uncompressedLength: Int) throws -> Data {
        var dst = [UInt8](repeating: 0, count: uncompressedLength)
        var written: size_t = dst.count
        let rc = data.withUnsafeBytes { srcRaw -> Int32 in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return dst.withUnsafeMutableBytes { dstRaw -> Int32 in
                guard let out = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return wax_deflate_decompress(src, srcRaw.count, out, &written)
            }
        }
        guard rc == 0 else {
            throw WaxError.io("deflate decompress failed: \(rc)")
        }
        guard Int(written) == uncompressedLength else {
            throw WaxError.io("deflate decompressed size mismatch: wrote \(written), expected \(uncompressedLength)")
        }
        return Data(dst)
    }

    static func linuxLZ4Compress(_ data: Data) throws -> Data {
        let maxCapacity = maxCompressedCapacity(forInputSize: data.count)
        var dstCapacity = max(64, min(maxCapacity, max(1, data.count)))

        while dstCapacity <= maxCapacity {
            var dst = [UInt8](repeating: 0, count: dstCapacity)
            var written: size_t = 0
            let rc = data.withUnsafeBytes { srcRaw -> Int32 in
                guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return dst.withUnsafeMutableBytes { dstRaw -> Int32 in
                    guard let out = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                    return wax_lz4_compress(src, srcRaw.count, out, dstRaw.count, &written)
                }
            }

            if rc == 0, written > 0 {
                dst.removeSubrange(Int(written)..<dst.count)
                return Data(dst)
            }

            // rc == -4 means dst_cap < LZ4_compressBound(src_len); double and retry.
            if rc != -4 { break }
            let doubled = dstCapacity &* 2
            if doubled <= dstCapacity { break }
            dstCapacity = doubled
        }

        throw WaxError.io("lz4 compression failed to fit within cap \(maxCapacity) bytes")
    }

    static func linuxLZ4Decompress(_ data: Data, uncompressedLength: Int) throws -> Data {
        if hasAppleLZ4FrameMagic(data),
           let legacy = try? linuxLZ4Decode(data, uncompressedLength: uncompressedLength, appleFramed: true) {
            return legacy
        }
        return try linuxLZ4Decode(data, uncompressedLength: uncompressedLength, appleFramed: false)
    }

    static func linuxLZ4Decode(_ data: Data, uncompressedLength: Int, appleFramed: Bool) throws -> Data {
        var dst = [UInt8](repeating: 0, count: uncompressedLength)
        let rc = data.withUnsafeBytes { srcRaw -> Int32 in
            guard let src = srcRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
            return dst.withUnsafeMutableBytes { dstRaw -> Int32 in
                guard let out = dstRaw.bindMemory(to: UInt8.self).baseAddress else { return -1 }
                return appleFramed
                    ? wax_lz4_decompress_apple_framed(src, srcRaw.count, out, dstRaw.count)
                    : wax_lz4_decompress(src, srcRaw.count, out, dstRaw.count)
            }
        }
        guard rc == 0 else {
            throw WaxError.io("lz4 decompress failed: \(rc)")
        }
        return Data(dst)
    }
}
#endif
