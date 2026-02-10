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

