import Foundation

public enum PhotoMetadataKey: String, Sendable, CaseIterable {
    case assetID = "photos.asset_id"
    case captureMs = "photo.capture_ms"
    case isLocal = "photo.availability.local"
    case pipelineVersion = "photo.pipeline.version"

    case lat = "photo.location.lat"
    case lon = "photo.location.lon"
    case gpsAccuracyM = "photo.location.accuracy_m"

    case cameraMake = "photo.camera.make"
    case cameraModel = "photo.camera.model"
    case lensModel = "photo.lens"

    case width = "photo.width"
    case height = "photo.height"
    case orientation = "photo.orientation"

    case bboxX = "photo.bbox.x"
    case bboxY = "photo.bbox.y"
    case bboxW = "photo.bbox.w"
    case bboxH = "photo.bbox.h"
    case regionType = "photo.region.type"
}
