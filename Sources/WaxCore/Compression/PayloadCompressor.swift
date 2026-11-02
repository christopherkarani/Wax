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

    /// Decodes `data`, returning the first candidate decoding that succeeds.
    package static func decompress(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int
    ) throws -> Data {
        guard algorithm != .none else { return data }
        try validateUncompressedLength(uncompressedLength, storedCount: data.count, algorithm: algorithm)
        if uncompressedLength == 0 { return Data() }
        return try firstDecoded(
            candidateDecoders(data, algorithm: algorithm, uncompressedLength: uncompressedLength)
        )
    }

    /// Decodes `data` and returns the first candidate decoding that `isValid` accepts
    /// (callers pass the canonical checksum). Returns `nil` when candidates decode but
    /// none verifies, and throws when none decodes.
    ///
    /// `.lz4` has two on-disk forms that a prefix cannot always tell apart (see
    /// `hasAppleLZ4FrameMagic`), and Apple's framed decoder accepts some malformed input,
    /// so a raw block that happens to frame-parse must still be retried as raw.
    package static func decompress(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int,
        verifiedBy isValid: (Data) -> Bool
    ) throws -> Data? {
        guard algorithm != .none else { return isValid(data) ? data : nil }
        try validateUncompressedLength(uncompressedLength, storedCount: data.count, algorithm: algorithm)
        if uncompressedLength == 0 { return isValid(Data()) ? Data() : nil }
        return try firstVerified(
            candidateDecoders(data, algorithm: algorithm, uncompressedLength: uncompressedLength),
            verifiedBy: isValid
        )
    }

    /// Upper bound on uncompressed/stored size per codec, so a corrupt or crafted
    /// `canonical_length` cannot drive a huge output allocation. LZ4 and DEFLATE use
    /// their format maxima (~255:1 and ~1032:1). LZFSE has no published maximum;
    /// all-zero input measured ~1.7k:1 at 64 MiB, so 4096 leaves headroom.
    static func maxExpansionRatio(for algorithm: CompressionKind) -> Int {
        switch algorithm {
        case .none: return 1
        case .lz4: return 255
        case .deflate: return 1032
        case .lzfse: return 4096
        }
    }

    /// Throws when `uncompressedLength` is negative, or is larger than `storedCount`
    /// bytes of `algorithm` output can decode to (`WaxError.decodingError`).
    static func validateUncompressedLength(
        _ uncompressedLength: Int,
        storedCount: Int,
        algorithm: CompressionKind
    ) throws {
        guard uncompressedLength >= 0 else {
            throw WaxError.io("uncompressedLength must be >= 0")
        }
        let bound = storedCount.multipliedReportingOverflow(by: maxExpansionRatio(for: algorithm))
        guard bound.overflow || uncompressedLength <= bound.partialValue else {
            throw WaxError.decodingError(
                reason: "uncompressed length \(uncompressedLength) exceeds the \(algorithm) maximum for \(storedCount) stored bytes"
            )
        }
    }

    /// Returns the first decoder output, or rethrows the last failure.
    static func firstDecoded(_ decoders: [() throws -> Data]) throws -> Data {
        var lastError: (any Error)?
        for decode in decoders {
            do {
                return try decode()
            } catch {
                lastError = error
            }
        }
        throw lastError ?? WaxError.io("no decoder for payload")
    }

    /// Returns the first decoder output `isValid` accepts; `nil` when outputs decode but
    /// none verifies; rethrows the last failure when nothing decodes.
    static func firstVerified(
        _ decoders: [() throws -> Data],
        verifiedBy isValid: (Data) -> Bool
    ) throws -> Data? {
        var lastError: (any Error)?
        var decodedAny = false
        for decode in decoders {
            let candidate: Data
            do {
                candidate = try decode()
            } catch {
                lastError = error
                continue
            }
            decodedAny = true
            if isValid(candidate) { return candidate }
        }
        if decodedAny { return nil }
        throw lastError ?? WaxError.io("no decoder for payload")
    }

    /// Candidate decodings of `data`, most likely first.
    static func candidateDecoders(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int
    ) -> [() throws -> Data] {
        #if canImport(Compression)
        return appleCandidateDecoders(data, algorithm: algorithm, uncompressedLength: uncompressedLength)
        #elseif os(Linux)
        return linuxCandidateDecoders(data, algorithm: algorithm, uncompressedLength: uncompressedLength)
        #else
        return [{ throw WaxError.io("decompression unsupported on this platform") }]
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

    /// `.lz4` payloads have two on-disk forms. Apple writes `COMPRESSION_LZ4` output:
    /// LZ4 blocks wrapped in `bv41` / `bv4-` frames and terminated by `bv4$`. Linux
    /// writes one raw liblz4 block. Each platform keeps its writer (older Apple builds
    /// can only read the framed form) and both read both forms: framing first when this
    /// magic is present, then a raw block.
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

    static func appleCandidateDecoders(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int
    ) -> [() throws -> Data] {
        guard algorithm == .lz4 else {
            return [{ try appleDecode(data, algorithm: algorithm.appleAlgorithm, uncompressedLength: uncompressedLength) }]
        }
        let raw: () throws -> Data = {
            try appleDecode(data, algorithm: COMPRESSION_LZ4_RAW, uncompressedLength: uncompressedLength)
        }
        guard hasAppleLZ4FrameMagic(data) else { return [raw] }
        return [
            { try appleDecode(data, algorithm: COMPRESSION_LZ4, uncompressedLength: uncompressedLength) },
            raw,
        ]
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
            // Framed `bv41` output, which every Apple build can read; Linux reads it too.
            return COMPRESSION_LZ4
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

    static func linuxCandidateDecoders(
        _ data: Data,
        algorithm: CompressionKind,
        uncompressedLength: Int
    ) -> [() throws -> Data] {
        switch algorithm {
        case .none:
            return [{ data }]
        case .lzfse:
            return [{ throw WaxError.io("compression algorithm lzfse is unavailable in this Linux build") }]
        case .lz4:
            let raw: () throws -> Data = {
                try linuxLZ4Decode(data, uncompressedLength: uncompressedLength, appleFramed: false)
            }
            guard hasAppleLZ4FrameMagic(data) else { return [raw] }
            return [
                { try linuxLZ4Decode(data, uncompressedLength: uncompressedLength, appleFramed: true) },
                raw,
            ]
        case .deflate:
            return [{ try linuxDeflateDecompress(data, uncompressedLength: uncompressedLength) }]
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
