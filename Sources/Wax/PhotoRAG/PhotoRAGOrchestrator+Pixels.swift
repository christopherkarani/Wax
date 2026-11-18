#if canImport(ImageIO)
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers
import WaxCore
import WaxVectorSearch

#if canImport(Photos)
@preconcurrency import Photos
#endif

#if canImport(CoreLocation)
import CoreLocation
#endif

extension PhotoRAGOrchestrator {
    // MARK: - Pixels (thumbnails + crops)

    func attachPixels(
        items: [PhotoRAGItem],
        rootCandidates: [RootCandidate],
        maxImages: Int,
        maxRegions: Int
    ) async throws -> [PhotoRAGItem] {
        guard (!items.isEmpty) else { return items }
        guard config.includeThumbnailsInContext || config.includeRegionCropsInContext else { return items }
        guard maxImages > 0 || maxRegions > 0 else { return items }

        var updated = items

        // Thumbnails for the first N items.
        let thumbCount = min(maxImages, updated.count)
        if config.includeThumbnailsInContext, thumbCount > 0 {
            for index in 0..<thumbCount {
                let photoID = updated[index].photoID
                if let pixel = try await loadThumbnail(photoID: photoID) {
                    updated[index].thumbnail = pixel
                }
            }
        }

        // Region crops: take the highest-scoring matched regions first.
        if config.includeRegionCropsInContext, maxRegions > 0 {
            var remaining = maxRegions
            for index in 0..<updated.count where remaining > 0 {
                let photoID = updated[index].photoID
                guard let rootId = indexStateRootId(for: photoID) else { continue }
                let matched = rootCandidates.first(where: { $0.rootId == rootId })?.matchedRegions ?? []
                guard !matched.isEmpty else { continue }

                let source = try await loadRegionSourceImage(photoID: photoID)
                guard let source else { continue }

                var regions: [PhotoRAGItem.RegionContext] = []
                for rect in matched where remaining > 0 {
                    guard let crop = Self.crop(source, rect: rect) else { continue }
                    if let encoded = try? Self.encodePNG(crop) {
                        let pixel = PhotoPixel(data: encoded, format: .png, width: crop.width, height: crop.height)
                        regions.append(.init(bbox: rect, crop: pixel))
                    } else {
                        regions.append(.init(bbox: rect, crop: nil))
                    }
                    remaining -= 1
                }

                if !regions.isEmpty {
                    updated[index].regions = regions
                }
            }
        }

        return updated
    }

    private func loadThumbnail(photoID: PhotoID) async throws -> PhotoPixel? {
        if let data = try await localFileImageData(photoID: photoID) {
            do {
                let thumb = try Self.decodeThumbnail(from: data, maxPixelSize: config.thumbnailMaxPixelSize)
                let encoded = try Self.encodePNG(thumb)
                return PhotoPixel(data: encoded, format: .png, width: thumb.width, height: thumb.height)
            } catch {
                return nil
            }
        }

        #if canImport(Photos)
        let data = try await PhotosAssetMetadata.loadImageData(photoID: photoID)
        guard let data else { return nil }
        let thumb = try Self.decodeThumbnail(from: data, maxPixelSize: config.thumbnailMaxPixelSize)
        let encoded = try Self.encodePNG(thumb)
        return PhotoPixel(data: encoded, format: .png, width: thumb.width, height: thumb.height)
        #else
        return nil
        #endif
    }

    private func loadRegionSourceImage(photoID: PhotoID) async throws -> CGImage? {
        if let data = try await localFileImageData(photoID: photoID) {
            do {
                return try Self.decodeThumbnail(from: data, maxPixelSize: config.regionCropMaxPixelSize)
            } catch {
                return nil
            }
        }

        #if canImport(Photos)
        let data = try await PhotosAssetMetadata.loadImageData(photoID: photoID)
        guard let data else { return nil }
        return try Self.decodeThumbnail(from: data, maxPixelSize: config.regionCropMaxPixelSize)
        #else
        return nil
        #endif
    }

