import Foundation
import Testing
@testable import Wax

private func makePhotoFrameMeta(
    kind: String?,
    entries: [String: String] = [:]
) -> FrameMeta {
    var metadata = Metadata()
    metadata.entries = entries
    return FrameMeta(
        id: 1,
        timestamp: 0,
        kind: kind,
        payloadOffset: 0,
        payloadLength: 0,
        checksum: Data(repeating: 0, count: 32),
        canonicalEncoding: .plain,
        metadata: metadata
    )
}

@Test
func photoRAGEvidenceSelectionCoversBranches() {
    let regionMeta = makePhotoFrameMeta(
        kind: PhotoFrameKind.region.rawValue,
        entries: [
            PhotoMetadataKey.bboxX.rawValue: "0.1",
            PhotoMetadataKey.bboxY.rawValue: "0.2",
            PhotoMetadataKey.bboxW.rawValue: "0.3",
            PhotoMetadataKey.bboxH.rawValue: "0.4",
        ]
    )

    let timeline = SearchResponse.Result(frameId: 1, score: 1, previewText: "p", sources: [.timeline, .vector, .text])
    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: timeline, meta: regionMeta) == .timeline)

    let region = SearchResponse.Result(frameId: 2, score: 1, previewText: "p", sources: [])
    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: region, meta: regionMeta) == .region(bbox: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4)))

    let vector = SearchResponse.Result(frameId: 3, score: 1, previewText: "p", sources: [.vector])
    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: vector, meta: makePhotoFrameMeta(kind: PhotoFrameKind.root.rawValue)) == .vector)

    let text = SearchResponse.Result(frameId: 4, score: 1, previewText: "snippet", sources: [.text])
    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: text, meta: makePhotoFrameMeta(kind: PhotoFrameKind.root.rawValue)) == .text(snippet: "snippet"))

    let malformedRegionMeta = makePhotoFrameMeta(
        kind: PhotoFrameKind.region.rawValue,
        entries: [PhotoMetadataKey.bboxX.rawValue: "oops"]
    )
    let none = SearchResponse.Result(frameId: 5, score: 1, previewText: nil, sources: [])
    #expect(PhotoRAGOrchestrator._evidenceForTesting(result: none, meta: malformedRegionMeta) == nil)
}

@Test
func photoRAGSummaryAndRangeHelpersAreDeterministic() {
    let query = PhotoQuery(text: "receipt")
    let root = makePhotoFrameMeta(
        kind: PhotoFrameKind.root.rawValue,
        entries: [
            PhotoMetadataKey.captureMs.rawValue: "1700000000000",
            PhotoMetadataKey.lat.rawValue: "37.777",
            PhotoMetadataKey.lon.rawValue: "-122.419",
            PhotoMetadataKey.cameraModel.rawValue: "iPhone Test",
        ]
    )

    let summary = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: root,
        caption: "Store receipt",
        ocrSummary: "TOTAL $42\nTAX $3",
        tags: "receipt, grocery",
        query: query,
        maxOCRLines: 1
    )
    #expect(summary.contains("Caption: Store receipt"))
    #expect(summary.contains("OCR:\nTOTAL $42"))
    #expect(summary.contains("Tags:\nreceipt, grocery"))
    #expect(summary.contains("Captured:"))
    #expect(summary.contains("Location: 37.777,-122.419"))
    #expect(summary.contains("Camera: iPhone Test"))
    #expect(!summary.contains("TAX $3"))

    let fallbackWithQuery = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: nil,
        caption: nil,
        ocrSummary: nil,
        tags: nil,
        query: PhotoQuery(text: "find cats"),
        maxOCRLines: 3
    )
    #expect(fallbackWithQuery == "Photo context (no extracted text). Query: find cats")

    let fallbackWithoutQuery = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: nil,
        caption: nil,
        ocrSummary: nil,
        tags: nil,
        query: PhotoQuery(text: nil),
        maxOCRLines: 3
    )
    #expect(fallbackWithoutQuery == "Photo context (no extracted text).")

    #expect(PhotoRAGOrchestrator._toWaxTimeRangeForTesting(nil) == nil)
    let bounded = PhotoRAGOrchestrator._toWaxTimeRangeForTesting(
        Date(timeIntervalSince1970: 10)...Date(timeIntervalSince1970: 11)
    )
    #expect(bounded == TimeRange(after: 10_000, before: 11_001))
}

