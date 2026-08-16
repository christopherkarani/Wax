import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Wax {
    // MARK: - Verification hook

    /// Verify the file on disk.
    ///
    /// Pass `deep: false` for a structural-only check (skip per-frame checksums).
    package func verify(deep: Bool = true) async throws {
        try await withReadLock {
            let file = self.file
            let pageA = try await io.run {
                try file.readExactly(length: Int(Constants.headerPageSize), at: 0)
            }
            let pageB = try await io.run {
                try file.readExactly(length: Int(Constants.headerPageSize), at: Constants.headerPageSize)
            }
            guard let selected = WaxHeaderPage.selectValidPage(pageA: pageA, pageB: pageB) else {
                throw WaxError.invalidHeader(reason: "no valid header pages")
            }
            let header = selected.page
            let url = self.url

            let fastFooter = try await io.run({
                try FooterScanner.findFooter(at: header.footerOffset, in: url)
            })
            let snapshotFooter: FooterSlice?
            if let snapshot = header.walReplaySnapshot {
                snapshotFooter = try await io.run {
                    try FooterScanner.findFooter(at: snapshot.footerOffset, in: url)
                }
            } else {
                snapshotFooter = nil
            }
            let scannedFooter = try await io.run {
                try FooterScanner.findLastValidFooter(in: url)
            }

            var footerCandidates: [FooterSlice] = []
            footerCandidates.reserveCapacity(3)
            if let fastFooter {
                footerCandidates.append(fastFooter)
            }
            if let snapshotFooter {
                footerCandidates.append(snapshotFooter)
            }
            if let scannedFooter {
                footerCandidates.append(scannedFooter)
            }
            guard let firstFooterCandidate = footerCandidates.first else {
                throw WaxError.invalidFooter(reason: "no valid footer found within max_footer_scan_bytes")
            }
            let footerSlice = footerCandidates.dropFirst().reduce(firstFooterCandidate) { current, candidate in
                if candidate.footer.generation > current.footer.generation {
                    return candidate
                }
                if candidate.footer.generation == current.footer.generation,
                   candidate.footerOffset > current.footerOffset {
                    return candidate
                }
                return current
            }
            let toc = try WaxTOC.decode(from: footerSlice.tocBytes)

            let dataStart = header.walOffset + header.walSize
            try Self.validateTocRanges(toc, dataStart: dataStart, dataEnd: footerSlice.footerOffset)

            guard deep else { return }

            var frameIndex = 0
            for frame in toc.frames {
                guard frame.payloadLength > 0 else {
                    frameIndex += 1
                    continue
                }
                guard let storedChecksum = frame.storedChecksum else {
                    throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
                }
                let stored = try await sha256(
                    file: file,
                    offset: frame.payloadOffset,
                    length: frame.payloadLength
                )
                guard stored == storedChecksum else {
                    throw WaxError.checksumMismatch("frame \(frame.id) stored_checksum mismatch")
                }
                if frame.canonicalEncoding == .plain {
                    guard stored == frame.checksum else {
                        throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
                    }
                } else {
                    guard let canonicalLength = frame.canonicalLength else {
                        throw WaxError.invalidToc(reason: "frame \(frame.id) missing canonical_length")
                    }
                    guard canonicalLength <= UInt64(Int.max) else {
                        throw WaxError.io("canonical payload too large: \(canonicalLength)")
                    }
                    guard frame.payloadLength <= UInt64(Int.max) else {
                        throw WaxError.io("payload too large: \(frame.payloadLength)")
                    }
                    let storedBytes = try await io.run {
                        try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
                    }
                    let canonicalBytes = try PayloadCompressor.decompress(
                        storedBytes,
                        algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
                        uncompressedLength: Int(canonicalLength)
                    )
                    let canonicalChecksum = SHA256Checksum.digest(canonicalBytes)
                    guard canonicalChecksum == frame.checksum else {
                        throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
                    }
                }

                frameIndex += 1
                if frameIndex % 32 == 0 {
                    await Task.yield()
                }
            }

            var segmentIndex = 0
            for entry in toc.segmentCatalog.entries {
                guard entry.bytesLength > 0 else {
                    segmentIndex += 1
                    continue
                }
                let computed = try await sha256(
                    file: file,
                    offset: entry.bytesOffset,
                    length: entry.bytesLength
                )
                guard computed == entry.checksum else {
                    throw WaxError.checksumMismatch("segment \(entry.segmentId) checksum mismatch")
                }

                segmentIndex += 1
                if segmentIndex % 16 == 0 {
                    await Task.yield()
                }
            }
        }
    }

    package func close() async throws {
        try await withWriteLock {
            var commitError: Error?
            if dirty || stagedLexIndex != nil || stagedVecIndex != nil {
                do {
                    try await commitLocked()
                } catch {
                    commitError = error
                }
            }

            let file = self.file
            let lock = self.lock
            var closeError: Error?
            do {
                try await io.run {
                    try file.close()
                    try lock.release()
                }
            } catch {
                closeError = error
            }

            if let commitError {
                // Commit error indicates potential data loss; prioritize it over close errors.
                throw commitError
            }
            if let closeError {
                throw closeError
            }
        }
    }

}
