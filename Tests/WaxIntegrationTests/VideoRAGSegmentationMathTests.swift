import Testing
@testable import Wax

@Test
func videoRAGSegmentationProducesFixedWindowSegments() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 10_000,
        segmentDurationSeconds: 4,
        segmentOverlapSeconds: 1,
        maxSegments: 10
    )

    #expect(segments == [
        .init(startMs: 0, endMs: 4_000),
        .init(startMs: 3_000, endMs: 7_000),
        .init(startMs: 6_000, endMs: 10_000),
        .init(startMs: 9_000, endMs: 10_000),
    ])
}

@Test
func videoRAGSegmentationRespectsMaxSegments() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 20_000,
        segmentDurationSeconds: 4,
        segmentOverlapSeconds: 1,
        maxSegments: 3
    )

    #expect(segments == [
        .init(startMs: 0, endMs: 4_000),
        .init(startMs: 3_000, endMs: 7_000),
        .init(startMs: 6_000, endMs: 10_000),
    ])
}

@Test
func videoRAGSegmentationReturnsEmptyForNonPositiveDuration() {
    #expect(VideoRAGOrchestrator._makeSegmentRangesForTesting(durationMs: 0, segmentDurationSeconds: 4, segmentOverlapSeconds: 1, maxSegments: 10).isEmpty)
    #expect(VideoRAGOrchestrator._makeSegmentRangesForTesting(durationMs: -1, segmentDurationSeconds: 4, segmentOverlapSeconds: 1, maxSegments: 10).isEmpty)
}

@Test
func videoRAGSegmentationHandlesOverlapGreaterThanDuration() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 30_000,
        segmentDurationSeconds: 5,
        segmentOverlapSeconds: 10,
        maxSegments: 100
    )

    #expect(!segments.isEmpty)
    #expect(segments.count == 100)
    #expect(segments.first?.startMs == 0)
    #expect((segments.last?.endMs ?? 0) <= 30_000)
}

@Test
func videoRAGSegmentationZeroDurationProducesEmpty() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 0,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 1,
        maxSegments: 100
    )
    #expect(segments.isEmpty)
}

@Test
func videoRAGSegmentationSubSecondVideoProducesAtMostOneSegment() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 500,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 1,
        maxSegments: 100
    )
    #expect(segments.count <= 1)
    #expect(segments.first?.startMs == 0)
    #expect(segments.first?.endMs == 500)
}

@Test
func videoRAGSegmentationMaxSegmentsOneCoversFromZero() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 60_000,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 1,
        maxSegments: 1
    )
    #expect(segments.count == 1)
    #expect(segments[0].startMs == 0)
}

@Test
func videoRAGSegmentationMaintainsCoverageWithoutStartGaps() {
    let durationMs: Int64 = 45_000
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: durationMs,
        segmentDurationSeconds: 10,
        segmentOverlapSeconds: 2,
        maxSegments: 100
    )
    #expect(!segments.isEmpty)
    #expect(segments.first?.startMs == 0)
    #expect(segments.last?.endMs == durationMs)

    for index in 1..<segments.count {
        #expect(segments[index].startMs <= segments[index - 1].endMs)
    }
}
