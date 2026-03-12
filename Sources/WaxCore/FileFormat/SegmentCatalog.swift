import Foundation

private enum SegmentCatalogValidation {
    static func validateSortedNonOverlapping(_ entries: [SegmentCatalogEntry]) throws {
        var previousOffset: UInt64?
        var previousEnd: UInt64?

        for entry in entries {
            guard entry.bytesOffset <= UInt64.max - entry.bytesLength else {
                throw WaxError.invalidToc(reason: "segment catalog entry \(entry.segmentId) range overflows")
            }
            let end = entry.bytesOffset + entry.bytesLength

            if let previousOffset, let previousEnd {
                guard entry.bytesOffset > previousOffset else {
                    throw WaxError.invalidToc(reason: "segment catalog entries not in file-offset order")
                }
                guard previousEnd <= entry.bytesOffset else {
                    throw WaxError.invalidToc(reason: "segment catalog entries overlap")
                }
            }

            previousOffset = entry.bytesOffset
            previousEnd = end
        }
    }
}

package struct SegmentCatalogEntry: Equatable, Sendable {
    package var segmentId: UInt64
    package var bytesOffset: UInt64
    package var bytesLength: UInt64
    package var checksum: Data
    package var compression: SegmentCompression
    package var kind: SegmentKind

    package init(
        segmentId: UInt64,
        bytesOffset: UInt64,
        bytesLength: UInt64,
        checksum: Data,
        compression: SegmentCompression,
        kind: SegmentKind
    ) {
        self.segmentId = segmentId
        self.bytesOffset = bytesOffset
        self.bytesLength = bytesLength
        self.checksum = checksum
        self.compression = compression
        self.kind = kind
    }
}

package struct SegmentCatalog: Equatable, Sendable {
    package var entries: [SegmentCatalogEntry]

    package init(entries: [SegmentCatalogEntry] = []) {
        self.entries = entries
    }
}

extension SegmentCatalog: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        let sorted = entries.sorted {
            if $0.bytesOffset != $1.bytesOffset { return $0.bytesOffset < $1.bytesOffset }
            return $0.segmentId < $1.segmentId
        }
        do {
            try SegmentCatalogValidation.validateSortedNonOverlapping(sorted)
        } catch let error as WaxError {
            throw WaxError.encodingError(reason: error.localizedDescription)
        }
        try encoder.encode(sorted) { encoder, entry in
            encoder.encode(entry.segmentId)
            encoder.encode(entry.bytesOffset)
            encoder.encode(entry.bytesLength)
            guard entry.checksum.count == 32 else {
                throw WaxError.encodingError(reason: "segment checksum must be 32 bytes (got \(entry.checksum.count))")
            }
            encoder.encodeFixedBytes(entry.checksum)
            encoder.encode(entry.compression.rawValue)
            encoder.encode(entry.kind.rawValue)
        }
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> SegmentCatalog {
        let count = Int(try decoder.decode(UInt32.self))
        guard count <= Constants.maxArrayCount else {
            throw WaxError.invalidToc(reason: "segment catalog count \(count) exceeds limit \(Constants.maxArrayCount)")
        }

        var entries: [SegmentCatalogEntry] = []
        entries.reserveCapacity(count)
        for _ in 0..<count {
            let segmentId = try decoder.decode(UInt64.self)
            let bytesOffset = try decoder.decode(UInt64.self)
            let bytesLength = try decoder.decode(UInt64.self)
            let checksum = try decoder.decodeFixedBytes(count: 32)
            let compressionRaw = try decoder.decode(UInt8.self)
            guard let compression = SegmentCompression(rawValue: compressionRaw) else {
                throw WaxError.invalidToc(reason: "segment catalog entry \(segmentId) has invalid compression \(compressionRaw)")
            }
            let kindRaw = try decoder.decode(UInt8.self)
            guard let kind = SegmentKind(rawValue: kindRaw) else {
                throw WaxError.invalidToc(reason: "segment catalog entry \(segmentId) has invalid kind \(kindRaw)")
            }
            entries.append(
                SegmentCatalogEntry(
                    segmentId: segmentId,
                    bytesOffset: bytesOffset,
                    bytesLength: bytesLength,
                    checksum: checksum,
                    compression: compression,
                    kind: kind
                )
            )
        }

        try SegmentCatalogValidation.validateSortedNonOverlapping(entries)
        return SegmentCatalog(entries: entries)
    }
}
