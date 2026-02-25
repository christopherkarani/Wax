import Foundation

public struct WaxFooter: Equatable, Sendable {
    public static let size: Int = Int(Constants.footerSize)
    public static let magic: Data = Constants.footerMagic

    public var tocLen: UInt64
    public var tocHash: Data
    public var generation: UInt64
    public var walCommittedSeq: UInt64

    public init(tocLen: UInt64, tocHash: Data, generation: UInt64, walCommittedSeq: UInt64) {
        self.tocLen = tocLen
        self.tocHash = tocHash
        self.generation = generation
        self.walCommittedSeq = walCommittedSeq
    }

    public func encode() throws -> Data {
        guard tocHash.count == 32 else {
            throw WaxError.invalidFooter(reason: "toc_hash must be 32 bytes (got \(tocHash.count))")
        }

        var encoder = BinaryEncoder()
        encoder.encodeFixedBytes(Self.magic)
        encoder.encode(tocLen)
        encoder.encodeFixedBytes(tocHash)
        encoder.encode(generation)
        encoder.encode(walCommittedSeq)

        let data = encoder.data
        guard data.count == Self.size else {
            throw WaxError.invalidFooter(reason: "encoded footer size mismatch (got \(data.count), expected \(Self.size))")
        }
        return data
    }

    public static func decode(from data: Data) throws -> WaxFooter {
        guard data.count == Self.size else {
            throw WaxError.invalidFooter(reason: "footer must be \(Self.size) bytes (got \(data.count))")
        }

        var decoder = try BinaryDecoder(data: data)
        let magic = try decoder.decodeFixedBytes(count: Self.magic.count)
        guard magic == Self.magic else {
            throw WaxError.invalidFooter(reason: "magic mismatch")
        }

        let tocLen = try decoder.decode(UInt64.self)
        let tocHash = try decoder.decodeFixedBytes(count: 32)
        let generation = try decoder.decode(UInt64.self)
        let walCommittedSeq = try decoder.decode(UInt64.self)
        try decoder.finalize()

        return WaxFooter(
            tocLen: tocLen,
            tocHash: tocHash,
            generation: generation,
            walCommittedSeq: walCommittedSeq
        )
    }

    /// Validates `toc_hash` against the TOC bytes.
    ///
    /// Wax v1 semantics:
    /// - `toc_checksum` is the final 32 bytes of the TOC encoding.
    /// - The checksum is computed as `SHA256(toc_body + zero32)` where `toc_body = toc_bytes[0..<len-32]`.
    /// - Footer `toc_hash` must equal both the computed checksum and the stamped `toc_checksum` bytes.
    public func hashMatches(tocBytes: Data) -> Bool {
        guard UInt64(tocBytes.count) == tocLen else { return false }
        guard tocBytes.count >= 32 else { return false }

        let storedChecksum = tocBytes.suffix(32)
        let bodyCount = tocBytes.count - 32

        var hasher = SHA256Checksum()
        tocBytes.withUnsafeBytes { raw in
            hasher.update(UnsafeRawBufferPointer(rebasing: raw[..<bodyCount]))
        }
        hasher.update(Data(repeating: 0, count: 32))
        let computed = hasher.finalize()

        return Data(storedChecksum) == computed && tocHash == computed
    }
}

