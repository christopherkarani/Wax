import Foundation

public struct WaxHeaderPage: Equatable, Sendable {
    public static let size: Int = Int(Constants.headerPageSize)
    public static let magic: Data = Constants.magic

    private static let headerChecksumOffset: Int = 104
    private static let headerChecksumCount: Int = 32
    private static let replaySnapshotMagicOffset: Int = 136
    private static let replaySnapshotMagicCount: Int = 8
    private static let replaySnapshotGenerationOffset: Int = 144
    private static let replaySnapshotCommittedSeqOffset: Int = 152
    private static let replaySnapshotFooterOffsetOffset: Int = 160
    private static let replaySnapshotWritePosOffset: Int = 168
    private static let replaySnapshotCheckpointPosOffset: Int = 176
    private static let replaySnapshotPendingBytesOffset: Int = 184
    private static let replaySnapshotLastSequenceOffset: Int = 192
    private static let replaySnapshotFlagsOffset: Int = 200
    private static let replaySnapshotValidFlag: UInt64 = 0x1
    private static let replaySnapshotMagic = Data([0x57, 0x41, 0x4C, 0x53, 0x4E, 0x41, 0x50, 0x31]) // WALSNAP1

    public struct WALReplaySnapshot: Equatable, Sendable {
        public var fileGeneration: UInt64
        public var walCommittedSeq: UInt64
        public var footerOffset: UInt64
        public var walWritePos: UInt64
        public var walCheckpointPos: UInt64
        public var walPendingBytes: UInt64
        public var walLastSequence: UInt64

        public init(
            fileGeneration: UInt64,
            walCommittedSeq: UInt64,
            footerOffset: UInt64,
            walWritePos: UInt64,
            walCheckpointPos: UInt64,
            walPendingBytes: UInt64,
            walLastSequence: UInt64
        ) {
            self.fileGeneration = fileGeneration
            self.walCommittedSeq = walCommittedSeq
            self.footerOffset = footerOffset
            self.walWritePos = walWritePos
            self.walCheckpointPos = walCheckpointPos
            self.walPendingBytes = walPendingBytes
            self.walLastSequence = walLastSequence
        }
    }

    public var formatVersion: UInt16
    public var specMajor: UInt8
    public var specMinor: UInt8

    public var headerPageGeneration: UInt64
    public var fileGeneration: UInt64

    public var footerOffset: UInt64
    public var walOffset: UInt64
    public var walSize: UInt64
    public var walWritePos: UInt64
    public var walCheckpointPos: UInt64
    public var walCommittedSeq: UInt64

    public var walReplaySnapshot: WALReplaySnapshot?

    public var tocChecksum: Data
    public var headerChecksum: Data

    public init(
        formatVersion: UInt16 = Constants.specVersion,
        specMajor: UInt8 = Constants.specMajor,
        specMinor: UInt8 = Constants.specMinor,
        headerPageGeneration: UInt64,
        fileGeneration: UInt64,
        footerOffset: UInt64,
        walOffset: UInt64,
        walSize: UInt64,
        walWritePos: UInt64,
        walCheckpointPos: UInt64,
        walCommittedSeq: UInt64,
        walReplaySnapshot: WALReplaySnapshot? = nil,
        tocChecksum: Data,
        headerChecksum: Data = Data(repeating: 0, count: 32)
    ) {
        self.formatVersion = formatVersion
        self.specMajor = specMajor
        self.specMinor = specMinor
        self.headerPageGeneration = headerPageGeneration
        self.fileGeneration = fileGeneration
        self.footerOffset = footerOffset
        self.walOffset = walOffset
        self.walSize = walSize
        self.walWritePos = walWritePos
        self.walCheckpointPos = walCheckpointPos
        self.walCommittedSeq = walCommittedSeq
        self.walReplaySnapshot = walReplaySnapshot
        self.tocChecksum = tocChecksum
        self.headerChecksum = headerChecksum
    }

