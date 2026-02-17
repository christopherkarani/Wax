import Foundation

public enum VideoFrameKind: String, Sendable, CaseIterable {
    case root = "video.root"
    case segment = "video.segment"
}
