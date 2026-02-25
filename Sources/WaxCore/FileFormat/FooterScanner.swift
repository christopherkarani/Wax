import Foundation

public struct FooterSlice: Equatable, Sendable {
    public let footerOffset: UInt64
    public let tocOffset: UInt64
    public let footer: WaxFooter
    public let tocBytes: Data
}

/// Scans for the most recent valid Wax footer.
public enum FooterScanner {
    public struct Limits: Sendable {
        public var maxTocBytes: UInt64 = Constants.maxTocBytes
        public var maxFooterScanBytes: UInt64 = Constants.maxFooterScanBytes

        public init() {}
    }

    /// Bounded scan over an in-memory buffer. Intended for tests and small buffers.
    public static func findLastValidFooter(in bytes: Data, limits: Limits = .init()) -> FooterSlice? {
        let footerSize = WaxFooter.size
        guard bytes.count >= footerSize else { return nil }

        let scanWindow = Int(min(UInt64(bytes.count), limits.maxFooterScanBytes))
        let scanStart = bytes.count - scanWindow

        var best: FooterSlice?

        for pos in stride(from: bytes.count - footerSize, through: scanStart, by: -1) {
            guard bytes[pos] == Constants.footerMagic[0] else { continue }
            let magicEnd = pos + Constants.footerMagic.count
            guard magicEnd <= bytes.count else { continue }
            guard bytes[pos..<magicEnd] == Constants.footerMagic else { continue }

            let footerEnd = pos + footerSize
            guard footerEnd <= bytes.count else { continue }

            guard let footer = try? WaxFooter.decode(from: bytes.subdata(in: pos..<footerEnd)) else {
                continue
            }

            guard footer.tocLen >= 32 else { continue }
            guard footer.tocLen <= limits.maxTocBytes else { continue }
            guard footer.tocLen <= UInt64(pos) else { continue }

            let tocOffset = pos - Int(footer.tocLen)
            let tocBytes = bytes.subdata(in: tocOffset..<pos)
            guard footer.hashMatches(tocBytes: tocBytes) else { continue }

            let candidate = FooterSlice(
                footerOffset: UInt64(pos),
                tocOffset: UInt64(tocOffset),
                footer: footer,
                tocBytes: tocBytes
            )

            if let current = best {
                if footer.generation > current.footer.generation {
                    best = candidate
                } else if footer.generation == current.footer.generation && candidate.footerOffset > current.footerOffset {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }

    /// Bounded scan over a file. Only the final `limits.maxFooterScanBytes` are searched.
    public static func findLastValidFooter(in fileURL: URL, limits: Limits = .init()) throws -> FooterSlice? {
        let file = try FDFile.openReadOnly(at: fileURL)
        defer { try? file.close() }

        let fileSize = try file.size()
        guard fileSize >= UInt64(WaxFooter.size) else { return nil }

        let scanStart = fileSize > limits.maxFooterScanBytes ? (fileSize - limits.maxFooterScanBytes) : 0
        guard let best = try findBestFooter(
            in: file,
            fileSize: fileSize,
            scanStart: scanStart,
            limits: limits
        ) else {
            return nil
        }

        guard best.footer.tocLen <= UInt64(Int.max) else {
            throw WaxError.invalidToc(reason: "toc_len too large for memory: \(best.footer.tocLen)")
        }
        let tocBytes = try file.readExactly(length: Int(best.footer.tocLen), at: best.tocOffset)
        return FooterSlice(
            footerOffset: best.footerOffset,
            tocOffset: best.tocOffset,
            footer: best.footer,
            tocBytes: tocBytes
        )
    }

    public static func findFooter(at footerOffset: UInt64, in fileURL: URL, limits: Limits = .init()) throws -> FooterSlice? {
        let file = try FDFile.openReadOnly(at: fileURL)
        defer { try? file.close() }

        let fileSize = try file.size()
        let footerSize = UInt64(WaxFooter.size)
        guard footerOffset + footerSize <= fileSize else { return nil }

        let footerBytes = try file.readExactly(length: Int(footerSize), at: footerOffset)
        guard let footer = try? WaxFooter.decode(from: footerBytes) else { return nil }
        guard footer.tocLen >= 32 else { return nil }
        guard footer.tocLen <= limits.maxTocBytes else { return nil }
        guard footerOffset >= footer.tocLen else { return nil }
        guard footer.tocLen <= UInt64(Int.max) else { return nil }

        let tocOffset = footerOffset - footer.tocLen
        guard try tocHashMatches(
            file: file,
            tocOffset: tocOffset,
            tocLen: footer.tocLen,
            expectedHash: footer.tocHash
        ) else { return nil }

        let tocBytes = try file.readExactly(length: Int(footer.tocLen), at: tocOffset)
        return FooterSlice(
            footerOffset: footerOffset,
            tocOffset: tocOffset,
            footer: footer,
            tocBytes: tocBytes
        )
    }

    private static func findBestFooter(
        in file: FDFile,
        fileSize: UInt64,
        scanStart: UInt64,
        limits: Limits
    ) throws -> (footerOffset: UInt64, tocOffset: UInt64, footer: WaxFooter)? {
        let footerSize = UInt64(WaxFooter.size)
        let overlap = UInt64(WaxFooter.size - 1)
        let chunkSize: UInt64 = 1 * 1024 * 1024

        var end = fileSize
        var best: (footerOffset: UInt64, tocOffset: UInt64, footer: WaxFooter)?

        while end > scanStart, end >= footerSize {
            let start = max(scanStart, end > chunkSize ? (end - chunkSize) : 0)
            guard end > start else { break }
            guard end - start <= UInt64(Int.max) else {
                throw WaxError.io("scan chunk too large: \(end - start) bytes")
            }

            let window = try file.readExactly(length: Int(end - start), at: start)
            if let candidate = try scanChunkForBestFooter(
                window: window,
                windowBaseOffset: start,
                file: file,
                fileSize: fileSize,
                limits: limits
            ) {
                if let current = best {
                    if candidate.footer.generation > current.footer.generation {
                        best = candidate
                    } else if candidate.footer.generation == current.footer.generation && candidate.footerOffset > current.footerOffset {
                        best = candidate
                    }
                } else {
                    best = candidate
                }
            }

            if start == scanStart { break }
            end = start + overlap
        }

        return best
    }

    private static func scanChunkForBestFooter(
        window: Data,
        windowBaseOffset: UInt64,
        file: FDFile,
        fileSize: UInt64,
        limits: Limits
    ) throws -> (footerOffset: UInt64, tocOffset: UInt64, footer: WaxFooter)? {
        let footerSize = WaxFooter.size
        guard window.count >= footerSize else { return nil }

        var best: (footerOffset: UInt64, tocOffset: UInt64, footer: WaxFooter)?

        for localPos in stride(from: window.count - footerSize, through: 0, by: -1) {
            guard window[localPos] == Constants.footerMagic[0] else { continue }
            let magicEnd = localPos + Constants.footerMagic.count
            guard magicEnd <= window.count else { continue }
            guard window[localPos..<magicEnd] == Constants.footerMagic else { continue }

            let footerEnd = localPos + footerSize
            guard footerEnd <= window.count else { continue }

            guard let footer = try? WaxFooter.decode(from: window.subdata(in: localPos..<footerEnd)) else {
                continue
            }

            guard footer.tocLen >= 32 else { continue }
            guard footer.tocLen <= limits.maxTocBytes else { continue }

            let footerOffset = windowBaseOffset + UInt64(localPos)
            guard footerOffset + UInt64(footerSize) <= fileSize else { continue }
            guard footerOffset >= footer.tocLen else { continue }
            let tocOffset = footerOffset - footer.tocLen

            guard try tocHashMatches(
                file: file,
                tocOffset: tocOffset,
                tocLen: footer.tocLen,
                expectedHash: footer.tocHash
            ) else { continue }

            let candidate = (footerOffset: footerOffset, tocOffset: tocOffset, footer: footer)
            if let current = best {
                if footer.generation > current.footer.generation {
                    best = candidate
                } else if footer.generation == current.footer.generation && candidate.footerOffset > current.footerOffset {
                    best = candidate
                }
            } else {
                best = candidate
            }
        }

        return best
    }

    private static func tocHashMatches(
        file: FDFile,
        tocOffset: UInt64,
        tocLen: UInt64,
        expectedHash: Data
    ) throws -> Bool {
        guard expectedHash.count == 32 else { return false }
        guard tocLen >= 32 else { return false }
        guard tocLen <= UInt64(Int.max) else { return false }

        let storedChecksumOffset = tocOffset + tocLen - 32
        let storedChecksum = try file.readExactly(length: 32, at: storedChecksumOffset)

        var hasher = SHA256Checksum()
        let bodyLen = tocLen - 32
        let chunkSize: UInt64 = 1024 * 1024

        var cursor: UInt64 = 0
        while cursor < bodyLen {
            let remaining = bodyLen - cursor
            let thisChunkLen = Int(min(chunkSize, remaining))
            let bytes = try file.readExactly(length: thisChunkLen, at: tocOffset + cursor)
            bytes.withUnsafeBytes { raw in
                hasher.update(raw)
            }
            cursor += UInt64(thisChunkLen)
        }

        hasher.update(Data(repeating: 0, count: 32))
        let computed = hasher.finalize()

        return computed == storedChecksum && computed == expectedHash
    }
}
