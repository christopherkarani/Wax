import Foundation
import WaxCore
import WaxVectorSearch

extension MemoryOrchestrator {
    // MARK: - Delete

    /// Soft-deletes a frame and removes it from text/vector indexes when those features are enabled.
    ///
    /// Matches ``FrameStore/delete(frameID:)`` durability (delete + commit) while also cleaning
    /// search indexes so forgotten content is not returned by subsequent recalls.
    ///
    /// Soft-delete is pending until a single commit after index removes, so the committed vector
    /// (and text) indexes exclude the deleted frame without a second commit or close-time flush.
    /// If index remove throws, the soft-delete is not committed in this call.
    ///
    /// Deleting a document frame also deletes its chunk frames (`parentId ==
    /// frameId`). Long texts are indexed as chunks, so deleting only the
    /// document would leave its text searchable.
    package func delete(frameId: UInt64) async throws {
        try await delete(frameIds: [frameId])
    }

    /// The two phases of ``delete(frameIds:)``, named for its test seam.
    package enum DeleteStep: Sendable, Equatable {
        case indexRemoval
        case softDelete
        /// The final commit after every step succeeded (frame id is 0).
        case commit
    }

    /// Thrown by ``delete(frameIds:)`` when it fails after writing
    /// soft-deletes. What was written is committed before this is thrown.
    package struct PartialDeleteError: Error, CustomStringConvertible, LocalizedError {
        /// Requested ids whose frame and descendants are all deleted.
        package var deletedFrameIds: [UInt64]
        package var requestedCount: Int
        package var underlying: any Error

        package var description: String {
            "deleted \(deletedFrameIds.count) of \(requestedCount) frames, then failed: \(underlying)"
        }

        package var errorDescription: String? { description }
    }

    /// Deletes several frames and all their descendants with one metadata scan
    /// and one commit.
    ///
    /// Descendants are found through `parentId` at any depth (document ->
    /// chunk -> enrichment). A requested frame that is already deleted still
    /// cascades to its live descendants, which repairs stores written before
    /// delete cascaded.
    ///
    /// Every id is checked first; an unknown id throws
    /// ``WaxError/frameNotFound(frameId:)`` and nothing is written. Frames are
    /// then soft-deleted, each requested frame's descendants before the frame
    /// itself, and only frames that are deleted are removed from the indexes.
    /// That order never leaves a live frame unindexed (search already hides
    /// deleted frames). If a soft-delete, an index removal or the final commit
    /// fails, ``PartialDeleteError`` names the requested ids that are fully
    /// deleted. Those soft-deletes are durable in the WAL: they are committed
    /// here when possible and otherwise applied on the next commit or reopen.
    /// A soft-delete that fails mid-tree leaves that requested id uncounted
    /// and live, while its already-deleted descendants stay hidden.
    package func delete(frameIds: [UInt64]) async throws {
        guard !frameIds.isEmpty else { return }
        try beginWrite()
        defer { endWrite() }
        lastWriteActivityAt = .now

        let metas = await wax.frameMetasIncludingPending()
        let statusById = Dictionary(metas.map { ($0.id, $0.status) }, uniquingKeysWith: { _, last in last })
        if let unknown = frameIds.first(where: { statusById[$0] == nil }) {
            throw WaxError.frameNotFound(frameId: unknown)
        }
        let roots = Self.uniqued(frameIds)
        let softDeletes = await softDeleteTrees(roots, children: Self.childrenByParent(metas), statusById: statusById)

        var failure = softDeletes.failure
        // Keep going past a failed removal so fewer stale index entries remain.
        for id in softDeletes.removedFromIndex {
            do {
                try deleteStepHookForTesting?(.indexRemoval, id)
                if config.enableTextSearch {
                    try await session.removeText(frameId: id)
                }
                if config.enableVectorSearch {
                    try await session.removeVector(frameId: id)
                }
            } catch {
                failure = failure ?? error
            }
        }
        guard let failure else {
            do {
                try deleteStepHookForTesting?(.commit, 0)
                try await session.commit()
            } catch {
                throw PartialDeleteError(
                    deletedFrameIds: softDeletes.deletedRoots,
                    requestedCount: roots.count,
                    underlying: error
                )
            }
            return
        }
        await commitAfterPartialDelete()
        throw PartialDeleteError(
            deletedFrameIds: softDeletes.deletedRoots,
            requestedCount: roots.count,
            underlying: failure
        )
    }

    /// Soft-deletes each root's tree, leaves first, stopping at the first
    /// failure. `removedFromIndex` is every visited frame that is now deleted
    /// (written here or deleted before).
    private func softDeleteTrees(
        _ roots: [UInt64],
        children: [UInt64: [UInt64]],
        statusById: [UInt64: FrameStatus]
    ) async -> (deletedRoots: [UInt64], removedFromIndex: [UInt64], failure: (any Error)?) {
        var handled: Set<UInt64> = []
        var deletedRoots: [UInt64] = []
        var removedFromIndex: [UInt64] = []
        for root in roots {
            let tree = Self.frameIdsWithDescendants([root], children: children).filter { !handled.contains($0) }
            for id in tree.reversed() {
                if statusById[id] == .active {
                    do {
                        try deleteStepHookForTesting?(.softDelete, id)
                        try await wax.delete(frameId: id)
                    } catch {
                        return (deletedRoots, removedFromIndex, error)
                    }
                }
                handled.insert(id)
                removedFromIndex.append(id)
            }
            deletedRoots.append(root)
        }
        return (deletedRoots, removedFromIndex, nil)
    }

    private func commitAfterPartialDelete() async {
        do {
            try await session.commit()
        } catch {
            WaxDiagnostics.logSwallowed(
                error,
                context: "commit after partial delete",
                fallback: "written soft-deletes stay in the WAL and apply on the next commit or reopen"
            )
        }
    }

    private static func childrenByParent(_ metas: [FrameMeta]) -> [UInt64: [UInt64]] {
        var children: [UInt64: [UInt64]] = [:]
        for meta in metas {
            if let parent = meta.parentId {
                children[parent, default: []].append(meta.id)
            }
        }
        return children
    }

    private static func uniqued(_ ids: [UInt64]) -> [UInt64] {
        var seen: Set<UInt64> = []
        return ids.filter { seen.insert($0).inserted }
    }

    /// The requested ids plus every frame reachable from them through `parentId`,
    /// in visit order. Already-deleted descendants are still walked so their own
    /// live children are found.
    private static func frameIdsWithDescendants(_ roots: [UInt64], children: [UInt64: [UInt64]]) -> [UInt64] {
        var visited: Set<UInt64> = []
        var ordered: [UInt64] = []
        var queue = roots
        var head = 0
        while head < queue.count {
            let id = queue[head]
            head += 1
            guard visited.insert(id).inserted else { continue }
            ordered.append(id)
            queue.append(contentsOf: children[id] ?? [])
        }
        return ordered
    }
}
