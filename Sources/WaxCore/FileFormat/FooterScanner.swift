import Foundation

/// A footer and its TOC bytes, which the scanner checked against the footer's `tocHash`.
package struct FooterSlice: Equatable, Sendable {
    package let footerOffset: UInt64
    package let tocOffset: UInt64
    package let footer: WaxFooter
    package let tocBytes: Data
}

/// Scans for the most recent valid Wax footer.
package enum FooterScanner {
    package struct Limits: Sendable {
        package var maxTocBytes: UInt64 = Constants.maxTocBytes
        package var maxFooterScanBytes: UInt64 = Constants.maxFooterScanBytes

        package init() {}
    }

    /// Bounded scan over an in-memory buffer. Intended for tests and small buffers.
    package static func findLastValidFooter(in bytes: Data, limits: Limits = .init()) -> FooterSlice? {
        let footerSize = WaxFooter.size
        guard bytes.count >= footerSize else { return nil }

        let scanWindow = Int(min(UInt64(bytes.count), limits.maxFooterScanBytes))
        let scanStart = bytes.count - scanWindow

        var best: FooterSlice?

        for pos in magicCandidates(in: bytes, from: bytes.count - footerSize, downTo: scanStart) {
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

    /// Bounded scan over a file. Only the final `limits.maxFooterScanBytes` are searched, and
    /// only footers `accepts(footerOffset, generation)` allows are candidates.
    package static func findLastValidFooter(
        in fileURL: URL,
        limits: Limits = .init(),
        accepts: (_ footerOffset: UInt64, _ generation: UInt64) -> Bool = { _, _ in true }
    ) throws -> FooterSlice? {
        let file = try FDFile.openReadOnly(at: fileURL)
        defer { try? file.close() }

        let fileSize = try file.size()
        guard fileSize >= UInt64(WaxFooter.size) else { return nil }

        let scanStart = fileSize > limits.maxFooterScanBytes ? (fileSize - limits.maxFooterScanBytes) : 0
        guard let best = try findBestFooter(
            in: file,
            fileSize: fileSize,
            scanStart: scanStart,
            limits: limits,
            accepts: accepts
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

    package static func findFooter(at footerOffset: UInt64, in fileURL: URL, limits: Limits = .init()) throws -> FooterSlice? {
        guard let slice = try readFooter(at: footerOffset, in: fileURL, limits: limits) else { return nil }
        return slice.footer.hashMatches(tocBytes: slice.tocBytes) ? slice : nil
    }

    /// ``findFooter(at:in:limits:)``, decoding the TOC while its hash is checked: at 100k
    /// frames each takes tens of milliseconds of an open. The decode is bounds-checked, so it
    /// is safe on bytes the hash may yet reject. `toc` is `nil` when the decode threw;
    /// decoding the slice again throws the same error.
    package static func findFooterDecodingToc(
        at footerOffset: UInt64,
        in fileURL: URL,
        limits: Limits = .init()
    ) throws -> (slice: FooterSlice, toc: WaxTOC?)? {
        guard let slice = try readFooter(at: footerOffset, in: fileURL, limits: limits) else { return nil }
        let work = HashAndDecode(slice)
        // The calling thread runs an iteration too, so both finish even with no worker free.
        DispatchQueue.concurrentPerform(iterations: 2) { work.run(iteration: $0) }
        guard work.hashMatches else { return nil }
        return (slice, work.decodedToc)
    }

    /// The footer at `footerOffset` and the TOC bytes before it, not yet checked against its hash.
    private static func readFooter(at footerOffset: UInt64, in fileURL: URL, limits: Limits) throws -> FooterSlice? {
        let file = try FDFile.openReadOnly(at: fileURL)
        defer { try? file.close() }

        let fileSize = try file.size()
        let footerSize = UInt64(WaxFooter.size)
        guard footerOffset <= fileSize, footerSize <= fileSize - footerOffset else { return nil }

        let footerBytes = try file.readExactly(length: Int(footerSize), at: footerOffset)
        guard let footer = try? WaxFooter.decode(from: footerBytes) else { return nil }
        guard footer.tocLen >= 32 else { return nil }
        guard footer.tocLen <= limits.maxTocBytes else { return nil }
        guard footerOffset >= footer.tocLen else { return nil }
        guard footer.tocLen <= UInt64(Int.max) else { return nil }

        let tocOffset = footerOffset - footer.tocLen
        // Read the TOC once and check it in memory; the caller decodes these same bytes.
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
        limits: Limits,
        accepts: (UInt64, UInt64) -> Bool
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
                limits: limits,
                accepts: accepts
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
        limits: Limits,
        accepts: (UInt64, UInt64) -> Bool
    ) throws -> (footerOffset: UInt64, tocOffset: UInt64, footer: WaxFooter)? {
        let footerSize = WaxFooter.size
        guard window.count >= footerSize else { return nil }

        var best: (footerOffset: UInt64, tocOffset: UInt64, footer: WaxFooter)?

        for localPos in magicCandidates(in: window, from: window.count - footerSize, downTo: 0) {
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
            let footerSize64 = UInt64(footerSize)
            guard footerOffset <= fileSize, footerSize64 <= fileSize - footerOffset else { continue }
            guard footerOffset >= footer.tocLen else { continue }
            guard accepts(footerOffset, footer.generation) else { continue }
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

    /// Offsets in `bytes` that hold the footer magic's first byte, from `upper` down to
    /// `lower` (both inclusive). A raw pointer loop: in debug builds a `stride` loop that
    /// subscripts `Data` looks up generic metadata on every byte, and footer-scanning tests
    /// ran 4-6x slower with it.
    private static func magicCandidates(in bytes: Data, from upper: Int, downTo lower: Int) -> [Int] {
        guard upper >= lower else { return [] }
        let first = Constants.footerMagic[Constants.footerMagic.startIndex]
        let base = bytes.startIndex
        return bytes.withUnsafeBytes { (raw: UnsafeRawBufferPointer) -> [Int] in
            var positions: [Int] = []
            var pos = upper
            while pos >= lower {
                if raw[pos - base] == first {
                    positions.append(pos)
                }
                pos -= 1
            }
            return positions
        }
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

/// A footer's hash check and TOC decode, run as two `concurrentPerform` iterations.
///
/// `@unchecked Sendable`: iteration 0 writes only `hashMatches` and iteration 1 only `decodedToc`,
/// and both are read after `concurrentPerform` returns.
private final class HashAndDecode: @unchecked Sendable {
    let slice: FooterSlice
    var hashMatches = false
    var decodedToc: WaxTOC?

    init(_ slice: FooterSlice) {
        self.slice = slice
    }

    func run(iteration: Int) {
        if iteration == 0 {
            hashMatches = slice.footer.hashMatches(tocBytes: slice.tocBytes)
        } else {
            decodedToc = try? WaxTOC.decode(from: slice)
        }
    }
}
