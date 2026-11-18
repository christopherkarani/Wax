import Foundation
import WaxCore
import WaxTextSearch
import WaxVectorSearch

extension Wax {
    private static func matches(metadataFilter: MetadataFilter, meta: FrameMeta) -> Bool {
        if !metadataFilter.requiredEntries.isEmpty {
            guard let entries = meta.metadata?.entries else { return false }
            for (key, value) in metadataFilter.requiredEntries {
                guard entries[key] == value else { return false }
            }
        }

        if !metadataFilter.requiredTags.isEmpty {
            for required in metadataFilter.requiredTags {
                let hasTag = meta.tags.contains { tag in
                    tag.key == required.key && tag.value == required.value
                }
                if !hasTag { return false }
            }
        }

        if !metadataFilter.requiredLabels.isEmpty {
            for label in metadataFilter.requiredLabels where !meta.labels.contains(label) {
                return false
            }
        }

        return true
    }

    static func isExpiredMemory(meta: FrameMeta, nowMs: Int64) -> Bool {
        guard let entries = meta.metadata?.entries,
              entries[MemoryMetadataKeys.expiresAtMs] != nil
        else { return false }
        return MemorySemantics.parse(metadata: entries, nowMs: nowMs).isExpired
    }

    static func passesFrameFilter(
        meta: FrameMeta,
        frameId: UInt64,
        score: Float,
        request: SearchRequest,
        filter: FrameFilter
    ) -> Bool {
        if let minScore = request.minScore, score < minScore { return false }
        if let timeRange = request.timeRange, !timeRange.contains(meta.timestamp) { return false }
        if let allowlist = filter.frameIds, !allowlist.contains(frameId) { return false }
        if !filter.includeDeleted, meta.status == .deleted { return false }
        if !filter.includeSuperseded, meta.supersededBy != nil { return false }
        if !filter.includeSurrogates, FrameKind(rawKind: meta.kind) == .surrogate { return false }
        if let metadataFilter = filter.metadataFilter, !matches(metadataFilter: metadataFilter, meta: meta) {
            return false
        }
        return true
    }
}
