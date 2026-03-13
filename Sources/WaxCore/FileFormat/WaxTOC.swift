import Foundation

package struct TimeIndexManifest: Equatable, Sendable {
    package var bytesOffset: UInt64
    package var bytesLength: UInt64
    package var entryCount: UInt64
    package var checksum: Data

    package init(bytesOffset: UInt64, bytesLength: UInt64, entryCount: UInt64, checksum: Data) {
        self.bytesOffset = bytesOffset
        self.bytesLength = bytesLength
        self.entryCount = entryCount
        self.checksum = checksum
    }
}

extension TimeIndexManifest: BinaryCodable {
    package mutating func encode(to encoder: inout BinaryEncoder) throws {
        encoder.encode(bytesOffset)
        encoder.encode(bytesLength)
        encoder.encode(entryCount)
        guard checksum.count == 32 else {
            throw WaxError.encodingError(reason: "time index checksum must be 32 bytes (got \(checksum.count))")
        }
        encoder.encodeFixedBytes(checksum)
    }

    package static func decode(from decoder: inout BinaryDecoder) throws -> TimeIndexManifest {
        let bytesOffset = try decoder.decode(UInt64.self)
        let bytesLength = try decoder.decode(UInt64.self)
        let entryCount = try decoder.decode(UInt64.self)
        let checksum = try decoder.decodeFixedBytes(count: 32)
        return TimeIndexManifest(
            bytesOffset: bytesOffset,
            bytesLength: bytesLength,
            entryCount: entryCount,
            checksum: checksum
        )
    }
}

