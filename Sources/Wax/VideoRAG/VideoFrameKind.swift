import Foundation

package enum VideoFrameKind: String, Sendable, CaseIterable {
    case root = "video.root"
    case segment = "video.segment"
}
