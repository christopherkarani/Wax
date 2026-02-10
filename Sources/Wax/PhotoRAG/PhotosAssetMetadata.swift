import Foundation
import ImageIO
import os

#if canImport(Photos)
@preconcurrency import Photos
#endif

#if canImport(CoreLocation)
import CoreLocation
#endif

enum PhotosAssetMetadata {
    private static let photosRequestTimeout: Duration = .seconds(10)

    struct EXIF: Sendable {
        var cameraMake: String?
        var cameraModel: String?
        var lensModel: String?
        var orientation: Int?
        var dateTimeOriginalMs: Int64?
        var gpsLatitude: Double?
        var gpsLongitude: Double?
    }

    struct Location: Sendable {
        var latitude: Double
        var longitude: Double
        var horizontalAccuracyMeters: Double?
    }

    struct Record: Sendable {
        var assetID: String
        var creationDateMs: Int64?
        var captureMs: Int64?
        var location: Location?
        var isFavorite: Bool
        var pixelWidth: Int
        var pixelHeight: Int
        var isLocal: Bool
        var imageData: Data?
        var exif: EXIF
    }

    @MainActor
    static func load(assetID: String) async throws -> Record {
        #if canImport(Photos)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else {
            throw WaxError.io("PHAsset not found for id: \(assetID)")
        }

        let (data, isLocal) = try await requestImageData(asset: asset)

        let exif = Self.extractEXIF(from: data)

        let creationMs = asset.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        let captureMs = exif.dateTimeOriginalMs ?? creationMs

        let location: Location? = asset.location.map { loc in
            Location(
                latitude: loc.coordinate.latitude,
                longitude: loc.coordinate.longitude,
                horizontalAccuracyMeters: loc.horizontalAccuracy >= 0 ? loc.horizontalAccuracy : nil
            )
        } ?? {
            if let lat = exif.gpsLatitude, let lon = exif.gpsLongitude {
                return Location(latitude: lat, longitude: lon, horizontalAccuracyMeters: nil)
            }
            return nil
        }()

        return Record(
            assetID: asset.localIdentifier,
            creationDateMs: creationMs,
            captureMs: captureMs,
            location: location,
            isFavorite: asset.isFavorite,
            pixelWidth: asset.pixelWidth,
            pixelHeight: asset.pixelHeight,
            isLocal: isLocal,
            imageData: data,
            exif: exif
        )
        #else
        throw WaxError.io("Photos framework unavailable on this platform")
        #endif
    }

    @MainActor
    static func loadImageData(assetID: String) async throws -> Data? {
        #if canImport(Photos)
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else { return nil }
        let (data, isLocal) = try await requestImageData(asset: asset)
        return isLocal ? data : nil
        #else
        return nil
        #endif
    }

    #if canImport(Photos)
    @MainActor
    private static func requestImageData(asset: PHAsset) async throws -> (data: Data?, isLocal: Bool) {
        let options = PHImageRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.version = .current

        let result = try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<(data: Data?, isLocal: Bool), Error>) in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let manager = PHImageManager.default()
            var requestID: PHImageRequestID = PHInvalidImageRequestID

            requestID = manager.requestImageDataAndOrientation(for: asset, options: options) { data, _, _, info in
                guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }

                let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                let error = info?[PHImageErrorKey] as? NSError

                if cancelled {
                    continuation.resume(returning: (data: nil, isLocal: false))
                    return
                }
                if let error {
                    // Treat as unavailable offline.
                    continuation.resume(returning: (data: nil, isLocal: false))
                    _ = error
                    return
                }
                guard let data, !inCloud else {
                    continuation.resume(returning: (data: nil, isLocal: false))
                    return
                }
                continuation.resume(returning: (data: data, isLocal: true))
            }

            Task { @MainActor in
                try? await Task.sleep(for: photosRequestTimeout)
                guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }
                if requestID != PHInvalidImageRequestID {
                    manager.cancelImageRequest(requestID)
                }
                continuation.resume(returning: (data: nil, isLocal: false))
            }
        }

        // Yield MainActor after heavy I/O to give UI work a chance to run
        await Task.yield()

        return result
    }
    #endif

    private static func extractEXIF(from data: Data?) -> EXIF {
        guard let data else { return EXIF() }
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return EXIF() }
        guard let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] else {
            return EXIF()
        }

        var out = EXIF()

        if let tiff = props[kCGImagePropertyTIFFDictionary] as? [CFString: Any] {
            out.cameraMake = tiff[kCGImagePropertyTIFFMake] as? String
            out.cameraModel = tiff[kCGImagePropertyTIFFModel] as? String
        }
        if let exif = props[kCGImagePropertyExifDictionary] as? [CFString: Any] {
            out.lensModel = exif[kCGImagePropertyExifLensModel] as? String

            if let dateString = exif[kCGImagePropertyExifDateTimeOriginal] as? String {
                out.dateTimeOriginalMs = Self.parseEXIFDateTimeMs(dateString)
            }
        }

        if let orientation = props[kCGImagePropertyOrientation] as? Int {
            out.orientation = orientation
        }

        if let gps = props[kCGImagePropertyGPSDictionary] as? [CFString: Any] {
            if let lat = gps[kCGImagePropertyGPSLatitude] as? Double {
                let ref = (gps[kCGImagePropertyGPSLatitudeRef] as? String) ?? "N"
                out.gpsLatitude = (ref == "S") ? -abs(lat) : abs(lat)
            }
            if let lon = gps[kCGImagePropertyGPSLongitude] as? Double {
                let ref = (gps[kCGImagePropertyGPSLongitudeRef] as? String) ?? "E"
                out.gpsLongitude = (ref == "W") ? -abs(lon) : abs(lon)
            }
        }

        return out
    }

    private static let exifDateFormatter: DateFormatter = {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = TimeZone(secondsFromGMT: 0)
        f.dateFormat = "yyyy:MM:dd HH:mm:ss"
        return f
    }()

    private static func parseEXIFDateTimeMs(_ value: String) -> Int64? {
        if let date = exifDateFormatter.date(from: value) {
            return Int64(date.timeIntervalSince1970 * 1000)
        }
        return nil
    }
}
