import Foundation

extension Wax {
    package func frameContent(frameId: UInt64) async throws -> Data {
        try await withReadLock {
            try await frameContentUnlocked(frameId: frameId)
        }
    }

    package func frameContentIncludingPending(frameId: UInt64) async throws -> Data {
        try await withReadLock {
            let metas = frameMetasIncludingPendingUnlocked(frameIds: [frameId])
            guard let meta = metas[frameId] else {
                throw WaxError.frameNotFound(frameId: frameId)
            }
            return try await frameContentFromMetaUnlocked(meta)
        }
    }

    package func framePreview(frameId: UInt64, maxBytes: Int) async throws -> Data {
        try await withReadLock {
            let clampedMax = max(0, maxBytes)
            if clampedMax == 0 { return Data() }

            let frame = try frameMetaUnlocked(frameId: frameId)
            if frame.payloadLength == 0 { return Data() }

            if frame.canonicalEncoding == .plain {
                let available = min(frame.payloadLength, UInt64(clampedMax))
                guard available <= UInt64(Int.max) else {
                    throw WaxError.io("payload preview too large: \(available)")
                }
                let file = self.file
                return try await io.run {
                    try file.readExactly(length: Int(available), at: frame.payloadOffset)
                }
            }

            let canonical = try await frameContentUnlocked(frameId: frameId)
            return Data(canonical.prefix(clampedMax))
        }
    }

    package func framePreviews(frameIds: [UInt64], maxBytes: Int) async throws -> [UInt64: Data] {
        struct PlainPreviewPlan: Sendable {
            let frameId: UInt64
            let offset: UInt64
            let length: Int
        }

        let clampedMax = max(0, maxBytes)
        guard clampedMax > 0 else { return [:] }

        let file = self.file

        let (emptyIds, plainPlans, compressedFrames): ([UInt64], [PlainPreviewPlan], [FrameMeta]) = try await withReadLock {
            var emptyIds: [UInt64] = []
            var plainPlans: [PlainPreviewPlan] = []
            var compressedFrames: [FrameMeta] = []

            emptyIds.reserveCapacity(frameIds.count)
            plainPlans.reserveCapacity(frameIds.count)
            compressedFrames.reserveCapacity(frameIds.count)

            let metaById = frameMetasIncludingPendingUnlocked(frameIds: frameIds)
            for frameId in frameIds {
                guard let frame = metaById[frameId] else { continue }
                if frame.payloadLength == 0 {
                    emptyIds.append(frameId)
                    continue
                }

                if frame.canonicalEncoding == .plain {
                    let available = min(frame.payloadLength, UInt64(clampedMax))
                    if available == 0 {
                        emptyIds.append(frameId)
                        continue
                    }
                    if available > UInt64(Int.max) {
                        throw WaxError.io("payload preview too large: \(available)")
                    }
                    plainPlans.append(
                        PlainPreviewPlan(
                            frameId: frameId,
                            offset: frame.payloadOffset,
                            length: Int(available)
                        )
                    )
                    continue
                }

                compressedFrames.append(frame)
            }

            return (emptyIds, plainPlans, compressedFrames)
        }

        var previews: [UInt64: Data] = [:]
        previews.reserveCapacity(emptyIds.count + plainPlans.count + compressedFrames.count)

        for frameId in emptyIds {
            previews[frameId] = Data()
        }

        if !plainPlans.isEmpty {
            let plainPreviewBytes = try await io.run {
                var bytesByFrameId: [UInt64: Data] = [:]
                bytesByFrameId.reserveCapacity(plainPlans.count)
                for plan in plainPlans {
                    bytesByFrameId[plan.frameId] = try file.readExactly(length: plan.length, at: plan.offset)
                }
                return bytesByFrameId
            }
            previews.merge(plainPreviewBytes, uniquingKeysWith: { _, new in new })
        }

        for frame in compressedFrames {
            let canonical = try await frameContentFromMeta(frame)
            previews[frame.id] = Data(canonical.prefix(clampedMax))
        }

        return previews
    }