package struct WaxTOC: Equatable, Sendable {
    package var tocVersion: UInt64
    package var frames: [FrameMeta]
    package var indexes: IndexManifests
    package var timeIndex: TimeIndexManifest?
    package var segmentCatalog: SegmentCatalog
    package var ticketRef: TicketRef
    package var memoryBinding: MemoryBinding?
    package var merkleRoot: Data
    package var tocChecksum: Data

    package init(
        tocVersion: UInt64,
        frames: [FrameMeta],
        indexes: IndexManifests,
        timeIndex: TimeIndexManifest?,
        segmentCatalog: SegmentCatalog,
        ticketRef: TicketRef,
        memoryBinding: MemoryBinding? = nil,
        merkleRoot: Data,
        tocChecksum: Data
    ) {
        self.tocVersion = tocVersion
        self.frames = frames
        self.indexes = indexes
        self.timeIndex = timeIndex
        self.segmentCatalog = segmentCatalog
        self.ticketRef = ticketRef
        self.memoryBinding = memoryBinding
        self.merkleRoot = merkleRoot
        self.tocChecksum = tocChecksum
    }

    package static func emptyV1() -> WaxTOC {
        WaxTOC(
            tocVersion: 1,
            frames: [],
            indexes: IndexManifests(),
            timeIndex: nil,
            segmentCatalog: SegmentCatalog(),
            ticketRef: TicketRef.emptyV1(),
            memoryBinding: nil,
            merkleRoot: Data(repeating: 0, count: 32),
            tocChecksum: Data(repeating: 0, count: 32)
        )
    }

    package func encode(cachedFramesPayload: Data? = nil) throws -> Data {
        guard tocVersion == 1 else {
            throw WaxError.encodingError(reason: "unsupported toc_version \(tocVersion)")
        }
        guard frames.count <= Constants.maxArrayCount else {
            throw WaxError.encodingError(reason: "frame count \(frames.count) exceeds limit \(Constants.maxArrayCount)")
        }

        var encoder = BinaryEncoder()
        encoder.encode(tocVersion)

        if let cachedFramesPayload {
            guard frames.count <= Int(UInt32.max) else {
                throw WaxError.encodingError(reason: "frame count \(frames.count) exceeds UInt32.max")
            }
            encoder.encode(UInt32(frames.count))
            encoder.appendRawBytes(cachedFramesPayload)
        } else {
            for (index, frame) in frames.enumerated() {
                let expected = UInt64(index)
                guard frame.id == expected else {
                    throw WaxError.encodingError(reason: "frame id not dense: found \(frame.id), expected \(expected)")
                }
            }
            try encoder.encode(frames) { encoder, frame in
                var mutable = frame
                try mutable.encode(to: &encoder)
            }
        }

        var indexes = indexes
        try indexes.encode(to: &encoder)

        try encoder.encode(timeIndex) { encoder, value in
            var mutable = value
            try mutable.encode(to: &encoder)
        }

        encoder.encode(UInt8(0)) // memories_track absent in v1
        encoder.encode(UInt8(0)) // logic_mesh absent in v1
        encoder.encode(UInt8(0)) // sketch_track absent in v1

        var segmentCatalog = segmentCatalog
        try segmentCatalog.encode(to: &encoder)

        var ticketRef = ticketRef
        try ticketRef.encode(to: &encoder)

        if var memoryBinding, !memoryBinding.isEmpty {
            encoder.encode(UInt8(1))
            try memoryBinding.encode(to: &encoder)
        } else {
            encoder.encode(UInt8(0))
        }
        encoder.encode(UInt8(0)) // replay_manifest absent in v1
        encoder.encode(UInt8(0)) // enrichment_queue absent in v1

        guard merkleRoot.count == 32 else {
            throw WaxError.encodingError(reason: "merkle_root must be 32 bytes (got \(merkleRoot.count))")
        }
        encoder.encodeFixedBytes(merkleRoot)
        encoder.encodeFixedBytes(Data(repeating: 0, count: 32)) // toc_checksum placeholder

        var data = encoder.data
        let checksum = WaxTOC.computeChecksum(for: data)
        data.replaceSubrange((data.count - 32)..<data.count, with: checksum)
        return data
    }

    package static func decode(from tocBytes: Data) throws -> WaxTOC {
        guard tocBytes.count >= 32 else {
            throw WaxError.invalidToc(reason: "toc must be at least 32 bytes (got \(tocBytes.count))")
        }
        guard UInt64(tocBytes.count) <= Constants.maxTocBytes else {
            throw WaxError.invalidToc(reason: "toc exceeds maxTocBytes (\(tocBytes.count) > \(Constants.maxTocBytes))")
        }

        let storedChecksum = Data(tocBytes.suffix(32))
        let computed = computeChecksum(for: tocBytes)
        guard storedChecksum == computed else {
            throw WaxError.invalidToc(reason: "toc_checksum mismatch")
        }

        var decoder = try BinaryDecoder(data: tocBytes)
        let tocVersion = try decoder.decode(UInt64.self)
        guard tocVersion == 1 else {
            throw WaxError.invalidToc(reason: "unsupported toc_version \(tocVersion)")
        }

        let frameCount = Int(try decoder.decode(UInt32.self))
        guard frameCount <= Constants.maxArrayCount else {
            throw WaxError.invalidToc(reason: "frame count \(frameCount) exceeds limit \(Constants.maxArrayCount)")
        }
        var frames: [FrameMeta] = []
        frames.reserveCapacity(frameCount)
        for _ in 0..<frameCount {
            frames.append(try FrameMeta.decode(from: &decoder))
        }
        for (index, frame) in frames.enumerated() {
            let expected = UInt64(index)
            guard frame.id == expected else {
                throw WaxError.invalidToc(reason: "frame id not dense: found \(frame.id), expected \(expected)")
            }
        }

        let indexes = try IndexManifests.decode(from: &decoder)
        let timeIndex = try decodeOptional(TimeIndexManifest.self, from: &decoder)

        let memoriesTag = try decoder.decode(UInt8.self)
        guard memoriesTag == 0 else {
            throw WaxError.invalidToc(reason: "memories_track not supported in v1")
        }
        let logicTag = try decoder.decode(UInt8.self)
        guard logicTag == 0 else {
            throw WaxError.invalidToc(reason: "logic_mesh not supported in v1")
        }
        let sketchTag = try decoder.decode(UInt8.self)
        guard sketchTag == 0 else {
            throw WaxError.invalidToc(reason: "sketch_track not supported in v1")
        }

        let segmentCatalog = try SegmentCatalog.decode(from: &decoder)
        let ticketRef = try TicketRef.decode(from: &decoder)

        let memoryBindingTag = try decoder.decode(UInt8.self)
        let memoryBinding: MemoryBinding?
        switch memoryBindingTag {
        case 0:
            memoryBinding = nil
        case 1:
            memoryBinding = try MemoryBinding.decode(from: &decoder)
        default:
            throw WaxError.invalidToc(reason: "invalid memory_binding optional tag \(memoryBindingTag)")
        }
        let replayTag = try decoder.decode(UInt8.self)
        guard replayTag == 0 else {
            throw WaxError.invalidToc(reason: "replay_manifest not supported in v1")
        }
        let enrichmentTag = try decoder.decode(UInt8.self)
        guard enrichmentTag == 0 else {
            throw WaxError.invalidToc(reason: "enrichment_queue not supported in v1")
        }

        let merkleRoot = try decoder.decodeFixedBytes(count: 32)
        let tocChecksum = try decoder.decodeFixedBytes(count: 32)
        try decoder.finalize()

        guard tocChecksum == storedChecksum else {
            throw WaxError.invalidToc(reason: "toc_checksum bytes mismatch")
        }

        return WaxTOC(
            tocVersion: tocVersion,
            frames: frames,
            indexes: indexes,
            timeIndex: timeIndex,
            segmentCatalog: segmentCatalog,
            ticketRef: ticketRef,
            memoryBinding: memoryBinding,
            merkleRoot: merkleRoot,
            tocChecksum: tocChecksum
        )
    }

    package static func computeChecksum(for tocBytes: Data) -> Data {
        guard tocBytes.count >= 32 else {
            assertionFailure("toc must be at least 32 bytes")
            return Data(repeating: 0, count: 32)
        }
        let bodyCount = tocBytes.count - 32
        var hasher = SHA256Checksum()
        tocBytes.withUnsafeBytes { raw in
            hasher.update(UnsafeRawBufferPointer(rebasing: raw[..<bodyCount]))
        }
        hasher.update(Data(repeating: 0, count: 32))
        return hasher.finalize()
    }
}

private func decodeOptional<T: BinaryDecodable>(_ type: T.Type, from decoder: inout BinaryDecoder) throws -> T? {
    let tag = try decoder.decode(UInt8.self)
    switch tag {
    case 0:
        return nil
    case 1:
        return try T.decode(from: &decoder)
    default:
        throw WaxError.decodingError(reason: "invalid optional tag \(tag)")
    }
}
