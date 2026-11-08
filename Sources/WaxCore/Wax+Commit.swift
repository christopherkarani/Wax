import Foundation

#if DEBUG
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

@inline(__always)
private func posixGetPID() -> Int32 {
    #if canImport(Darwin)
    Darwin.getpid()
    #else
    Glibc.getpid()
    #endif
}

@inline(__always)
private func posixKill(_ pid: Int32, _ signal: Int32) -> Int32 {
    #if canImport(Darwin)
    Darwin.kill(pid, signal)
    #else
    Glibc.kill(pid, signal)
    #endif
}
#endif

extension Wax {
    /// Internal only because of the file split.
    enum CrashInjectionCheckpoint: String {
        case afterVectorRunWriteBeforeToc = "after_vector_run_write_before_toc"
        case afterTocWriteBeforeFooter = "after_toc_write_before_footer"
        case afterFooterWriteBeforeFsync = "after_footer_write_before_fsync"
        case afterFooterFsyncBeforeHeader = "after_footer_fsync_before_header"
        case afterHeaderWriteBeforeFinalFsync = "after_header_write_before_final_fsync"

        static let envKey = "WAX_CRASH_INJECT_CHECKPOINT"
    }

    // MARK: - Internal helpers

#if DEBUG
    /// Internal only because of the file split.
    static func maybeCrashAfterCheckpoint(_ checkpoint: CrashInjectionCheckpoint) {
        let env = ProcessInfo.processInfo.environment
        guard env[CrashInjectionCheckpoint.envKey] == checkpoint.rawValue else { return }
        // SIGKILL is delivered asynchronously and may be delayed or masked in sandboxed
        // environments (containers, test harnesses). The fatalError below is a safety net
        // for those cases; it should never be reached in normal crash-injection runs but
        // produces a clear diagnostic if SIGKILL did not terminate the process in time.
        _ = posixKill(posixGetPID(), SIGKILL)
        fatalError("crash injection did not terminate process at \(checkpoint.rawValue)")
    }
#else
    /// Internal only because of the file split.
    @inline(__always)
    static func maybeCrashAfterCheckpoint(_ checkpoint: CrashInjectionCheckpoint) {
        _ = checkpoint
    }
#endif

    /// What the commit in progress changed in place, so its rollback undoes just that.
    /// Internal only because of the file split.
    struct CommitUndo {
        /// Committed frames as they were before the commit first modified each, by index.
        private(set) var committedFrameOriginals: [Int: FrameMeta] = [:]
        /// Whether the commit dropped the encoded frame cache to encode every frame again.
        private(set) var replacedFrameCache = false
        private(set) var frameCacheBeforeCommit: Data?

        mutating func recordOriginal(_ frame: FrameMeta, at index: Int) {
            if committedFrameOriginals[index] == nil {
                committedFrameOriginals[index] = frame
            }
        }

        mutating func recordReplacedFrameCache(_ cache: Data?) {
            guard !replacedFrameCache else { return }
            replacedFrameCache = true
            frameCacheBeforeCommit = cache
        }
    }