    public func encodeWithChecksum() throws -> Data {
        let unpackedMajor = UInt8(truncatingIfNeeded: formatVersion >> 8)
        let unpackedMinor = UInt8(truncatingIfNeeded: formatVersion & 0x00FF)
        guard specMajor == unpackedMajor && specMinor == unpackedMinor else {
            throw WaxError.invalidHeader(reason: "spec_major/spec_minor mismatch format_version")
        }
        guard formatVersion == Constants.specVersion else {
            throw WaxError.invalidHeader(reason: "unsupported format_version 0x\(String(format: "%04X", formatVersion))")
        }
        guard tocChecksum.count == 32 else {
            throw WaxError.invalidHeader(reason: "toc_checksum must be 32 bytes (got \(tocChecksum.count))")
        }
        guard walSize >= Constants.walRecordHeaderSize else {
            throw WaxError.invalidHeader(reason: "wal_size must be >= \(Constants.walRecordHeaderSize)")
        }

        var page = Data(repeating: 0, count: Self.size)
        page.replaceSubrange(0..<Self.magic.count, with: Self.magic)

        // version fields
        var versionLE = formatVersion.littleEndian
        withUnsafeBytes(of: &versionLE) { page.replaceSubrange(4..<6, with: $0) }
        page[6] = specMajor
        page[7] = specMinor

        // UInt64 fields
        func putUInt64(_ value: UInt64, at offset: Int) {
            var le = value.littleEndian
            withUnsafeBytes(of: &le) { page.replaceSubrange(offset..<(offset + 8), with: $0) }
        }

        putUInt64(headerPageGeneration, at: 8)
        putUInt64(fileGeneration, at: 16)
        putUInt64(footerOffset, at: 24)
        putUInt64(walOffset, at: 32)
        putUInt64(walSize, at: 40)
        putUInt64(walWritePos, at: 48)
        putUInt64(walCheckpointPos, at: 56)
        putUInt64(walCommittedSeq, at: 64)

        page.replaceSubrange(72..<104, with: tocChecksum)

        if let snapshot = walReplaySnapshot {
            page.replaceSubrange(
                Self.replaySnapshotMagicOffset..<(Self.replaySnapshotMagicOffset + Self.replaySnapshotMagicCount),
                with: Self.replaySnapshotMagic
            )
            putUInt64(snapshot.fileGeneration, at: Self.replaySnapshotGenerationOffset)
            putUInt64(snapshot.walCommittedSeq, at: Self.replaySnapshotCommittedSeqOffset)
            putUInt64(snapshot.footerOffset, at: Self.replaySnapshotFooterOffsetOffset)
            putUInt64(snapshot.walWritePos, at: Self.replaySnapshotWritePosOffset)
            putUInt64(snapshot.walCheckpointPos, at: Self.replaySnapshotCheckpointPosOffset)
            putUInt64(snapshot.walPendingBytes, at: Self.replaySnapshotPendingBytesOffset)
            putUInt64(snapshot.walLastSequence, at: Self.replaySnapshotLastSequenceOffset)
            putUInt64(Self.replaySnapshotValidFlag, at: Self.replaySnapshotFlagsOffset)
        }

        let computed = Self.computeHeaderChecksum(over: page)
        page.replaceSubrange(Self.headerChecksumOffset..<(Self.headerChecksumOffset + Self.headerChecksumCount), with: computed)

        return page
    }

    public static func decodeWithChecksumValidation(from data: Data) throws -> WaxHeaderPage {
        let page = try decodeUnchecked(from: data)

        let stored = data.subdata(in: Self.headerChecksumOffset..<(Self.headerChecksumOffset + Self.headerChecksumCount))
        let computed = computeHeaderChecksum(over: data)
        guard stored == computed else {
            throw WaxError.checksumMismatch("header_checksum mismatch")
        }

        var validated = page
        validated.headerChecksum = stored
        return validated
    }