@Test
func photoRAGOCRTagsAndMetadataHelpersCoverEdgeCases() {
    let blocks = [
        RecognizedTextBlock(text: " low ", bbox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.3),
        RecognizedTextBlock(text: "HIGH", bbox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.9),
        RecognizedTextBlock(text: "HIGH", bbox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.8),
        RecognizedTextBlock(text: "   ", bbox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 1.0),
    ]
    let ocrSummary = PhotoRAGOrchestrator._buildOCRSummaryForTesting(blocks, maxLines: 2)
    #expect(ocrSummary == "HIGH\nlow")

    let exif = PhotosAssetMetadata.EXIF(
        cameraMake: "Apple",
        cameraModel: "iPhone Test",
        lensModel: "Main Lens",
        orientation: 1,
        dateTimeOriginalMs: nil,
        gpsLatitude: nil,
        gpsLongitude: nil,
        keywords: ["Cat", " cat ", "", "Travel"]
    )
    let record = PhotosAssetMetadata.Record(
        assetID: "asset-1",
        creationDateMs: nil,
        captureMs: 1_700_000_000_000,
        location: .init(latitude: 12.34567, longitude: -45.67891, horizontalAccuracyMeters: 7.5),
        isFavorite: false,
        pixelWidth: 2048,
        pixelHeight: 1536,
        isLocal: true,
        imageData: nil,
        exif: exif
    )

    let weakCaption = PhotoRAGOrchestrator._weakCaptionForTesting(
        metadata: record,
        ocrBlocks: [RecognizedTextBlock(text: "RECEIPT", bbox: .init(x: 0, y: 0, width: 1, height: 1), confidence: 0.9)]
    )
    #expect(weakCaption.contains("Captured"))
    #expect(weakCaption.contains("Near 12.34567, -45.67891"))
    #expect(weakCaption.contains("Camera iPhone Test"))
    #expect(weakCaption.contains("Text: RECEIPT"))

    let tagsFromKeywords = PhotoRAGOrchestrator._buildPhotoTagsForTesting(from: record, captionText: nil)
    #expect(tagsFromKeywords == "Cat, Travel")

    var captionOnly = record
    captionOnly.exif.keywords = []
    let tagsFromCaption = PhotoRAGOrchestrator._buildPhotoTagsForTesting(
        from: captionOnly,
        captionText: "swift, on-device; memory-cache  ai  ml"
    )
    #expect(tagsFromCaption?.contains("swift") == true)
    #expect(tagsFromCaption?.contains("memory") == true)
    #expect(tagsFromCaption?.contains("ai") == false)

    let base = PhotoRAGOrchestrator._baseMetadataForTesting(
        assetID: "asset-1",
        captureMs: 1_700_000_000_000,
        pipelineVersion: "v-test",
        isLocal: true,
        location: record.location,
        pixelWidth: record.pixelWidth,
        pixelHeight: record.pixelHeight,
        exif: record.exif
    )
    #expect(base.entries[PhotoMetadataKey.assetID.rawValue] == "asset-1")
    #expect(base.entries[PhotoMetadataKey.pipelineVersion.rawValue] == "v-test")
    #expect(base.entries[PhotoMetadataKey.isLocal.rawValue] == "true")
    #expect(base.entries[PhotoMetadataKey.width.rawValue] == "2048")
    #expect(base.entries[PhotoMetadataKey.height.rawValue] == "1536")
    #expect(base.entries[PhotoMetadataKey.cameraModel.rawValue] == "iPhone Test")

    let proposedFromOCR = PhotoRAGOrchestrator._proposeRegionsForTesting(from: blocks, maxRegions: 2)
    #expect(proposedFromOCR.count == 2)
    #expect(proposedFromOCR.allSatisfy { $0.type == "ocr" })
    #expect(PhotoRAGOrchestrator._proposeRegionsForTesting(from: [], maxRegions: 0).isEmpty)
    let proposedGrid = PhotoRAGOrchestrator._proposeRegionsForTesting(from: [], maxRegions: 3)
    #expect(proposedGrid.count == 3)
    #expect(proposedGrid.allSatisfy { $0.type == "grid" })

    let bboxMeta = PhotoRAGOrchestrator._writeBBoxForTesting(rect: .init(x: 0.1, y: 0.2, width: 0.3, height: 0.4))
    #expect(bboxMeta.entries[PhotoMetadataKey.bboxX.rawValue] == "0.1")
    #expect(bboxMeta.entries[PhotoMetadataKey.bboxY.rawValue] == "0.2")
    #expect(bboxMeta.entries[PhotoMetadataKey.bboxW.rawValue] == "0.3")
    #expect(bboxMeta.entries[PhotoMetadataKey.bboxH.rawValue] == "0.4")
}

