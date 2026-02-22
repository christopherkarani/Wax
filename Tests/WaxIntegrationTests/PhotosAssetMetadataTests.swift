import CoreGraphics
import Foundation
import ImageIO
import Testing
@testable import Wax

private enum PhotosAssetMetadataTestError: Error {
    case failedToCreateImage
    case failedToCreateDestination
    case failedToFinalizeDestination
}

private func makeTestImage(width: Int = 8, height: Int = 8) throws -> CGImage {
    let colorSpace = CGColorSpaceCreateDeviceRGB()
    var pixels: [UInt8] = Array(repeating: 255, count: width * height * 4)
    guard let context = CGContext(
        data: &pixels,
        width: width,
        height: height,
        bitsPerComponent: 8,
        bytesPerRow: width * 4,
        space: colorSpace,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
    ) else {
        throw PhotosAssetMetadataTestError.failedToCreateImage
    }

    guard let image = context.makeImage() else {
        throw PhotosAssetMetadataTestError.failedToCreateImage
    }
    return image
}

private func makeJPEGData(with properties: [CFString: Any]) throws -> Data {
    let image = try makeTestImage()
    let output = NSMutableData()
    guard let destination = CGImageDestinationCreateWithData(output, "public.jpeg" as CFString, 1, nil) else {
        throw PhotosAssetMetadataTestError.failedToCreateDestination
    }

    CGImageDestinationAddImage(destination, image, properties as CFDictionary)
    guard CGImageDestinationFinalize(destination) else {
        throw PhotosAssetMetadataTestError.failedToFinalizeDestination
    }

    return output as Data
}

#if canImport(Photos)
@Test
func photosAssetMetadataMissingAssetIDReturnsExpectedErrors() async throws {
    let assetID = UUID().uuidString

    do {
        _ = try await PhotosAssetMetadata.load(assetID: assetID)
        Issue.record("Expected WaxError.io for missing asset")
    } catch let error as WaxError {
        guard case .io(let message) = error else {
            Issue.record("Expected WaxError.io, got \(error)")
            return
        }
        #expect(message.contains("PHAsset not found"))
    }

    let imageData = try await PhotosAssetMetadata.loadImageData(assetID: assetID)
    #expect(imageData == nil)
}
#endif

@Test
func photosAssetMetadataParseKeywordsNormalizesAndDeduplicates() {
    #expect(PhotosAssetMetadata._parseKeywordsForTesting(nil).isEmpty)

    let fromArray = PhotosAssetMetadata._parseKeywordsForTesting([" Cat ", "cat", "DOG", "", "dog"])
    #expect(fromArray == ["Cat", "DOG"])

    let fromString = PhotosAssetMetadata._parseKeywordsForTesting(" one, two;One ; ; THREE ")
    #expect(fromString == ["one", "two", "THREE"])
}

@Test
func photosAssetMetadataParseEXIFDateTimeParsesUTCAndRejectsInvalidInput() {
    let value = "2024:08:17 04:05:06"
    let parsed = PhotosAssetMetadata._parseEXIFDateTimeMsForTesting(value)

    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: "en_US_POSIX")
    formatter.timeZone = TimeZone(secondsFromGMT: 0)
    formatter.dateFormat = "yyyy:MM:dd HH:mm:ss"
    let expected = formatter.date(from: value).map { Int64($0.timeIntervalSince1970 * 1000) }

    #expect(parsed == expected)
    #expect(PhotosAssetMetadata._parseEXIFDateTimeMsForTesting("not-a-date") == nil)
}

@Test
func photosAssetMetadataExtractEXIFReadsTIFFExifIPTCAndGPS() throws {
    let exifDate = "2024:01:02 03:04:05"
    let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [
            kCGImagePropertyTIFFMake: "Canon",
            kCGImagePropertyTIFFModel: "EOS"
        ],
        kCGImagePropertyExifDictionary: [
            kCGImagePropertyExifLensModel: "50mm",
            kCGImagePropertyExifDateTimeOriginal: exifDate
        ],
        kCGImagePropertyIPTCDictionary: [
            kCGImagePropertyIPTCKeywords: [" beach ", "Beach", "Sunset"]
        ],
        kCGImagePropertyOrientation: 6,
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 37.5,
            kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 122.4,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
    ]

    let data = try makeJPEGData(with: properties)
    let exif = PhotosAssetMetadata._extractEXIFForTesting(from: data)

    #expect(exif.cameraMake == "Canon")
    #expect(exif.cameraModel == "EOS")
    #expect(exif.lensModel == "50mm")
    #expect(exif.orientation == 6)
    #expect(exif.dateTimeOriginalMs == PhotosAssetMetadata._parseEXIFDateTimeMsForTesting(exifDate))
    #expect(exif.gpsLatitude == -37.5)
    #expect(exif.gpsLongitude == -122.4)
    #expect(exif.keywords == ["beach", "Sunset"])
}

