import Foundation

extension Wax {
    /// Payload ranges of the first `frameCount` frames, sorted by start and non-overlapping.
    ///
    /// A commit checks only its new frames' ranges and the catalog segments against these,
    /// instead of sorting every frame's range again; open still validates the whole TOC
    /// (`validateTocRanges`). Internal only because of the file split.
    struct FramePayloadRangeIndex {
        private struct Entry {
            var start: UInt64
            var end: UInt64
            var frameId: UInt64
        }

        private var entries: [Entry] = []
        /// Frames covered, with or without a payload.
        private(set) var frameCount = 0

        /// Checks `frames` (ids from 0) as `validateTocRanges` checks a TOC's frames.
        init(frames: ArraySlice<FrameMeta>, dataStart: UInt64, dataEnd: UInt64) throws {
            let ranges = try Wax.collectFramePayloadRanges(
                frames,
                firstFrameId: 0,
                dataStart: dataStart,
                dataEnd: dataEnd
            )
            entries = try Wax.sortedNonOverlapping(ranges).map(Self.entry)
            frameCount = frames.count
        }

        /// Checks frames that would follow the indexed ones, and the catalog `segments`, as
        /// `validateTocRanges` checks a TOC holding the indexed frames plus `newFrames`.
        func validateAppending(
            _ newFrames: [FrameMeta],
            segments: [SegmentCatalogEntry],
            dataStart: UInt64,
            dataEnd: UInt64
        ) throws {
            let added = try Wax.collectFramePayloadRanges(
                newFrames[...],
                firstFrameId: UInt64(frameCount),
                dataStart: dataStart,
                dataEnd: dataEnd
            )
            let segmentRanges = try Wax.collectSegmentRanges(segments, dataStart: dataStart, dataEnd: dataEnd)
            for range in try Wax.sortedNonOverlapping(added + segmentRanges) {
                try checkNoOverlapWithIndexed(range)
            }
        }

        /// Adds frames `validateAppending` accepted.
        mutating func append(_ newFrames: [FrameMeta]) {
            let added = newFrames
                .filter { $0.payloadLength > 0 }
                .map { Entry(start: $0.payloadOffset, end: $0.payloadOffset + $0.payloadLength, frameId: $0.id) }
                .sorted { $0.start < $1.start }
            frameCount += newFrames.count
            guard let first = added.first else { return }
            if first.start >= (entries.last?.end ?? 0) {
                entries.append(contentsOf: added)
                return
            }
            var merged: [Entry] = []
            merged.reserveCapacity(entries.count + added.count)
            var lhs = 0
            var rhs = 0
            while lhs < entries.count, rhs < added.count {
                if entries[lhs].start <= added[rhs].start {
                    merged.append(entries[lhs])
                    lhs += 1
                } else {
                    merged.append(added[rhs])
                    rhs += 1
                }
            }
            merged.append(contentsOf: entries[lhs...])
            merged.append(contentsOf: added[rhs...])
            entries = merged
        }

        /// End of the highest indexed range, or 0: the ranges do not overlap, so the one that
        /// starts last also ends last.
        var end: UInt64 {
            entries.last?.end ?? 0
        }

        private func checkNoOverlapWithIndexed(_ range: DataRange) throws {
            // The indexed range starting last below `range.end` is the only one that can
            // overlap it: every earlier one ends at or before that range starts.
            var low = 0
            var high = entries.count
            while low < high {
                let mid = (low + high) / 2
                if entries[mid].start < range.end {
                    low = mid + 1
                } else {
                    high = mid
                }
            }
            guard low > 0 else { return }
            let candidate = entries[low - 1]
            guard candidate.end > range.start else { return }
            let indexed = DataRange(start: candidate.start, end: candidate.end, owner: .frame(candidate.frameId))
            throw indexed.start <= range.start
                ? Wax.overlapError(indexed, range)
                : Wax.overlapError(range, indexed)
        }

        private static func entry(_ range: DataRange) -> Entry {
            guard case .frame(let frameId) = range.owner else {
                preconditionFailure("frame payload ranges are owned by frames")
            }
            return Entry(start: range.start, end: range.end, frameId: frameId)
        }
    }

    /// The payload range index over the first `committedFrameCount` frames of `toc`, built
    /// on first use. Internal only because of the file split; call only while holding
    /// `opLock` for writing.
    func committedFramePayloadRangesLocked(committedFrameCount: Int) throws -> FramePayloadRangeIndex {
        if let index = committedFramePayloadRanges, index.frameCount == committedFrameCount {
            return index
        }
        let index = try FramePayloadRangeIndex(
            frames: toc.frames[..<committedFrameCount],
            dataStart: header.walOffset + header.walSize,
            dataEnd: dataEnd
        )
        committedFramePayloadRanges = index
        return index
    }
}
