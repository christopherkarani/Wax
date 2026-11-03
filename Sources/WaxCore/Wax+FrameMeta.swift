import Foundation

extension Wax {
    package func pendingFrameMeta(frameId: UInt64) async -> FrameMeta? {
        await withReadLock {
            let maxCommittedId = UInt64(toc.frames.count)
            guard frameId >= maxCommittedId else { return nil }
            return frameMetasIncludingPendingUnlocked(frameIds: [frameId])[frameId]
        }
    }

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

    package func latestActiveHandoffMeta(
        project: String,
        matchingSessionId sessionId: String
    ) async -> FrameMeta? {
        await withReadLock {
            var visibleFrames = toc.frames
            for mutation in orderedPendingMutationsLocked() {
                switch mutation.entry {
                case .putFrame(let put):
                    if let meta = try? FrameMeta.fromPut(put) {
                        visibleFrames.append(meta)
                    }
                case .deleteFrame(let delete):
                    if delete.frameId < UInt64(visibleFrames.count) {
                        visibleFrames[Int(delete.frameId)].status = .deleted
                    }
                case .supersedeFrame(let supersede):
                    if supersede.supersededId < UInt64(visibleFrames.count) {
                        visibleFrames[Int(supersede.supersededId)].supersededBy = supersede.supersedingId
                    }
                    if supersede.supersedingId < UInt64(visibleFrames.count) {
                        visibleFrames[Int(supersede.supersedingId)].supersedes = supersede.supersededId
                    }
                case .putEmbedding:
                    continue
                }
            }

            var latest: FrameMeta?

            for frame in visibleFrames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }

                let hasHandoffKind = frame.kind == "handoff" || frame.metadata?.entries["kind"] == "handoff"
                let hasHandoffLabel = frame.labels.contains("handoff")
                guard hasHandoffKind || hasHandoffLabel else { continue }
                guard frame.metadata?.entries["project"] == project else { continue }
                guard frame.metadata?.entries["session_id"] == sessionId else { continue }

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

    /// Internal only because of the file split; call only while holding `opLock`.
    func frameMetaUnlocked(frameId: UInt64) throws -> FrameMeta {
        guard frameId < UInt64(toc.frames.count) else {
            throw WaxError.frameNotFound(frameId: frameId)
        }
        return toc.frames[Int(frameId)]
    }

    /// Internal only because of the file split; call only while holding `opLock`.
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

                if trackedFrameIds.contains(supersede.supersededId),
                   var supersededMeta = metas[supersede.supersededId] {
                    if supersededMeta.supersededBy == nil
                        || supersededMeta.supersededBy == supersede.supersedingId {
                        supersededMeta.supersededBy = supersede.supersedingId
                        metas[supersede.supersededId] = supersededMeta
                    }
                }

                if trackedFrameIds.contains(supersede.supersedingId),
                   var supersedingMeta = metas[supersede.supersedingId] {
                    if supersedingMeta.supersedes == nil {
                        supersedingMeta.supersedes = supersede.supersededId
                        metas[supersede.supersedingId] = supersedingMeta
                    }
                }

            case .putEmbedding:
                continue
            }
        }

        return metas
    }

    private func frameIdsTouchedByCommittedOrPendingFramesUnlocked() -> [UInt64] {
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

    /// Live frames that should have vectors when a provider is active.
    ///
    /// Single-chunk remember writes only a searchable document. Count those
    /// alongside chunk frames so reopen can mark `.degraded` when some saved
    /// text has no vectors.
    package func liveChunkCount() async -> UInt64 {
        await withReadLock {
            var count: UInt64 = 0
            for frame in toc.frames {
                guard frame.status == .active, frame.supersededBy == nil else { continue }
                guard frame.role == .chunk || frame.role == .document else { continue }
                guard frame.kind != "surrogate" else { continue }
                let searchText = frame.searchText?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                if frame.role == .document, searchText.isEmpty { continue }
                count += 1
            }
            return count
        }
    }

    package func timeline(_ query: TimelineQuery) async -> [FrameMeta] {
        await withReadLock {
            TimelineQuery.filter(frames: toc.frames, query: query)
        }
    }
}
