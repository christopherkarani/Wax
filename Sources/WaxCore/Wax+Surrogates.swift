import Foundation

package struct SurrogateSourceFrame: Equatable, Sendable {
    package var id: UInt64
    package var searchText: String

    package init(id: UInt64, searchText: String) {
        self.id = id
        self.searchText = searchText
    }
}

extension Wax {
    package func activeSurrogateSourceFrames() async -> [SurrogateSourceFrame] {
        await withReadLock {
            let frames = toc.frames
            var sources: [SurrogateSourceFrame] = []
            sources.reserveCapacity(frames.count)

            for index in frames.indices where Self.isLiveSurrogateSource(frames, at: index) {
                guard let searchText = Self.embeddableText(of: frames[index]) else { continue }
                sources.append(.init(id: frames[index].id, searchText: searchText))
            }

            return sources
        }
    }

    /// Whether every live surrogate source with embeddable text is in `frameIds`, as
    /// `activeSurrogateSourceFrames()` would tell: the open's coverage check. Only a frame
    /// missing from `frameIds` has its text read; collecting the sources of a 100k store
    /// took about 8 ms of its open.
    package func activeSurrogateSourcesAreCovered(by frameIds: Set<UInt64>) async -> Bool {
        await withReadLock {
            let frames = toc.frames
            for index in frames.indices where Self.isLiveSurrogateSource(frames, at: index) {
                guard !frameIds.contains(frames[index].id) else { continue }
                if Self.embeddableText(of: frames[index]) != nil { return false }
            }
            return true
        }
    }

    /// Committed frames in `frameIds` whose vectors must be rewritten after an embedding
    /// model change, in ascending id order: every non-deleted frame that already has a vector
    /// (live, superseded, or surrogate) plus every live source that still lacks one.
    package func reembedSources(
        frameIds: Range<UInt64>,
        embeddedFrameIds: Set<UInt64>
    ) async -> [SurrogateSourceFrame] {
        await withReadLock {
            let upper = min(frameIds.upperBound, UInt64(toc.frames.count))
            guard frameIds.lowerBound < upper else { return [] }
            var sources: [SurrogateSourceFrame] = []
            for id in frameIds.lowerBound..<upper {
                let frame = toc.frames[Int(id)]
                guard frame.status != .deleted, frame.role != .system else { continue }
                guard embeddedFrameIds.contains(id) || Self.isLiveSurrogateSource(toc.frames, at: Int(id)) else {
                    continue
                }
                // Every vector-writing path embeds `searchText`; a frame without one has
                // nothing to re-embed from.
                guard let searchText = Self.embeddableText(of: frame) else { continue }
                sources.append(.init(id: id, searchText: searchText))
            }
            return sources
        }
    }

    /// Fields are read in place: binding each of 100k frames to a local copies and releases
    /// its strings.
    private static func isLiveSurrogateSource(_ frames: [FrameMeta], at index: Int) -> Bool {
        guard frames[index].status == .active, frames[index].supersededBy == nil else { return false }
        // Single-chunk remember writes only a searchable document.
        // Corpus ingest already does the same. Chunks stay the
        // multi-chunk source.
        let role = frames[index].role
        guard role == .chunk || role == .document else { return false }
        return frames[index].kind != "surrogate"
    }

    private static func embeddableText(of frame: FrameMeta) -> String? {
        guard let text = frame.searchText else { return nil }
        // Trimming builds a new string; text that neither starts nor ends with whitespace
        // trims to itself, and an open checks this for every frame (100k at a time).
        let whitespace = CharacterSet.whitespacesAndNewlines
        if let first = text.unicodeScalars.first, let last = text.unicodeScalars.last,
           !whitespace.contains(first), !whitespace.contains(last) {
            return text
        }
        let trimmed = text.trimmingCharacters(in: whitespace)
        return trimmed.isEmpty ? nil : trimmed
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

    private func buildSurrogateIndexUnlocked() -> [UInt64: UInt64] {
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
}
