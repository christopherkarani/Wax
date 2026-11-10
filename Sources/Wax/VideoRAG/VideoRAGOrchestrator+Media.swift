#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WaxCore
import WaxVectorSearch
import os

#if canImport(AVFoundation)
import AVFoundation
#endif

#if canImport(Photos)
@preconcurrency import Photos
#endif

extension VideoRAGOrchestrator {
    // MARK: - Media helpers

    #if canImport(AVFoundation)
    func buildKeyframes(url: URL) async throws -> (durationMs: Int64, keyframes: [CGImage]) {
        let asset = AVURLAsset(url: url)
        let duration: CMTime
        do {
            duration = try await asset.load(.duration)
        } catch {
            // AVFoundation throws untyped NSErrors for undecodable files; map to
            // the typed ingest error so callers can handle malformed media uniformly.
            throw VideoIngestError.invalidVideo(reason: "unreadable video file: \(error.localizedDescription)")
        }
        let durationMs = try Self.durationMilliseconds(from: duration)

        let segments = Self.makeSegments(
            durationMs: durationMs,
            segmentDurationSeconds: config.segmentDurationSeconds,
            segmentOverlapSeconds: config.segmentOverlapSeconds,
            maxSegments: config.maxSegmentsPerVideo
        )
        let times = segments.map { CMTime(seconds: Double($0.midMs) / 1000.0, preferredTimescale: 600) }

        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: config.embedMaxPixelSize, height: config.embedMaxPixelSize)
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol

        var images: [CGImage] = []
        images.reserveCapacity(times.count)
        for time in times {
            let cg = try await cgImage(generator: generator, for: time)
            images.append(cg)
        }