    private func localFileImageData(photoID: PhotoID) async throws -> Data? {
        guard let rootId = index.rootByPhotoID[photoID] else { return nil }
        let metas = await wax.frameMetasIncludingPending(frameIds: [rootId])
        guard let meta = metas[rootId],
              meta.metadata?.entries[MetaKey.source] == "file",
              let urlString = meta.metadata?.entries[MetaKey.fileURL],
              let url = URL(string: urlString),
              url.isFileURL
        else {
            return nil
        }
        do {
            return try Data(contentsOf: url)
        } catch {
            return nil
        }
    }

    struct ProposedRegion {
        var bbox: PhotoNormalizedRect
        var type: String
    }

    static func proposeRegions(from ocr: [RecognizedTextBlock], maxRegions: Int) -> [ProposedRegion] {
        guard maxRegions > 0 else { return [] }
        if !ocr.isEmpty {
            let sorted = ocr.sorted { $0.confidence > $1.confidence }
            return sorted.prefix(maxRegions).map { ProposedRegion(bbox: $0.bbox, type: "ocr") }
        }

        // Fallback 2x2 grid.
        let grid: [ProposedRegion] = [
            .init(bbox: .init(x: 0.0, y: 0.0, width: 0.5, height: 0.5), type: "grid"),
            .init(bbox: .init(x: 0.5, y: 0.0, width: 0.5, height: 0.5), type: "grid"),
            .init(bbox: .init(x: 0.0, y: 0.5, width: 0.5, height: 0.5), type: "grid"),
            .init(bbox: .init(x: 0.5, y: 0.5, width: 0.5, height: 0.5), type: "grid"),
        ]
        return Array(grid.prefix(maxRegions))
    }

    static func writeBBox(into meta: inout Metadata, rect: PhotoNormalizedRect) {
        meta.entries[MetaKey.bboxX] = String(rect.x)
        meta.entries[MetaKey.bboxY] = String(rect.y)
        meta.entries[MetaKey.bboxW] = String(rect.width)
        meta.entries[MetaKey.bboxH] = String(rect.height)
    }

    static func crop(_ image: CGImage, rect: PhotoNormalizedRect) -> CGImage? {
        let w = Double(image.width)
        let h = Double(image.height)
        let x = max(0, min(w, rect.x * w))
        let y = max(0, min(h, rect.y * h))
        let cw = max(1, min(w - x, rect.width * w))
        let ch = max(1, min(h - y, rect.height * h))
        let cropRect = CGRect(x: x.rounded(.down), y: y.rounded(.down), width: cw.rounded(.down), height: ch.rounded(.down))
        return image.cropping(to: cropRect)
    }

    static func decodeThumbnail(from data: Data, maxPixelSize: Int) throws -> CGImage {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else {
            throw WaxError.io("failed to create image source")
        }

        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, maxPixelSize),
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else {
            throw WaxError.io("failed to decode thumbnail")
        }
        return image
    }

    static func imagePixelDimensions(from data: Data) -> (width: Int, height: Int)? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil),
              let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
        else { return nil }
        guard let width = props[kCGImagePropertyPixelWidth] as? Int,
              let height = props[kCGImagePropertyPixelHeight] as? Int,
              width > 0,
              height > 0
        else { return nil }
        return (width, height)
    }

    private static func encodePNG(_ image: CGImage) throws -> Data {
        let data = NSMutableData()
        guard let dest = CGImageDestinationCreateWithData(data as CFMutableData, UTType.png.identifier as CFString, 1, nil) else {
            throw WaxError.io("failed to create image destination")
        }
        CGImageDestinationAddImage(dest, image, nil)
        guard CGImageDestinationFinalize(dest) else {
            throw WaxError.io("failed to encode png")
        }
        return data as Data
    }
}

#endif // canImport(ImageIO)
