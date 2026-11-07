import Foundation

/// Byte ranges of the data region that neither the durable commit nor any pending write
/// references, so new payloads, index segments and TOCs can be written there instead of
/// at the end of the file.
///
/// The map never offers a range that the last durable TOC, its footer, or a pending
/// (WAL-logged, uncommitted) payload uses: a crash at any point recovers that commit plus
/// its WAL, and neither has been overwritten. Ranges a commit supersedes (the previous
/// index segments and TOC) are released only after that commit is durable.
struct FreeSpaceMap: Equatable, Sendable {
    /// Sorted, non-overlapping, non-adjacent half-open ranges.
    private(set) var extents: [Range<UInt64>] = []

    init() {}

    /// The free space in `[start, end)` left after removing `used` (in any order; may overlap).
    init(start: UInt64, end: UInt64, used: [Range<UInt64>]) {
        guard end > start else { return }
        let sorted = used
            .filter { !$0.isEmpty && $0.upperBound > start && $0.lowerBound < end }
            .sorted { $0.lowerBound < $1.lowerBound }
        var cursor = start
        for range in sorted {
            if range.lowerBound > cursor {
                extents.append(cursor..<range.lowerBound)
            }
            cursor = max(cursor, range.upperBound)
            if cursor >= end { break }
        }
        if cursor < end {
            extents.append(cursor..<end)
        }
    }

    var freeBytes: UInt64 {
        extents.reduce(0) { $0 + UInt64($1.count) }
    }

    /// Takes the lowest free range of `length` bytes starting at or above `minimumOffset`,
    /// or returns nil when no free extent fits (the caller then appends at the file end).
    mutating func takeFirstFit(length: UInt64, notBelow minimumOffset: UInt64 = 0) -> UInt64? {
        guard length > 0 else { return nil }
        for (index, extent) in extents.enumerated() {
            let start = max(extent.lowerBound, minimumOffset)
            guard start < extent.upperBound, extent.upperBound - start >= length else { continue }
            var pieces: [Range<UInt64>] = []
            if start > extent.lowerBound {
                pieces.append(extent.lowerBound..<start)
            }
            if start + length < extent.upperBound {
                pieces.append((start + length)..<extent.upperBound)
            }
            extents.replaceSubrange(index...index, with: pieces)
            return start
        }
        return nil
    }

    /// Marks `range` free again, merging it with neighbouring free extents.
    mutating func release(_ range: Range<UInt64>) {
        guard !range.isEmpty else { return }
        var lower = range.lowerBound
        var upper = range.upperBound
        var kept: [Range<UInt64>] = []
        kept.reserveCapacity(extents.count + 1)
        var inserted = false
        for extent in extents {
            if extent.upperBound < lower {
                kept.append(extent)
            } else if extent.lowerBound > upper {
                if !inserted {
                    kept.append(lower..<upper)
                    inserted = true
                }
                kept.append(extent)
            } else {
                lower = min(lower, extent.lowerBound)
                upper = max(upper, extent.upperBound)
            }
        }
        if !inserted {
            kept.append(lower..<upper)
        }
        extents = kept
    }

    /// Whether every byte of `range` is free.
    func isFree(_ range: Range<UInt64>) -> Bool {
        guard !range.isEmpty else { return true }
        return extents.contains { $0.lowerBound <= range.lowerBound && $0.upperBound >= range.upperBound }
    }

    /// Drops free space at or above `end` (the file is being truncated there).
    mutating func truncate(to end: UInt64) {
        extents = extents.compactMap { extent in
            guard extent.lowerBound < end else { return nil }
            return extent.lowerBound..<min(extent.upperBound, end)
        }
    }
}
