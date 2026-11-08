import Foundation

extension Wax {
    // MARK: - Verification hook

    /// Verify the file on disk.
    ///
    /// This is equivalent to `verify(deep: true)`. Use `verify(deep: false)` for a structural-only check.
    package func verify() async throws {
        try await verify(deep: true)
    }

    package func verify(deep: Bool) async throws {
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
                }.flatMap {
                    header.admitsRecovery(footerOffset: $0.footerOffset, generation: $0.footer.generation) ? $0 : nil
                }
            } else {
                snapshotFooter = nil
            }
            let scannedFooter = try await io.run {
                try FooterScanner.findLastValidFooter(in: url, accepts: header.admitsRecovery)
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
            let candidates = footerCandidates
            let (footerSlice, toc) = try await io.run {
                try Self.newestWholeCommit(
                    candidates,
                    headerFooterOffset: header.footerOffset,
                    headerGeneration: header.fileGeneration,
                    file: file
                )
            }

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
                    let expectedChecksum = frame.checksum
                    let canonicalBytes = try PayloadCompressor.decompress(
                        storedBytes,
                        algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
                        uncompressedLength: Int(canonicalLength),
                        verifiedBy: { SHA256Checksum.digest($0) == expectedChecksum }
                    )
                    guard canonicalBytes != nil else {
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

    /// Internal only because of the file split.
    struct DataRange {
        /// What uses the range. Named only when an overlap is reported: formatting a label for
        /// every frame cost a string per frame on each commit and open.
        enum Owner {
            case frame(UInt64)
            case segment(UInt64)

            var label: String {
                switch self {
                case .frame(let id): "frame \(id)"
                case .segment(let id): "segment \(id)"
                }
            }
        }

        var start: UInt64
        var end: UInt64
        var owner: Owner
    }

    /// Internal only because of the file split.
    static func validateTocRanges(_ toc: WaxTOC, dataStart: UInt64, dataEnd: UInt64) throws {
        let frameRanges = try collectFramePayloadRanges(
            toc.frames[...],
            firstFrameId: 0,
            dataStart: dataStart,
            dataEnd: dataEnd
        )
        let segmentRanges = try collectSegmentRanges(toc.segmentCatalog.entries, dataStart: dataStart, dataEnd: dataEnd)

        _ = try sortedNonOverlapping(frameRanges + segmentRanges)
        try validateTocManifests(toc)
    }

    /// Internal only because of the file split.
    static func validateTocManifests(_ toc: WaxTOC) throws {
        try validateSegmentCatalogMatchesManifests(
            segmentCatalog: toc.segmentCatalog,
            indexes: toc.indexes,
            timeIndex: toc.timeIndex
        )
    }

    /// Checks each frame and returns its payload range, if it has one. `frames` must carry
    /// the dense ids `firstFrameId`, `firstFrameId + 1`, ...
    /// Internal only because of the file split.
    static func collectFramePayloadRanges(
        _ frames: ArraySlice<FrameMeta>,
        firstFrameId: UInt64,
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> [DataRange] {
        guard dataEnd >= dataStart else {
            throw WaxError.invalidToc(reason: "data region invalid: start \(dataStart), end \(dataEnd)")
        }

        var ranges: [DataRange] = []
        ranges.reserveCapacity(frames.count)

        for (offset, frame) in frames.enumerated() {
            let expected = firstFrameId + UInt64(offset)
            guard frame.id == expected else {
                throw WaxError.invalidToc(reason: "frame id not dense: found \(frame.id), expected \(expected)")
            }
            if frame.checksum.count != 32 {
                throw WaxError.invalidToc(reason: "frame \(frame.id) checksum must be 32 bytes")
            }
            if frame.canonicalEncoding != .plain && frame.canonicalLength == nil {
                throw WaxError.invalidToc(reason: "frame \(frame.id) missing canonical_length")
            }
            if frame.payloadLength > 0 && frame.storedChecksum == nil {
                throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
            }
            if frame.payloadLength == 0 { continue }
            guard frame.payloadOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload below data region")
            }
            guard frame.payloadOffset <= UInt64.max - frame.payloadLength else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload range overflows")
            }
            let end = frame.payloadOffset + frame.payloadLength
            guard end <= dataEnd else {
                throw WaxError.invalidToc(reason: "frame \(frame.id) payload exceeds data end")
            }
            ranges.append(DataRange(start: frame.payloadOffset, end: end, owner: .frame(frame.id)))
        }

        return ranges
    }

    /// Internal only because of the file split.
    static func collectSegmentRanges(
        _ entries: [SegmentCatalogEntry],
        dataStart: UInt64,
        dataEnd: UInt64
    ) throws -> [DataRange] {
        var ranges: [DataRange] = []
        ranges.reserveCapacity(entries.count)

        for entry in entries {
            if entry.bytesLength == 0 { continue }
            guard entry.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) below data region")
            }
            guard entry.bytesOffset <= UInt64.max - entry.bytesLength else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) range overflows")
            }
            let end = entry.bytesOffset + entry.bytesLength
            guard end <= dataEnd else {
                throw WaxError.invalidToc(reason: "segment \(entry.segmentId) exceeds data end")
            }
            ranges.append(DataRange(start: entry.bytesOffset, end: end, owner: .segment(entry.segmentId)))
        }

        return ranges
    }

    /// `ranges` sorted by start, after checking that no two overlap.
    /// Internal only because of the file split.
    static func sortedNonOverlapping(_ ranges: [DataRange]) throws -> [DataRange] {
        let sorted = ranges.sorted { $0.start < $1.start }
        for idx in sorted.indices.dropFirst() {
            let prev = sorted[idx - 1]
            let next = sorted[idx]
            if prev.end > next.start {
                throw overlapError(prev, next)
            }
        }
        return sorted
    }

    /// Internal only because of the file split.
    static func overlapError(_ first: DataRange, _ second: DataRange) -> WaxError {
        WaxError.invalidToc(reason: "data overlap between \(first.owner.label) and \(second.owner.label)")
    }

    private static func validateSegmentCatalogMatchesManifests(
        segmentCatalog: SegmentCatalog,
        indexes: IndexManifests,
        timeIndex: TimeIndexManifest?
    ) throws {
        if let lex = indexes.lex {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .lex
                    && entry.bytesOffset == lex.bytesOffset
                    && entry.bytesLength == lex.bytesLength
                    && entry.checksum == lex.checksum
            }) else {
                throw WaxError.invalidToc(reason: "lex index manifest missing matching segment catalog entry")
            }
        }
        if let vec = indexes.vec {
            for run in vec.runs {
                guard segmentCatalog.entries.contains(where: { entry in
                    entry.kind == .vec
                        && entry.bytesOffset == run.bytesOffset
                        && entry.bytesLength == run.bytesLength
                        && entry.checksum == run.checksum
                }) else {
                    throw WaxError.invalidToc(reason: "vec run missing matching segment catalog entry")
                }
            }
            guard segmentCatalog.entries.count(where: { $0.kind == .vec }) == vec.runs.count else {
                throw WaxError.invalidToc(reason: "vec segment catalog entries do not match the vec runs")
            }
            let rowCount = vec.runs.reduce(UInt64(0)) { $0 &+ $1.rowCount }
            guard vec.vectorCount <= rowCount else {
                throw WaxError.invalidToc(reason: "vec vector count exceeds the rows of its runs")
            }
        }
        if let timeIndex {
            guard segmentCatalog.entries.contains(where: { entry in
                entry.kind == .time
                    && entry.bytesOffset == timeIndex.bytesOffset
                    && entry.bytesLength == timeIndex.bytesLength
                    && entry.checksum == timeIndex.checksum
            }) else {
                throw WaxError.invalidToc(reason: "time index manifest missing matching segment catalog entry")
            }
        }
    }

    private func sha256(file: FDFile, offset: UInt64, length: UInt64) async throws -> Data {
        guard length > 0 else { return SHA256Checksum.digest(Data()) }
        var hasher = SHA256Checksum()
        let chunkSize: UInt64 = 1 * 1024 * 1024

        var cursor: UInt64 = 0
	        var chunkIndex = 0
	        while cursor < length {
	            let remaining = length - cursor
	            let thisChunkLen64 = min(chunkSize, remaining)
	            guard thisChunkLen64 <= UInt64(Int.max) else {
	                throw WaxError.io("verify chunk exceeds Int.max: \(thisChunkLen64)")
	            }
	            let readOffset = offset + cursor
	            let bytes = try await io.run {
	                try file.readExactly(length: Int(thisChunkLen64), at: readOffset)
	            }
	            bytes.withUnsafeBytes { raw in
	                hasher.update(raw)
	            }
            cursor += thisChunkLen64
            chunkIndex += 1
            if chunkIndex % 8 == 0 {
                await Task.yield()
            }
        }

        return hasher.finalize()
    }
}
