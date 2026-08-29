import Foundation
#if canImport(Darwin)
import Darwin
#elseif canImport(Glibc)
import Glibc
#endif

package struct MemoryRetentionSettings: Sendable, Equatable {
    package var recentlyClosedMs: Int64
    package var workingQuarantineMs: Int64
    package var keepColdThreshold: Float
    package var coldMinAgeMs: Int64
    package var lowEngagementAgeMs: Int64
    package var lowEngagementMaxCount: UInt32

    package static let `default` = MemoryRetentionSettings(
        recentlyClosedMs: 604_800_000,
        workingQuarantineMs: 2_592_000_000,
        keepColdThreshold: 0.55,
        coldMinAgeMs: 1_209_600_000,
        lowEngagementAgeMs: 1_209_600_000,
        lowEngagementMaxCount: 1
    )

    package static func fromEnvironment(
        _ environment: [String: String] = ProcessInfo.processInfo.environment
    ) -> MemoryRetentionSettings {
        func seconds(_ key: String, defaultMs: Int64) -> Int64 {
            guard let raw = environment[key], let seconds = Int64(raw) else {
                return defaultMs
            }
            return max(0, seconds) * 1000
        }
        let threshold = environment["WAX_KEEP_COLD_THRESHOLD"].flatMap(Float.init)
        return MemoryRetentionSettings(
            recentlyClosedMs: seconds("WAX_SESSION_RECENTLY_CLOSED_SECS", defaultMs: Self.default.recentlyClosedMs),
            workingQuarantineMs: seconds("WAX_WORKING_QUARANTINE_SECS", defaultMs: Self.default.workingQuarantineMs),
            keepColdThreshold: threshold.map { min(max($0, 0), 1) } ?? Self.default.keepColdThreshold,
            coldMinAgeMs: seconds("WAX_COLD_MIN_AGE_SECS", defaultMs: Self.default.coldMinAgeMs),
            lowEngagementAgeMs: Self.default.lowEngagementAgeMs,
            lowEngagementMaxCount: Self.default.lowEngagementMaxCount
        )
    }
}

package enum MemoryTier: String, Sendable {
    case hot
    case cold
}

package enum MemoryRetention {
    private static let frequencyHalfLifeHours: Float = 30 * 24
    private static let recencyHalfLifeHours: Float = 24
    private static let countSaturation: Float = 32

    package static func typePrior(for type: MemoryType) -> Float {
        switch type {
        case .decision, .constraint:
            return 1.0
        case .userPreference, .lesson, .fact:
            return 0.85
        case .handoff:
            return 0.55
        case .note:
            return 0.40
        case .taskState:
            return 0.25
        }
    }

    package static func keepScore(
        type: MemoryType,
        durability: MemoryDurability,
        reviewed: Bool,
        engagementCount: UInt32,
        lastEngagementMs: Int64,
        nowMs: Int64
    ) -> Float {
        let hours: Float
        if lastEngagementMs > 0 {
            hours = Float(max(0, nowMs - lastEngagementMs)) / (1000 * 60 * 60)
        } else {
            hours = Float.greatestFiniteMagnitude / 4
        }
        let frequency = log(Float(min(engagementCount, UInt32(countSaturation))) + 1) / log(countSaturation + 1)
        let frequencyDecay = hours.isFinite ? exp(-hours / frequencyHalfLifeHours) : 0
        let recency = hours.isFinite ? exp(-hours / recencyHalfLifeHours) : 0
        let agedEngagement = frequency * frequencyDecay
        let pin: Float = (durability == .locked || reviewed) ? 1.0 : 0.0
        let keep =
            0.35 * typePrior(for: type)
            + 0.25 * agedEngagement
            + 0.15 * recency
            + 0.25 * pin
        return min(1, max(0, keep))
    }

    package static func parsedTier(_ metadata: [String: String]) -> MemoryTier {
        if metadata[MemoryMetadataKeys.tier] == MemoryTier.cold.rawValue {
            return .cold
        }
        return .hot
    }

    /// Keep-score archival candidate (REQ-011). Default recall uses explicit `wax.tier` only.
    package static func isCold(
        metadata: [String: String],
        stats: FrameAccessStats?,
        nowMs: Int64,
        settings: MemoryRetentionSettings = .default
    ) -> Bool {
        let info = MemorySemantics.parse(metadata: metadata, nowMs: nowMs)
        if info.durability == .locked {
            return false
        }
        if parsedTier(metadata) == .cold {
            return true
        }
        guard let createdAtMs = info.createdAtMs else { return false }
        let ageMs = max(0, nowMs - createdAtMs)
        guard ageMs > settings.coldMinAgeMs else { return false }
        let keep = keepScore(
            type: info.type,
            durability: info.durability,
            reviewed: info.isReviewed,
            engagementCount: stats?.engagementCount ?? 0,
            lastEngagementMs: stats?.lastEngagementMs ?? 0,
            nowMs: nowMs
        )
        return keep < settings.keepColdThreshold
    }

    package static func includeColdInRetrieval(query: String, mode: Memory.RetrievalMode?) -> Bool {
        if mode == .textOnly {
            return true
        }
        return RuleBasedQueryClassifier.isExactIntentQuery(query)
    }

    /// Default hybrid omits only explicit `wax.tier=cold`. Unset tier is hot (REQ-010).
    package static func isVisibleInDefaultRecall(
        metadata: [String: String],
        nowMs: Int64,
        query: String,
        mode: Memory.RetrievalMode?
    ) -> Bool {
        if includeColdInRetrieval(query: query, mode: mode) {
            return true
        }
        let info = MemorySemantics.parse(metadata: metadata, nowMs: nowMs)
        if info.durability == .locked {
            return true
        }
        return parsedTier(metadata) != .cold
    }

    package static func isQuarantineCandidate(
        metadata: [String: String],
        stats: FrameAccessStats?,
        nowMs: Int64,
        settings: MemoryRetentionSettings = .default
    ) -> Bool {
        let info = MemorySemantics.parse(metadata: metadata, nowMs: nowMs)
        if info.durability == .durable || info.durability == .locked {
            return false
        }
        if info.isExpired {
            return true
        }
        guard let createdAtMs = info.createdAtMs else { return false }
        let ageMs = max(0, nowMs - createdAtMs)
        if ageMs > settings.workingQuarantineMs,
           info.durability == .working || info.durability == .ephemeral {
            return true
        }
        let engagement = stats?.engagementCount ?? 0
        if ageMs > settings.lowEngagementAgeMs, engagement <= settings.lowEngagementMaxCount,
           info.durability == .working || info.durability == .ephemeral {
            return true
        }
        return false
    }

    package static func fileApparentBytes(at path: String) -> UInt64 {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path),
              let size = attrs[.size] as? NSNumber
        else { return 0 }
        return size.uint64Value
    }

    package static func fileActualBytes(at path: String) -> UInt64? {
        var st = stat()
        guard stat(path, &st) == 0 else { return nil }
        return UInt64(st.st_blocks) * 512
    }
}
