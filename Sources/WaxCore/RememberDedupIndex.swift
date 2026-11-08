import Foundation

/// The frames a remember dedup probe can match, kept in step with every WAL mutation so a
/// probe reads only the documents that carry its content hash and their chunks, instead of
/// decoding every pending put and scanning every committed frame.
///
/// Frame ids are stable and a frame's role, parent and metadata never change once it is
/// written: deletes and supersedes only retire it. The index therefore lists candidates by
/// id, and a probe checks each candidate's current status before it trusts it.
struct RememberDedupIndex {
    static let contentHashKey = "wax.content.hash"

    /// Document frames by their `wax.content.hash` metadata, in ascending id order.
    private var documentIdsByContentHash: [String: [UInt64]] = [:]
    /// Chunk frames by parent id, in ascending id order.
    private var chunkIdsByParentId: [UInt64: [UInt64]] = [:]
    /// Frames put since the last commit, which `toc.frames` does not hold yet.
    private var pendingFrames: [UInt64: FrameMeta] = [:]
    /// Frames deleted or superseded since the last commit; the committed TOC reflects the rest.
    private var pendingRetiredIds: Set<UInt64> = []

    init(committedFrames: [FrameMeta], orderedPendingMutations: [PendingMutation]) {
        for frame in committedFrames {
            insert(frame)
        }
        for mutation in orderedPendingMutations {
            record(mutation.entry)
        }
    }

    mutating func record(_ entry: WALEntry) {
        switch entry {
        case .putFrame(let put):
            // A put that does not decode cannot be committed either; the scan skipped it too.
            guard let frame = try? FrameMeta.fromPut(put) else { return }
            pendingFrames[frame.id] = frame
            insert(frame)
        case .deleteFrame(let delete):
            pendingRetiredIds.insert(delete.frameId)
        case .supersedeFrame(let supersede):
            pendingRetiredIds.insert(supersede.supersededId)
        case .putEmbedding, .removeEmbedding:
            return
        }
    }

    /// Call after a commit applied every pending mutation to the TOC.
    mutating func didCommit() {
        pendingFrames.removeAll(keepingCapacity: true)
        pendingRetiredIds.removeAll(keepingCapacity: true)
    }

    /// Document ids carrying `contentHash`, newest first.
    func documentIds(contentHash: String) -> ReversedCollection<[UInt64]> {
        (documentIdsByContentHash[contentHash] ?? []).reversed()
    }

    /// Chunk ids whose parent is `documentId`, in ascending id order.
    func chunkIds(parentId documentId: UInt64) -> [UInt64] {
        chunkIdsByParentId[documentId] ?? []
    }

    /// The frame if it is active and not superseded, counting pending deletes and supersedes.
    func liveFrame(_ frameId: UInt64, committedFrames: [FrameMeta]) -> FrameMeta? {
        guard !pendingRetiredIds.contains(frameId) else { return nil }
        let frame: FrameMeta
        if frameId < UInt64(committedFrames.count) {
            frame = committedFrames[Int(frameId)]
        } else if let pending = pendingFrames[frameId] {
            frame = pending
        } else {
            return nil
        }
        guard frame.status == .active, frame.supersededBy == nil else { return nil }
        return frame
    }

    private mutating func insert(_ frame: FrameMeta) {
        switch frame.role {
        case .document:
            guard let hash = frame.metadata?.entries[Self.contentHashKey] else { return }
            documentIdsByContentHash[hash, default: []].append(frame.id)
        case .chunk:
            guard let parentId = frame.parentId else { return }
            chunkIdsByParentId[parentId, default: []].append(frame.id)
        default:
            return
        }
    }
}