@Test
func photosAssetMetadataExtractEXIFHandlesNilAndInvalidData() {
    let nilEXIF = PhotosAssetMetadata._extractEXIFForTesting(from: nil)
    #expect(nilEXIF.cameraMake == nil)
    #expect(nilEXIF.keywords.isEmpty)

    let invalid = Data([0x00, 0x01, 0x02, 0x03])
    let invalidEXIF = PhotosAssetMetadata._extractEXIFForTesting(from: invalid)
    #expect(invalidEXIF.cameraModel == nil)
    #expect(invalidEXIF.orientation == nil)
}

// MARK: - Phase 1C: GPS defaults, keyword integer input, empty dictionaries, timestamp edge cases

/// GPS dictionary that omits `LatitudeRef` and `LongitudeRef` must default to "N" (positive
/// latitude) and "E" (positive longitude) per the source code:
///   let ref = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
///   let ref = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
/// This exercises the `?? "N"` and `?? "E"` default branches.
@Test
func photosAssetMetadataGPSDefaultsToNorthEastWhenRefsOmitted() throws {
    let properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 37.5,
            kCGImagePropertyGPSLongitude: 122.4
            // No LatitudeRef or LongitudeRef — must default to N / E
        ]
    ]

    let data = try makeJPEGData(with: properties)
    let exif = PhotosAssetMetadata._extractEXIFForTesting(from: data)

    // Defaults to "N" → positive latitude.
    #expect(exif.gpsLatitude == 37.5)
    // Defaults to "E" → positive longitude.
    #expect(exif.gpsLongitude == 122.4)
}

/// GPS dictionary with explicit "S" and "W" refs must negate both values.
/// Combined with the test above, both sign branches are confirmed correct.
@Test
func photosAssetMetadataGPSSouthWestRefsNegatesCoordinates() throws {
    let properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 33.8688,
            kCGImagePropertyGPSLatitudeRef: "S",
            kCGImagePropertyGPSLongitude: 151.2093,
            kCGImagePropertyGPSLongitudeRef: "W"
        ]
    ]

    let data = try makeJPEGData(with: properties)
    let exif = PhotosAssetMetadata._extractEXIFForTesting(from: data)

    #expect(exif.gpsLatitude == -33.8688)
    #expect(exif.gpsLongitude == -151.2093)
}

/// `_parseKeywordsForTesting` with an integer value hits the `default` case in the
/// switch expression and returns an empty array. This is distinct from the `nil`,
/// `[Any]`, and `String` arms already tested.
@Test
func photosAssetMetadataParseKeywordsWithIntegerInputHitsDefaultCase() {
    let result = PhotosAssetMetadata._parseKeywordsForTesting(42 as Int)
    #expect(result.isEmpty)
}

/// `_parseKeywordsForTesting` with a `Double` value also hits the `default` case.
@Test
func photosAssetMetadataParseKeywordsWithDoubleInputHitsDefaultCase() {
    let result = PhotosAssetMetadata._parseKeywordsForTesting(3.14 as Double)
    #expect(result.isEmpty)
}

/// `_parseKeywordsForTesting` with an array that contains no `String` elements —
/// only `Int` values — must return an empty array because `compactMap { $0 as? String }`
/// produces nothing.
@Test
func photosAssetMetadataParseKeywordsArrayOfNonStringsReturnsEmpty() {
    let result = PhotosAssetMetadata._parseKeywordsForTesting([1, 2, 3] as [Any])
    #expect(result.isEmpty)
}

/// `_parseKeywordsForTesting` with a mixed array must keep only the `String` elements.
@Test
func photosAssetMetadataParseKeywordsArrayWithMixedTypesKeepsOnlyStrings() {
    let result = PhotosAssetMetadata._parseKeywordsForTesting(["nature", 99, "travel"] as [Any])
    #expect(result == ["nature", "travel"])
}

/// `_parseKeywordsForTesting` with a comma-and-semicolon-delimited `String` that
/// has duplicate tokens after trimming and lowercasing must deduplicate correctly.
@Test
func photosAssetMetadataParseKeywordsStringWithDuplicatesDeduplicates() {
    let result = PhotosAssetMetadata._parseKeywordsForTesting("Alpha;alpha ; ALPHA, Beta")
    // "Alpha", "alpha", "ALPHA" all lowercase to "alpha" — first occurrence wins.
    #expect(result.first == "Alpha")
    #expect(result.count == 2)
    #expect(result.contains("Beta"))
}