// MARK: - Phase 1A additional edge cases

/// `_buildOCRSummaryForTesting` with maxLines=0 must return an empty string regardless
/// of block content, exercising the early-exit guard at the top of `buildOCRSummary`.
@Test
func photoRAGOCRSummaryMaxLinesZeroReturnsEmpty() {
    let blocks = [
        RecognizedTextBlock(
            text: "should not appear",
            bbox: .init(x: 0, y: 0, width: 1, height: 1),
            confidence: 0.99
        ),
        RecognizedTextBlock(
            text: "neither should this",
            bbox: .init(x: 0, y: 0, width: 1, height: 1),
            confidence: 0.95
        ),
    ]
    let result = PhotoRAGOrchestrator._buildOCRSummaryForTesting(blocks, maxLines: 0)
    #expect(result == "")
}

/// `_buildOCRSummaryForTesting` with an empty blocks array must return an empty string
/// (no items to join, so the output is trivially empty even when maxLines > 0).
@Test
func photoRAGOCRSummaryEmptyBlocksReturnsEmpty() {
    let result = PhotoRAGOrchestrator._buildOCRSummaryForTesting([], maxLines: 10)
    #expect(result == "")
}

/// `_toWaxTimeRangeForTesting` with `Date.distantFuture` as the upper bound must not
/// overflow Int64. The implementation guards: if `beforeInclusive > Int64.max - 1` then
/// `beforeExclusive = Int64.max`. This test verifies that path is taken and the result
/// is a well-formed `TimeRange` (non-nil, `before == Int64.max`).
@Test
func photoRAGTimeRangeDistantFutureDoesNotOverflow() {
    let lower = Date(timeIntervalSince1970: 0)
    let range = lower...Date.distantFuture
    let result = PhotoRAGOrchestrator._toWaxTimeRangeForTesting(range)
    #expect(result != nil)
    // The upper bound must be clamped to Int64.max, not wrap around.
    #expect(result?.before == Int64.max)
    // The lower bound is derived from epoch=0, so after==0.
    #expect(result?.after == 0)
}

/// `_buildSummaryTextForTesting` with a non-nil root FrameMeta that has no recognized
/// metadata entries (no captureMs, no lat/lon, no cameraModel) but does have a caption
/// must still produce a partial summary without crashing. Only the "Caption:" line is
/// expected; no metadata-derived lines should appear.
@Test
func photoRAGSummaryTextRootWithEmptyEntriesProducesPartialSummary() {
    let emptyRoot = makePhotoFrameMeta(kind: PhotoFrameKind.root.rawValue, entries: [:])
    let summary = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: emptyRoot,
        caption: "A rainy day",
        ocrSummary: nil,
        tags: nil,
        query: PhotoQuery(text: nil),
        maxOCRLines: 3
    )
    #expect(summary.contains("Caption: A rainy day"))
    #expect(!summary.contains("Captured:"))
    #expect(!summary.contains("Location:"))
    #expect(!summary.contains("Camera:"))
}

