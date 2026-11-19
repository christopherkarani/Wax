import CoreMedia
import Testing
@testable import Wax

@Test
func videoRAGDurationConversionRejectsNonNumericOrOutOfRangeDurations() throws {
    let rejected: [CMTime] = [
        .invalid,
        .indefinite,
        .positiveInfinity,
        .negativeInfinity,
        .zero,
        CMTime(value: -1, timescale: 1),
        CMTime(value: Int64.max, timescale: 1),
        CMTime(value: -Int64.max, timescale: 1),
        CMTime(value: 1, timescale: 10_000),
    ]
    for duration in rejected {
        #expect(throws: VideoIngestError.self) {
            try VideoRAGOrchestrator.durationMilliseconds(from: duration)
        }
    }

    #expect(try VideoRAGOrchestrator.durationMilliseconds(from: CMTime(value: 1_500, timescale: 1_000)) == 1_500)
}

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

@Test
func videoRAGTranscriptMappingKeepsLongChunkThatOverlapsLaterSegments() {
    // Chunks sort by startMs, so endMs is not monotonic: the long chunk ends after the
    // short one. A binary search over endMs skipped the long chunk for the second segment.
    let mapped = VideoRAGOrchestrator._mapTranscriptForTesting(
        chunks: [
            .init(startMs: 0, endMs: 2_000, text: "LONG_TOKEN"),
            .init(startMs: 100, endMs: 600, text: "SHORT_TOKEN"),
        ],
        segments: [
            .init(startMs: 0, endMs: 1_000),
            .init(startMs: 1_000, endMs: 2_000),
        ],
        maxBytes: 1_024
    )

    #expect(mapped[0] == "LONG_TOKEN\nSHORT_TOKEN")
    #expect(mapped[1] == "LONG_TOKEN")
}

@Test
func videoRAGTranscriptMappingHandlesUnsortedOverlappingChunks() {
    let mapped = VideoRAGOrchestrator._mapTranscriptForTesting(
        chunks: [
            .init(startMs: 2_500, endMs: 3_000, text: "C"),
            .init(startMs: 200, endMs: 400, text: "B"),
            .init(startMs: 0, endMs: 3_000, text: "A"),
        ],
        segments: [
            .init(startMs: 0, endMs: 1_000),
            .init(startMs: 1_000, endMs: 2_000),
            .init(startMs: 2_000, endMs: 3_000),
        ],
        maxBytes: 1_024
    )

    #expect(mapped[0] == "A")
    #expect(mapped[1] == "A")
    #expect(mapped[2] == "A\nC")
}
