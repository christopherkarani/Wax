import Foundation

/// Where new bytes go in the data region.
///
/// Every commit writes a full lex index, vector index and TOC. Appending each one made the
/// file grow by a whole snapshot per commit (about N × commits). Instead, space the durable
/// commit no longer references is reused: payloads, index segments and the TOC take the
/// lowest free range that fits, and the file is truncated after the newest footer.
///
/// Crash safety: a range is free only if no commit a recovery could select uses it (its
/// frames, catalog segments, TOC and footer) and no pending WAL-logged payload does. Those
/// commits are the durable one and the one the other header page names: open falls back to
/// that page when the newest is torn. So the ranges a commit supersedes (replaced segments and
/// its TOC) become free only once the next commit's header overwrites the page naming it, one
/// commit after they were superseded. A crash before a commit's header is durable recovers
/// the previous commit plus its WAL, none of which was overwritten. The TOC and footer are
/// placed above every range the new TOC references, as `validateTocRanges` requires.
struct DataSpaceState: Sendable {
    var free = FreeSpaceMap()
    /// TOC plus footer of the durable commit.
    var committedTocRange: Range<UInt64> = 0..<0
    /// Ranges only the commit the other header page names uses. Freed when the next commit's
    /// header overwrites that page.
    var retainedForOtherHeaderPage: [Range<UInt64>] = []
    /// Highest footer generation that may exist in the file, committed or not. A commit that
    /// fails (or crashes) after syncing its footer but before its header leaves a valid footer
    /// in what is now free space; numbering past it keeps every later footer strictly newer,
    /// so a footer scan never prefers the stale one over a footer it shares an offset rank with.
    var highestWrittenFooterGeneration: UInt64 = 0
}

extension Wax {
    /// Internal only because of the file split; call from `create` / `open` before the handle
    /// is shared, or under `opLock` for writing.
    ///
    /// - Parameters:
    ///   - headerCommitRanges: Ranges of the commits the header pages name other than the
    ///     durable one; they stay reserved.
    ///   - releasesHeaderCommitsAfterNextCommit: Whether the next commit's header overwrites
    ///     the only page naming them (true when they are exactly the other page's commit).
    ///     Otherwise they stay reserved until the handle closes.
    ///   - mayHoldUnreferencedFooter: true on open. A crash between a commit's footer sync and
    ///     its header write can leave that footer (generation + 1) in a hole that open never
    ///     scans; the next commit then numbers past it.
    func initializeDataSpace(
        committedTocRange: Range<UInt64>,
        headerCommitRanges: [Range<UInt64>] = [],
        releasesHeaderCommitsAfterNextCommit: Bool = false,
        mayHoldUnreferencedFooter: Bool
    ) {
        let dataStart = header.walOffset + header.walSize
        var used = Self.referencedDataRanges(of: toc)
        used.append(committedTocRange)
        for mutation in pendingMutations {
            guard case .putFrame(let put) = mutation.entry, put.payloadLength > 0 else { continue }
            used.append(put.payloadOffset..<(put.payloadOffset + put.payloadLength))
        }
        var free = FreeSpaceMap(start: dataStart, end: dataEnd, used: used)
        var retained: [Range<UInt64>] = []
        for range in headerCommitRanges {
            let onlyTheirs = free.reserve(range)
            if releasesHeaderCommitsAfterNextCommit {
                retained += onlyTheirs
            }
        }
        dataSpace = DataSpaceState(
            free: free,
            committedTocRange: committedTocRange,
            retainedForOtherHeaderPage: retained,
            highestWrittenFooterGeneration: mayHoldUnreferencedFooter ? generation &+ 1 : generation
        )
    }

    /// Every range the commit ending at `footer` uses (frames, catalog segments, TOC and
    /// footer), or nil when its TOC does not decode, so no recovery can select it.
    static func commitRanges(of footer: FooterSlice) -> [Range<UInt64>]? {
        guard let toc = try? WaxTOC.decode(from: footer.tocBytes) else { return nil }
        return referencedDataRanges(of: toc) + [footer.tocOffset..<(footer.footerOffset + Constants.footerSize)]
    }