/// `_buildSummaryTextForTesting` with a non-empty ocrSummary but maxOCRLines=0 must
/// suppress the OCR section entirely, exercising the `prefix(max(0, maxOCRLines))` path
/// that yields an empty prefix and therefore skips appending the "OCR:" block.
@Test
func photoRAGSummaryTextOCRLinesZeroSuppressesOCRSection() {
    let summary = PhotoRAGOrchestrator._buildSummaryTextForTesting(
        root: nil,
        caption: "Sunset",
        ocrSummary: "LINE ONE\nLINE TWO",
        tags: nil,
        query: PhotoQuery(text: nil),
        maxOCRLines: 0
    )
    #expect(summary.contains("Caption: Sunset"))
    #expect(!summary.contains("OCR:"))
    #expect(!summary.contains("LINE ONE"))
}

/// `_proposeRegionsForTesting` with a single OCR block must return exactly one region
/// of type "ocr". The source array has only one element so the `.prefix(maxRegions)`
/// path with `maxRegions >= 1` still exercises the OCR branch, not the grid fallback.
@Test
func photoRAGProposeRegionsSingleOCRBlockReturnsOneOCRRegion() {
    let singleBlock = [
        RecognizedTextBlock(
            text: "ONLY",
            bbox: .init(x: 0.1, y: 0.1, width: 0.8, height: 0.3),
            confidence: 0.9
        )
    ]
    let regions = PhotoRAGOrchestrator._proposeRegionsForTesting(from: singleBlock, maxRegions: 4)
    #expect(regions.count == 1)
    #expect(regions[0].type == "ocr")
    #expect(regions[0].bbox == .init(x: 0.1, y: 0.1, width: 0.8, height: 0.3))
}

/// `_proposeRegionsForTesting` grid fallback with `maxRegions=1` must return exactly
/// one grid cell (the top-left quadrant), exercising `Array(grid.prefix(1))`.
@Test
func photoRAGProposeRegionsGridFallbackLimitedToOne() {
    let regions = PhotoRAGOrchestrator._proposeRegionsForTesting(from: [], maxRegions: 1)
    #expect(regions.count == 1)
    #expect(regions[0].type == "grid")
    // The first grid cell is always the top-left quadrant: (0,0,0.5,0.5).
    #expect(regions[0].bbox == .init(x: 0.0, y: 0.0, width: 0.5, height: 0.5))
}

/// `_proposeRegionsForTesting` grid fallback with `maxRegions=4` must return all four
/// predefined quadrant cells, each of type "grid".
@Test
func photoRAGProposeRegionsGridFallbackFourCells() {
    let regions = PhotoRAGOrchestrator._proposeRegionsForTesting(from: [], maxRegions: 4)
    #expect(regions.count == 4)
    #expect(regions.allSatisfy { $0.type == "grid" })
    let expectedBBoxes: [PhotoNormalizedRect] = [
        .init(x: 0.0, y: 0.0, width: 0.5, height: 0.5),
        .init(x: 0.5, y: 0.0, width: 0.5, height: 0.5),
        .init(x: 0.0, y: 0.5, width: 0.5, height: 0.5),
        .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5),
    ]
    for (i, expected) in expectedBBoxes.enumerated() {
        #expect(regions[i].bbox == expected)
    }
}

/// Requesting more grid cells than the predefined four must be clamped to four.
/// `grid.prefix(maxRegions)` where `maxRegions > 4` still yields the full four-cell grid.
@Test
func photoRAGProposeRegionsGridFallbackMaxRegionsExceedingFourClampsToFour() {
    let regions = PhotoRAGOrchestrator._proposeRegionsForTesting(from: [], maxRegions: 99)
    #expect(regions.count == 4)
    #expect(regions.allSatisfy { $0.type == "grid" })
}