    /// Batch read full frame contents (committed only) in a single actor hop.
    package func frameContents(frameIds: [UInt64]) async throws -> [UInt64: Data] {
        try await withReadLock {
            var contents: [UInt64: Data] = [:]
            contents.reserveCapacity(frameIds.count)
            let maxId = UInt64(toc.frames.count)

            for frameId in frameIds where frameId < maxId {
                let frame = toc.frames[Int(frameId)]
                guard frame.payloadLength > 0 else {
                    contents[frameId] = Data()
                    continue
                }
                let data = try await frameContentFromMetaUnlocked(frame)
                contents[frameId] = data
            }

            return contents
        }
    }

    package func frameStoredContent(frameId: UInt64) async throws -> Data {
        try await withReadLock {
            try await frameStoredContentUnlocked(frameId: frameId)
        }
    }

    package func frameStoredPreview(frameId: UInt64, maxBytes: Int) async throws -> Data {
        try await withReadLock {
            let frame = try frameMetaUnlocked(frameId: frameId)
            if frame.payloadLength == 0 { return Data() }
            let clampedMax = max(0, maxBytes)
            if clampedMax == 0 { return Data() }
            let available = min(frame.payloadLength, UInt64(clampedMax))
            guard available <= UInt64(Int.max) else {
                throw WaxError.io("payload preview too large: \(available)")
            }
            let file = self.file
            return try await io.run {
                try file.readExactly(length: Int(available), at: frame.payloadOffset)
            }
        }
    }

    private func frameStoredContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        let stored = try await readStoredPayloadFromMeta(frame)
        _ = try Self.validateStoredPayloadChecksum(stored, frame: frame)
        return stored
    }

    private func frameContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        return try await frameContentFromMeta(frame)
    }

    private func frameContentFromMeta(_ frame: FrameMeta) async throws -> Data {
        let stored = try await readStoredPayloadFromMeta(frame)
        if frame.payloadLength == 0 { return stored }

        let storedChecksum = try Self.validateStoredPayloadChecksum(stored, frame: frame)
        guard frame.canonicalEncoding != .plain else {
            guard storedChecksum == frame.checksum else {
                throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
            }
            return stored
        }

        guard let canonicalLength = frame.canonicalLength else {
            throw WaxError.invalidToc(reason: "missing canonical_length for frame \(frame.id)")
        }
        guard canonicalLength <= UInt64(Int.max) else {
            throw WaxError.io("canonical payload too large: \(canonicalLength)")
        }
        // Decompress also bounds canonical_length by the codec's maximum expansion of
        // the stored bytes before allocating, and tries each candidate decoding until
        // one matches the canonical checksum.
        let expectedChecksum = frame.checksum
        guard let canonical = try PayloadCompressor.decompress(
            stored,
            algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
            uncompressedLength: Int(canonicalLength),
            verifiedBy: { SHA256Checksum.digest($0) == expectedChecksum }
        ) else {
            throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
        }
        return canonical
    }

    private func frameContentFromMetaUnlocked(_ frame: FrameMeta) async throws -> Data {
        try await frameContentFromMeta(frame)
    }

    private func readStoredPayloadFromMeta(_ frame: FrameMeta) async throws -> Data {
        if frame.payloadLength == 0 { return Data() }
        guard frame.payloadLength <= UInt64(Int.max) else {
            throw WaxError.io("payload too large: \(frame.payloadLength)")
        }
        let file = self.file
        return try await io.run {
            try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
        }
    }

    private static func validateStoredPayloadChecksum(_ stored: Data, frame: FrameMeta) throws -> Data {
        if frame.payloadLength == 0 { return Data() }
        guard let expectedStoredChecksum = frame.storedChecksum else {
            throw WaxError.invalidToc(reason: "frame \(frame.id) missing stored_checksum")
        }
        let storedChecksum = SHA256Checksum.digest(stored)
        guard storedChecksum == expectedStoredChecksum else {
            throw WaxError.checksumMismatch("frame \(frame.id) stored_checksum mismatch")
        }
        return storedChecksum
    }
}