    /// Internal only because of the file split.
    struct AppliedPendingMutations {
        var maxSequence: UInt64
        var appendedFrames: [FrameMeta]
        var modifiedCommittedFrames: Bool
        /// The pending embeddings and removals, in WAL order.
        var vectorChanges: [PendingVectorChange]
    }

    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func applyPendingMutationsIntoTOC() throws -> AppliedPendingMutations {
        let committedSeq = header.walCommittedSeq
        var maxSeq = committedSeq

        let ordered = orderedPendingMutationsLocked()
        var newFrames: [FrameMeta] = []
        var vectorChanges: [PendingVectorChange] = []
        var modifiedCommittedFrames = false

        func withFrame(_ frameId: UInt64, _ update: (inout FrameMeta) throws -> Void) throws {
            let committedCount = toc.frames.count
            let maxKnown = committedCount + newFrames.count
            guard frameId < UInt64(maxKnown) else {
                throw WaxError.invalidToc(reason: "mutation references unknown frameId \(frameId) (known < \(maxKnown))")
            }
            if frameId < UInt64(committedCount) {
                modifiedCommittedFrames = true
                commitUndo?.recordOriginal(toc.frames[Int(frameId)], at: Int(frameId))
                try update(&toc.frames[Int(frameId)])
            } else {
                let index = Int(frameId - UInt64(committedCount))
                try update(&newFrames[index])
            }
        }

        for mutation in ordered {
            guard mutation.sequence > committedSeq else {
                throw WaxError.invalidToc(reason: "mutation sequence \(mutation.sequence) not > committed \(committedSeq)")
            }
            if mutation.sequence > maxSeq { maxSeq = mutation.sequence }

            switch mutation.entry {
            case .putFrame(let put):
                let expectedId = UInt64(toc.frames.count + newFrames.count)
                guard put.frameId == expectedId else {
                    throw WaxError.invalidToc(reason: "non-dense frame id \(put.frameId), expected \(expectedId)")
                }
                let frame = try FrameMeta.fromPut(put)
                newFrames.append(frame)
            case .deleteFrame(let delete):
                try withFrame(delete.frameId) { frame in
                    frame.status = .deleted
                }
            case .supersedeFrame(let supersede):
                guard supersede.supersededId != supersede.supersedingId else {
                    throw WaxError.invalidToc(reason: "supersedeFrame requires distinct ids")
                }
                try withFrame(supersede.supersededId) { frame in
                    // A poisoned WAL can record several replacements for one
                    // predecessor. Keep the first supersededBy; later links
                    // still set supersedes on the newer frames.
                    if frame.supersededBy == nil {
                        frame.supersededBy = supersede.supersedingId
                    }
                }
                try withFrame(supersede.supersedingId) { frame in
                    // One replacement can retire many live twins. Keep the first
                    // predecessor pointer; additional twins still set supersededBy.
                    if frame.supersedes == nil {
                        frame.supersedes = supersede.supersededId
                    }
                }
            case .putEmbedding(let embedding):
                let maxKnownFrameIdExclusive = UInt64(toc.frames.count + newFrames.count)
                guard embedding.frameId < maxKnownFrameIdExclusive else {
                    throw WaxError.invalidToc(
                        reason: "putEmbedding references unknown frameId \(embedding.frameId) (known < \(maxKnownFrameIdExclusive))"
                    )
                }
                vectorChanges.append(.put(embedding))
            case .removeEmbedding(let removal):
                let maxKnownFrameIdExclusive = UInt64(toc.frames.count + newFrames.count)
                guard removal.frameId < maxKnownFrameIdExclusive else {
                    throw WaxError.invalidToc(
                        reason: "removeEmbedding references unknown frameId \(removal.frameId) (known < \(maxKnownFrameIdExclusive))"
                    )
                }
                vectorChanges.append(.remove(removal.frameId))
            }
        }

        if !newFrames.isEmpty {
            // Open validated the committed frames; check only the new ones against them.
            try committedFramePayloadRangesLocked(committedFrameCount: toc.frames.count).validateAppending(
                newFrames,
                segments: toc.segmentCatalog.entries,
                dataStart: header.walOffset + header.walSize,
                dataEnd: dataEnd
            )
            try Self.validateTocManifests(toc)
            toc.frames.append(contentsOf: newFrames)
        }

        return AppliedPendingMutations(
            maxSequence: maxSeq,
            appendedFrames: newFrames,
            modifiedCommittedFrames: modifiedCommittedFrames,
            vectorChanges: vectorChanges
        )
    }

    /// Internal only because of the file split; call only while holding `opLock` for writing.
    func encodedCommittedFramePayloadForCommit(
        appendedFrames: [FrameMeta],
        invalidated: Bool
    ) throws -> Data {
        if invalidated {
            commitUndo?.recordReplacedFrameCache(encodedCommittedFramePayloadCache)
            encodedCommittedFramePayloadCache = nil
        }

        if encodedCommittedFramePayloadCache == nil {
            encodedCommittedFramePayloadCache = try Self.encodeFramePayloads(toc.frames)
            return encodedCommittedFramePayloadCache ?? Data()
        }

        if !appendedFrames.isEmpty {
            encodedCommittedFramePayloadCache?.append(try Self.encodeFramePayloads(appendedFrames))
        }

        return encodedCommittedFramePayloadCache ?? Data()
    }

    private static func encodeFramePayloads(_ frames: [FrameMeta]) throws -> Data {
        guard !frames.isEmpty else { return Data() }

        var encoder = BinaryEncoder()
        for frame in frames {
            var mutable = frame
            try mutable.encode(to: &encoder)
        }
        return encoder.data
    }
}
