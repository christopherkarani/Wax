import Foundation

/// Constants matching `WAX_SPEC.md` (Wax v1.0).
public enum Constants {
    // MARK: - Magic Bytes

    /// Header magic: "WAX1" (4 bytes)
    public static let magic = Data([0x57, 0x41, 0x58, 0x31])

    /// Footer magic: "WAX1FOOT" (8 bytes)
    public static let footerMagic = Data([0x57, 0x41, 0x58, 0x31, 0x46, 0x4F, 0x4F, 0x54])

    // MARK: - Version

    public static let specMajor: UInt8 = 1
    public static let specMinor: UInt8 = 0

    /// Packed major/minor: `(major << 8) | minor` (little-endian on disk).
    public static let specVersion: UInt16 = (UInt16(specMajor) << 8) | UInt16(specMinor)

    // MARK: - Sizes

    /// Header page size: 4 KiB
    public static let headerPageSize: UInt64 = 4096

    /// Back-compat alias (Phase 0 scaffold used `headerSize`).
    public static let headerSize: UInt64 = headerPageSize

    /// Header region size: 8 KiB (A+B pages)
    public static let headerRegionSize: UInt64 = 8192

    /// Footer size: 64 bytes (v1 footer includes `wal_committed_seq`)
    public static let footerSize: UInt64 = 64

    /// WAL record header size: 48 bytes (fixed for Wax v1).
    public static let walRecordHeaderSize: UInt64 = 48

    // MARK: - File Layout (v1 defaults)

    /// WAL starts immediately after the header region.
    public static let walOffset: UInt64 = headerRegionSize

    /// Default WAL size used by tests/examples (256 MiB).
    public static let defaultWalSize: UInt64 = 256 * 1024 * 1024

    // MARK: - Decoder Limits (recommended defaults)

    public static let maxStringBytes: Int = 16 * 1024 * 1024
    public static let maxBlobBytes: Int = 256 * 1024 * 1024
    public static let maxArrayCount: Int = 10_000_000
    public static let maxEmbeddingDimensions: Int = 1_000_000

    public static let maxTocBytes: UInt64 = 64 * 1024 * 1024
    public static let maxFooterScanBytes: UInt64 = 32 * 1024 * 1024
}
