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
    static func buildSummaryText(
        root: FrameMeta?,
        caption: String?,
        ocrSummary: String?,
        tags: String?,
        query: PhotoQuery,
        maxOCRLines: Int
    ) -> String {
        var parts: [String] = []
        parts.reserveCapacity(6)

        if let caption, !caption.isEmpty {
            parts.append("Caption: \(caption)")
        }

        if let ocrSummary, !ocrSummary.isEmpty {
            let lines = ocrSummary
                .split(separator: "\n", omittingEmptySubsequences: true)
                .prefix(max(0, maxOCRLines))
                .map(String.init)
            if !lines.isEmpty {
                parts.append("OCR:\n" + lines.joined(separator: "\n"))
            }
        }

        if let tags, !tags.isEmpty {
            parts.append("Tags:\n" + tags)
        }

        if let root, let entries = root.metadata?.entries {
            if let ms = Int64(entries[MetaKey.captureMs] ?? "") {
                let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
                parts.append("Captured: \(date.formatted(.iso8601))")
            }
            if let lat = entries[MetaKey.lat], let lon = entries[MetaKey.lon] {
                parts.append("Location: \(lat),\(lon)")
            }
            if let model = entries[MetaKey.cameraModel] {
                parts.append("Camera: \(model)")
            }
        }

        if parts.isEmpty {
            // Deterministic fallback
            if let q = query.text, !q.isEmpty {
                return "Photo context (no extracted text). Query: \(q)"
            }
            return "Photo context (no extracted text)."
        }

        return parts.joined(separator: "\n\n")
    }

    static func buildOCRSummary(_ blocks: [RecognizedTextBlock], maxLines: Int) -> String {
        guard maxLines > 0 else { return "" }
        var seen: Set<String> = []
        var out: [String] = []
        out.reserveCapacity(min(maxLines, blocks.count))

        let sorted = blocks.sorted { a, b in
            if a.confidence != b.confidence { return a.confidence > b.confidence }
            return a.text.count > b.text.count
        }

        for block in sorted {
            let t = block.text.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !t.isEmpty else { continue }
            guard seen.insert(t).inserted else { continue }
            out.append(t)
            if out.count >= maxLines { break }
        }
        return out.joined(separator: "\n")
    }

    static func weakCaption(metadata: PhotosAssetMetadata.Record, ocrBlocks: [RecognizedTextBlock]) -> String {
        var parts: [String] = []
        parts.reserveCapacity(4)

        if let ms = metadata.captureMs {
            let date = Date(timeIntervalSince1970: TimeInterval(ms) / 1000)
            parts.append("Captured \(date.formatted(.iso8601))")
        }
        if let loc = metadata.location {
            parts.append(String(format: "Near %.5f, %.5f", loc.latitude, loc.longitude))
        }
        if let model = metadata.exif.cameraModel {
            parts.append("Camera \(model)")
        }
        if let top = ocrBlocks.first?.text, !top.isEmpty {
            parts.append("Text: \(top)")
        }
        return parts.joined(separator: " • ")
    }

    static func buildPhotoTags(from metadata: PhotosAssetMetadata.Record, captionText: String?) -> String? {
        var tags: [String] = []
        tags.reserveCapacity(16)
        var seen: Set<String> = []

        for keyword in metadata.exif.keywords {
            let normalized = keyword.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !normalized.isEmpty else { continue }
            let key = normalized.lowercased()
            guard seen.insert(key).inserted else { continue }
            tags.append(normalized)
        }

        if tags.isEmpty, let captionText {
            let splitCaption = captionText
                .split { $0.isWhitespace || $0 == "," || $0 == "." || $0 == ";" || $0 == "|" || $0 == "-" }
                .map { String($0).trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty && $0.count >= 3 }
            for token in splitCaption {
                let normalized = token.lowercased()
                if seen.insert(normalized).inserted {
                    tags.append(token)
                }
                if tags.count >= 16 { break }
            }
        }

        guard !tags.isEmpty else { return nil }
        return tags.joined(separator: ", ")
    }

    static func baseMetadata(
        photoID: PhotoID,
        captureMs: Int64?,
        pipelineVersion: String,
        isLocal: Bool,
        location: PhotosAssetMetadata.Location?,
        pixelWidth: Int,
        pixelHeight: Int,
        exif: PhotosAssetMetadata.EXIF,
        fileURL: URL? = nil
    ) -> Metadata {
        var meta = Metadata()
        meta.entries[MetaKey.assetID] = photoID.id
        meta.entries[MetaKey.source] = photoID.metadataSource
        if let fileURL {
            meta.entries[MetaKey.fileURL] = fileURL.absoluteString
        }
        if let captureMs {
            meta.entries[MetaKey.captureMs] = String(captureMs)
        }
        meta.entries[MetaKey.pipelineVersion] = pipelineVersion
        meta.entries[MetaKey.width] = String(pixelWidth)
        meta.entries[MetaKey.height] = String(pixelHeight)
        meta.entries[MetaKey.isLocal] = isLocal ? "true" : "false"

        if let location {
            meta.entries[MetaKey.lat] = String(location.latitude)
            meta.entries[MetaKey.lon] = String(location.longitude)
            if let accuracy = location.horizontalAccuracyMeters {
                meta.entries[MetaKey.gpsAccuracyM] = String(accuracy)
            }
        }

        if let make = exif.cameraMake { meta.entries[MetaKey.cameraMake] = make }
        if let model = exif.cameraModel { meta.entries[MetaKey.cameraModel] = model }
        if let lens = exif.lensModel { meta.entries[MetaKey.lensModel] = lens }
        if let orientation = exif.orientation { meta.entries[MetaKey.orientation] = String(orientation) }

        return meta
    }
}

#endif // canImport(ImageIO)