/// `extractEXIF` with JPEG data that contains an empty EXIF dictionary (no keys)
/// must return a default `EXIF` struct with all optional fields nil and keywords empty.
@Test
func photosAssetMetadataExtractEXIFHandlesEmptySubdictionaries() throws {
    let properties: [CFString: Any] = [
        kCGImagePropertyTIFFDictionary: [CFString: Any](),
        kCGImagePropertyExifDictionary: [CFString: Any](),
        kCGImagePropertyIPTCDictionary: [CFString: Any](),
        kCGImagePropertyGPSDictionary: [CFString: Any]()
    ]

    let data = try makeJPEGData(with: properties)
    let exif = PhotosAssetMetadata._extractEXIFForTesting(from: data)

    #expect(exif.cameraMake == nil)
    #expect(exif.cameraModel == nil)
    #expect(exif.lensModel == nil)
    #expect(exif.orientation == nil)
    #expect(exif.dateTimeOriginalMs == nil)
    #expect(exif.gpsLatitude == nil)
    #expect(exif.gpsLongitude == nil)
    #expect(exif.keywords.isEmpty)
}

/// `extractEXIF` with a GPS dictionary that has only the latitude fields (no longitude)
/// must populate `gpsLatitude` but leave `gpsLongitude` nil.
@Test
func photosAssetMetadataExtractEXIFLatitudeOnlyLeavesLongitudeNil() throws {
    let properties: [CFString: Any] = [
        kCGImagePropertyGPSDictionary: [
            kCGImagePropertyGPSLatitude: 51.5,
            kCGImagePropertyGPSLatitudeRef: "N"
        ]
    ]

    let data = try makeJPEGData(with: properties)
    let exif = PhotosAssetMetadata._extractEXIFForTesting(from: data)

    #expect(exif.gpsLatitude == 51.5)
    #expect(exif.gpsLongitude == nil)
}

/// `_parseEXIFDateTimeMsForTesting` with the epoch string "1970:01:01 00:00:00"
/// must return 0 (the Unix epoch in milliseconds), not nil.
@Test
func photosAssetMetadataParseEXIFDateTimeEpochReturnsZero() {
    let result = PhotosAssetMetadata._parseEXIFDateTimeMsForTesting("1970:01:01 00:00:00")
    #expect(result == 0)
}

/// `_parseEXIFDateTimeMsForTesting` with a string that has the correct format but an
/// impossible date (month 13) must return nil — the `DateFormatter` will not parse it.
@Test
func photosAssetMetadataParseEXIFDateTimeImpossibleDateReturnsNil() {
    // Month 13 is invalid.
    let result = PhotosAssetMetadata._parseEXIFDateTimeMsForTesting("2024:13:01 00:00:00")
    #expect(result == nil)
}

/// `_parseEXIFDateTimeMsForTesting` with an empty string must return nil.
@Test
func photosAssetMetadataParseEXIFDateTimeEmptyStringReturnsNil() {
    let result = PhotosAssetMetadata._parseEXIFDateTimeMsForTesting("")
    #expect(result == nil)
}

/// `_parseEXIFDateTimeMsForTesting` round-trips a known timestamp correctly:
/// "2020:06:15 12:30:45" → a specific millisecond value that matches a manually
/// constructed `DateComponents` in UTC.
@Test
func photosAssetMetadataParseEXIFDateTimeKnownValueRoundTrips() {
    // 2020-06-15T12:30:45Z  →  1592224245000 ms
    var comps = DateComponents()
    comps.calendar = Calendar(identifier: .gregorian)
    comps.timeZone = TimeZone(secondsFromGMT: 0)
    comps.year = 2020
    comps.month = 6
    comps.day = 15
    comps.hour = 12
    comps.minute = 30
    comps.second = 45

    guard let date = comps.date else {
        Issue.record("DateComponents.date returned nil — test environment issue")
        return
    }
    let expectedMs = Int64(date.timeIntervalSince1970 * 1000)
    let result = PhotosAssetMetadata._parseEXIFDateTimeMsForTesting("2020:06:15 12:30:45")
    #expect(result == expectedMs)
}

#if canImport(Vision)
@Test
func visionOCRProviderInitializerAndExecutionModeAreStable() {
    let accurate = VisionOCRProvider()
    #expect(accurate.accuracy == .accurate)
    #expect(accurate.usesLanguageCorrection)
    #expect(accurate.executionMode == .onDeviceOnly)

    let fast = VisionOCRProvider(accuracy: .fast, usesLanguageCorrection: false)
    #expect(fast.accuracy == .fast)
    #expect(!fast.usesLanguageCorrection)
}

@Test
func visionOCRProviderRecognizeTextOnBlankImageReturnsValidBlocks() async throws {
    let image = try makeTestImage()

    let accurate = VisionOCRProvider(accuracy: .accurate, usesLanguageCorrection: true)
    let fast = VisionOCRProvider(accuracy: .fast, usesLanguageCorrection: false)

    let accurateBlocks = try await accurate.recognizeText(in: image)
    let fastBlocks = try await fast.recognizeText(in: image)

    for block in accurateBlocks + fastBlocks {
        #expect(!block.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
        #expect(block.bbox.width >= 0)
        #expect(block.bbox.height >= 0)
    }
}
#endif
