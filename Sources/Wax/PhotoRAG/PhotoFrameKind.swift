import Foundation

public enum PhotoFrameKind: String, Sendable, CaseIterable {
    case root = "photo.root"
    case ocrBlock = "photo.ocr.block"
    case ocrSummary = "photo.ocr.summary"
    case captionShort = "photo.caption.short"
    case tags = "photo.tags"
    case region = "photo.region"
    case syncState = "system.photos.sync_state"
}
