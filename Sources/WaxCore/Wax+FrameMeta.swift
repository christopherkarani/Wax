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
                case .putEmbedding, .removeEmbedding:
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
            // Committed ids are dense and in order (the TOC decode checks it), so with nothing
            // pending the merge below would rebuild `toc.frames`. It runs on every open.
            guard !pendingMutations.isEmpty else { return toc.frames }
            return allFrameMetasIncludingPendingUnlocked()
        }
    }

    /// The entries of `frameMetasIncludingPending()` that staging the text index reads: every
    /// frame at or above `floor` (its coverage watermark), and the inactive (deleted or
    /// superseded) frames below it, in id order. Copies only those, not every frame. An open
    /// frame import's frames follow, since its commit publishes the index staged from them.
    package func frameMetasForTextStaging(atOrAbove floor: UInt64) async -> [FrameMeta] {
        await withReadLock {
            let committedCount = UInt64(toc.frames.count)
            let scanEnd = Int(min(floor, committedCount))
            var ids: [UInt64] = []
            toc.frames.withUnsafeBufferPointer { frames in
                for index in 0..<scanEnd where frames[index].status == .deleted || frames[index].supersededBy != nil {
                    ids.append(UInt64(index))
                }
            }
            // Pending mutations can change frames below the floor, and add frames past the
            // committed ones.
            var pendingIds: [UInt64] = []
            for mutation in pendingMutations {
                switch mutation.entry {
                case .putFrame(let put):
                    pendingIds.append(put.frameId)
                case .deleteFrame(let delete):
                    pendingIds.append(delete.frameId)
                case .supersedeFrame(let supersede):
                    pendingIds.append(supersede.supersededId)
                    pendingIds.append(supersede.supersedingId)
                case .putEmbedding, .removeEmbedding:
                    continue
                }
            }
            if floor < committedCount {
                ids.append(contentsOf: floor..<committedCount)
            }
            ids.append(contentsOf: pendingIds.filter { $0 < floor || $0 >= committedCount })
            let candidates = Array(Set(ids)).sorted()

            let metas = frameMetasIncludingPendingUnlocked(frameIds: candidates)
            let staged = candidates.compactMap { frameId -> FrameMeta? in
                guard let meta = metas[frameId] else { return nil }
                guard frameId >= floor || meta.status == .deleted || meta.supersededBy != nil else { return nil }
                return meta
            }
            guard let frameImport else { return staged }
            return staged + frameImport.frames.filter { $0.id >= floor }
        }
    }

    /// Committed frames with pending mutations applied, then pending puts, in id order.
    ///
    /// Same result as `frameMetasIncludingPendingUnlocked(frameIds:)` over every committed and
    /// pending id, without building a dictionary over the whole store: every commit stages
    /// the text index from this list, so its cost is paid once per commit.
    private func allFrameMetasIncludingPendingUnlocked() -> [FrameMeta] {
        var committed = toc.frames
        let committedCount = UInt64(committed.count)
        var pending: [UInt64: FrameMeta] = [:]

        func update(_ frameId: UInt64, _ body: (inout FrameMeta) -> Void) {
            if frameId < committedCount {
                body(&committed[Int(frameId)])
            } else if var meta = pending[frameId] {
                body(&meta)
                pending[frameId] = meta
            }
        }

        let ordered = pendingMutations.sorted { $0.sequence < $1.sequence }
        for mutation in ordered {
            switch mutation.entry {
            case .putFrame(let put):
                guard let pendingMeta = try? FrameMeta.fromPut(put) else { continue }
                if put.frameId < committedCount {
                    committed[Int(put.frameId)] = pendingMeta
                } else {
                    pending[put.frameId] = pendingMeta
                }
            case .deleteFrame(let delete):
                update(delete.frameId) { $0.status = .deleted }
            case .supersedeFrame(let supersede):
                guard supersede.supersededId != supersede.supersedingId else { continue }
                update(supersede.supersededId) { meta in
                    if meta.supersededBy == nil || meta.supersededBy == supersede.supersedingId {
                        meta.supersededBy = supersede.supersedingId
                    }
                }
                update(supersede.supersedingId) { meta in
                    if meta.supersedes == nil {
                        meta.supersedes = supersede.supersededId
                    }
                }
            case .putEmbedding, .removeEmbedding:
                continue
            }
        }

        guard !pending.isEmpty else { return committed }
        committed.reserveCapacity(committed.count + pending.count)
        committed.append(contentsOf: pending.values.sorted { $0.id < $1.id })
        return committed
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

            case .putEmbedding, .removeEmbedding:
                continue
            }
        }

        return metas
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
            timelineScans &+= 1
            return TimelineQuery.filter(frames: toc.frames, query: query)
        }
    }

    /// Timeline scans (each one walks every frame) since this handle opened.
    package func timelineScansForTesting() async -> UInt64 {
        await withReadLock { timelineScans }
    }
}
