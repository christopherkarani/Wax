import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

extension Wax {
    // MARK: - Reads

    package func frameMetas() async -> [FrameMeta] {
        await withReadLock {
            toc.frames
        }
    }

    package func activeFrameIDs(
        matchingMetadataKey key: String,
        value: String
    ) async -> [UInt64] {
        await withReadLock {
            var frameIDs: [UInt64] = []
            frameIDs.reserveCapacity(toc.frames.count)

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }
                guard frame.metadata?.entries[key] == value else { continue }
                frameIDs.append(frame.id)
            }

            return frameIDs
        }
    }

    package func latestCommittedActiveSystemFrameMeta(
        kind: String,
        fallbackMetadataKey: String,
        fallbackMetadataValue: String
    ) async -> FrameMeta? {
        await withReadLock {
            var latest: FrameMeta?

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil, frame.role == .system else {
                    continue
                }
                guard frame.kind == kind
                    || frame.metadata?.entries[fallbackMetadataKey] == fallbackMetadataValue else {
                    continue
                }
                guard latest?.timestamp ?? .min < frame.timestamp else { continue }
                latest = frame
            }

            return latest
        }
    }

    package func latestCommittedActiveHandoffMeta(project: String? = nil) async -> FrameMeta? {
        await withReadLock {
            var latest: FrameMeta?

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }

                let hasHandoffKind = frame.kind == "handoff" || frame.metadata?.entries["kind"] == "handoff"
                let hasHandoffLabel = frame.labels.contains("handoff")
                guard hasHandoffKind || hasHandoffLabel else { continue }

                if let project, !project.isEmpty, frame.metadata?.entries["project"] != project {
                    continue
                }

                guard let current = latest else {
                    latest = frame
                    continue
                }

                if frame.timestamp > current.timestamp
                    || (frame.timestamp == current.timestamp && frame.id > current.id) {
                    latest = frame
                }
            }

            return latest
        }
    }

    package func committedPayloadLivenessBytes() async -> (
        totalPayloadBytes: UInt64,
        deadPayloadBytes: UInt64
    ) {
        await withReadLock {
            var totalPayloadBytes: UInt64 = 0
            var deadPayloadBytes: UInt64 = 0

            for frame in toc.frames where frame.payloadLength > 0 {
                totalPayloadBytes &+= frame.payloadLength
                let isLive = frame.status == .active && frame.supersededBy == nil
                if !isLive {
                    deadPayloadBytes &+= frame.payloadLength
                }
            }

            return (totalPayloadBytes, deadPayloadBytes)
        }
    }

    package func activeSurrogateSourceFrames() async -> [SurrogateSourceFrame] {
        await withReadLock {
            var sources: [SurrogateSourceFrame] = []
            sources.reserveCapacity(toc.frames.count)

            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }
                guard frame.role == .chunk else { continue }
                guard frame.kind != "surrogate" else { continue }
                guard let searchText = frame.searchText?.trimmingCharacters(in: .whitespacesAndNewlines),
                      !searchText.isEmpty else {
                    continue
                }
                sources.append(.init(id: frame.id, searchText: searchText))
            }

            return sources
        }
    }

    package func rememberDedupProbe(
        contentHash: String,
        metadata: [String: String],
        expectedChunkCount: Int,
        embeddingIdentity: RememberDedupEmbeddingIdentity?
    ) async -> RememberDedupProbe? {
        await withReadLock {
            struct ChunkCoverage {
                var count = 0
                var indices: Set<Int> = []
                var indicesAreValid = true
                var chunkCountsMatch = true
                var embeddingIdentityMatches = true

                mutating func record(
                    _ chunk: FrameMeta,
                    expectedChunkCount: Int,
                    embeddingIdentity: RememberDedupEmbeddingIdentity?
                ) {
                    count += 1
                    guard expectedChunkCount > 0 else { return }

                    guard let chunkCount = chunk.chunkCount, Int(chunkCount) == expectedChunkCount else {
                        chunkCountsMatch = false
                        return
                    }
                    guard let chunkIndex = chunk.chunkIndex else {
                        indicesAreValid = false
                        return
                    }

                    let index = Int(chunkIndex)
                    guard (0..<expectedChunkCount).contains(index) else {
                        indicesAreValid = false
                        return
                    }
                    guard indices.insert(index).inserted else {
                        indicesAreValid = false
                        return
                    }

                    if let embeddingIdentity,
                       embeddingIdentity.matches(metadataEntries: chunk.metadata?.entries ?? [:]) == false {
                        embeddingIdentityMatches = false
                    }
                }

                func isComplete(expectedChunkCount: Int) -> Bool {
                    guard expectedChunkCount > 0 else { return true }
                    guard count == expectedChunkCount else { return false }
                    guard indices.count == expectedChunkCount else { return false }
                    return indicesAreValid && chunkCountsMatch && embeddingIdentityMatches
                }
            }

            var chunkCoverageByDocument: [UInt64: ChunkCoverage] = [:]

            let orderedPending = orderedPendingMutationsLocked()
            let cappedPendingPuts = min(
                pendingMutationSummary.putFrameCount,
                UInt64(pendingMutations.count)
            )
            let pendingPutCapacity = Int(cappedPendingPuts)
            var pendingPutMetas: [UInt64: FrameMeta] = [:]
            pendingPutMetas.reserveCapacity(pendingPutCapacity)
            var pendingPutIds: [UInt64] = []
            pendingPutIds.reserveCapacity(pendingPutCapacity)
            var pendingDeleted = Set<UInt64>()
            var pendingSupersededBy: [UInt64: UInt64] = [:]
            var pendingSupersedes: [UInt64: UInt64] = [:]

            for mutation in orderedPending {
                switch mutation.entry {
                case .putFrame(let put):
                    guard let meta = try? FrameMeta.fromPut(put) else { continue }
                    pendingPutMetas[meta.id] = meta
                    pendingPutIds.append(meta.id)
                case .deleteFrame(let delete):
                    pendingDeleted.insert(delete.frameId)
                case .supersedeFrame(let supersede):
                    pendingSupersededBy[supersede.supersededId] = supersede.supersedingId
                    pendingSupersedes[supersede.supersedingId] = supersede.supersededId
                case .putEmbedding:
                    continue
                }
            }

            func pendingVisibleMeta(_ meta: FrameMeta) -> FrameMeta {
                var visible = meta
                if pendingDeleted.contains(meta.id) {
                    visible.status = .deleted
                }
                if let supersededBy = pendingSupersededBy[meta.id] {
                    visible.supersededBy = supersededBy
                }
                if let supersedes = pendingSupersedes[meta.id] {
                    visible.supersedes = supersedes
                }
                return visible
            }

            func visit(_ meta: FrameMeta) -> RememberDedupProbe? {
                guard meta.status == .active, meta.supersededBy == nil else { return nil }

                if meta.role == .chunk, let parentId = meta.parentId {
                    var coverage = chunkCoverageByDocument[parentId] ?? ChunkCoverage()
                    coverage.record(
                        meta,
                        expectedChunkCount: expectedChunkCount,
                        embeddingIdentity: embeddingIdentity
                    )
                    chunkCoverageByDocument[parentId] = coverage
                    return nil
                }

                guard meta.role == .document else { return nil }
                guard let entries = meta.metadata?.entries else { return nil }
                guard entries["wax.content.hash"] == contentHash else { return nil }
                guard entries == metadata else { return nil }

                let coverage = chunkCoverageByDocument[meta.id] ?? ChunkCoverage()
                return RememberDedupProbe(
                    documentId: meta.id,
                    isComplete: coverage.isComplete(expectedChunkCount: expectedChunkCount)
                )
            }

            for frameId in pendingPutIds.reversed() {
                guard let meta = pendingPutMetas[frameId] else { continue }
                if let probe = visit(pendingVisibleMeta(meta)) {
                    return probe
                }
            }

            for meta in toc.frames.reversed() {
                if let probe = visit(pendingVisibleMeta(meta)) {
                    return probe
                }
            }

            return nil
        }
    }

    package func frameMetas(frameIds: [UInt64]) async -> [UInt64: FrameMeta] {
        await withReadLock {
            var metas: [UInt64: FrameMeta] = [:]
            metas.reserveCapacity(frameIds.count)
            let maxId = UInt64(toc.frames.count)
            for frameId in frameIds where frameId < maxId {
                metas[frameId] = toc.frames[Int(frameId)]
            }
            return metas
        }
    }

    package func frameMetasIncludingPending(frameIds: [UInt64]) async -> [UInt64: FrameMeta] {
        await withReadLock {
            frameMetasIncludingPendingUnlocked(frameIds: frameIds)
        }
    }

    package func frameMetasIncludingPending() async -> [FrameMeta] {
        await withReadLock {
            let frameIds = frameIdsTouchedByCommittedOrPendingFramesUnlocked()
            let metas = frameMetasIncludingPendingUnlocked(frameIds: frameIds)
            return metas.values.sorted { $0.id < $1.id }
        }
    }

    package func surrogateFrameId(sourceFrameId: UInt64) async -> UInt64? {
        await withReadLock {
            if surrogateIndex == nil {
                surrogateIndex = buildSurrogateIndexUnlocked()
            }
            return surrogateIndex?[sourceFrameId]
        }
    }

    /// Batch lookup of surrogate frame ids to avoid repeated actor hops.
    package func surrogateFrameIds(for sourceFrameIds: [UInt64]) async -> [UInt64: UInt64] {
        await withReadLock {
            if surrogateIndex == nil {
                surrogateIndex = buildSurrogateIndexUnlocked()
            }
            guard let surrogateIndex else { return [:] }
            var result: [UInt64: UInt64] = [:]
            result.reserveCapacity(sourceFrameIds.count)
            for frameId in sourceFrameIds {
                if let surrogate = surrogateIndex[frameId] {
                    result[frameId] = surrogate
                }
            }
            return result
        }
    }

    package func frameMeta(frameId: UInt64) async throws -> FrameMeta {
        try await withReadLock {
            try frameMetaUnlocked(frameId: frameId)
        }
    }

    package func frameMetaIncludingPending(frameId: UInt64) async throws -> FrameMeta {
        try await withReadLock {
            let metas = frameMetasIncludingPendingUnlocked(frameIds: [frameId])
            guard let meta = metas[frameId] else {
                throw WaxError.frameNotFound(frameId: frameId)
            }
            return meta
        }
    }

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

    func frameStoredContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        let stored = try await readStoredPayloadFromMeta(frame)
        _ = try Self.validateStoredPayloadChecksum(stored, frame: frame)
        return stored
    }

    func frameContentUnlocked(frameId: UInt64) async throws -> Data {
        let frame = try frameMetaUnlocked(frameId: frameId)
        return try await frameContentFromMeta(frame)
    }

    func frameContentFromMeta(_ frame: FrameMeta) async throws -> Data {
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
        let canonical = try PayloadCompressor.decompress(
            stored,
            algorithm: CompressionKind(canonicalEncoding: frame.canonicalEncoding),
            uncompressedLength: Int(canonicalLength)
        )
        let canonicalChecksum = SHA256Checksum.digest(canonical)
        guard canonicalChecksum == frame.checksum else {
            throw WaxError.checksumMismatch("frame \(frame.id) checksum mismatch")
        }
        return canonical
    }

    func frameContentFromMetaUnlocked(_ frame: FrameMeta) async throws -> Data {
        try await frameContentFromMeta(frame)
    }

    func readStoredPayloadFromMeta(_ frame: FrameMeta) async throws -> Data {
        if frame.payloadLength == 0 { return Data() }
        guard frame.payloadLength <= UInt64(Int.max) else {
            throw WaxError.io("payload too large: \(frame.payloadLength)")
        }
        let file = self.file
        return try await io.run {
            try file.readExactly(length: Int(frame.payloadLength), at: frame.payloadOffset)
        }
    }

    static func validateStoredPayloadChecksum(_ stored: Data, frame: FrameMeta) throws -> Data {
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

    static func validatePendingPayloadChecksums(
        _ mutations: [PendingMutation],
        file: FDFile
    ) throws {
        for mutation in mutations {
            guard case .putFrame(let put) = mutation.entry else { continue }
            guard put.payloadLength <= UInt64(Int.max) else {
                throw WaxError.io("pending frame \(put.frameId) payload too large: \(put.payloadLength)")
            }

            let payload: Data
            if put.payloadLength == 0 {
                payload = Data()
            } else {
                payload = try file.readExactly(length: Int(put.payloadLength), at: put.payloadOffset)
            }

            let storedChecksum = SHA256Checksum.digest(payload)
            guard storedChecksum == put.storedChecksum else {
                throw WaxError.checksumMismatch("pending frame \(put.frameId) stored_checksum mismatch")
            }
        }
    }

    func frameMetaUnlocked(frameId: UInt64) throws -> FrameMeta {
        guard frameId < UInt64(toc.frames.count) else {
            throw WaxError.frameNotFound(frameId: frameId)
        }
        return toc.frames[Int(frameId)]
    }

    func frameMetasIncludingPendingUnlocked(frameIds: [UInt64]) -> [UInt64: FrameMeta] {
        let trackedFrameIds = Set(frameIds)
        guard !trackedFrameIds.isEmpty else { return [:] }

        var metas: [UInt64: FrameMeta] = [:]
        metas.reserveCapacity(trackedFrameIds.count)

        let maxCommittedId = UInt64(toc.frames.count)
        for frameId in trackedFrameIds where frameId < maxCommittedId {
            metas[frameId] = toc.frames[Int(frameId)]
        }

        guard !pendingMutations.isEmpty else { return metas }

        let ordered = pendingMutations.sorted { $0.sequence < $1.sequence }
        for mutation in ordered {
            switch mutation.entry {
            case .putFrame(let put):
                guard trackedFrameIds.contains(put.frameId) else { continue }
                guard let pendingMeta = try? FrameMeta.fromPut(put) else { continue }
                metas[put.frameId] = pendingMeta

            case .deleteFrame(let delete):
                guard trackedFrameIds.contains(delete.frameId),
                      var meta = metas[delete.frameId]
                else { continue }
                meta.status = .deleted
                metas[delete.frameId] = meta

            case .supersedeFrame(let supersede):
                guard supersede.supersededId != supersede.supersedingId else { continue }

                if trackedFrameIds.contains(supersede.supersededId) {
                    guard let supersededMeta = metas[supersede.supersededId] else { continue }
                    if let existing = supersededMeta.supersededBy,
                       existing != supersede.supersedingId {
                        continue
                    }
                }

                if trackedFrameIds.contains(supersede.supersedingId) {
                    guard let supersedingMeta = metas[supersede.supersedingId] else { continue }
                    if let existing = supersedingMeta.supersedes,
                       existing != supersede.supersededId {
                        continue
                    }
                }

                if trackedFrameIds.contains(supersede.supersededId),
                   var supersededMeta = metas[supersede.supersededId] {
                    supersededMeta.supersededBy = supersede.supersedingId
                    metas[supersede.supersededId] = supersededMeta
                }
                if trackedFrameIds.contains(supersede.supersedingId),
                   var supersedingMeta = metas[supersede.supersedingId] {
                    supersedingMeta.supersedes = supersede.supersededId
                    metas[supersede.supersedingId] = supersedingMeta
                }

            case .putEmbedding:
                continue
            }
        }

        return metas
    }

    func frameIdsTouchedByCommittedOrPendingFramesUnlocked() -> [UInt64] {
        var frameIds = Set(toc.frames.map(\.id))
        for mutation in pendingMutations {
            switch mutation.entry {
            case .putFrame(let put):
                frameIds.insert(put.frameId)
            case .deleteFrame(let delete):
                frameIds.insert(delete.frameId)
            case .supersedeFrame(let supersede):
                frameIds.insert(supersede.supersededId)
                frameIds.insert(supersede.supersedingId)
            case .putEmbedding:
                continue
            }
        }
        return Array(frameIds)
    }

    package func readCommittedLexIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let manifest = toc.indexes.lex else { return nil }
            guard manifest.version == 1 else {
                throw WaxError.invalidToc(reason: "unsupported lex index version \(manifest.version)")
            }
            guard manifest.bytesLength > 0 else { return nil }
            let maxBlob = UInt64(Constants.maxBlobBytes)
            guard manifest.bytesLength <= maxBlob else {
                throw WaxError.capacityExceeded(limit: maxBlob, requested: manifest.bytesLength)
            }
            guard manifest.bytesLength <= UInt64(Int.max) else {
                throw WaxError.io("lex index size exceeds Int.max: \(manifest.bytesLength)")
            }

            let dataStart = header.walOffset + header.walSize
            guard manifest.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "lex index below data region")
            }
            guard manifest.bytesOffset <= UInt64.max - manifest.bytesLength else {
                throw WaxError.invalidToc(reason: "lex index range overflows")
            }
            let end = manifest.bytesOffset + manifest.bytesLength
            guard end <= header.footerOffset else {
                throw WaxError.invalidToc(reason: "lex index exceeds footer offset")
            }

            let file = self.file
            let bytes = try await io.run {
                try file.readExactly(length: Int(manifest.bytesLength), at: manifest.bytesOffset)
            }
            let computed = SHA256Checksum.digest(bytes)
            guard computed == manifest.checksum else {
                throw WaxError.checksumMismatch("lex index checksum mismatch")
            }
            return bytes
        }
    }

    func buildSurrogateIndexUnlocked() -> [UInt64: UInt64] {
        var index: [UInt64: UInt64] = [:]
        for frame in toc.frames {
            guard frame.status == .active else { continue }
            guard frame.supersededBy == nil else { continue }
            guard frame.kind == "surrogate" else { continue }
            guard let source = frame.metadata?.entries["source_frame_id"],
                  let sourceFrameId = UInt64(source) else {
                continue
            }
            guard sourceFrameId < UInt64(toc.frames.count) else { continue }
            let sourceMeta = toc.frames[Int(sourceFrameId)]
            guard sourceMeta.status == .active else { continue }
            guard sourceMeta.supersededBy == nil else { continue }
            guard sourceMeta.kind != "surrogate" else { continue }
            index[sourceFrameId] = frame.id
        }
        return index
    }

    package func committedLexIndexManifest() async -> LexIndexManifest? {
        await withReadLock {
            toc.indexes.lex
        }
    }

    package func readStagedLexIndexBytes() async -> Data? {
        await withReadLock {
            stagedLexIndex?.bytes
        }
    }

    package func stagedLexIndexStamp() async -> UInt64? {
        await withReadLock {
            stagedLexIndexStamp
        }
    }

    package func readCommittedVecIndexBytes() async throws -> Data? {
        try await withReadLock {
            guard let manifest = toc.indexes.vec else { return nil }
            guard manifest.bytesLength > 0 else { return nil }
            let maxBlob = UInt64(Constants.maxBlobBytes)
            guard manifest.bytesLength <= maxBlob else {
                throw WaxError.capacityExceeded(limit: maxBlob, requested: manifest.bytesLength)
            }
            guard manifest.bytesLength <= UInt64(Int.max) else {
                throw WaxError.io("vec index size exceeds Int.max: \(manifest.bytesLength)")
            }

            let dataStart = header.walOffset + header.walSize
            guard manifest.bytesOffset >= dataStart else {
                throw WaxError.invalidToc(reason: "vec index below data region")
            }
            guard manifest.bytesOffset <= UInt64.max - manifest.bytesLength else {
                throw WaxError.invalidToc(reason: "vec index range overflows")
            }
            let end = manifest.bytesOffset + manifest.bytesLength
            guard end <= header.footerOffset else {
                throw WaxError.invalidToc(reason: "vec index exceeds footer offset")
            }

            let file = self.file
            let bytes = try await io.run {
                try file.readExactly(length: Int(manifest.bytesLength), at: manifest.bytesOffset)
            }
            let computed = SHA256Checksum.digest(bytes)
            guard computed == manifest.checksum else {
                throw WaxError.checksumMismatch("vec index checksum mismatch")
            }
            return bytes
        }
    }

    package func readStagedVecIndexBytes() async -> (bytes: Data, dimension: UInt32, similarity: VecSimilarity)? {
        await withReadLock {
            guard let staged = stagedVecIndex else { return nil }
            return (bytes: staged.bytes, dimension: staged.dimension, similarity: staged.similarity)
        }
    }

    package func stagedVecIndexStamp() async -> UInt64? {
        await withReadLock {
            stagedVecIndexStamp
        }
    }

    package func committedVecIndexManifest() async -> VecIndexManifest? {
        await withReadLock {
            toc.indexes.vec
        }
    }

    package func memoryBinding() async -> MemoryBinding? {
        await withReadLock {
            toc.memoryBinding
        }
    }

    package func setMemoryBindingIfMissing(_ binding: MemoryBinding) async throws {
        await withWriteLock {
            guard !binding.isEmpty else { return }
            guard toc.memoryBinding == nil else { return }
            toc.memoryBinding = binding
            dirty = true
        }
    }

    package func overwriteMemoryBindingForTesting(_ binding: MemoryBinding?) async throws {
        await withWriteLock {
            guard toc.memoryBinding != binding else { return }
            toc.memoryBinding = binding
            dirty = true
        }
    }

    // MARK: - Introspection

    package func stats() async -> WaxStats {
        await withReadLock {
            let pending = pendingMutations.reduce(0) { count, mutation in
                if case .putFrame = mutation.entry { return count + 1 }
                return count
            }
            return WaxStats(
                frameCount: UInt64(toc.frames.count),
                pendingFrames: UInt64(pending),
                generation: generation
            )
        }
    }

    package func fileURL() -> URL {
        url
    }

    package func walStats() async -> WaxWALStats {
        await withReadLock {
            WaxWALStats(
                walSize: wal.walSize,
                writePos: wal.writePos,
                checkpointPos: wal.checkpointPos,
                pendingBytes: wal.pendingBytes,
                committedSeq: header.walCommittedSeq,
                lastSeq: wal.lastSequence,
                wrapCount: wal.wrapCount,
                checkpointCount: wal.checkpointCount,
                sentinelWriteCount: wal.sentinelWriteCount,
                writeCallCount: wal.writeCallCount,
                autoCommitCount: walAutoCommitCount,
                replaySnapshotHitCount: walReplaySnapshotHitCount
            )
        }
    }

    package func timeline(_ query: TimelineQuery) async -> [FrameMeta] {
        await withReadLock {
            TimelineQuery.filter(frames: toc.frames, query: query)
        }
    }

}
