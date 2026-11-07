import Foundation
import Testing
import WaxCore

@Test func timelineReturnsAllFrames() {
    let frames = makeTestFrames(count: 10)
    let query = TimelineQuery(limit: 100, order: .chronological)
    let results = TimelineQuery.filter(frames: frames, query: query)
    #expect(results.count == 10)
}

@Test func timelineLimitRespected() {
    let frames = makeTestFrames(count: 100)
    let query = TimelineQuery(limit: 10)
    let results = TimelineQuery.filter(frames: frames, query: query)
    #expect(results.count == 10)
}

@Test func timelineChronologicalOrder() {
    let frames = makeTestFrames(count: 5)
    let query = TimelineQuery(limit: 5, order: .chronological)
    let results = TimelineQuery.filter(frames: frames, query: query)
    for i in 1..<results.count {
        #expect(results[i].timestamp >= results[i - 1].timestamp)
    }
}

@Test func timelineReverseChronological() {
    let frames = makeTestFrames(count: 5)
    let query = TimelineQuery(limit: 5, order: .reverseChronological)
    let results = TimelineQuery.filter(frames: frames, query: query)
    for i in 1..<results.count {
        #expect(results[i].timestamp <= results[i - 1].timestamp)
    }
}

@Test func timelineDateRange() {
    let frames = makeTestFrames(count: 10)
    let midTimestamp = frames[4].timestamp
    let query = TimelineQuery(limit: 100, after: midTimestamp - 1000, before: midTimestamp + 1000)
    let results = TimelineQuery.filter(frames: frames, query: query)

    for frame in results {
        #expect(frame.timestamp >= midTimestamp - 1000)
        #expect(frame.timestamp < midTimestamp + 1000)
    }
}

@Test func timelineExcludesDeletedFrames() {
    var frames = makeTestFrames(count: 5)
    frames[2].status = .deleted
    let query = TimelineQuery(limit: 100)
    let results = TimelineQuery.filter(frames: frames, query: query)
    #expect(results.count == 4)
    #expect(results.contains { $0.id == frames[2].id } == false)
}

@Test func timelineIncludesDeletedFramesWhenEnabled() {
    var frames = makeTestFrames(count: 5)
    frames[2].status = .deleted
    let query = TimelineQuery(limit: 100, includeDeleted: true)
    let results = TimelineQuery.filter(frames: frames, query: query)
    #expect(results.count == 5)
    #expect(results.contains { $0.id == frames[2].id })
}

/// The bounded selection must return exactly what a stable full sort followed by a prefix
/// returns, including frame order among equal timestamps.
@Test(arguments: [TimelineQuery.Order.chronological, .reverseChronological])
func timelineMatchesStableSortReference(order: TimelineQuery.Order) {
    var generator = SplitMix64(seed: 0x7157_1A1E)
    var frames = makeTestFrames(count: 300)
    for index in frames.indices {
        // Few distinct timestamps, so most frames tie with others.
        frames[index].timestamp = 1_000_000 + Int64(generator.next() % 40) * 1_000
        if generator.next() % 7 == 0 { frames[index].status = .deleted }
        if generator.next() % 9 == 0 { frames[index].supersededBy = UInt64(index + 1) }
    }
    let windows: [(after: Int64?, before: Int64?)] = [(nil, nil), (1_005_000, nil), (nil, 1_030_000), (1_010_000, 1_020_000)]
    for window in windows {
        for limit in [0, 1, 5, 17, 299, 300, 1_000] {
            for includeDeleted in [false, true] {
                for includeSuperseded in [false, true] {
                    let query = TimelineQuery(
                        limit: limit,
                        order: order,
                        after: window.after,
                        before: window.before,
                        includeDeleted: includeDeleted,
                        includeSuperseded: includeSuperseded
                    )
                    let expected = referenceTimeline(frames: frames, query: query).map(\.id)
                    #expect(TimelineQuery.filter(frames: frames, query: query).map(\.id) == expected)
                }
            }
        }
    }
}

/// The filter-then-stable-sort implementation the bounded selection replaced.
private func referenceTimeline(frames: [FrameMeta], query: TimelineQuery) -> [FrameMeta] {
    let filtered = frames
        .filter { query.contains($0.timestamp) }
        .filter { query.includeDeleted || $0.status != .deleted }
        .filter { query.includeSuperseded || $0.supersededBy == nil }
    let ordered = switch query.order {
    case .chronological: filtered.sorted { $0.timestamp < $1.timestamp }
    case .reverseChronological: filtered.sorted { $0.timestamp > $1.timestamp }
    }
    if query.limit <= 0 { return [] }
    return Array(ordered.prefix(query.limit))
}

private struct SplitMix64 {
    var state: UInt64
    init(seed: UInt64) { state = seed }
    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}

private func makeTestFrames(count: Int) -> [FrameMeta] {
    let baseTime: Int64 = 1_000_000
    return (0..<count).map { i in
        FrameMeta(
            id: UInt64(i),
            timestamp: baseTime + Int64(i) * 1_000,
            anchorTs: nil,
            kind: nil,
            track: nil,
            payloadOffset: 0,
            payloadLength: 0,
            checksum: Data(repeating: 0, count: 32),
            uri: nil,
            title: nil,
            canonicalEncoding: .plain,
            canonicalLength: nil,
            storedChecksum: nil,
            metadata: nil,
            searchText: nil,
            tags: [],
            labels: [],
            contentDates: [],
            role: .document,
            parentId: nil,
            chunkIndex: nil,
            chunkCount: nil,
            chunkManifest: nil,
            status: .active,
            supersedes: nil,
            supersededBy: nil
        )
    }
}