    /// Reserves `length` bytes: the lowest free range at or above `minimumOffset` that fits,
    /// else the end of the file. Internal only because of the file split; call only while
    /// holding `opLock` for writing, after any commit the write may trigger.
    func allocateDataLocked(length: UInt64, notBelow minimumOffset: UInt64 = 0) -> UInt64 {
        if let offset = dataSpace.free.takeFirstFit(length: length, notBelow: minimumOffset) {
            return offset
        }
        // Referenced ranges end at or below `dataEnd`, so the floor never lies past it; if it
        // did, the gap would stay unused rather than enter the free map.
        let offset = max(dataEnd, minimumOffset)
        dataEnd = offset + length
        return offset
    }

    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func nextFooterGenerationLocked() -> UInt64 {
        let next = max(generation, dataSpace.highestWrittenFooterGeneration) &+ 1
        dataSpace.highestWrittenFooterGeneration = next
        return next
    }

    /// Removes catalog entries of `kind` (the segments a new one of that kind replaces) and
    /// returns their ranges, to free once the replacing commit is durable.
    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func removeSupersededSegmentsLocked(kind: SegmentKind) -> [Range<UInt64>] {
        var removed: [Range<UInt64>] = []
        toc.segmentCatalog.entries.removeAll { entry in
            guard entry.kind == kind else { return false }
            if entry.bytesLength > 0 {
                removed.append(entry.bytesOffset..<(entry.bytesOffset + entry.bytesLength))
            }
            return true
        }
        return removed
    }

    /// End of the highest range `toc` references; its TOC and footer must start at or above it.
    static func referencedDataEnd(of toc: WaxTOC) -> UInt64 {
        var end: UInt64 = 0
        for frame in toc.frames where frame.payloadLength > 0 {
            end = max(end, frame.payloadOffset + frame.payloadLength)
        }
        for entry in toc.segmentCatalog.entries where entry.bytesLength > 0 {
            end = max(end, entry.bytesOffset + entry.bytesLength)
        }
        return end
    }

    /// After a commit is durable: its header overwrote the page naming the commit before the
    /// previous one, so that commit's ranges are freed; what this commit superseded (the
    /// previous commit's replaced segments and TOC) is kept while the other page names it.
    /// Then truncates the file after the new footer when nothing above it is in use.
    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func reclaimAfterDurableCommitLocked(superseded: [Range<UInt64>], committedTocRange: Range<UInt64>) async {
        for range in dataSpace.retainedForOtherHeaderPage {
            dataSpace.free.release(range)
        }
        dataSpace.retainedForOtherHeaderPage = superseded + [dataSpace.committedTocRange]
        dataSpace.committedTocRange = committedTocRange
        let newEnd = committedTocRange.upperBound
        guard newEnd < dataEnd else {
            dataEnd = max(dataEnd, newEnd)
            return
        }
        guard dataSpace.free.isFree(newEnd..<dataEnd) else { return }
        let file = self.file
        do {
            try await io.run {
                try file.truncate(to: newEnd)
            }
            dataSpace.free.truncate(to: newEnd)
            dataEnd = newEnd
        } catch {
            // The commit is already durable. The tail stays free space for later writes; the
            // next open finds the newest footer through the header and repairs the tail.
        }
    }

    /// Bytes of the durable TOC plus footer.
    package func committedTocByteCount() async -> UInt64? {
        await withReadLock {
            let range = dataSpace.committedTocRange
            return range.isEmpty ? nil : UInt64(range.count) - Constants.footerSize
        }
    }

    private static func referencedDataRanges(of toc: WaxTOC) -> [Range<UInt64>] {
        var ranges: [Range<UInt64>] = []
        ranges.reserveCapacity(toc.frames.count + toc.segmentCatalog.entries.count)
        for frame in toc.frames where frame.payloadLength > 0 {
            ranges.append(frame.payloadOffset..<(frame.payloadOffset + frame.payloadLength))
        }
        for entry in toc.segmentCatalog.entries where entry.bytesLength > 0 {
            ranges.append(entry.bytesOffset..<(entry.bytesOffset + entry.bytesLength))
        }
        return ranges
    }
}
