import Foundation
import Testing
@testable import Wax

private func makeVideoFrameMeta(entries: [String: String] = [:]) -> FrameMeta {
    var metadata = Metadata()
    metadata.entries = entries
    return FrameMeta(
        id: 1,
        timestamp: 0,
        kind: VideoFrameKind.root.rawValue,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        metadata: metadata
    )
}

@Test
func videoRAGDedupAndRangeHelpersAreDeterministic() {
    #expect(VideoRAGOrchestrator._dedupeIDsForTesting([]).isEmpty)
    #expect(VideoRAGOrchestrator._dedupeIDsForTesting(["a"]) == ["a"])
    #expect(VideoRAGOrchestrator._dedupeIDsForTesting(["a", "b", "a", "c", "b"]) == ["a", "b", "c"])

    let files = [
        VideoFile(id: "1", url: URL(fileURLWithPath: "/tmp/a.mov")),
        VideoFile(id: "2", url: URL(fileURLWithPath: "/tmp/b.mov")),
        VideoFile(id: "1", url: URL(fileURLWithPath: "/tmp/c.mov")),
    ]
    #expect(VideoRAGOrchestrator._dedupeFilesForTesting(files).map(\.id) == ["1", "2"])

    #expect(VideoRAGOrchestrator._toWaxTimeRangeForTesting(nil) == nil)
    let bounded = VideoRAGOrchestrator._toWaxTimeRangeForTesting(
        Date(timeIntervalSince1970: 1)...Date(timeIntervalSince1970: 3)
    )
    #expect(bounded == TimeRange(after: 1_000, before: 3_001))
}

@Test
func videoRAGTranscriptHelpersCoverNormalizationAndUtf8Capping() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 2_000,
        segmentDurationSeconds: 1,
        segmentOverlapSeconds: 0,
        maxSegments: 4
    )
    #expect(segments.map(\.startMs) == [0, 1_000])

    let mapped = VideoRAGOrchestrator._mapTranscriptForTesting(
        chunks: [
            .init(startMs: -100, endMs: 100, text: "too-short-overlap"),
            .init(startMs: 100, endMs: 900, text: "  chunk one  "),
            .init(startMs: 1_100, endMs: 1_900, text: "chunk two"),
            .init(startMs: 1_200, endMs: 1_230, text: "drop"),
            .init(startMs: 1_300, endMs: 1_700, text: "chunk three"),
            .init(startMs: 1_600, endMs: 1_900, text: "   "),
        ],
        segmentRanges: segments,
        maxBytes: 20
    )
    #expect(mapped[0] == "chunk one")
    #expect(mapped[1]?.contains("chunk two") == true)
    #expect(mapped[1]?.contains("drop") == false)

    let utf8 = "A🙂B"
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(utf8, maxBytes: 6) == utf8)
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(utf8, maxBytes: 4) == "A")
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(utf8, maxBytes: 0) == "")

    #expect(VideoRAGOrchestrator._firstLinesForTesting("a\nb\nc", maxLines: 2) == "a\nb")
    #expect(VideoRAGOrchestrator._firstLinesForTesting("a\nb\nc", maxLines: 0) == "")
}

@Test
func videoRAGSummaryHelpersCoverTranscriptAndFallback() {
    let withTranscript = VideoRAGOrchestrator._buildSummaryTextForTesting(
        rootMeta: makeVideoFrameMeta(),
        segments: [
            .init(startMs: 0, endMs: 1_000, score: 1, evidence: [.text(snippet: "x")], transcriptSnippet: "line 1\nline 2"),
            .init(startMs: 1_000, endMs: 2_000, score: 0.5, evidence: [.timeline], transcriptSnippet: nil),
        ],
        maxLinesPerSegment: 1
    )
    #expect(withTranscript.contains("[00:00–00:01] line 1"))
    #expect(withTranscript.contains("[00:01–00:02]"))
    #expect(!withTranscript.contains("line 2"))

    let fallbackWithMetadata = VideoRAGOrchestrator._buildSummaryTextForTesting(
        rootMeta: makeVideoFrameMeta(
            entries: [
                VideoMetadataKey.captureMs.rawValue: "1700000000000",
                VideoMetadataKey.durationMs.rawValue: "61000",
            ]
        ),
        segments: [],
        maxLinesPerSegment: 3
    )
    #expect(fallbackWithMetadata.contains("Captured"))
    #expect(fallbackWithMetadata.contains("Duration 01:01"))

    let fallbackNoMetadata = VideoRAGOrchestrator._buildSummaryTextForTesting(
        rootMeta: makeVideoFrameMeta(),
        segments: [],
        maxLinesPerSegment: 3
    )
    #expect(fallbackNoMetadata == "Video context (no transcript).")

    #expect(VideoRAGOrchestrator._formatMMSSForTesting(-1) == "00:00")
    #expect(VideoRAGOrchestrator._formatMMSSForTesting(65_000) == "01:05")
}

// MARK: - Phase 1B additional edge cases