    public static func decodeUnchecked(from data: Data) throws -> WaxHeaderPage {
        guard data.count == Self.size else {
            throw WaxError.invalidHeader(reason: "header page must be \(Self.size) bytes (got \(data.count))")
        }

        let magic = data.subdata(in: 0..<Self.magic.count)
        guard magic == Self.magic else {
            throw WaxError.invalidHeader(reason: "magic mismatch")
        }

        func readUInt16(at offset: Int) -> UInt16 {
            var raw: UInt16 = 0
            _ = withUnsafeMutableBytes(of: &raw) { dest in
                data.copyBytes(to: dest, from: offset..<(offset + 2))
            }
            return UInt16(littleEndian: raw)
        }

        func readUInt64(at offset: Int) -> UInt64 {
            var raw: UInt64 = 0
            _ = withUnsafeMutableBytes(of: &raw) { dest in
                data.copyBytes(to: dest, from: offset..<(offset + 8))
            }
            return UInt64(littleEndian: raw)
        }

        let formatVersion = readUInt16(at: 4)
        let specMajor = data[6]
        let specMinor = data[7]

        let unpackedMajor = UInt8(truncatingIfNeeded: formatVersion >> 8)
        let unpackedMinor = UInt8(truncatingIfNeeded: formatVersion & 0x00FF)
        guard specMajor == unpackedMajor && specMinor == unpackedMinor else {
            throw WaxError.invalidHeader(reason: "spec_major/spec_minor mismatch format_version")
        }

        guard formatVersion == Constants.specVersion else {
            throw WaxError.invalidHeader(reason: "unsupported format_version 0x\(String(format: "%04X", formatVersion))")
        }

        let headerPageGeneration = readUInt64(at: 8)
        let fileGeneration = readUInt64(at: 16)
        let footerOffset = readUInt64(at: 24)
        let walOffset = readUInt64(at: 32)
        let walSize = readUInt64(at: 40)
        let walWritePos = readUInt64(at: 48)
        let walCheckpointPos = readUInt64(at: 56)
        let walCommittedSeq = readUInt64(at: 64)
        let replaySnapshotMagic = data.subdata(
            in: Self.replaySnapshotMagicOffset..<(Self.replaySnapshotMagicOffset + Self.replaySnapshotMagicCount)
        )
        let replaySnapshotFlags = readUInt64(at: Self.replaySnapshotFlagsOffset)
        let walReplaySnapshot: WALReplaySnapshot?
        if replaySnapshotMagic == Self.replaySnapshotMagic,
           (replaySnapshotFlags & Self.replaySnapshotValidFlag) != 0
        {
            walReplaySnapshot = WALReplaySnapshot(
                fileGeneration: readUInt64(at: Self.replaySnapshotGenerationOffset),
                walCommittedSeq: readUInt64(at: Self.replaySnapshotCommittedSeqOffset),
                footerOffset: readUInt64(at: Self.replaySnapshotFooterOffsetOffset),
                walWritePos: readUInt64(at: Self.replaySnapshotWritePosOffset),
                walCheckpointPos: readUInt64(at: Self.replaySnapshotCheckpointPosOffset),
                walPendingBytes: readUInt64(at: Self.replaySnapshotPendingBytesOffset),
                walLastSequence: readUInt64(at: Self.replaySnapshotLastSequenceOffset)
            )
        } else {
            walReplaySnapshot = nil
        }

        let tocChecksum = data.subdata(in: 72..<104)
        let headerChecksum = data.subdata(in: Self.headerChecksumOffset..<(Self.headerChecksumOffset + Self.headerChecksumCount))

        guard walOffset >= Constants.headerRegionSize else {
            throw WaxError.invalidHeader(reason: "wal_offset must be >= \(Constants.headerRegionSize)")
        }
        guard walSize >= Constants.walRecordHeaderSize else {
            throw WaxError.invalidHeader(reason: "wal_size must be >= \(Constants.walRecordHeaderSize)")
        }
        guard walWritePos <= walSize else {
            throw WaxError.invalidHeader(reason: "wal_write_pos must be <= wal_size")
        }
        guard walCheckpointPos <= walSize else {
            throw WaxError.invalidHeader(reason: "wal_checkpoint_pos must be <= wal_size")
        }
        if let walReplaySnapshot {
            guard walReplaySnapshot.walWritePos <= walSize else {
                throw WaxError.invalidHeader(reason: "wal_replay_snapshot.wal_write_pos must be <= wal_size")
            }
            guard walReplaySnapshot.walCheckpointPos <= walSize else {
                throw WaxError.invalidHeader(reason: "wal_replay_snapshot.wal_checkpoint_pos must be <= wal_size")
            }
            guard walReplaySnapshot.walPendingBytes <= walSize else {
                throw WaxError.invalidHeader(reason: "wal_replay_snapshot.wal_pending_bytes must be <= wal_size")
            }
            guard walReplaySnapshot.footerOffset >= walOffset + walSize else {
                throw WaxError.invalidHeader(
                    reason: "wal_replay_snapshot.footer_offset must be >= wal_offset + wal_size"
                )
            }
        }
        guard footerOffset >= walOffset + walSize else {
            throw WaxError.invalidHeader(reason: "footer_offset must be >= wal_offset + wal_size")
        }

        return WaxHeaderPage(
            formatVersion: formatVersion,
            specMajor: specMajor,
            specMinor: specMinor,
            headerPageGeneration: headerPageGeneration,
            fileGeneration: fileGeneration,
            footerOffset: footerOffset,
            walOffset: walOffset,
            walSize: walSize,
            walWritePos: walWritePos,
            walCheckpointPos: walCheckpointPos,
            walCommittedSeq: walCommittedSeq,
            walReplaySnapshot: walReplaySnapshot,
            tocChecksum: tocChecksum,
            headerChecksum: headerChecksum
        )
    }

    /// Selects the most recent valid header page from A/B candidates.
    ///
    /// A page is considered valid if:
    /// - `magic` matches
    /// - `format_version` is supported
    /// - `header_checksum` verifies
    ///
    /// Selection:
    /// - If both are valid, choose the one with higher `header_page_generation` (tie-breaker: page A).
    public static func selectValidPage(pageA: Data, pageB: Data) -> (page: WaxHeaderPage, pageIndex: Int)? {
        let a = try? WaxHeaderPage.decodeWithChecksumValidation(from: pageA)
        let b = try? WaxHeaderPage.decodeWithChecksumValidation(from: pageB)

        switch (a, b) {
        case (nil, nil):
            return nil
        case (let page?, nil):
            return (page, 0)
        case (nil, let page?):
            return (page, 1)
        case (let aPage?, let bPage?):
            if aPage.headerPageGeneration >= bPage.headerPageGeneration {
                return (aPage, 0)
            }
            return (bPage, 1)
        }
    }

    private static func computeHeaderChecksum(over data: Data) -> Data {
        precondition(data.count == Self.size, "header page must be \(Self.size) bytes")

        var hasher = SHA256Checksum()
        data.withUnsafeBytes { raw in
            hasher.update(UnsafeRawBufferPointer(rebasing: raw[..<Self.headerChecksumOffset]))
            hasher.update(Data(repeating: 0, count: Self.headerChecksumCount))
            let after = Self.headerChecksumOffset + Self.headerChecksumCount
            hasher.update(UnsafeRawBufferPointer(rebasing: raw[after..<raw.count]))
        }
        return hasher.finalize()
    }
}
