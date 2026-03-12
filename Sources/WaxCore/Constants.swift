import Foundation

/// Constants matching `WAX_SPEC.md` (Wax v1.0).
package enum Constants {
    // MARK: - Magic Bytes

    /// Header magic: "WAX1" (4 bytes)
    package static let magic = Data([0x57, 0x41, 0x58, 0x31])

    /// Footer magic: "WAX1FOOT" (8 bytes)
    package static let footerMagic = Data([0x57, 0x41, 0x58, 0x31, 0x46, 0x4F, 0x4F, 0x54])

    // MARK: - Version

    package static let specMajor: UInt8 = 1
    package static let specMinor: UInt8 = 0

    /// Packed major/minor: `(major << 8) | minor` (little-endian on disk).
    package static let specVersion: UInt16 = (UInt16(specMajor) << 8) | UInt16(specMinor)

    // MARK: - Sizes

    /// Header page size: 4 KiB
    package static let headerPageSize: UInt64 = 4096

    /// Back-compat alias (Phase 0 scaffold used `headerSize`).
    package static let headerSize: UInt64 = headerPageSize

    /// Header region size: 8 KiB (A+B pages)
    package static let headerRegionSize: UInt64 = 8192

    /// Footer size: 64 bytes (v1 footer includes `wal_committed_seq`)
    package static let footerSize: UInt64 = 64

    /// WAL record header size: 48 bytes (fixed for Wax v1).
    package static let walRecordHeaderSize: UInt64 = 48

    // MARK: - File Layout (v1 defaults)

    /// WAL starts immediately after the header region.
    package static let walOffset: UInt64 = headerRegionSize

    /// Default WAL size used by tests/examples (256 MiB).
    package static let defaultWalSize: UInt64 = 256 * 1024 * 1024

    // MARK: - Decoder Limits (recommended defaults)

    package static let maxStringBytes: Int = 16 * 1024 * 1024
    package static let maxBlobBytes: Int = 256 * 1024 * 1024
    package static let maxArrayCount: Int = 10_000_000
    package static let maxEmbeddingDimensions: Int = 1_000_000

    package static let maxTocBytes: UInt64 = 64 * 1024 * 1024
    package static let maxFooterScanBytes: UInt64 = 32 * 1024 * 1024
}