/// `_makeSegmentRangesForTesting` with `durationMs=0` must return an empty array because
/// the guard `durationMs > 0` at the top of `makeSegments` fires immediately.
@Test
func videoRAGMakeSegmentRangesDurationZeroReturnsEmpty() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 0,
        segmentDurationSeconds: 5,
        segmentOverlapSeconds: 0,
        maxSegments: 10
    )
    #expect(segments.isEmpty)
}

/// `_makeSegmentRangesForTesting` with `segmentDurationSeconds=0` must return an empty
/// array because `segmentDurationMs == 0` triggers the second guard in `makeSegments`.
@Test
func videoRAGMakeSegmentRangesZeroSegmentDurationReturnsEmpty() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 10_000,
        segmentDurationSeconds: 0,
        segmentOverlapSeconds: 0,
        maxSegments: 10
    )
    #expect(segments.isEmpty)
}

/// When `segmentOverlapSeconds >= segmentDurationSeconds`, `strideMs = max(1, segmentDurationMs - overlapMs)`
/// clamps to 1 ms. With a 1 ms stride and a short video, this produces many 1-segment results
/// bounded by `maxSegments=1`. Verify the guard prevents infinite expansion.
@Test
func videoRAGMakeSegmentRangesOverlapEqualsDurationProducesSingleSegmentPerMaxLimit() {
    // overlap == duration => stride = max(1, 0) = 1 ms
    // With maxSegments=1, only the first segment [0, durationMs) is produced.
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 5_000,
        segmentDurationSeconds: 2,
        segmentOverlapSeconds: 2,   // overlap == duration
        maxSegments: 1
    )
    #expect(segments.count == 1)
    #expect(segments[0].startMs == 0)
    #expect(segments[0].endMs == 2_000)
}

/// When overlap exceeds duration, stride is still clamped to 1 ms. With `maxSegments=3`
/// and a 3 ms-stride walk over a 5-second video, we get 3 segments.
@Test
func videoRAGMakeSegmentRangesOverlapExceedsDurationStrideClampedToOne() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 5_000,
        segmentDurationSeconds: 1,
        segmentOverlapSeconds: 10,  // far exceeds segmentDurationSeconds
        maxSegments: 3
    )
    // stride = max(1, 1000 - 10000) = 1 ms; 3 segments starting at 0, 1, 2 ms.
    #expect(segments.count == 3)
    #expect(segments[0].startMs == 0)
    #expect(segments[1].startMs == 1)
    #expect(segments[2].startMs == 2)
}

/// `_mapTranscriptForTesting` with an empty chunks array must return an empty dictionary,
/// exercising the `guard !chunks.isEmpty` fast-path.
@Test
func videoRAGMapTranscriptEmptyChunksReturnsEmptyDictionary() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 2_000,
        segmentDurationSeconds: 1,
        segmentOverlapSeconds: 0,
        maxSegments: 4
    )
    let result = VideoRAGOrchestrator._mapTranscriptForTesting(
        chunks: [],
        segmentRanges: segments,
        maxBytes: 512
    )
    #expect(result.isEmpty)
}

/// `_mapTranscriptForTesting` with `maxBytes=0` must return an empty dictionary,
/// exercising the `guard maxBytes > 0` fast-path.
@Test
func videoRAGMapTranscriptMaxBytesZeroReturnsEmptyDictionary() {
    let segments = VideoRAGOrchestrator._makeSegmentRangesForTesting(
        durationMs: 2_000,
        segmentDurationSeconds: 1,
        segmentOverlapSeconds: 0,
        maxSegments: 4
    )
    let result = VideoRAGOrchestrator._mapTranscriptForTesting(
        chunks: [
            .init(startMs: 0, endMs: 1_000, text: "hello"),
        ],
        segmentRanges: segments,
        maxBytes: 0
    )
    #expect(result.isEmpty)
}

/// `_mapTranscriptForTesting` with empty segment ranges must return an empty dictionary,
/// exercising the `guard !segments.isEmpty` fast-path.
@Test
func videoRAGMapTranscriptEmptySegmentsReturnsEmptyDictionary() {
    let result = VideoRAGOrchestrator._mapTranscriptForTesting(
        chunks: [.init(startMs: 0, endMs: 1_000, text: "hello")],
        segmentRanges: [],
        maxBytes: 512
    )
    #expect(result.isEmpty)
}