        return (durationMs: durationMs, keyframes: images)
    }

    /// Converts an asset duration to whole milliseconds. An invalid, indefinite, infinite or
    /// out-of-range duration is reported as an unreadable video instead of trapping.
    static func durationMilliseconds(from duration: CMTime) throws -> Int64 {
        guard duration.isNumeric else {
            throw VideoIngestError.invalidVideo(reason: "unreadable video file: duration is not numeric")
        }
        let milliseconds = duration.seconds * 1000
        guard milliseconds.isFinite, milliseconds < Double(Int64.max) else {
            throw VideoIngestError.invalidVideo(reason: "unreadable video file: duration is out of range")
        }
        guard milliseconds >= 1 else {
            throw VideoIngestError.invalidVideo(reason: "duration must be > 0")
        }
        return Int64(milliseconds)
    }
    #else
    func buildKeyframes(url: URL) async throws -> (durationMs: Int64, keyframes: [CGImage]) {
        _ = url
        throw VideoIngestError.unsupportedPlatform(reason: "AVFoundation is unavailable on this platform")
    }
    #endif

    #if canImport(Photos)
    struct PhotosVideoRecord: Sendable {
        var captureMs: Int64?
        var durationMs: Int64
        var isLocal: Bool
        var localFileURL: URL?
    }

    @MainActor
    static func loadPhotosVideo(assetID: String) async throws -> PhotosVideoRecord {
        let assets = PHAsset.fetchAssets(withLocalIdentifiers: [assetID], options: nil)
        guard let asset = assets.firstObject else {
            throw WaxError.io("PHAsset not found for id: \(assetID)")
        }

        let captureMs = asset.creationDate.map { Int64($0.timeIntervalSince1970 * 1000) }
        let durationMs = Int64(asset.duration * 1000)

        let options = PHVideoRequestOptions()
        options.isNetworkAccessAllowed = false
        options.deliveryMode = .highQualityFormat
        options.version = .current

        return try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            let manager = PHImageManager.default()
            var requestID: PHImageRequestID = PHInvalidImageRequestID

            requestID = manager.requestAVAsset(forVideo: asset, options: options) { avAsset, _, info in
                guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }

                let inCloud = (info?[PHImageResultIsInCloudKey] as? NSNumber)?.boolValue ?? false
                let cancelled = (info?[PHImageCancelledKey] as? NSNumber)?.boolValue ?? false
                let error = info?[PHImageErrorKey] as? NSError

                if cancelled || inCloud || error != nil || avAsset == nil {
                    continuation.resume(
                        returning: PhotosVideoRecord(
                            captureMs: captureMs,
                            durationMs: durationMs,
                            isLocal: false,
                            localFileURL: nil
                        )
                    )
                    return
                }

                let url = (avAsset as? AVURLAsset)?.url
                continuation.resume(
                    returning: PhotosVideoRecord(
                        captureMs: captureMs,
                        durationMs: durationMs,
                        isLocal: (url != nil),
                        localFileURL: url
                    )
                )
            }

            Task { @MainActor in
                try? await Task.sleep(for: photosVideoRequestTimeout)
                guard resumed.withLock({ let was = $0; $0 = true; return !was }) else { return }
                if requestID != PHInvalidImageRequestID {
                    manager.cancelImageRequest(requestID)
                }
                continuation.resume(
                    returning: PhotosVideoRecord(
                        captureMs: captureMs,
                        durationMs: durationMs,
                        isLocal: false,
                        localFileURL: nil
                    )
                )
            }
        }
    }
    #endif

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw WaxError.io("failed to create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WaxError.io("failed to encode PNG")
        }
        return data as Data
    }

    func attachThumbnailsIfNeeded(
        items: [VideoRAGItem],
        rootMetaById: [UInt64: FrameMeta],
        maxThumbnails: Int
    ) async throws -> [VideoRAGItem] {
        guard config.includeThumbnailsInContext else { return items }
        guard maxThumbnails > 0 else { return items }
        guard !items.isEmpty else { return items }

        var updated = items
        var remaining = maxThumbnails

        for itemIndex in updated.indices where remaining > 0 {
            // Only file-backed videos have a stable file URL in v1.
            let videoID = updated[itemIndex].videoID
            guard let rootId = index.rootByVideoID[videoID],
                  let rootMeta = rootMetaById[rootId],
                  let fileURLString = rootMeta.metadata?.entries[MetaKey.fileURL],
                  let url = URL(string: fileURLString)
            else { continue }

            // Attach thumbnails to the first N segments, in existing order.
            for segIndex in updated[itemIndex].segments.indices where remaining > 0 {
                let startMs = updated[itemIndex].segments[segIndex].startMs
                let endMs = updated[itemIndex].segments[segIndex].endMs
                let midMs = (startMs + endMs) / 2

                do {
                    let thumb = try await keyframeThumbnail(url: url, midMs: midMs)
                    updated[itemIndex].segments[segIndex].thumbnail = thumb
                    remaining -= 1
                } catch {
                    WaxDiagnostics.logSwallowed(
                        error,
                        context: "video thumbnail extraction",
                        fallback: "skip thumbnail for this segment"
                    )
                }
            }
        }

        return updated
    }

    #if canImport(AVFoundation)
    private func keyframeThumbnail(url: URL, midMs: Int64) async throws -> VideoThumbnail {
        let asset = AVURLAsset(url: url)
        let generator = AVAssetImageGenerator(asset: asset)
        generator.appliesPreferredTrackTransform = true
        generator.maximumSize = CGSize(width: config.thumbnailMaxPixelSize, height: config.thumbnailMaxPixelSize)
        let tol = CMTime(seconds: 0.1, preferredTimescale: 600)
        generator.requestedTimeToleranceBefore = tol
        generator.requestedTimeToleranceAfter = tol
        let time = CMTime(seconds: Double(midMs) / 1000.0, preferredTimescale: 600)

        let cg = try await cgImage(generator: generator, for: time)

        let png = try Self.encodePNG(cg)
        return VideoThumbnail(data: png, format: .png, width: cg.width, height: cg.height)
    }
    #else
    private func keyframeThumbnail(url: URL, midMs: Int64) async throws -> VideoThumbnail {
        _ = url
        _ = midMs
        throw VideoIngestError.unsupportedPlatform(reason: "AVFoundation is unavailable on this platform")
    }
    #endif

    private func cgImage(generator: AVAssetImageGenerator, for time: CMTime) async throws -> CGImage {
        try await withCheckedThrowingContinuation { continuation in
            let resumed = OSAllocatedUnfairLock(initialState: false)
            generator.generateCGImagesAsynchronously(forTimes: [NSValue(time: time)]) {
                _, image, _, result, error in
                guard resumed.withLock({ state in
                    defer { state = true }
                    return !state
                }) else { return }
                switch result {
                case .succeeded:
                    if let image {
                        continuation.resume(returning: image)
                    } else {
                        continuation.resume(throwing: WaxError.io("Video frame generation returned no image"))
                    }
                case .cancelled:
                    continuation.resume(throwing: WaxError.io("Video keyframe generation was cancelled"))
                case .failed:
                    continuation.resume(throwing: error ?? WaxError.io("Video keyframe generation failed"))
                @unknown default:
                    continuation.resume(throwing: WaxError.io("Video keyframe generation failed"))
                }
            }
        }
    }
}

#endif // canImport(ImageIO)