/// `_cappedUTF8ForTesting` must truncate at a valid UTF-8 character boundary when the
/// byte limit falls in the middle of a multi-byte CJK character (3 bytes each). The
/// string "ABC日本語XYZ" has ASCII (1 byte each) followed by CJK (3 bytes each).
/// Cutting at 5 bytes lands inside the first CJK codepoint, so the result is "ABC" (3 bytes),
/// not a partial surrogate or corrupted sequence.
@Test
func videoRAGCappedUTF8CJKBoundaryTruncatesCleanly() {
    // "日" = 0xE6 0x97 0xA5 (3 UTF-8 bytes)
    // "本" = 0xE6 0x9C 0xAC (3 UTF-8 bytes)
    // "語" = 0xE8 0xAA 0x9E (3 UTF-8 bytes)
    let text = "ABC日本語"
    // UTF-8 byte layout: A(1) B(1) C(1) 日(3) 本(3) 語(3) = 12 bytes total

    // Cutting at exactly 3 bytes yields "ABC" (no CJK).
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(text, maxBytes: 3) == "ABC")

    // Cutting at 4 bytes falls in the middle of "日" (3 bytes starting at offset 3).
    // The implementation backtracks until a valid UTF-8 string is found, yielding "ABC".
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(text, maxBytes: 4) == "ABC")

    // Cutting at 5 bytes still inside "日".
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(text, maxBytes: 5) == "ABC")

    // Cutting at 6 bytes gives "ABC日" (exactly 6 bytes: 3 ASCII + 3 for "日").
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(text, maxBytes: 6) == "ABC日")

    // Full string fits within a large byte limit.
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(text, maxBytes: 100) == text)
}

/// `_cappedUTF8ForTesting` must handle emoji (4-byte UTF-8 sequences) correctly.
/// The pile-of-poo emoji U+1F4A9 encodes as 4 bytes: 0xF0 0x9F 0x92 0xA9.
/// Truncating at 1, 2, or 3 bytes all fall inside that sequence; the result must be "".
@Test
func videoRAGCappedUTF8EmojiBoundaryTruncatesCleanly() {
    // U+1F4A9 PILE OF POO: 4 UTF-8 bytes
    let emoji = "\u{1F4A9}"
    #expect(emoji.utf8.count == 4)

    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(emoji, maxBytes: 1) == "")
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(emoji, maxBytes: 2) == "")
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(emoji, maxBytes: 3) == "")
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(emoji, maxBytes: 4) == emoji)

    // Prefix ASCII + emoji: "Hi\u{1F4A9}" = 2 + 4 = 6 bytes.
    let mixed = "Hi\u{1F4A9}"
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(mixed, maxBytes: 3) == "Hi")
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(mixed, maxBytes: 5) == "Hi")
    #expect(VideoRAGOrchestrator._cappedUTF8ForTesting(mixed, maxBytes: 6) == mixed)
}

/// `_dedupeFilesForTesting` with a single-element array must return it unchanged,
/// exercising the `guard files.count > 1` early-return path that skips Set allocation.
@Test
func videoRAGDedupeFilesSingleElementReturnsUnchanged() {
    let single = VideoFile(id: "only", url: URL(fileURLWithPath: "/tmp/only.mov"))
    let result = VideoRAGOrchestrator._dedupeFilesForTesting([single])
    #expect(result.count == 1)
    #expect(result[0].id == "only")
}

/// `_dedupeFilesForTesting` with an empty array must return an empty array without
/// crashing (the `guard count > 1` path returns the original empty array).
@Test
func videoRAGDedupeFilesEmptyArrayReturnsEmpty() {
    let result = VideoRAGOrchestrator._dedupeFilesForTesting([])
    #expect(result.isEmpty)
}

/// `_dedupeIDsForTesting` with an empty array must return an empty array (guard fires).
@Test
func videoRAGDedupeIDsEmptyArrayReturnsEmpty() {
    #expect(VideoRAGOrchestrator._dedupeIDsForTesting([]).isEmpty)
}

/// `_toWaxTimeRangeForTesting` with `Date.distantFuture` as the upper bound must not
/// overflow Int64. The implementation guards: when `beforeInclusive > Int64.max - 1`,
/// `beforeExclusive` is clamped to `Int64.max` instead of wrapping.
@Test
func videoRAGTimeRangeDistantFutureDoesNotOverflow() {
    let lower = Date(timeIntervalSince1970: 5)
    let range = lower...Date.distantFuture
    let result = VideoRAGOrchestrator._toWaxTimeRangeForTesting(range)
    #expect(result != nil)
    // The upper bound must be exactly Int64.max — not a wrapped negative value.
    #expect(result?.before == Int64.max)
    // The lower bound is 5 seconds * 1000 = 5000 ms.
    #expect(result?.after == 5_000)
}

/// `_toWaxTimeRangeForTesting` with `Date.distantPast` as the lower bound produces a
/// negative `after` value (distant past is before Unix epoch). This verifies the
/// conversion does not special-case the lower bound and faithfully converts negative ms.
@Test
func videoRAGTimeRangeDistantPastLowerBoundProducesNegativeAfter() {
    let range = Date.distantPast...Date(timeIntervalSince1970: 0)
    let result = VideoRAGOrchestrator._toWaxTimeRangeForTesting(range)
    #expect(result != nil)
    // distantPast is year ~0001, far before epoch — after must be a large negative value.
    #expect((result?.after ?? 0) < 0)
    // Upper bound: 0 ms + 1 = 1.
    #expect(result?.before == 1)
}
